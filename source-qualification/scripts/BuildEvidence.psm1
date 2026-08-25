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

    if ($null -eq $parsed.resultSchemaVersion) { return 'evidence_malformed' }
    try { $schema = ResolveEnvelopeSchema -Version ([int] $parsed.resultSchemaVersion) }
    catch { return 'evidence_unsupported_version' }

    if (-not (Test-Json -Json $Json -SchemaFile $schema -ErrorAction SilentlyContinue)) {
        return 'evidence_malformed'
    }

    # The schema patterns are ECMA-262 portable, so under .NET a trailing
    # newline satisfies a pattern ending in $. This is what refuses it.
    try { Assert-NoControlCharacter -Node $parsed -Location 'envelope' -Subject 'Evidence' }
    catch { return 'evidence_malformed' }

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
            if (@($payload.phases | Where-Object { $_.name -eq 'seal' -and $_.outcome -eq 'passed' }).Count -ne 1) {
                return 'sealed_without_a_passed_seal_phase'
            }
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
    param([Parameter(Mandatory)] $Evidence)

    if ($Evidence.resultKind -ne 'image-build') { return $false }

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

function HasProperty {
    param($Object, [string] $Name)
    ($Object.PSObject.Properties.Name -contains $Name) -and $null -ne $Object.$Name
}

function TerminalReason {
    param($Payload)
    if (HasProperty -Object $Payload -Name 'terminalReasonCode') { $Payload.terminalReasonCode } else { $null }
}

Export-ModuleMember -Function Test-EvidenceEnvelopeDocument, Test-ImageBuildResult, Test-SealedCandidate
