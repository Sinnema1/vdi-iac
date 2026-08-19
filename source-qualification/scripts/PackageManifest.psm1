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

$script:ContractDirectory = Join-Path $PSScriptRoot '..' '..' 'contracts'

# Hard-coded version map. A schema path is never built from the declared value,
# and there is no fallback to the newest schema: an unrecognized version is
# rejected. Version 1 keeps its original filename because it is frozen
# byte-for-byte at that path; only later versions carry a version suffix.
$script:SchemaFileByVersion = @{
    1 = 'package-manifest.schema.json'
    2 = 'package-manifest-2.schema.json'
}

# Reserved for the executor. A manifest naming one is rejected with that reason,
# rather than as an unknown field, which would misdescribe why.
$script:ExecutorOwnedMsiProperties = @('REBOOT', 'REBOOTPROMPT', 'TRANSFORMS', 'PATCH', 'ACTION', 'REINSTALL', 'REINSTALLMODE')

# An installer that initiates its own reboot takes the restart boundary away
# from Packer, so this code is never a success or restart-required signal.
$script:ForbiddenExitCode = 1641

function Import-PackageManifest {
    <#
    .SYNOPSIS
        Reads, validates, and normalizes a package manifest.

    .PARAMETER Path
        Path to the manifest file.

    .PARAMETER SchemaDirectory
        Directory holding the committed schemas. Defaults to contracts/. The
        schema file itself is chosen by the version map, never by the caller.

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
        [string] $SchemaDirectory = $script:ContractDirectory
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "Manifest not found: $Path"
    }
    $raw = Get-Content -LiteralPath $Path -Raw -Encoding utf8
    if ([string]::IsNullOrWhiteSpace($raw)) {
        throw "Manifest is empty: $Path"
    }

    # Parse before validating, because the declared version selects the schema.
    # Parsing is safe; the only thing done with parsed content before validation
    # is a lookup in a fixed table.
    try {
        $manifest = $raw | ConvertFrom-Json
    }
    catch {
        throw "Manifest is not valid JSON: $Path -- $($_.Exception.Message)"
    }

    $declared = if ($manifest.PSObject.Properties.Name -contains 'schemaVersion') { $manifest.schemaVersion } else { $null }

    # ConvertFrom-Json yields [long] for JSON integers, so both integral types
    # are accepted. A number with a fractional part parses as [double] and is
    # refused here rather than being truncated into a version.
    if ($declared -isnot [int] -and $declared -isnot [long]) {
        throw "Manifest does not declare an integer schemaVersion: $Path"
    }
    $declared = [int] $declared

    if (-not $script:SchemaFileByVersion.ContainsKey($declared)) {
        $known = ($script:SchemaFileByVersion.Keys | Sort-Object) -join ', '
        throw "Manifest declares unsupported schemaVersion $declared. Supported versions: $known -- $Path"
    }

    $schemaPath = Join-Path $SchemaDirectory $script:SchemaFileByVersion[$declared]
    if (-not (Test-Path -LiteralPath $schemaPath -PathType Leaf)) {
        throw "Manifest schema not found: $schemaPath"
    }

    # Stage one: structure, types, and value patterns.
    #
    # Test-Json writes its own error record before returning false, which would
    # surface as noise ahead of the message that actually explains the failure.
    $schemaErrors = $null
    $structurallyValid = Test-Json -Json $raw -SchemaFile $schemaPath -ErrorAction SilentlyContinue -ErrorVariable schemaErrors
    if (-not $structurallyValid) {
        $detail = if ($schemaErrors) { ($schemaErrors | ForEach-Object { $_.ToString() }) -join '; ' } else { 'no detail reported' }
        throw "Manifest failed schema validation: $Path -- $detail"
    }

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

    if ([int] $Manifest.schemaVersion -ge 2) {
        Assert-PackageInstallerConsistency -Manifest $Manifest -Path $Path
    }
}

function Assert-PackageInstallerConsistency {
    <#
    .SYNOPSIS
        Enforces schema version 2 rules that span fields.

    .DESCRIPTION
        JSON Schema constrains each field in isolation. These rules relate two
        fields to each other, or relate a field to the set the executor reserves,
        and none can be written as a per-field constraint.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $Manifest,
        [Parameter(Mandatory)] [string] $Path
    )

    foreach ($package in $Manifest.packages) {
        $installer = $package.installer
        $label = "package '$($package.id)'"

        # The source extension and the declared kind describe one file, so a
        # disagreement means one of them is wrong.
        $extension = [System.IO.Path]::GetExtension($package.source).TrimStart('.').ToLowerInvariant()
        if ($extension -ne $installer.kind) {
            throw "$label declares installer kind '$($installer.kind)' but its source ends in '.$extension' -- $Path"
        }

        if ($installer.kind -eq 'msi') {
            $names = @()
            if ($installer.PSObject.Properties.Name -contains 'properties' -and $installer.properties) {
                $names = @($installer.properties.PSObject.Properties.Name)
            }
            # The schema already refuses unknown names. This exists so a reserved
            # one is refused with its actual reason: the property is real, and
            # ours, which "unknown field" would not convey.
            $reserved = @($names | Where-Object { $script:ExecutorOwnedMsiProperties -contains $_.ToUpperInvariant() })
            if ($reserved) {
                throw "$label sets MSI properties the executor owns: $($reserved -join ', '). Restart and transform behavior are not manifest-controlled -- $Path"
            }
        }
        else {
            $success = @($installer.exitCodes.success)
            $restart = @()
            if ($installer.exitCodes.PSObject.Properties.Name -contains 'restartRequired') {
                $restart = @($installer.exitCodes.restartRequired)
            }

            $forbidden = @(($success + $restart) | Where-Object { $_ -eq $script:ForbiddenExitCode })
            if ($forbidden) {
                throw "$label lists exit code $script:ForbiddenExitCode, which means the installer initiated a reboot outside Packer's control and is always a failure -- $Path"
            }

            $overlap = @($success | Where-Object { $restart -contains $_ })
            if ($overlap) {
                throw "$label lists exit code(s) $($overlap -join ', ') as both success and restart-required, so the outcome is ambiguous -- $Path"
            }
        }

        $duplicateChecks = $package.validation |
            Group-Object -Property id |
            Where-Object Count -GT 1 |
            ForEach-Object { $_.Name }
        if ($duplicateChecks) {
            throw "$label has duplicate validation check ids: $($duplicateChecks -join ', ') -- $Path"
        }
    }
}

Export-ModuleMember -Function Import-PackageManifest, Assert-PackageManifestConsistency, Assert-PackageInstallerConsistency
