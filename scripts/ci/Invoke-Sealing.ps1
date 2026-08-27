#!/usr/bin/env pwsh
#Requires -Version 7.0

<#
.SYNOPSIS
    Seals a candidate after a Packer build, on the host.

.DESCRIPTION
    The entry point for stage 6. It runs after Packer exits, because conversion
    is static configuration and cannot be conditional: inside the build it would
    convert whatever the build produced.

    Whether the build succeeded is taken from Packer's actual exit code, not
    from a caller's assertion. A wrapper that passed a flag would let a failed
    build be sealed by a script that forgot to check.

    The process status reflects durability, not just outcome. A seal that could
    not write its evidence exits non-zero even though the platform work may have
    succeeded, because code whose evidence sink is unavailable cannot claim a
    durable record and something downstream will need to reconcile.

    Nothing here has run against vCenter.
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)] [ValidateNotNullOrEmpty()] [string] $RunId,
    [Parameter(Mandatory)] [ValidateNotNullOrEmpty()] [string] $Nonce,
    [Parameter(Mandatory)] [ValidateNotNullOrEmpty()] [string] $CandidateName,
    [Parameter(Mandatory)] [int] $PackerExitCode,
    [Parameter(Mandatory)] [ValidateNotNullOrEmpty()] [string] $EvidenceRoot,
    [Parameter(Mandatory)] [ValidateNotNullOrEmpty()] [string] $RecipeDigest,
    [Parameter(Mandatory)] [int] $RecipeInputVersion,
    [Parameter(Mandatory)] [int] $ManifestSchemaVersion,
    [Parameter(Mandatory)] [ValidateNotNullOrEmpty()] [string] $MediaId,
    [Parameter(Mandatory)] [ValidateNotNullOrEmpty()] [string] $StartedUtc,
    [Parameter(Mandatory)] [ValidateNotNullOrEmpty()] [string] $VCenterServer,
    [Parameter(Mandatory)] [ValidateNotNullOrEmpty()] [string] $VCenterUsername
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 3.0

Import-Module (Join-Path $PSScriptRoot 'Sealing.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'VSpherePlatform.psm1') -Force

# The password comes from the environment, never from a parameter. A parameter
# is visible to anything enumerating processes and lands in shell history; an
# environment variable is read once here and never passed on.
$secret = $env:VDIIAC_VCENTER_PASSWORD
if ([string]::IsNullOrEmpty($secret)) {
    Write-Error 'VDIIAC_VCENTER_PASSWORD is not set. The vCenter password is never accepted as an argument.'
    exit 2
}
# Appended character by character rather than converted from plaintext. The
# value arrived as a string and cannot be unmade, but this keeps the forbidden
# conversion out of the code path and the secret out of any further copy.
$protected = [securestring]::new()
foreach ($character in $secret.ToCharArray()) { $protected.AppendChar($character) }
$protected.MakeReadOnly()

$credential = [pscredential]::new($VCenterUsername, $protected)

# Cleared from this process and from the environment it would otherwise be
# inherited from by anything this script starts.
Remove-Variable -Name secret -ErrorAction SilentlyContinue
$env:VDIIAC_VCENTER_PASSWORD = $null

$prerequisite = Test-VSpherePrerequisite
if (-not $prerequisite.Satisfied) {
    Write-Error "The vSphere platform module is not available: $($prerequisite.ReasonCode)."
    exit 2
}

# Derived, not asserted. Packer's exit code is the only thing that knows whether
# the build finished.
$packerSucceeded = ($PackerExitCode -eq 0)
Write-Information "packer exit code $PackerExitCode; build succeeded: $packerSucceeded" -InformationAction Continue

# The phases the build established, in the order the contract requires. A build
# that did not succeed has not established them, and the coordinator refuses
# before it looks at any of this.
$completedPhases = @(
    'media-qualification', 'answer-file', 'construction', 'provisioning',
    'pre-generalization', 'credential-residue', 'generalization', 'shutdown'
) | ForEach-Object { [PSCustomObject]@{ name = $_; outcome = 'passed' } }

$adapter = Get-VSpherePlatformAdapter -Server $VCenterServer -Credential $credential -EvidenceRoot $EvidenceRoot

$result = Invoke-CandidateSealing -RunId $RunId -Nonce $Nonce -CandidateName $CandidateName `
    -PackerSucceeded $packerSucceeded -CompletedPhases $completedPhases `
    -RecipeDigest $RecipeDigest -RecipeInputVersion $RecipeInputVersion `
    -ManifestSchemaVersion $ManifestSchemaVersion -MediaId $MediaId -StartedUtc $StartedUtc `
    -Adapter $adapter -WhatIf:$WhatIfPreference

Write-Information "build state       : $($result.BuildState)" -InformationAction Continue
Write-Information "outcome           : $($result.Outcome)" -InformationAction Continue
Write-Information "reason            : $($result.ReasonCode)" -InformationAction Continue
Write-Information "evidence persisted: $($result.EvidencePersisted)" -InformationAction Continue

if ($result.BuildState -eq 'sealed') {
    Write-Information "sealed candidate  : $($result.ArtifactIdentity.managedObjectReference)" -InformationAction Continue
    exit 0
}

if (-not $result.EvidencePersisted) {
    # Worse than a failed seal: nothing durable records what happened, so
    # nothing downstream can reconcile whatever exists on the platform.
    Write-Error 'The sealing result could not be persisted. No durable record of this run exists.'
    exit 3
}

Write-Error "Sealing did not produce a candidate: $($result.ReasonCode). A reconciliation record was written."
exit 1
