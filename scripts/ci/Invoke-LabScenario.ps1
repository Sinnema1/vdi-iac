#!/usr/bin/env pwsh
#Requires -Version 7.0

<#
.SYNOPSIS
    Runs one Level 3 lab scenario against a supplied disposable target.

.DESCRIPTION
    The three scenarios ADR 3 requires: a positive run, a payload-tampering run
    refused by the per-package hash comparison, and a descriptor-tampering run
    refused by the digest delivered out of band.

    Runnable as soon as a target is supplied. Until one is, these are definitions
    rather than results, and the increment's maturity says so.

    Tampering is applied after the bundle is assembled and verified, which is the
    point: it stands in for content altered in transit, between the host proving
    a payload matches its manifest entry and the guest receiving it.

.NOTES
    Exit codes:
      0  the scenario ended exactly as it was expected to
      1  the scenario ran and ended differently
      2  the scenario could not be run to a conclusion
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)] [ValidateSet('positive','payload-tamper','descriptor-tamper')] [string] $Scenario,
    [Parameter(Mandatory)] [ValidateNotNullOrEmpty()] [string] $ManifestPath,
    [Parameter(Mandatory)] [ValidateNotNullOrEmpty()] [string] $SourceRoot,
    [Parameter(Mandatory)] [ValidateNotNullOrEmpty()] [string] $VarFile,
    [Parameter()] [ValidateNotNullOrEmpty()] [string] $WorkRoot = ([System.IO.Path]::GetTempPath())
)

Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'
$InformationPreference = 'Continue'

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..' '..')).Path
foreach ($module in 'PackageManifest', 'RunIdentity', 'Evidence', 'SourceQualification', 'TransferBundle') {
    Import-Module (Join-Path $repoRoot 'source-qualification' 'scripts' "$module.psm1") -Force
}
Import-Module (Join-Path $PSScriptRoot 'LabEvidence.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'LabScenario.psm1') -Force

$definition = Get-LabScenario -Name $Scenario
Write-Information "scenario '$Scenario': $($definition.Description)"

$runId = Get-RunIdentifier
$startedUtc = [datetime]::UtcNow
$runWork = New-RunDirectory -Root $WorkRoot -RunId $runId -Prefix 'scenario'
$evidenceDirectory = Join-Path $runWork 'evidence'
$null = New-Item -ItemType Directory -Path $evidenceDirectory -Force

$bundle = New-TransferBundle -ManifestPath $ManifestPath -SourceRoot $SourceRoot `
    -BundleRoot (Join-Path $runWork 'bundles') -RunId $runId
if ($bundle.Outcome -ne 'passed') {
    Write-Error "scenario '$Scenario': bundle assembly did not pass. Nothing was uploaded." -ErrorAction Continue
    exit 2
}

# Applied after verification, standing in for alteration in transit. The digest
# returned is the one the orchestrator delivers out of band: an attacker cannot
# change what was already sent, which is exactly what the descriptor scenario
# depends on.
$digest = Set-LabBundleTampering -BundlePath $bundle.BundlePath `
    -OriginalDigest $bundle.DescriptorSha256 -Tamper $definition.Tamper

if (-not $PSCmdlet.ShouldProcess($VarFile, "Run scenario '$Scenario' against the configured target")) {
    exit 0
}

$arguments = @(
    'build'
    '-on-error=run-cleanup-provisioner'
    "-var-file=$VarFile"
    "-var", "run_id=$runId"
    "-var", "bundle_path=$($bundle.BundlePath)"
    "-var", "descriptor_sha256=$digest"
    "-var", "evidence_output_dir=$evidenceDirectory"
    "-var", "tools_source_dir=$(Join-Path $repoRoot 'source-qualification' 'scripts')"
    "-var", "guest_scripts_dir=$(Join-Path $repoRoot 'packer' 'scripts' 'guest')"
    (Join-Path $repoRoot 'packer' 'harness')
)

$packerOutput = & packer @arguments 2>&1
$packerExit = $LASTEXITCODE
$packerOutput | ForEach-Object { Write-Information $_ }

# The execution witness. A negative scenario that refuses content but runs the
# installer anyway has not demonstrated the control it claims to.
$installerRan = [bool]($packerOutput -match 'guest phase ''install'': passed')

$guestCleanup = if ($packerOutput -match 'guest cleanup: run directory removed') { 'removed' }
                elseif ($packerOutput -match 'error cleanup: staging removed') { 'removed' }
                elseif ($packerOutput -match 'still present') { 'failed' }
                else { 'not-attempted' }

$halted = [bool]($packerOutput -match 'Refusing to restart a guest')
$verdict = Get-LabEvidenceOutcome -EvidenceDirectory $evidenceDirectory -RunId $runId `
    -PackerExitCode $packerExit -RequireValidatePhase (-not $halted)

$hostCleanup = 'not-attempted'
if (Test-Path -LiteralPath $bundle.BundlePath) {
    try {
        Remove-Item -LiteralPath $bundle.BundlePath -Recurse -Force -ErrorAction Stop
        $hostCleanup = if (Test-Path -LiteralPath $bundle.BundlePath) { 'failed' } else { 'removed' }
    }
    catch { $hostCleanup = 'failed' }
}
else { $hostCleanup = 'removed' }

$orchestration = Get-LabOrchestrationEvidence -RunId $runId -Verdict $verdict `
    -HostCleanupOutcome $hostCleanup -GuestCleanupOutcome $guestCleanup -StartedUtc $startedUtc
$orchestration | ConvertTo-Json -Depth 16 |
    Set-Content -LiteralPath (Join-Path $evidenceDirectory 'orchestration-evidence.json') -Encoding utf8

Write-Information "  outcome        : $($orchestration.outcome) (expected $($definition.ExpectedOutcome))"
Write-Information "  installer ran  : $installerRan (expected $($definition.ExpectInstalled))"
Write-Information "  host cleanup   : $hostCleanup"
Write-Information "  guest cleanup  : $guestCleanup"
Write-Information "  evidence       : $evidenceDirectory"

$matchedOutcome = $orchestration.outcome -eq $definition.ExpectedOutcome
$matchedWitness = $installerRan -eq $definition.ExpectInstalled
$cleanupAttempted = $hostCleanup -ne 'not-attempted' -and $guestCleanup -ne 'not-attempted'

if (-not $cleanupAttempted) {
    Write-Error "scenario '$Scenario': cleanup was not attempted on both sides." -ErrorAction Continue
    exit 2
}
if ($matchedOutcome -and $matchedWitness) { exit 0 }

Write-Error "scenario '$Scenario' did not end as expected." -ErrorAction Continue
exit 1
