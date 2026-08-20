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

# Accepted by the harness so evidence retrieval and cleanup still run. The build
# is failed afterwards by the host, from evidence already collected.
$LogicalFailureExitCode = 200

function WriteHaltMarker {
    <#
        Written when a phase could not complete. The harness gates the restart on
        this file: an installer whose process tree could not be confirmed stopped
        may still be writing, and an incomplete install must never meet a reboot.
    #>
    param([string] $Reason)

    if ([string]::IsNullOrWhiteSpace($env:VDIIAC_HALT_PATH)) { return }
    try {
        Set-Content -LiteralPath $env:VDIIAC_HALT_PATH -Value $Reason -Encoding utf8 -NoNewline
    }
    catch {
        Write-Error "could not write the halt marker: $($_.Exception.Message)" -ErrorAction Continue
    }
}

function WriteBoundedEvidence {
    <#
        A minimal, schema-valid envelope for a phase that failed before it could
        produce one. Without it a descriptor-authentication failure leaves nothing
        to retrieve, and the host cannot tell a refused bundle from a lost
        communicator.
    #>
    param([string] $Path, [string] $Phase, [string] $RunIdentifier, [string] $ReasonCode)

    try {
        $envelope = ConvertTo-EvidenceEnvelope -ResultKind 'guest-provisioning' -RunId $RunIdentifier `
            -Outcome 'incomplete' -StartedUtc ([datetime]::UtcNow) -ManifestSchemaVersion 2 `
            -Payload ([ordered]@{
                phase = $Phase; restartRequired = $false
                packageCount = 0; passedCount = 0; failedRequiredCount = 0
                terminalReasonCode = $ReasonCode
                cleanupOutcome = 'not-attempted'
                packages = @()
            })

        $directory = Split-Path -Parent $Path
        if ($directory -and -not (Test-Path -LiteralPath $directory)) {
            $null = New-Item -ItemType Directory -Path $directory -Force
        }
        $envelope | ConvertTo-Json -Depth 16 | Set-Content -LiteralPath $Path -Encoding utf8
    }
    catch {
        Write-Error "could not write bounded evidence: $($_.Exception.Message)" -ErrorAction Continue
    }
}

# Declared before the try so the catch can reference it under StrictMode even
# when the failure happened before it was read.
$runId = $null

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

    if ($evidence.outcome -eq 'incomplete') {
        # Nothing is known about the guest's state. Evidence is already written;
        # the halt marker stops the harness before the restart.
        WriteHaltMarker -Reason "phase '$Phase' did not complete"
    }

    # A reported outcome, not a broken run. The harness accepts this code so
    # retrieval and cleanup happen before the host decides the build's fate.
    exit $LogicalFailureExitCode
}
catch {
    # The message stays out of every published artifact; only a bounded reason
    # code reaches evidence.
    $code = $_.Exception.Data['ReasonCode']
    $reasonCode = if ($code) { $code } else { 'unexpected_error' }
    Write-Error "guest phase '$Phase' could not run ($reasonCode)" -ErrorAction Continue

    # A descriptor that fails authentication used to leave nothing behind, so the
    # host could not tell a refused bundle from a lost communicator. It now
    # leaves bounded evidence to retrieve, and halts the run before the restart.
    if (-not [string]::IsNullOrWhiteSpace($runId)) {
        WriteBoundedEvidence -Path $EvidencePath -Phase $Phase -RunIdentifier $runId -ReasonCode $reasonCode
        WriteHaltMarker -Reason "phase '$Phase' could not run: $reasonCode"
        exit $LogicalFailureExitCode
    }

    # Without a run identifier no envelope can be built at all.
    exit 1
}
