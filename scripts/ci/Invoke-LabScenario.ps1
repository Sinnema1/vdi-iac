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
# Generated per invocation, exactly as the main runner does. Omitting it left
# every scenario rejected by packer before the guest was ever reached.
$cleanupNonce = -join ((1..32) | ForEach-Object { '{0:x}' -f (Get-Random -Minimum 0 -Maximum 16) })
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
    "-var", "cleanup_nonce=$cleanupNonce"
    "-var", "bundle_path=$($bundle.BundlePath)"
    "-var", "descriptor_sha256=$digest"
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

$verdict = Get-LabEvidenceOutcome -EvidenceDirectory $evidenceDirectory -RunId $runId `
    -PackerExitCode $packerExit -RequireValidatePhase $true
if ($verdict.Reason -eq 'evidence_missing') {
    $halted = Get-LabEvidenceOutcome -EvidenceDirectory $evidenceDirectory -RunId $runId `
        -PackerExitCode $packerExit -RequireValidatePhase $false
    if ($halted.Outcome -eq 'incomplete' -and $halted.Reason -ne 'evidence_missing') { $verdict = $halted }
}

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

# The scenario's own assertions, read from schema-validated guest evidence rather
# than from console text.
$observation = Get-LabScenarioObservation -EvidenceDirectory $evidenceDirectory -RunId $runId

Write-Information "  outcome            : $($orchestration.outcome) (expected $($definition.ExpectedOutcome))"
Write-Information "  reason code        : $($observation.ReasonCode) (expected $($definition.ExpectedReasonCode))"
Write-Information "  installers started : $($observation.InstallerAttemptCount) (expected installed: $($definition.ExpectInstalled))"
Write-Information "  host cleanup       : $hostCleanup"
Write-Information "  guest cleanup      : $guestCleanup"
Write-Information "  evidence           : $evidenceDirectory"

$scenarioVerdict = Get-LabScenarioVerdict -Definition $definition -Outcome $orchestration.outcome `
    -ObservedReasonCode $observation.ReasonCode -InstallerAttemptCount $observation.InstallerAttemptCount `
    -HostCleanupOutcome $hostCleanup -GuestCleanupOutcome $guestCleanup

$failures = $scenarioVerdict.Failures

if ($failures.Count -eq 0) {
    Write-Information "scenario '$Scenario': as expected"
    exit 0
}

foreach ($failure in $failures) { Write-Error "scenario '$Scenario': $failure" -ErrorAction Continue }
exit 1
