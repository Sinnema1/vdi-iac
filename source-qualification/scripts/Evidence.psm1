#Requires -Version 7.0

<#
.SYNOPSIS
    Builds and validates the evidence envelope every stage emits.

.DESCRIPTION
    Implements ADR 5. Increment 1 stamped its result `SchemaVersion = 1`, which
    read unambiguously while one schema existed and stops being readable once a
    manifest version 2 exists: a result from a version 2 manifest would still say
    1, meaning the result format while appearing to describe the manifest.

    Evidence therefore carries two separately named versions, and declares which
    stage produced it so a consumer never infers the shape from whichever fields
    happen to be present.

    Evidence is not inherently safe to publish. Package identifiers and versions
    come from a manifest, so classification remains a decision for whoever
    releases it. What the contract guarantees is narrower and enforceable: each
    resultKind has a closed payload definition with an explicit field list and
    bounded reason-code enumerations, so values that must never appear cannot be
    carried under a different name.
#>

Set-StrictMode -Version 3.0

# Imported here rather than assumed present in the caller's session. Without
# this the module works under a test session that happened to load RunIdentity
# and fails in a fresh subprocess, which is exactly where it matters.
Import-Module (Join-Path $PSScriptRoot 'RunIdentity.psm1')

$script:EnvelopeSchema = Join-Path $PSScriptRoot '..' '..' 'contracts' 'evidence-envelope-2.schema.json'
$script:ResultSchemaVersion = 2

function ConvertTo-EvidenceEnvelope {
    <#
    .SYNOPSIS
        Wraps a stage payload in the common envelope.

    .NOTES
        ConvertTo- rather than New-: it transforms a payload into an envelope and
        creates no resource, so a state-changing verb would require ShouldProcess
        for a function that has nothing to confirm.

    .PARAMETER ResultKind
        Which stage produced this.

    .PARAMETER RunId
        Canonical lowercase UUID, validated before use.

    .PARAMETER Payload
        Stage-specific content, validated against the closed definition the
        schema selects for this ResultKind. A payload is not an open object: an
        unexpected field is rejected outright, so a path, an installer argument,
        raw output, or exception text cannot be smuggled through a renamed key.

    .OUTPUTS
        The envelope, already validated against its committed schema.
    #>
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param(
        [Parameter(Mandatory)] [ValidateSet('source-qualification','guest-provisioning')] [string] $ResultKind,
        [Parameter(Mandatory)] [ValidateNotNullOrEmpty()] [string] $RunId,
        [Parameter(Mandatory)] [ValidateSet('passed','failed','incomplete','skipped')] [string] $Outcome,
        [Parameter(Mandatory)] [datetime] $StartedUtc,
        [Parameter(Mandatory)] $Payload,
        [Parameter()] [ValidateSet(1,2)] [int] $ManifestSchemaVersion,
        [Parameter()] [datetime] $CompletedUtc = [datetime]::UtcNow
    )

    $validatedRunId = Assert-RunIdentifier -RunId $RunId

    $envelope = [ordered]@{
        resultSchemaVersion = $script:ResultSchemaVersion
        resultKind          = $ResultKind
        runId               = $validatedRunId
        startedUtc          = $StartedUtc.ToUniversalTime().ToString('o')
        completedUtc        = $CompletedUtc.ToUniversalTime().ToString('o')
        outcome             = $Outcome
        toolVersion         = "PowerShell $($PSVersionTable.PSVersion)"
        payload             = $Payload
    }
    if ($PSBoundParameters.ContainsKey('ManifestSchemaVersion')) {
        $envelope['manifestSchemaVersion'] = $ManifestSchemaVersion
    }

    $result = [PSCustomObject] $envelope

    $schemaErrors = $null
    $json = $result | ConvertTo-Json -Depth 16
    if (-not (Test-Json -Json $json -SchemaFile $script:EnvelopeSchema -ErrorAction SilentlyContinue -ErrorVariable schemaErrors)) {
        $detail = if ($schemaErrors) { ($schemaErrors | ForEach-Object { $_.ToString() }) -join '; ' } else { 'no detail reported' }
        throw "Generated evidence does not satisfy the envelope schema: $detail"
    }

    $result
}

Export-ModuleMember -Function ConvertTo-EvidenceEnvelope
