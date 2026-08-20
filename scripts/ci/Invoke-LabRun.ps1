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
$startedUtc = [datetime]::UtcNow
$runWork = New-RunDirectory -Root $WorkRoot -RunId $runId -Prefix 'lab'
$evidenceDirectory = Join-Path $runWork 'evidence'
$null = New-Item -ItemType Directory -Path $evidenceDirectory -Force

$bundle = $null
$packerExit = $null
$hostCleanup = 'not-attempted'
$guestCleanup = 'not-attempted'

try {
    Write-Information "lab run $runId"

    $bundle = New-TransferBundle -ManifestPath $ManifestPath -SourceRoot $SourceRoot `
        -BundleRoot (Join-Path $runWork 'bundles') -RunId $runId
    if ($bundle.Outcome -ne 'passed') {
        Write-Error "lab run: bundle assembly did not pass ($($bundle.Outcome)). Nothing was uploaded." -ErrorAction Continue
        exit 2
    }

    $arguments = @(
        'build'
        '-on-error=run-cleanup-provisioner'
        "-var-file=$VarFile"
        "-var", "run_id=$runId"
        "-var", "bundle_path=$($bundle.BundlePath)"
        "-var", "descriptor_sha256=$($bundle.DescriptorSha256)"
        "-var", "evidence_output_dir=$evidenceDirectory"
        "-var", "tools_source_dir=$(Join-Path $repoRoot 'source-qualification' 'scripts')"
        "-var", "guest_scripts_dir=$(Join-Path $repoRoot 'packer' 'scripts' 'guest')"
        (Join-Path $repoRoot 'packer' 'harness')
    )

    if (-not $PSCmdlet.ShouldProcess($VarFile, 'Run the lab harness against the configured target')) {
        exit 0
    }

    $packerOutput = & packer @arguments 2>&1
    $packerExit = $LASTEXITCODE
    $packerOutput | ForEach-Object { Write-Information $_ }

    # The harness reports its own cleanup step. Reading it from output rather
    # than assuming it: a run that never reached the step has not attempted it.
    $guestCleanup = if ($packerOutput -match 'guest cleanup: run directory removed') { 'removed' }
                    elseif ($packerOutput -match 'error cleanup: staging removed') { 'removed' }
                    elseif ($packerOutput -match 'guest cleanup: run directory still present') { 'failed' }
                    elseif ($packerOutput -match 'error cleanup: staging still present') { 'failed' }
                    elseif ($packerOutput -match 'no ownership sentinel') { 'not-attempted' }
                    else { 'not-attempted' }

    # A halted run stops before the restart deliberately, so its missing validate
    # evidence is the designed behavior rather than a gap in the record.
    $halted = [bool]($packerOutput -match 'Refusing to restart a guest')

    $verdict = Get-LabEvidenceOutcome -EvidenceDirectory $evidenceDirectory -RunId $runId `
        -PackerExitCode $packerExit -RequireValidatePhase (-not $halted)

    foreach ($phase in $verdict.Phases) {
        Write-Information ("  {0,-9} {1}" -f $phase.phase, $phase.outcome)
    }
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
                # Recorded, not suppressed. A cleanup failure nobody records is a
                # cleanup failure nobody can audit.
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
    exit 2
}

$orchestration = Get-LabOrchestrationEvidence -RunId $runId -Verdict $verdict `
    -HostCleanupOutcome $hostCleanup -GuestCleanupOutcome $guestCleanup -StartedUtc $startedUtc

$orchestrationPath = Join-Path $evidenceDirectory 'orchestration-evidence.json'
$orchestration | ConvertTo-Json -Depth 16 | Set-Content -LiteralPath $orchestrationPath -Encoding utf8

Write-Information "lab run: $($orchestration.outcome) (packer exit $packerExit, host cleanup $hostCleanup, guest cleanup $guestCleanup)"
Write-Information "evidence: $evidenceDirectory"

switch ($orchestration.outcome) {
    'passed' { exit 0 }
    'failed' { exit 1 }
    default  { exit 2 }
}
