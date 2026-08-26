#Requires -Version 7.0

<#
.SYNOPSIS
    The image-build result, and the rules that decide when it is a sealed candidate.

.DESCRIPTION
    Increment 3 stage 3, governed by ADR 7. Version 3 of the evidence envelope
    adds the image-build kind; version 2 is left exactly as it was, because a
    published contract version is never edited in place.

    The rule this module exists to enforce cannot be written in the schema.
    Test-Json does not apply draft-07 if/then -- measured, not assumed -- so a
    conditional there would validate every document while reading as a
    constraint, which is worse than no rule because a reviewer stops looking for
    it elsewhere.

    The rule: artifactIdentity appears exactly when a build sealed successfully.
    Its presence is what makes a record an accepted sealed candidate, so a
    record that reached sealing without confirming it records what may exist
    under a different name -- unconfirmedArtifact -- and remains incomplete. An
    artifact created when evidence emission failed therefore stays describable
    without ever being mistaken for a candidate. That is the whole point: a
    reader searching for sealed candidates must not find an unconfirmed one.
#>

Set-StrictMode -Version 3.0

Import-Module (Join-Path $PSScriptRoot 'RunIdentity.psm1')
Import-Module (Join-Path $PSScriptRoot 'JsonSafety.psm1')

# Hard-coded, never a path built from a declared value and never a fallback to
# the newest. An envelope claiming a version this map does not know is refused
# rather than validated against whatever happens to be latest.
$script:SchemaFileByVersion = @{
    2 = 'evidence-envelope-2.schema.json'
    3 = 'evidence-envelope-3.schema.json'
}

# The recipe-input document versions this code knows how to interpret. A digest
# is only comparable within one version, so a record declaring a version nobody
# here implements describes an identity this code cannot reason about -- and
# must not promote.
# Version 1 was never emitted by a real build, and the canonicalizer now emits
# version 2. Accepting 1 would admit a digest computed without the processor,
# memory, and guest OS inputs the builder actually uses.
$script:SupportedRecipeInputVersions = @(2)

# The manifest contract versions an image build can actually have consumed. The
# recipe path reads installer kind, timeout, restart policy, exit codes, and
# validation definitions; a version 1 package carries none of them, so a record
# claiming version 1 describes provenance that path could not have produced. Not
# a stylistic restriction -- the recipe would have terminated on the first
# package rather than producing the digest the record carries.
$script:SupportedImageBuildManifestVersions = @(2)

# The ordered obligations a sealed candidate has to have met, from the charter.
# Every one of them changes whether the image is usable or safe: media that was
# never qualified, an answer file that never rendered, packages that never
# installed, a pre-generalization check that never ran, a credential left in the
# image, an image never generalized, a shutdown never observed, a seal that
# never completed, or provenance that cannot say what was built.
#
# Order is part of the requirement. Residue removal after generalization would
# be sealing the credential in; provenance before sealing could not name the
# artifact.
$script:RequiredSealPhases = @(
    'media-qualification'
    'answer-file'
    'construction'
    'provisioning'
    'pre-generalization'
    'credential-residue'
    'generalization'
    'shutdown'
    'seal'
    'provenance'
)

function ResolveEnvelopeSchema {
    param([int] $Version)

    if (-not $script:SchemaFileByVersion.ContainsKey($Version)) {
        throw "Unsupported evidence envelope version: $Version. Supported versions are $(($script:SchemaFileByVersion.Keys | Sort-Object) -join ', ')."
    }
    $path = Join-Path $PSScriptRoot '..' '..' 'contracts' $script:SchemaFileByVersion[$Version]
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        throw "The schema file for evidence envelope version $Version is missing: $($script:SchemaFileByVersion[$Version])."
    }
    $path
}

