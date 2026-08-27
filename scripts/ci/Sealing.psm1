#Requires -Version 7.0

<#
.SYNOPSIS
    The host-side sealing phase: confirm, consume, clear, convert, name.

.DESCRIPTION
    Increment 3 stage 6, governed by ADR 8. This runs after Packer exits, on the
    host, because conversion cannot be a Packer setting: convert_to_template is
    static configuration and cannot be conditional, so inside the build it would
    convert whatever the build produced.

    Every platform interaction is injected, so the whole sequence and all of its
    refusals run with no vSphere anywhere near the machine executing the tests.
    The production adapter does not exist yet, and nothing here has been
    exercised against a real platform.

    Two properties this file exists to hold:

    Failure to clear the attestation key blocks conversion. A template that
    inherited a previous build's attestation would hand every clone evidence
    about a machine it is not, which is worse than no evidence -- so clearing is
    verified by re-reading, and a clear that cannot be confirmed stops the seal
    before the artifact becomes immutable.

    Any ambiguity after conversion produces an unconfirmed artifact rather than a
    candidate. Once conversion has been attempted something may exist, and the
    honest record of that is the one field that carries what may exist without
    naming it as accepted.
#>

Set-StrictMode -Version 3.0

Import-Module (Join-Path $PSScriptRoot '..' '..' 'source-qualification' 'scripts' 'RunIdentity.psm1')
Import-Module (Join-Path $PSScriptRoot '..' '..' 'source-qualification' 'scripts' 'Finalization.psm1')

function Invoke-CandidateSealing {
    <#
    .SYNOPSIS
        Turns a powered-off, finalized build VM into a named sealed candidate.

    .PARAMETER Adapter
        ResolveVirtualMachine, GetPowerState, ReadGuestInfo, ClearGuestInfo,
        ConvertToTemplate, and GetArtifactIdentity. All injected.

    .OUTPUTS
        The build state, the artifact identity when there is one, the
        unconfirmed artifact when there may be one, and a bounded reason.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([PSCustomObject])]
    param(
        [Parameter(Mandatory)] [ValidateNotNullOrEmpty()] [string] $RunId,
        [Parameter(Mandatory)] [ValidatePattern('^[0-9a-f]{32}$')] [string] $Nonce,
        [Parameter(Mandatory)] [ValidateNotNullOrEmpty()] [string] $CandidateName,
        [Parameter(Mandatory)] [bool] $PackerSucceeded,
        [Parameter(Mandatory)] [hashtable] $Adapter
    )

    $validatedRunId = Assert-RunIdentifier -RunId $RunId

    # 1. Packer must have finished. A build that failed produced a machine in
    #    whatever state it failed in, and sealing it would make that permanent.
    if (-not $PackerSucceeded) { return Refused -State 'pre-seal' -Reason 'construction_failed' }

    # 2. Resolve the VM by run identity, not by name alone. A name is mutable
    #    and can be reused, so sealing the object that merely answers to it is
    #    how one build's artifact acquires another build's provenance.
    $machine = $null
    try { $machine = & $Adapter['ResolveVirtualMachine'] $validatedRunId $CandidateName }
    catch { $machine = $null }
    if (-not $machine) { return Refused -State 'pre-seal' -Reason 'vm_not_resolved' }

    # 3. Powered off, observed through the platform. A guest command that says
    #    it will shut down is not a shutdown that happened.
    $power = $null
    try { $power = [string](& $Adapter['GetPowerState'] $machine) } catch { $power = $null }
    if ($power -ne 'poweredOff') { return Refused -State 'pre-seal' -Reason 'vm_not_powered_off' }

    # 4. The attestation, validated against this run and this run's nonce.
    $raw = $null
    try { $raw = [string](& $Adapter['ReadGuestInfo'] $machine (Get-FinalizationAttestationKey)) }
    catch { $raw = $null }

    $attestationReason = Test-FinalizationAttestation -Json ([string]$raw) -RunId $validatedRunId -Nonce $Nonce
    if ($attestationReason) { return Refused -State 'pre-seal' -Reason $attestationReason -Attestation $raw }

    # 5. Cleared, and the clearing verified by re-reading. A template inheriting
    #    a previous build's attestation hands every clone evidence about a
    #    machine it is not, which is worse than carrying none.
    if (-not $PSCmdlet.ShouldProcess($CandidateName, 'Clear the attestation and seal the candidate')) {
        return Refused -State 'pre-seal' -Reason 'not_attempted' -Attestation $raw
    }

    try { $null = & $Adapter['ClearGuestInfo'] $machine (Get-FinalizationAttestationKey) }
    catch { return Refused -State 'pre-seal' -Reason 'attestation_not_cleared' -Attestation $raw }

    $residual = $null
    try { $residual = [string](& $Adapter['ReadGuestInfo'] $machine (Get-FinalizationAttestationKey)) }
    catch { $residual = 'unreadable' }
    if (-not [string]::IsNullOrWhiteSpace($residual)) {
        # Blocks conversion. The artifact is not made immutable while it still
        # carries evidence that would outlive the machine it describes.
        return Refused -State 'pre-seal' -Reason 'attestation_not_cleared' -Attestation $raw
    }

    # 6. Convert. Everything after this point may have produced an artifact, so
    #    every remaining failure is unconfirmed rather than pre-seal.
    try { $null = & $Adapter['ConvertToTemplate'] $machine }
    catch {
        return Unconfirmed -Reason 'seal_failed' -Attestation $raw -Artifact (TryIdentity -Adapter $Adapter -Machine $machine)
    }

    # 7. Name it. An artifact whose identity cannot be read is one nothing
    #    downstream can refer to, so it is recorded as possibly existing rather
    #    than as a candidate.
    $identity = TryIdentity -Adapter $Adapter -Machine $machine
    if (-not $identity) { return Unconfirmed -Reason 'seal_unconfirmed' -Attestation $raw -Artifact $null }

    foreach ($field in 'vCenterInstanceId', 'managedObjectReference', 'instanceUuid') {
        if (-not $identity.PSObject.Properties.Name -contains $field -or
            [string]::IsNullOrWhiteSpace([string]$identity.$field)) {
            return Unconfirmed -Reason 'seal_unconfirmed' -Attestation $raw -Artifact $identity
        }
    }

    [PSCustomObject]@{
        BuildState          = 'sealed'
        Outcome             = 'passed'
        ReasonCode          = $null
        ArtifactIdentity    = $identity
        UnconfirmedArtifact = $null
        Attestation         = $raw
    }
}

function TryIdentity {
    param([hashtable] $Adapter, $Machine)
    try { & $Adapter['GetArtifactIdentity'] $Machine } catch { $null }
}

function Refused {
    param([string] $State, [string] $Reason, [string] $Attestation)
    [PSCustomObject]@{
        BuildState          = $State
        Outcome             = $(if ($Reason -eq 'not_attempted') { 'incomplete' } else { 'failed' })
        ReasonCode          = $Reason
        ArtifactIdentity    = $null
        UnconfirmedArtifact = $null
        Attestation         = $Attestation
    }
}

function Unconfirmed {
    param([string] $Reason, [string] $Attestation, $Artifact)
    [PSCustomObject]@{
        BuildState          = 'seal-unconfirmed'
        Outcome             = 'incomplete'
        ReasonCode          = $Reason
        ArtifactIdentity    = $null
        UnconfirmedArtifact = $Artifact
        Attestation         = $Attestation
    }
}

Export-ModuleMember -Function Invoke-CandidateSealing
