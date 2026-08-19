#!/usr/bin/env pwsh
#Requires -Version 7.0

<#
.SYNOPSIS
    Qualifies every package in a manifest and writes structured evidence.

.DESCRIPTION
    Entry point for host-side source qualification. Reads and validates a
    manifest, resolves each source beneath the source root, stages it, and
    verifies it against the expected SHA-256 from the manifest.

    Evidence is written as JSON. Nothing in the result contains a credential or
    a path outside the run, so it is safe to retain and publish alongside a
    build.

.PARAMETER ManifestPath
    Path to the package manifest.

.PARAMETER SourceRoot
    Directory that manifest source references resolve beneath.

.PARAMETER StagingRoot
    Parent directory for per-run staging. Defaults to the system temp path.

.PARAMETER EvidencePath
    Where to write the JSON result. Optional; the object is always returned.

.PARAMETER KeepStaging
    Retain staged content for diagnosis.

.OUTPUTS
    The aggregate result object.

.NOTES
    Exit codes:
      0  every required package qualified
      1  at least one required package failed
      2  the run could not complete, for example an invalid manifest
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)] [ValidateNotNullOrEmpty()] [string] $ManifestPath,
    [Parameter(Mandatory)] [ValidateNotNullOrEmpty()] [string] $SourceRoot,
    [Parameter()] [ValidateNotNullOrEmpty()] [string] $StagingRoot = ([System.IO.Path]::GetTempPath()),
    [Parameter()] [string] $EvidencePath,
    [Parameter()] [switch] $KeepStaging
)

Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'

# Progress lines go to the information stream so a caller can capture or silence
# them with -InformationAction. The result object stays the only thing on the
# success stream.
$InformationPreference = 'Continue'

Import-Module (Join-Path $PSScriptRoot 'PackageManifest.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'SourceQualification.psm1') -Force

try {
    $manifest = Import-PackageManifest -Path $ManifestPath
    $result = Invoke-SourceQualification -Manifest $manifest -SourceRoot $SourceRoot -StagingRoot $StagingRoot -KeepStaging:$KeepStaging
}
catch {
    # -ErrorAction Continue is required here: under $ErrorActionPreference = 'Stop'
    # a Write-Error is itself terminating, which would end the script before the
    # intended exit code is set and surface as 1 instead of 2.
    Write-Error "source-qualification: could not complete -- $($_.Exception.Message)" -ErrorAction Continue
    exit 2
}

if ($EvidencePath) {
    $evidenceDirectory = Split-Path -Parent $EvidencePath
    if ($evidenceDirectory -and -not (Test-Path -LiteralPath $evidenceDirectory)) {
        $null = New-Item -ItemType Directory -Path $evidenceDirectory -Force
    }
    $result | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $EvidencePath -Encoding utf8
    Write-Verbose "Evidence written to $EvidencePath"
}

foreach ($package in $result.Packages) {
    $label = if ($package.Required) { 'required' } else { 'optional' }
    if ($package.Outcome -eq 'passed') {
        Write-Information ("  passed  {0} {1} ({2})" -f $package.Id, $package.Version, $label)
    }
    else {
        Write-Information ("  FAILED  {0} {1} ({2}) -- {3}" -f $package.Id, $package.Version, $label, $package.Reason)
    }
}

Write-Information ("source-qualification: {0} -- {1}/{2} passed, {3} required failure(s), {4} optional failure(s)" -f
    $result.Outcome, $result.PassedCount, $result.PackageCount, $result.FailedRequiredCount, $result.FailedOptionalCount)

$result

if ($result.Outcome -ne 'passed') { exit 1 }
exit 0
