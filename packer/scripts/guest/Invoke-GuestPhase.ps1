#!/usr/bin/env pwsh
#Requires -Version 7.0

<#
.SYNOPSIS
    Guest-side entry point invoked by the Packer harness.

.DESCRIPTION
    Runs one phase of guest provisioning and writes its evidence, then reports
    the outcome through an exit code the harness can distinguish.

    Two exit codes matter. Zero means the phase did what it was asked. The
    logical-failure code means packages failed for reasons the run is designed to
    report, and the harness lists it in valid_exit_codes so evidence retrieval
    and cleanup still run before the host evaluator fails the build. Anything
    else is a genuine failure of this script and stays one.

    The expected descriptor digest arrives through the environment rather than
    inside the bundle. A descriptor carrying its own expected digest would
    authenticate itself, which is no authentication at all.

.NOTES
    Exit codes:
      0    the phase completed and no package failed
      200  the phase completed and packages failed, or the run is incomplete
      1    this script could not run
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)] [ValidateNotNullOrEmpty()] [string] $BundlePath,
    [Parameter(Mandatory)] [ValidateNotNullOrEmpty()] [string] $ToolsPath,
    [Parameter(Mandatory)] [ValidateSet('install', 'validate')] [string] $Phase,
    [Parameter(Mandatory)] [ValidateNotNullOrEmpty()] [string] $EvidencePath
)

Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'
$InformationPreference = 'Continue'

$LogicalFailureExitCode = 200

try {
    $expectedDigest = $env:VDIIAC_DESCRIPTOR_SHA256
    if ([string]::IsNullOrWhiteSpace($expectedDigest)) {
        throw 'VDIIAC_DESCRIPTOR_SHA256 is not set. The expected descriptor digest is delivered out of band and is required before the descriptor is read.'
    }

    $runId = $env:VDIIAC_RUN_ID
    if ([string]::IsNullOrWhiteSpace($runId)) {
        throw 'VDIIAC_RUN_ID is not set. Evidence from this phase would not correlate with the rest of the run.'
    }

    foreach ($module in 'PackageManifest', 'RunIdentity', 'Evidence', 'SourceQualification', 'GuestAdapter', 'TransferBundle', 'GuestProvisioning') {
        Import-Module (Join-Path $ToolsPath "$module.psm1") -Force
    }

    $evidence = Invoke-GuestProvisioning -BundlePath $BundlePath -Phase $Phase `
        -ExpectedDescriptorSha256 $expectedDigest -RunId $runId

    $directory = Split-Path -Parent $EvidencePath
    if ($directory -and -not (Test-Path -LiteralPath $directory)) {
        $null = New-Item -ItemType Directory -Path $directory -Force
    }
    $evidence | ConvertTo-Json -Depth 16 | Set-Content -LiteralPath $EvidencePath -Encoding utf8

    Write-Information "guest phase '$Phase': $($evidence.outcome)"

    if ($evidence.outcome -eq 'passed') { exit 0 }

    # A reported failure, not a broken run. The harness accepts this code so
    # retrieval and cleanup happen before the host decides the build's fate.
    exit $LogicalFailureExitCode
}
catch {
    # No evidence to retrieve for this phase, and the message stays out of any
    # published artifact.
    Write-Error "guest phase '$Phase' could not run: $($_.Exception.Message)" -ErrorAction Continue
    exit 1
}
