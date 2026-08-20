#!/usr/bin/env pwsh
#Requires -Version 7.0

<#
.SYNOPSIS
    Runs one lab pass: build the bundle, drive the Packer harness, evaluate.

.DESCRIPTION
    Host-side orchestration for Stage 5. It owns the ordering the guest cannot:
    evidence retrieval, then guest cleanup, then host cleanup, then evaluation.

    Evaluation is last on purpose. A run that fails before retrieving evidence
    has destroyed the explanation of its own failure, so the build's fate is
    decided from evidence already on the host.

    Packer is invoked with -on-error=run-cleanup-provisioner. Declaring an
    error-cleanup-provisioner is not sufficient: under the default
    -on-error=cleanup it never executes, and a harness that declares one and
    invokes packer build plainly has cleanup that never runs.

    The guest staging root is passed in as host-controlled configuration and is
    never read or derived from the uploaded descriptor, because cleanup has to
    work after descriptor tampering.

.NOTES
    Exit codes:
      0  every required package qualified, installed, and validated
      1  the run completed and reported a failure
      2  the run could not complete
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)] [ValidateNotNullOrEmpty()] [string] $ManifestPath,
    [Parameter(Mandatory)] [ValidateNotNullOrEmpty()] [string] $SourceRoot,
    [Parameter(Mandatory)] [ValidateNotNullOrEmpty()] [string] $VarFile,
    [Parameter()] [ValidateNotNullOrEmpty()] [string] $WorkRoot = ([System.IO.Path]::GetTempPath()),
    [Parameter()] [switch] $KeepHostBundle
)

Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'
$InformationPreference = 'Continue'

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..' '..')).Path
foreach ($module in 'PackageManifest', 'RunIdentity', 'Evidence', 'SourceQualification', 'TransferBundle') {
    Import-Module (Join-Path $repoRoot 'source-qualification' 'scripts' "$module.psm1") -Force
}
Import-Module (Join-Path $PSScriptRoot 'LabEvidence.psm1') -Force

$runId = Get-RunIdentifier
$cleanupNonce = -join ((1..32) | ForEach-Object { '{0:x}' -f (Get-Random -Minimum 0 -Maximum 16) })
$startedUtc = [datetime]::UtcNow
$runWork = New-RunDirectory -Root $WorkRoot -RunId $runId -Prefix 'lab'
$evidenceDirectory = Join-Path $runWork 'evidence'
$null = New-Item -ItemType Directory -Path $evidenceDirectory -Force

# One exit, at the end, after evidence is written. Every earlier path sets these
# and falls through: a run that returns early has skipped cleanup and left no
# record of what it did.
$bundle = $null
$packerExit = $null
$hostCleanup = 'not-attempted'
$guestCleanup = 'not-attempted'
$verdict = $null
$terminalReason = $null

Write-Information "lab run $runId"

try {
    $bundle = New-TransferBundle -ManifestPath $ManifestPath -SourceRoot $SourceRoot `
        -BundleRoot (Join-Path $runWork 'bundles') -RunId $runId

    if ($bundle.Outcome -ne 'passed') {
        # Nothing was uploaded, so there is nothing on the guest to clean up.
        $terminalReason = 'bundle_assembly_failed'
        $guestCleanup = 'removed'
    }
    elseif (-not $PSCmdlet.ShouldProcess($VarFile, 'Run the lab harness against the configured target')) {
        # -WhatIf still produces an envelope. A run that reports nothing is
        # indistinguishable from one that was never asked to report.
        $terminalReason = $null
        $guestCleanup = 'not-attempted'
        $verdict = [PSCustomObject]@{ Outcome = 'skipped'; Reason = $null; Phases = @(); PackerExitCode = $null }
    }
    else {
        $arguments = @(
            'build'
            '-on-error=run-cleanup-provisioner'
            "-var-file=$VarFile"
            "-var", "run_id=$runId"
            "-var", "cleanup_nonce=$cleanupNonce"
            "-var", "bundle_path=$($bundle.BundlePath)"
            "-var", "descriptor_sha256=$($bundle.DescriptorSha256)"
            "-var", "evidence_output_dir=$evidenceDirectory"
            "-var", "tools_source_dir=$(Join-Path $repoRoot 'source-qualification' 'scripts')"
            "-var", "guest_scripts_dir=$(Join-Path $repoRoot 'packer' 'scripts' 'guest')"
            "-var", "contracts_source_dir=$(Join-Path $repoRoot 'contracts')"
            (Join-Path $repoRoot 'packer' 'harness')
        )

        $build = Invoke-PackerBuild -Arguments $arguments
        $packerExit = $build.ExitCode
        $build.Output | ForEach-Object { Write-Information $_ }

        $guestCleanup = Get-GuestCleanupOutcome -PackerOutput $build.Output

        # Whether the run halted before the restart is decided by the install
        # evidence, not by matching console text.
        $verdict = Get-LabEvidenceOutcome -EvidenceDirectory $evidenceDirectory -RunId $runId `
            -PackerExitCode $packerExit -RequireValidatePhase $true

        if ($verdict.Reason -eq 'evidence_missing') {
            $halted = Get-LabEvidenceOutcome -EvidenceDirectory $evidenceDirectory -RunId $runId `
                -PackerExitCode $packerExit -RequireValidatePhase $false
            if ($halted.Outcome -eq 'incomplete' -and $halted.Reason -ne 'evidence_missing') {
                $verdict = $halted
            }
        }

        foreach ($phase in $verdict.Phases) {
            Write-Information ("  {0,-9} {1}" -f $phase.phase, $phase.outcome)
        }
    }
}
catch {
    $terminalReason = 'unexpected_error'
    Write-Information "lab run failed: $($_.Exception.Message)"
}
finally {
    if ($bundle -and $bundle.BundlePath -and (Test-Path -LiteralPath $bundle.BundlePath)) {
        if ($KeepHostBundle) {
            $hostCleanup = 'retained'
        }
        else {
            try {
                Remove-Item -LiteralPath $bundle.BundlePath -Recurse -Force -ErrorAction Stop
                $hostCleanup = if (Test-Path -LiteralPath $bundle.BundlePath) { 'failed' } else { 'removed' }
            }
            catch {
                $hostCleanup = 'failed'
                Write-Information "host cleanup failed: $($_.Exception.Message)"
            }
        }
    }
    else {
        $hostCleanup = 'removed'
    }
}

if (-not $verdict) {
    $verdict = [PSCustomObject]@{
        Outcome = 'incomplete'
        Reason = if ($terminalReason) { $terminalReason } else { 'unexpected_error' }
        Phases = @()
        PackerExitCode = $packerExit
    }
}

$orchestration = Get-LabOrchestrationEvidence -RunId $runId -Verdict $verdict `
    -HostCleanupOutcome $hostCleanup -GuestCleanupOutcome $guestCleanup -StartedUtc $startedUtc

$orchestrationPath = Join-Path $evidenceDirectory 'orchestration-evidence.json'
$orchestration | ConvertTo-Json -Depth 16 | Set-Content -LiteralPath $orchestrationPath -Encoding utf8

Write-Information "lab run: $($orchestration.outcome) (packer exit $packerExit, host cleanup $hostCleanup, guest cleanup $guestCleanup)"
Write-Information "evidence: $evidenceDirectory"

switch ($orchestration.outcome) {
    'passed'  { exit 0 }
    'skipped' { exit 0 }
    'failed'  { exit 1 }
    default   { exit 2 }
}