function Test-EvidenceEnvelopeDocument {
    <#
    .SYNOPSIS
        Validates a document against the envelope version it declares.

    .DESCRIPTION
        The declared version selects the schema through a hard-coded map, so a
        version 2 document is still checked against version 2 after version 3
        exists. Validating everything against the newest schema would silently
        accept a version 2 document carrying version 3 fields.

    .OUTPUTS
        A reason string when the document is unacceptable, or null.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)] [ValidateNotNullOrEmpty()] [string] $Json)

    try { $parsed = $Json | ConvertFrom-Json } catch { return 'evidence_malformed' }
    if ($null -eq $parsed) { return 'evidence_malformed' }

    # Presence first. Reading an absent property throws under StrictMode, so a
    # document without a version would fail with an exception rather than the
    # bounded reason a caller can act on.
    if (-not (HasProperty -Object $parsed -Name 'resultSchemaVersion')) { return 'evidence_malformed' }
    try { $schema = ResolveEnvelopeSchema -Version ([int] $parsed.resultSchemaVersion) }
    catch { return 'evidence_unsupported_version' }

    if (-not (Test-Json -Json $Json -SchemaFile $schema -ErrorAction SilentlyContinue)) {
        return 'evidence_malformed'
    }

    # Version 3 only. The patterns are ECMA-262 portable, so under .NET a
    # trailing newline satisfies a pattern ending in $, and this refuses it.
    # Applying it to version 2 as well would change what a published contract
    # accepts, which is a behavioural change to a version that is meant to be
    # stable -- and would be made here, silently, as a side effect.
    if ([int] $parsed.resultSchemaVersion -eq 3) {
        try { Assert-NoControlCharacter -Node $parsed -Location 'envelope' -Subject 'Evidence' }
        catch { return 'evidence_malformed' }
    }

    $null
}

function Test-ImageBuildResult {
    <#
    .SYNOPSIS
        Returns a reason when a build result contradicts its own state, or null.

    .DESCRIPTION
        Schema validity is not enough. A document can satisfy every field
        constraint and still claim a sealed candidate it did not produce, and
        that claim is the one a downstream consumer acts on.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)] $Evidence)

    $payload = $Evidence.payload
    $state = $payload.buildState
    $sealed = HasProperty -Object $payload -Name 'artifactIdentity'
    $unconfirmed = HasProperty -Object $payload -Name 'unconfirmedArtifact'

    switch ($state) {
        'sealed' {
            # The only state that may name an accepted candidate, and it has to
            # name one: a sealed record with no artifact describes nothing.
            if ($Evidence.outcome -ne 'passed') { return 'sealed_without_passed_outcome' }
            if (-not $sealed) { return 'sealed_without_artifact_identity' }
            if ($unconfirmed) { return 'sealed_with_unconfirmed_artifact' }
            if (TerminalReason -Payload $payload) { return 'sealed_with_terminal_reason' }
            if (@($payload.phases | Where-Object { $_.outcome -notin @('passed', 'skipped') }).Count -gt 0) {
                return 'sealed_with_failed_phase'
            }
            $phaseReason = TestRequiredSealPhases -Phases @($payload.phases)
            if ($phaseReason) { return $phaseReason }
        }
        'seal-unconfirmed' {
            # An artifact may exist. Recording it is useful; calling it a
            # candidate is not, so it may only appear under the other name.
            if ($sealed) { return 'unconfirmed_seal_carrying_artifact_identity' }
            if ($Evidence.outcome -ne 'incomplete') { return 'unconfirmed_seal_without_incomplete_outcome' }
        }
        'pre-seal' {
            if ($sealed) { return 'pre_seal_carrying_artifact_identity' }
            if ($unconfirmed) { return 'pre_seal_carrying_unconfirmed_artifact' }
            if ($Evidence.outcome -eq 'passed') {
                # A build that never sealed did not produce a candidate, so it
                # must not report the outcome a consumer reads as success.
                return 'pre_seal_reporting_passed'
            }
        }
        default { return 'unknown_build_state' }
    }

    if ($Evidence.outcome -eq 'failed' -and $sealed) { return 'failed_result_carrying_artifact_identity' }
    if ($Evidence.outcome -in @('failed', 'incomplete') -and -not (TerminalReason -Payload $payload)) {
        return 'unsuccessful_result_without_terminal_reason'
    }

    $null
}

