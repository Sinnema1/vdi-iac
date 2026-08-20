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

    Evidence is not inherently safe to publish. Package identifiers, versions,
    and paths are supplied by the caller, so this module refuses the values that
    are never acceptable -- installer arguments, property values, command lines,
    and raw exception text -- and the classification of the rest stays a decision
    for whoever releases it.
#>

Set-StrictMode -Version 3.0

$script:EnvelopeSchema = Join-Path $PSScriptRoot '..' '..' 'contracts' 'evidence-envelope-2.schema.json'
$script:ResultSchemaVersion = 2

# Keys that must never appear anywhere in a payload. Arguments are the tempting
# one: a failed install is exactly when someone wants to see the command, and a
# manifest may carry an install location or a property value its author should
# not have put there.
$script:ForbiddenPayloadKeys = @(
    'arguments', 'argumentlist', 'properties', 'commandline', 'command',
    'exception', 'stacktrace', 'stdout', 'stderr', 'password', 'secret', 'token'
)

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
        Stage-specific content. Rejected if it carries a forbidden key at any
        depth, so a stage cannot leak by accident and pass validation.

    .OUTPUTS
        The envelope, already validated against its committed schema.
    #>
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param(
        [Parameter(Mandatory)] [ValidateSet('source-qualification','build-orchestration','guest-provisioning')] [string] $ResultKind,
        [Parameter(Mandatory)] [ValidateNotNullOrEmpty()] [string] $RunId,
        [Parameter(Mandatory)] [ValidateSet('passed','failed','incomplete','skipped')] [string] $Outcome,
        [Parameter(Mandatory)] [datetime] $StartedUtc,
        [Parameter(Mandatory)] $Payload,
        [Parameter()] [ValidateSet(1,2)] [int] $ManifestSchemaVersion,
        [Parameter()] [datetime] $CompletedUtc = [datetime]::UtcNow
    )

    $validatedRunId = Assert-RunIdentifier -RunId $RunId
    AssertPayloadIsPublishable -Node $Payload

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

function AssertPayloadIsPublishable {
    <#
    .SYNOPSIS
        Refuses a payload carrying a value evidence may never contain.

    .DESCRIPTION
        Module-internal. Descent is bounded by type: probing whether a node has
        properties descends into primitives whose own properties are of the same
        type, which recurses without end.
    #>
    [CmdletBinding()]
    param(
        # AllowNull, because a payload legitimately carries null fields -- an
        # absent reason code, a phase that ran no validation -- and Mandatory
        # rejects null at binding, before this function's own null check runs.
        [Parameter(Mandatory)] [AllowNull()] $Node,
        [Parameter()] [string] $Location = 'payload',
        [Parameter()] [int] $Depth = 0
    )

    if ($Depth -gt 32) { throw "Evidence payload nests deeper than expected at $Location." }
    if ($null -eq $Node -or $Node -is [string] -or $Node -is [valuetype]) { return }

    if ($Node -is [System.Collections.IDictionary]) {
        foreach ($key in $Node.Keys) {
            if ($script:ForbiddenPayloadKeys -contains ([string] $key).ToLowerInvariant()) {
                throw "Evidence payload carries '$key' at $Location, which may never appear in evidence."
            }
            AssertPayloadIsPublishable -Node $Node[$key] -Location "$Location.$key" -Depth ($Depth + 1)
        }
        return
    }

    if ($Node -is [System.Collections.IList]) {
        for ($i = 0; $i -lt $Node.Count; $i++) {
            AssertPayloadIsPublishable -Node $Node[$i] -Location "$Location[$i]" -Depth ($Depth + 1)
        }
        return
    }

    if ($Node -is [System.Management.Automation.PSCustomObject]) {
        foreach ($property in $Node.PSObject.Properties) {
            if ($script:ForbiddenPayloadKeys -contains $property.Name.ToLowerInvariant()) {
                throw "Evidence payload carries '$($property.Name)' at $Location, which may never appear in evidence."
            }
            AssertPayloadIsPublishable -Node $property.Value -Location "$Location.$($property.Name)" -Depth ($Depth + 1)
        }
    }
}

Export-ModuleMember -Function ConvertTo-EvidenceEnvelope
