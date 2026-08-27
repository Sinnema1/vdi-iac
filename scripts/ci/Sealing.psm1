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
Import-Module (Join-Path $PSScriptRoot '..' '..' 'source-qualification' 'scripts' 'BuildEvidence.psm1')

# The phases a sealed candidate must have completed, in order. The caller
# supplies everything up to the seal; this module adds the last two, because
# they describe what it did rather than what the build did.
$script:PhasesBeforeSeal = @(
    'media-qualification', 'answer-file', 'construction', 'provisioning',
    'pre-generalization', 'credential-residue', 'generalization', 'shutdown'
)

function Invoke-CandidateSealing {
    <#
    .SYNOPSIS
        Turns a powered-off, finalized build VM into a named sealed candidate.

    .PARAMETER Adapter
        ResolveVirtualMachine, GetPowerState, ReadGuestInfo, ClearGuestInfo,
        WriteHostEvidence, ReadHostEvidence, ConvertToTemplate, and
        GetArtifactIdentity. All injected.

        WriteHostEvidence must be atomic. A partially written evidence file that
        survived an interruption would be worse than none, because it would look
        like a record.

    .PARAMETER CompletedPhases
        The phases established before sealing, each as name and outcome. This
        module adds the seal and provenance phases, because those describe what
        it did rather than what the build did.

    .OUTPUTS
        The build state, the emitted provenance document when there is one, the
        artifact identity when there is one, the unconfirmed artifact when there
        may be one, and a bounded reason.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([PSCustomObject])]
    param(
        [Parameter(Mandatory)] [ValidateNotNullOrEmpty()] [string] $RunId,
        [Parameter(Mandatory)] [ValidatePattern('^[0-9a-f]{32}$')] [string] $Nonce,
        [Parameter(Mandatory)] [ValidateNotNullOrEmpty()] [string] $CandidateName,
        [Parameter(Mandatory)] [bool] $PackerSucceeded,
        [Parameter(Mandatory)] $CompletedPhases,
        [Parameter(Mandatory)] [ValidateNotNullOrEmpty()] [string] $RecipeDigest,
        [Parameter(Mandatory)] [int] $RecipeInputVersion,
        [Parameter(Mandatory)] [int] $ManifestSchemaVersion,
        [Parameter(Mandatory)] [ValidateNotNullOrEmpty()] [string] $MediaId,
        [Parameter(Mandatory)] [ValidateNotNullOrEmpty()] [string] $StartedUtc,
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

    # 5. Persist the attestation before clearing it. Clearing destroys the only
    #    copy that exists outside this process, so a host interruption between
    #    the clear and a later write would leave the evidence nowhere. Returning
    #    it in a result object is not preservation.
    $persisted = $false
    try { $persisted = [bool](& $Adapter['WriteHostEvidence'] 'finalization-attestation.json' $raw) }
    catch { $persisted = $false }
    if (-not $persisted) { return Refused -State 'pre-seal' -Reason 'attestation_not_persisted' -Attestation $raw }

    # Read back rather than trusting the write. A writer that reported success
    # without producing a readable document is the case this guards.
    $readBack = $null
    try { $readBack = [string](& $Adapter['ReadHostEvidence'] 'finalization-attestation.json') }
    catch { $readBack = $null }
    if (-not [string]::Equals($readBack, $raw, [System.StringComparison]::Ordinal)) {
        return Refused -State 'pre-seal' -Reason 'attestation_not_persisted' -Attestation $raw
    }

    # 6. Only now clear it.
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

    # 7. Convert. Everything after this point may have produced an artifact, so
    #    every remaining failure is unconfirmed rather than pre-seal.
    try { $null = & $Adapter['ConvertToTemplate'] $machine }
    catch {
        return Unconfirmed -Reason 'seal_failed' -Attestation $raw -Artifact (TryIdentity -Adapter $Adapter -Machine $machine)
    }

    # 8. Name it. An artifact whose identity cannot be read is one nothing
    #    downstream can refer to, so it is recorded as possibly existing rather
    #    than as a candidate.
    $identity = TryIdentity -Adapter $Adapter -Machine $machine
    if (-not $identity) { return Unconfirmed -Reason 'seal_unconfirmed' -Attestation $raw -Artifact $null }

    # 9. Emit provenance, and let the contract decide. Field-presence checks
    #    were the previous test of identity, which accepts a managed object
    #    reference that is not one and a UUID that is not a UUID. The schema
    #    knows the shapes; this asks it.
    $document = NewProvenanceDocument -RunId $validatedRunId -ManifestSchemaVersion $ManifestSchemaVersion `
        -StartedUtc $StartedUtc -RecipeDigest $RecipeDigest -RecipeInputVersion $RecipeInputVersion `
        -MediaId $MediaId -CompletedPhases $CompletedPhases -Identity $identity -Sealed $true

    $json = $document | ConvertTo-Json -Depth 20
    $documentReason = Test-EvidenceEnvelopeDocument -Json $json
    if ($documentReason) { return Unconfirmed -Reason 'provenance_incomplete' -Attestation $raw -Artifact $identity }

    $consistency = Test-ImageBuildResult -Evidence ($json | ConvertFrom-Json)
    if ($consistency) { return Unconfirmed -Reason 'provenance_incomplete' -Attestation $raw -Artifact $identity }

    # The same gate every downstream consumer uses, applied to the serialized
    # document rather than to the object this function happens to be holding.
    if (-not (Test-SealedCandidate -Json $json)) {
        return Unconfirmed -Reason 'provenance_incomplete' -Attestation $raw -Artifact $identity
    }

    $written = $false
    try { $written = [bool](& $Adapter['WriteHostEvidence'] 'image-build-evidence.json' $json) }
    catch { $written = $false }
    if (-not $written) { return Unconfirmed -Reason 'provenance_incomplete' -Attestation $raw -Artifact $identity }

    [PSCustomObject]@{
        BuildState          = 'sealed'
        Outcome             = 'passed'
        ReasonCode          = $null
        ArtifactIdentity    = $identity
        UnconfirmedArtifact = $null
        Attestation         = $raw
        Provenance          = $json
    }
}