function Test-SealedCandidate {
    <#
    .SYNOPSIS
        Answers whether a record describes an accepted sealed candidate.

    .DESCRIPTION
        The single place that question is answered, so no caller decides it by
        looking for a field. Anything short of a schema-valid, self-consistent,
        sealed, passed record is not a candidate -- including a record whose
        seal could not be confirmed, which is the case that would otherwise be
        promoted by an eager reader.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory)] [ValidateNotNullOrEmpty()] [string] $Json)

    # Schema validity is established here rather than assumed. This took a
    # parsed object and answered from semantic rules alone, so a document the
    # validator rejected -- a malformed artifact identity, an unsupported
    # envelope version -- could still be reported as a candidate by any caller
    # who forgot the separate step. A gate that depends on being called in the
    # right order is not a gate.
    if (Test-EvidenceEnvelopeDocument -Json $Json) { return $false }

    $Evidence = $Json | ConvertFrom-Json

    if ($Evidence.resultKind -ne 'image-build') { return $false }

    # A digest is only comparable within a recipe-input version this code
    # implements. One it does not know describes an identity it cannot reason
    # about, whatever else the record says.
    if ($Evidence.payload.recipeInputVersion -notin $script:SupportedRecipeInputVersions) { return $false }

    # The manifest contract the run claims to have consumed must be one the
    # recipe path can process. The envelope permits versions 1 and 2 because
    # other result kinds legitimately carry version 1; an image build cannot.
    if ($Evidence.manifestSchemaVersion -notin $script:SupportedImageBuildManifestVersions) { return $false }


    # Redundant, and kept deliberately. Mutation testing confirms no fixture can
    # reach this line and pass the two below: a non-sealed state either carries
    # an outcome other than passed, or Test-ImageBuildResult rejects the
    # combination. It stays because this function answers the question the rest
    # of the system acts on, and it should not depend on another function's rule
    # ordering to get it right. Redundancy that cannot fire is documented here
    # rather than left to look like the load-bearing check.
    if ($Evidence.payload.buildState -ne 'sealed') { return $false }

    if ($Evidence.outcome -ne 'passed') { return $false }
    if (Test-ImageBuildResult -Evidence $Evidence) { return $false }
    $true
}

function TestRequiredSealPhases {
    <#
        A seal event is not a build. Before this existed a record carrying one
        passed 'seal' phase was accepted as a candidate, so every obligation the
        design rests on could be omitted, skipped, duplicated, or reordered
        without preventing promotion -- and a phase marked passed while carrying
        a failure reason was accepted too.

        The sequence is matched exactly: same phases, same order, once each.
    #>
    param($Phases)

    $observed = @($Phases | ForEach-Object { $_.name })
    if ($observed.Count -ne $script:RequiredSealPhases.Count) { return 'sealed_without_every_required_phase' }

    for ($i = 0; $i -lt $script:RequiredSealPhases.Count; $i++) {
        if ($observed[$i] -ne $script:RequiredSealPhases[$i]) { return 'sealed_with_phases_out_of_order' }
    }

    foreach ($phase in $Phases) {
        if ($phase.outcome -ne 'passed') { return 'sealed_with_a_phase_that_did_not_pass' }
        # A passed phase naming a failure contradicts itself, and the reason is
        # the more specific of the two claims.
        if (HasProperty -Object $phase -Name 'reasonCode') { return 'sealed_with_a_phase_reporting_a_failure' }
    }

    $null
}

function HasProperty {
    param($Object, [string] $Name)
    ($Object.PSObject.Properties.Name -contains $Name) -and $null -ne $Object.$Name
}

function TerminalReason {
    param($Payload)
    if (HasProperty -Object $Payload -Name 'terminalReasonCode') { $Payload.terminalReasonCode } else { $null }
}

Export-ModuleMember -Function Test-EvidenceEnvelopeDocument, Test-ImageBuildResult, Test-SealedCandidate
