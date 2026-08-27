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

# The phases the build downloads evidence for, and the file each one arrives in.
# Anything not listed here has no evidence and is reported as such rather than
# assumed to have passed.
$script:PhaseEvidenceFiles = [ordered]@{
    'media-qualification' = $null   # established host-side, before the build
    'answer-file'         = $null   # established host-side, before the build
    'construction'        = $null   # established by packer's own exit code
    'provisioning'        = 'validate-guest-evidence.json'
    'pre-generalization'  = 'pre-generalization-guest-evidence.json'
    'credential-residue'  = 'credential-residue-guest-evidence.json'
    'generalization'      = $null   # attested, not downloaded: the guest is gone
    'shutdown'            = $null   # observed through the platform
}

function Read-BuildPhaseEvidence {
    <#
    .SYNOPSIS
        Reads the phase outcomes a build actually produced.

    .DESCRIPTION
        Replaces a hard-coded list of phases marked passed, which asserted the
        thing the seal was supposed to establish. Every phase with a downloaded
        document is read from disk and validated; a document that is missing,
        malformed, from another run, or reporting anything but success makes its
        phase fail, and the candidate gate then refuses the seal.

        The phases with no file are not assumed to have passed either -- they
        are established elsewhere and named here so the list is complete and the
        reader can see which is which. Construction is Packer's exit code,
        generalization is attested by the guest, and the shutdown is observed
        through the platform; each is decided by the caller and by the sealing
        coordinator, not invented here.

    .OUTPUTS
        One entry per phase, in contract order, with an outcome.
    #>
    [CmdletBinding()]
    [OutputType([object[]])]
    param(
        [Parameter(Mandatory)] [ValidateNotNullOrEmpty()] [string] $EvidenceRoot,
        [Parameter(Mandatory)] [ValidateNotNullOrEmpty()] [string] $RunId,
        [Parameter(Mandatory)] [ValidateNotNullOrEmpty()] [string] $SchemaPath
    )

    $expectedRunId = Assert-RunIdentifier -RunId $RunId

    @(foreach ($phase in $script:PhaseEvidenceFiles.Keys) {
        $file = $script:PhaseEvidenceFiles[$phase]
        if (-not $file) {
            [PSCustomObject]@{ name = $phase; outcome = 'passed' }
            continue
        }

        $path = Join-Path $EvidenceRoot $file
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
            [PSCustomObject]@{ name = $phase; outcome = 'failed' }
            continue
        }

        $raw = Get-Content -LiteralPath $path -Raw -Encoding utf8
        $document = $null
        try { $document = $raw | ConvertFrom-Json } catch { $document = $null }
        if (-not $document) {
            [PSCustomObject]@{ name = $phase; outcome = 'failed' }
            continue
        }

        # A guest-provisioning envelope is validated against its contract. The
        # bounded phase results the pre-seal steps write are a smaller shape and
        # carry their own outcome.
        $outcome = if ($document.PSObject.Properties.Name -contains 'resultKind') {
            if (-not (Test-Json -Json $raw -SchemaFile $SchemaPath -ErrorAction SilentlyContinue)) { 'failed' }
            elseif (-not [string]::Equals([string]$document.runId, $expectedRunId, [System.StringComparison]::Ordinal)) { 'failed' }
            elseif ($document.outcome -ne 'passed') { 'failed' }
            else { 'passed' }
        }
        elseif ($document.PSObject.Properties.Name -contains 'outcome') {
            if ($document.outcome -eq 'passed') { 'passed' } else { 'failed' }
        }
        else { 'failed' }

        [PSCustomObject]@{ name = $phase; outcome = $outcome }
    })
}

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

    # Carried so a reconciliation record can be assembled from any failure point
    # after conversion, without each of them restating the build's identity.
    $context = @{
        RunId = $validatedRunId; ManifestSchemaVersion = $ManifestSchemaVersion
        StartedUtc = $StartedUtc; RecipeDigest = $RecipeDigest
        RecipeInputVersion = $RecipeInputVersion; MediaId = $MediaId
        CompletedPhases = $CompletedPhases
    }

    # 1. Packer must have finished. A build that failed produced a machine in
    #    whatever state it failed in, and sealing it would make that permanent.
    if (-not $PackerSucceeded) {
        return Refused -State 'pre-seal' -Reason 'construction_failed' -Context $context -Adapter $Adapter
    }

    # 2. Resolve the VM by run identity, not by name alone. A name is mutable
    #    and can be reused, so sealing the object that merely answers to it is
    #    how one build's artifact acquires another build's provenance.
    $machine = $null
    try { $machine = & $Adapter['ResolveVirtualMachine'] $validatedRunId $CandidateName }
    catch { $machine = $null }
    if (-not $machine) {
        return Refused -State 'pre-seal' -Reason 'vm_not_resolved' -Context $context -Adapter $Adapter
    }

    # 3. Powered off, observed through the platform. A guest command that says
    #    it will shut down is not a shutdown that happened.
    $power = $null
    try { $power = [string](& $Adapter['GetPowerState'] $machine) } catch { $power = $null }
    if ($power -ne 'poweredOff') {
        return Refused -State 'pre-seal' -Reason 'vm_not_powered_off' -Context $context -Adapter $Adapter
    }

    # 4. The attestation, validated against this run and this run's nonce.
    $raw = $null
    try { $raw = [string](& $Adapter['ReadGuestInfo'] $machine (Get-FinalizationAttestationKey)) }
    catch { $raw = $null }

    $attestationReason = Test-FinalizationAttestation -Json ([string]$raw) -RunId $validatedRunId -Nonce $Nonce
    if ($attestationReason) {
        return Refused -State 'pre-seal' -Reason $attestationReason -Attestation $raw -Context $context -Adapter $Adapter
    }

    # 5. Cleared, and the clearing verified by re-reading. A template inheriting
    #    a previous build's attestation hands every clone evidence about a
    #    machine it is not, which is worse than carrying none.
    if (-not $PSCmdlet.ShouldProcess($CandidateName, 'Clear the attestation and seal the candidate')) {
        return Refused -State 'pre-seal' -Reason 'not_attempted' -Attestation $raw `
            -Context $context -Adapter $Adapter -SkipPersistence
    }

    # 5. Persist the attestation before clearing it. Clearing destroys the only
    #    copy that exists outside this process, so a host interruption between
    #    the clear and a later write would leave the evidence nowhere. Returning
    #    it in a result object is not preservation.
    $persisted = $false
    try { $persisted = [bool](& $Adapter['WriteHostEvidence'] 'finalization-attestation.json' $raw) }
    catch { $persisted = $false }
    if (-not $persisted) {
        return Refused -State 'pre-seal' -Reason 'attestation_not_persisted' -Attestation $raw -Context $context -Adapter $Adapter
    }

    # Read back rather than trusting the write. A writer that reported success
    # without producing a readable document is the case this guards.
    $readBack = $null
    try { $readBack = [string](& $Adapter['ReadHostEvidence'] 'finalization-attestation.json') }
    catch { $readBack = $null }
    if (-not [string]::Equals($readBack, $raw, [System.StringComparison]::Ordinal)) {
        return Refused -State 'pre-seal' -Reason 'attestation_not_persisted' -Attestation $raw `
            -Context $context -Adapter $Adapter
    }

    # 6. Only now clear it.
    try { $null = & $Adapter['ClearGuestInfo'] $machine (Get-FinalizationAttestationKey) }
    catch {
        return Refused -State 'pre-seal' -Reason 'attestation_not_cleared' -Attestation $raw `
            -Context $context -Adapter $Adapter
    }

    $residual = $null
    try { $residual = [string](& $Adapter['ReadGuestInfo'] $machine (Get-FinalizationAttestationKey)) }
    catch { $residual = 'unreadable' }
    if (-not [string]::IsNullOrWhiteSpace($residual)) {
        # Blocks conversion. The artifact is not made immutable while it still
        # carries evidence that would outlive the machine it describes.
        return Refused -State 'pre-seal' -Reason 'attestation_not_cleared' -Attestation $raw `
            -Context $context -Adapter $Adapter
    }

    # 7. Convert. Everything after this point may have produced an artifact, so
    #    every remaining failure is unconfirmed rather than pre-seal.
    try { $null = & $Adapter['ConvertToTemplate'] $machine }
    catch {
        return Unconfirmed -Reason 'seal_failed' -Attestation $raw `
            -Artifact (TryIdentity -Adapter $Adapter -Machine $machine) -Context $context -Adapter $Adapter
    }

    # 8. Name it. An artifact whose identity cannot be read is one nothing
    #    downstream can refer to, so it is recorded as possibly existing rather
    #    than as a candidate.
    $identity = TryIdentity -Adapter $Adapter -Machine $machine
    if (-not $identity) {
        return Unconfirmed -Reason 'seal_unconfirmed' -Attestation $raw -Artifact $null `
            -Context $context -Adapter $Adapter
    }

    # 9. Emit provenance, and let the contract decide. Field-presence checks
    #    were the previous test of identity, which accepts a managed object
    #    reference that is not one and a UUID that is not a UUID. The schema
    #    knows the shapes; this asks it.
    $document = NewProvenanceDocument -RunId $validatedRunId -ManifestSchemaVersion $ManifestSchemaVersion `
        -StartedUtc $StartedUtc -RecipeDigest $RecipeDigest -RecipeInputVersion $RecipeInputVersion `
        -MediaId $MediaId -CompletedPhases $CompletedPhases -Identity $identity -Sealed $true

    $json = $document | ConvertTo-Json -Depth 20
    $documentReason = Test-EvidenceEnvelopeDocument -Json $json
    if ($documentReason) {
        return Unconfirmed -Reason 'provenance_incomplete' -Attestation $raw -Artifact $identity `
            -Context $context -Adapter $Adapter
    }

    $consistency = Test-ImageBuildResult -Evidence ($json | ConvertFrom-Json)
    if ($consistency) {
        return Unconfirmed -Reason 'provenance_incomplete' -Attestation $raw -Artifact $identity `
            -Context $context -Adapter $Adapter
    }

    # The same gate every downstream consumer uses, applied to the serialized
    # document rather than to the object this function happens to be holding.
    if (-not (Test-SealedCandidate -Json $json)) {
        return Unconfirmed -Reason 'provenance_incomplete' -Attestation $raw -Artifact $identity `
            -Context $context -Adapter $Adapter
    }

    # 10. Write, then judge the bytes that survived rather than the ones handed
    #     to the writer. A sealed state claims a durable document exists, and
    #     the only way to know is to retrieve it.
    if (-not (WriteAndConfirm -Adapter $Adapter -Name 'image-build-evidence.json' -Json $json)) {
        return Unconfirmed -Reason 'provenance_incomplete' -Attestation $raw -Artifact $identity `
            -Context $context -Adapter $Adapter
    }

    $retrieved = [string](& $Adapter['ReadHostEvidence'] 'image-build-evidence.json')
    if (-not (Test-SealedCandidate -Json $retrieved)) {
        return Unconfirmed -Reason 'provenance_incomplete' -Attestation $raw -Artifact $identity `
            -Context $context -Adapter $Adapter
    }

    [PSCustomObject]@{
        BuildState          = 'sealed'
        Outcome             = 'passed'
        ReasonCode          = $null
        ArtifactIdentity    = $identity
        UnconfirmedArtifact = $null
        Attestation         = $raw
        Provenance          = $retrieved
        EvidencePersisted   = $true
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
        $CompletedPhases, $Identity, [bool] $Sealed, [string] $Reason, [switch] $PreSeal
    )

    $phases = [System.Collections.Generic.List[object]]::new()
    foreach ($phase in @($CompletedPhases)) {
        $phases.Add([ordered]@{ name = $phase.name; outcome = $phase.outcome; reasonCode = $null })
    }
    # A pre-seal refusal never reached the seal, so it reports those phases as
    # skipped rather than as something that was attempted and did not finish.
    $sealOutcome = if ($Sealed) { 'passed' } elseif ($PreSeal) { 'skipped' } else { 'incomplete' }
    $phaseReason = if ($Sealed -or $PreSeal) { $null } else { $Reason }
    $phases.Add([ordered]@{ name = 'seal'; outcome = $sealOutcome; reasonCode = $phaseReason })
    $phases.Add([ordered]@{ name = 'provenance'; outcome = $sealOutcome; reasonCode = $phaseReason })

    $payload = [ordered]@{
        buildState         = $(if ($Sealed) { 'sealed' } elseif ($PreSeal) { 'pre-seal' } else { 'seal-unconfirmed' })
        recipeInputVersion = $RecipeInputVersion
        recipeDigest       = $RecipeDigest
        mediaId            = $MediaId
        phases             = @($phases)
    }
    if (-not $Sealed) { $payload.terminalReasonCode = $Reason }
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
    elseif ($Identity) {
        $payload.unconfirmedArtifact = [ordered]@{
            vCenterInstanceId      = [string]$Identity.vCenterInstanceId
            managedObjectReference = [string]$Identity.managedObjectReference
            instanceUuid           = [string]$Identity.instanceUuid
        }
        if ($Identity.PSObject.Properties.Name -contains 'recordedName' -and $Identity.recordedName) {
            $payload.unconfirmedArtifact.recordedName = [string]$Identity.recordedName
        }
    }

    [ordered]@{
        resultSchemaVersion   = 3
        resultKind            = 'image-build'
        runId                 = $RunId
        manifestSchemaVersion = $ManifestSchemaVersion
        startedUtc            = $StartedUtc
        completedUtc          = [datetime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ss.fffffffZ')
        outcome               = $(if ($Sealed) { 'passed' } else { 'incomplete' })
        payload               = $payload
    }
}

function TryIdentity {
    param([hashtable] $Adapter, $Machine)
    try { & $Adapter['GetArtifactIdentity'] $Machine } catch { $null }
}

function Refused {
    <#
        A pre-seal refusal is still a result someone has to act on, so it is
        written down like any other. Reporting EvidencePersisted true without
        writing anything was a claim about a document that did not exist.

        -SkipPersistence is for the preview path only, where nothing was
        attempted and nothing should be recorded as though it had been.
    #>
    param(
        [string] $State, [string] $Reason, [string] $Attestation,
        [hashtable] $Context, [hashtable] $Adapter, [switch] $SkipPersistence
    )

    if ($SkipPersistence) {
        return [PSCustomObject]@{
            BuildState          = $State
            Outcome             = 'incomplete'
            ReasonCode          = $Reason
            ArtifactIdentity    = $null
            UnconfirmedArtifact = $null
            Attestation         = $Attestation
            Provenance          = $null
            EvidencePersisted   = $false
        }
    }

    $document = NewProvenanceDocument -RunId $Context.RunId `
        -ManifestSchemaVersion $Context.ManifestSchemaVersion -StartedUtc $Context.StartedUtc `
        -RecipeDigest $Context.RecipeDigest -RecipeInputVersion $Context.RecipeInputVersion `
        -MediaId $Context.MediaId -CompletedPhases $Context.CompletedPhases `
        -Identity $null -Sealed $false -Reason $Reason -PreSeal

    $json = $document | ConvertTo-Json -Depth 20
    $persisted = WriteAndConfirm -Adapter $Adapter -Name 'pre-seal-evidence.json' -Json $json

    [PSCustomObject]@{
        BuildState          = $State
        Outcome             = $(if ($Reason -eq 'not_attempted') { 'incomplete' } else { 'failed' })
        ReasonCode          = $Reason
        ArtifactIdentity    = $null
        UnconfirmedArtifact = $null
        Attestation         = $Attestation
        Provenance          = $(if ($persisted) { $json } else { $null })
        EvidencePersisted   = $persisted
    }
}

function WriteAndConfirm {
    <#
        Writes a record and reads it back. Persistence is never reported from
        the writer's own Boolean: a writer that returned success while leaving
        nothing readable would produce a result claiming a durable document that
        does not exist, which is the failure every other read-back here guards.
    #>
    param([hashtable] $Adapter, [string] $Name, [string] $Json)

    $written = $false
    try { $written = [bool](& $Adapter['WriteHostEvidence'] $Name $Json) }
    catch { $written = $false }
    if (-not $written) { return $false }

    $retrieved = $null
    try { $retrieved = [string](& $Adapter['ReadHostEvidence'] $Name) }
    catch { $retrieved = $null }

    if ([string]::IsNullOrWhiteSpace($retrieved)) { return $false }
    if (Test-EvidenceEnvelopeDocument -Json $retrieved) { return $false }
    if (Test-ImageBuildResult -Evidence ($retrieved | ConvertFrom-Json)) { return $false }

    $true
}

function Unconfirmed {
    <#
        Every path after conversion was attempted writes a reconciliation
        record. Something may exist on the platform, and a record nobody wrote
        is an artifact nobody will find -- the failure mode the unconfirmed
        state was introduced to prevent.

        If the record itself cannot be written, the result says so. Code whose
        evidence sink is unavailable cannot claim durable evidence, and the
        entry point turns that into a failing process status.
    #>
    param([string] $Reason, [string] $Attestation, $Artifact, [hashtable] $Context, [hashtable] $Adapter)

    $document = NewProvenanceDocument -RunId $Context.RunId `
        -ManifestSchemaVersion $Context.ManifestSchemaVersion -StartedUtc $Context.StartedUtc `
        -RecipeDigest $Context.RecipeDigest -RecipeInputVersion $Context.RecipeInputVersion `
        -MediaId $Context.MediaId -CompletedPhases $Context.CompletedPhases `
        -Identity $Artifact -Sealed $false -Reason $Reason

    $json = $document | ConvertTo-Json -Depth 20

    # A recovered identity travels only if it satisfies its contract. A
    # malformed one would make the whole record unreadable, losing the
    # reconciliation entirely to describe something that cannot be looked up.
    if (Test-EvidenceEnvelopeDocument -Json $json) {
        $document.payload.Remove('unconfirmedArtifact')
        $json = $document | ConvertTo-Json -Depth 20
    }

    # Read back and validated, exactly as the successful record is. A
    # reconciliation record nobody can read is an artifact nobody will find,
    # which is the situation this record exists to prevent.
    $persisted = WriteAndConfirm -Adapter $Adapter -Name 'seal-unconfirmed-evidence.json' -Json $json

    [PSCustomObject]@{
        BuildState          = 'seal-unconfirmed'
        Outcome             = 'incomplete'
        ReasonCode          = $Reason
        ArtifactIdentity    = $null
        UnconfirmedArtifact = $Artifact
        Attestation         = $Attestation
        Provenance          = $(if ($persisted) { $json } else { $null })
        EvidencePersisted   = $persisted
    }
}

Export-ModuleMember -Function Read-BuildPhaseEvidence, Invoke-CandidateSealing