function NewProvenanceDocument {
    <#
        The image-build record. Assembled here rather than by a caller, so the
        document a consumer reads and the checks this module ran are about the
        same thing.
    #>
    param(
        [string] $RunId, [int] $ManifestSchemaVersion, [string] $StartedUtc,
        [string] $RecipeDigest, [int] $RecipeInputVersion, [string] $MediaId,
        $CompletedPhases, $Identity, [bool] $Sealed
    )

    $phases = [System.Collections.Generic.List[object]]::new()
    foreach ($phase in @($CompletedPhases)) {
        $phases.Add([ordered]@{ name = $phase.name; outcome = $phase.outcome; reasonCode = $null })
    }
    $phases.Add([ordered]@{ name = 'seal'; outcome = 'passed'; reasonCode = $null })
    $phases.Add([ordered]@{ name = 'provenance'; outcome = 'passed'; reasonCode = $null })

    $payload = [ordered]@{
        buildState         = 'sealed'
        recipeInputVersion = $RecipeInputVersion
        recipeDigest       = $RecipeDigest
        mediaId            = $MediaId
        phases             = @($phases)
    }
    if ($Sealed -and $Identity) {
        $payload.artifactIdentity = [ordered]@{
            vCenterInstanceId      = [string]$Identity.vCenterInstanceId
            managedObjectReference = [string]$Identity.managedObjectReference
            instanceUuid           = [string]$Identity.instanceUuid
        }
        if ($Identity.PSObject.Properties.Name -contains 'recordedName' -and $Identity.recordedName) {
            $payload.artifactIdentity.recordedName = [string]$Identity.recordedName
        }
    }

    [ordered]@{
        resultSchemaVersion   = 3
        resultKind            = 'image-build'
        runId                 = $RunId
        manifestSchemaVersion = $ManifestSchemaVersion
        startedUtc            = $StartedUtc
        completedUtc          = [datetime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ss.fffffffZ')
        outcome               = 'passed'
        payload               = $payload
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
        Provenance          = $null
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
        Provenance          = $null
    }
}

Export-ModuleMember -Function Invoke-CandidateSealing
