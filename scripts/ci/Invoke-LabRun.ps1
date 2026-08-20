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
$runWork = New-RunDirectory -Root $WorkRoot -RunId $runId -Prefix 'lab'
$evidenceDirectory = Join-Path $runWork 'evidence'
$null = New-Item -ItemType Directory -Path $evidenceDirectory -Force

$bundle = $null
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

    & packer @arguments
    $packerExit = $LASTEXITCODE

    $verdict = Get-LabEvidenceOutcome -EvidenceDirectory $evidenceDirectory
    foreach ($phase in $verdict.Phases) {
        Write-Information ("  {0,-9} {1}" -f $phase.Phase, $phase.Outcome)
    }
    Write-Information "lab run: $($verdict.Outcome) (packer exit $packerExit)"

    switch ($verdict.Outcome) {
        'passed' { if ($packerExit -eq 0) { exit 0 } else { exit 2 } }
        'failed' { exit 1 }
        default  { exit 2 }
    }
}
finally {
    if ($bundle -and -not $KeepHostBundle -and $bundle.BundlePath -and (Test-Path -LiteralPath $bundle.BundlePath)) {
        Remove-Item -LiteralPath $bundle.BundlePath -Recurse -Force -ErrorAction SilentlyContinue
    }
}
