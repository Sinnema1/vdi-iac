#Requires -Version 7.0

<#
.SYNOPSIS
    Reads and validates a package manifest.

.DESCRIPTION
    Validation is two-stage, as recorded in ADR 1. The committed JSON Schema
    covers structure, types, and value patterns. This module covers what a
    schema cannot express: uniqueness of identifiers and ordering keys.

    Every failure is terminating. A manifest that does not fully conform stops
    the caller rather than yielding a partially trusted object.
#>

Set-StrictMode -Version 3.0

$script:SchemaPath = Join-Path $PSScriptRoot '..' '..' 'contracts' 'package-manifest.schema.json'

function Import-PackageManifest {
    <#
    .SYNOPSIS
        Reads, validates, and normalizes a package manifest.

    .PARAMETER Path
        Path to the manifest file.

    .PARAMETER SchemaPath
        Path to the JSON Schema. Defaults to the committed contract.

    .OUTPUTS
        A PSCustomObject with SchemaVersion and Packages, the latter sorted by
        Order. Sorting happens here so every consumer sees the same sequence.
    #>
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string] $Path,

        [Parameter()]
        [ValidateNotNullOrEmpty()]
        [string] $SchemaPath = $script:SchemaPath
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "Manifest not found: $Path"
    }
    if (-not (Test-Path -LiteralPath $SchemaPath -PathType Leaf)) {
        throw "Manifest schema not found: $SchemaPath"
    }

    $raw = Get-Content -LiteralPath $Path -Raw -Encoding utf8
    if ([string]::IsNullOrWhiteSpace($raw)) {
        throw "Manifest is empty: $Path"
    }

    # Stage one: structure, types, and value patterns.
    #
    # Test-Json writes its own error record before returning false, which would
    # surface as noise ahead of the message that actually explains the failure.
    $schemaErrors = $null
    $structurallyValid = Test-Json -Json $raw -SchemaFile $SchemaPath -ErrorAction SilentlyContinue -ErrorVariable schemaErrors
    if (-not $structurallyValid) {
        $detail = if ($schemaErrors) { ($schemaErrors | ForEach-Object { $_.ToString() }) -join '; ' } else { 'no detail reported' }
        throw "Manifest failed schema validation: $Path -- $detail"
    }

    $manifest = $raw | ConvertFrom-Json

    # Stage two: constraints a schema cannot express.
    Assert-PackageManifestConsistency -Manifest $manifest -Path $Path

    [PSCustomObject]@{
        SchemaVersion = $manifest.schemaVersion
        Packages      = @($manifest.packages | Sort-Object -Property order)
        Source        = (Resolve-Path -LiteralPath $Path).Path
    }
}

function Assert-PackageManifestConsistency {
    <#
    .SYNOPSIS
        Enforces manifest rules that JSON Schema cannot express.

    .DESCRIPTION
        Duplicate identifiers make a result set ambiguous. Duplicate ordering
        keys make the install sequence non-deterministic, which defeats the
        purpose of pinning inputs at all.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $Manifest,
        [Parameter(Mandatory)] [string] $Path
    )

    $duplicateIds = $Manifest.packages |
        Group-Object -Property id |
        Where-Object Count -GT 1 |
        ForEach-Object { $_.Name }
    if ($duplicateIds) {
        throw "Manifest has duplicate package ids: $($duplicateIds -join ', ') -- $Path"
    }

    $duplicateOrders = $Manifest.packages |
        Group-Object -Property order |
        Where-Object Count -GT 1 |
        ForEach-Object { $_.Name }
    if ($duplicateOrders) {
        throw "Manifest has duplicate order values, so the sequence is not deterministic: $($duplicateOrders -join ', ') -- $Path"
    }
}

Export-ModuleMember -Function Import-PackageManifest, Assert-PackageManifestConsistency
