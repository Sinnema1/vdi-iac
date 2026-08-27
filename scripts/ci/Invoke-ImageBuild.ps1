#!/usr/bin/env pwsh
#Requires -Version 7.0

<#
.SYNOPSIS
    Builds and seals a candidate image, deriving every fact it reports.

.DESCRIPTION
    The one host entry point for Increment 3. It exists because the previous
    seam let a caller assert what should have been observed: an exit code, a
    recipe digest, a media identity, and a list of phases that were all
    hard-coded as passed. A script that accepts "the build succeeded" as a
    parameter will eventually be handed that value by something that did not
    check.

    So nothing here is taken on trust. The run identity and nonce are generated
    and written down before anything runs. The recipe is assembled from the
    validated media reference, the imported manifest, and the answer-file
    declaration, and its digest is computed rather than supplied. Packer is
    invoked and its exit code captured internally. The phase evidence the build
    downloaded is read from disk and validated before it is believed. Only then
    does sealing run.

    Nothing here has been executed against vSphere.
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)] [ValidateNotNullOrEmpty()] [string] $MediaReferencePath,
    [Parameter(Mandatory)] [ValidateNotNullOrEmpty()] [string] $MediaRoot,
    [Parameter(Mandatory)] [ValidateNotNullOrEmpty()] [string] $ManifestPath,
    [Parameter(Mandatory)] [ValidateNotNullOrEmpty()] [string] $AnswerFileDeclarationPath,
    [Parameter(Mandatory)] [ValidateNotNullOrEmpty()] [string] $PackageSourceRoot,
    [Parameter(Mandatory)] [ValidateNotNullOrEmpty()] [string] $VarFile,
    [Parameter(Mandatory)] [ValidateNotNullOrEmpty()] [string] $WorkRoot,
    [Parameter(Mandatory)] [ValidateNotNullOrEmpty()] [string] $CandidateName,
    [Parameter(Mandatory)] [ValidateNotNullOrEmpty()] [string] $VCenterServer,
    [Parameter(Mandatory)] [ValidateNotNullOrEmpty()] [string] $VCenterUsername,
    [Parameter(Mandatory)] [bool] $InsecureConnection,
    [Parameter(Mandatory)] [hashtable] $Hardware,
    [Parameter(Mandatory)] [hashtable] $Tooling,
    [Parameter(Mandatory)] [hashtable] $BuildLogic
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 3.0

$scripts = Join-Path $PSScriptRoot '..' '..' 'source-qualification' 'scripts'
foreach ($module in 'RunIdentity', 'PackageManifest', 'MediaQualification', 'AnswerFile',
                    'TransferBundle', 'RecipeIdentity', 'BuildInputs', 'Finalization', 'BuildEvidence') {
    Import-Module (Join-Path $scripts "$module.psm1") -Force
}
Import-Module (Join-Path $PSScriptRoot 'Sealing.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'VSpherePlatform.psm1') -Force

# ---------------------------------------------------------------------------
# Identity, generated here and written down before anything runs. A run that
# crashes before its first provisioner still leaves a record of what it was.
# ---------------------------------------------------------------------------
$runId = Get-RunIdentifier
$nonce = Get-FinalizationNonce
$startedUtc = [datetime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ss.fffffffZ')

$runRoot = New-RunDirectory -Root $WorkRoot -RunId $runId -Prefix 'image-build'
$evidenceRoot = Join-Path $runRoot 'evidence'
$null = New-Item -ItemType Directory -Path $evidenceRoot -Force

[ordered]@{ runId = $runId; nonce = $nonce; startedUtc = $startedUtc } |
    ConvertTo-Json | Set-Content -LiteralPath (Join-Path $runRoot 'run.json') -Encoding utf8

Write-Information "run $runId" -InformationAction Continue

# ---------------------------------------------------------------------------
# The recipe, assembled from validated inputs and digested here. A supplied
# digest is a claim about inputs nobody re-read.
# ---------------------------------------------------------------------------
$mediaRecord = Invoke-MediaQualification -ReferencePath $MediaReferencePath -MediaRoot $MediaRoot -RunId $runId
$mediaRecordPath = Join-Path $runRoot 'media-qualification.json'
Save-MediaQualificationRecord -Record $mediaRecord -Path $mediaRecordPath | Out-Null

if ($mediaRecord.outcome -ne 'passed') {
    Write-Error "Media qualification failed: $($mediaRecord.reasonCode)."
    exit 1
}

$qualified = Assert-QualifiedMedia -RecordPath $mediaRecordPath -MediaRoot $MediaRoot -RunId $runId
$manifest = Import-PackageManifest -Path $ManifestPath
$declaration = Import-AnswerFileTemplate -Path $AnswerFileDeclarationPath

# The tooling version has to be one value across the manifest, the build, and
# the recipe before any of them is acted on.
$disagreement = Test-ToolsVersionAgreement -Manifest $manifest `
    -BuilderVersion $Tooling.VMwareToolsVersion -Tooling $Tooling
if ($disagreement) {
    Write-Error "The VMware Tools version does not agree: $disagreement."
    exit 1
}

$answerFileDigest = (Get-FileHash -LiteralPath $declaration.templatePath -Algorithm SHA256).Hash.ToLowerInvariant()
$declarationDigest = (Get-FileHash -LiteralPath $AnswerFileDeclarationPath -Algorithm SHA256).Hash.ToLowerInvariant()

$recipe = ConvertTo-RecipeInput -MediaReference $mediaRecord -Manifest $manifest `
    -AnswerFile @{
        TemplateDigest = $answerFileDigest
        DeclarationDigest = $declarationDigest
        ImageSelection = $declaration.imageSelection
    } `
    -BuildLogic $BuildLogic -Hardware $Hardware -Tooling $Tooling

$recipeIdentity = Get-RecipeDigest -RecipeInput $recipe
$recipe | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath (Join-Path $runRoot 'recipe-input.json') -Encoding utf8
Write-Information "recipe $($recipeIdentity.RecipeDigest) (input version $($recipeIdentity.RecipeInputVersion))" -InformationAction Continue

# ---------------------------------------------------------------------------
# The bundle, assembled here from the same manifest the recipe digested. Taking
# a bundle path and a descriptor digest as arguments let provenance describe one
# manifest while the guest installed another, and nothing would have noticed:
# both documents would have been internally consistent.
# ---------------------------------------------------------------------------
$bundle = New-TransferBundle -ManifestPath $ManifestPath -SourceRoot $PackageSourceRoot `
    -BundleRoot (Join-Path $runRoot 'bundle') -RunId $runId

if ($bundle.Outcome -ne 'passed') {
    Write-Error "The transfer bundle was not assembled: $($bundle.Outcome). Nothing unverified crosses the boundary."
    exit 1
}
Write-Information "bundle $($bundle.DescriptorSha256)" -InformationAction Continue

# ---------------------------------------------------------------------------
# The build password, from the environment. Never a parameter, never in the var
# file, never on a command line: all three are readable by anything that can
# list processes or read the working tree.
# ---------------------------------------------------------------------------
$buildSecret = $env:VDIIAC_BUILD_PASSWORD
if ([string]::IsNullOrEmpty($buildSecret)) {
    Write-Error 'VDIIAC_BUILD_PASSWORD is not set. The build password is never accepted as an argument.'
    exit 2
}
$buildPassword = [securestring]::new()
foreach ($character in $buildSecret.ToCharArray()) { $buildPassword.AppendChar($character) }
$buildPassword.MakeReadOnly()
Remove-Variable -Name buildSecret -ErrorAction SilentlyContinue

$variables = ConvertTo-BuildVariableSet -QualifiedMedia $qualified -Declaration $declaration `
    -Hardware $Hardware -AnswerFilePath 'rendered-at-build-time' -RunId $runId

# ---------------------------------------------------------------------------
# The build runs inside the rendering callback, so the answer file exists only
# for as long as Packer needs it and is removed on every exit path -- including
# a build that throws. Passing the template's own path here would have uploaded
# a file full of unsubstituted placeholders under the wrong name.
# ---------------------------------------------------------------------------
# Captured into one object the callback reads from. The callback closes over
# this rather than over each parameter, which is also the only form static
# analysis can see -- it does not look inside a closure.
$invocation = @{
    VarFile        = $VarFile
    Variables      = $variables
    Nonce          = $nonce
    CandidateName  = $CandidateName
    BundlePath     = $bundle.BundlePath
    DescriptorHash = $bundle.DescriptorSha256
    MediaRecord    = $mediaRecordPath
    EvidenceRoot   = $evidenceRoot
    BuildDirectory = (Join-Path $PSScriptRoot '..' '..' 'packer' 'builds')
    Password       = $buildPassword
}

$packerExitCode = 1
$answerFileRendered = $false

if ($PSCmdlet.ShouldProcess($CandidateName, 'Build and seal a candidate image')) {
    $packerExitCode = Invoke-WithRenderedAnswerFile -Declaration $declaration `
        -Secrets @{ ADMINISTRATOR_PASSWORD = $buildPassword } -ScriptBlock {
        param($RenderedPath)

        # -on-error=abort, not cleanup. Cleanup deletes the virtual machine,
        # and a failed finalizer deliberately leaves one powered on for
        # reconciliation -- deleting it would destroy the thing the
        # unconfirmed-artifact record exists to point at. Removing a failed
        # build is a separate authorized action, not an automatic consequence.
        $arguments = @('build', '-on-error=abort', "-var-file=$($invocation.VarFile)")
        foreach ($name in ($invocation.Variables.Keys | Sort-Object)) {
            if ($name -eq 'answer_file_path') { continue }
            $arguments += @('-var', "$name=$($invocation.Variables[$name])")
        }
        $arguments += @(
            '-var', "answer_file_path=$RenderedPath"
            '-var', "finalization_nonce=$($invocation.Nonce)"
            '-var', "candidate_name=$($invocation.CandidateName)"
            '-var', "bundle_path=$($invocation.BundlePath)"
            '-var', "descriptor_sha256=$($invocation.DescriptorHash)"
            '-var', "media_qualification_record_path=$($invocation.MediaRecord)"
            '-var', "evidence_output_dir=$($invocation.EvidenceRoot)"
            $invocation.BuildDirectory
        )

        # The password reaches Packer through PKR_VAR_, not an argument. A -var
        # on the command line is visible to anything enumerating processes, and
        # the var file is on disk.
        $env:PKR_VAR_build_password = [System.Net.NetworkCredential]::new('', $invocation.Password).Password
        try {
            # ErrorActionPreference is lowered deliberately: a native command's
            # stderr becomes a terminating error under Stop, and packer writes
            # progress there.
            $previous = $ErrorActionPreference
            $ErrorActionPreference = 'Continue'
            try {
                & packer @arguments
                $LASTEXITCODE
            }
            finally { $ErrorActionPreference = $previous }
        }
        finally { $env:PKR_VAR_build_password = $null }
    }

    $answerFileRendered = $true
}

Write-Information "packer exit code $packerExitCode" -InformationAction Continue

# ---------------------------------------------------------------------------
# The phases, each from the fact that establishes it. Nothing is reported as
# passed because no file happened to be expected for it.
# ---------------------------------------------------------------------------
$phases = Read-BuildPhaseEvidence -EvidenceRoot $evidenceRoot -RunId $runId `
    -SchemaPath (Join-Path $PSScriptRoot '..' '..' 'contracts' 'evidence-envelope-2.schema.json') `
    -MediaQualified ($mediaRecord.outcome -eq 'passed') `
    -AnswerFilePrepared $answerFileRendered `
    -ConstructionSucceeded ($packerExitCode -eq 0)

# ---------------------------------------------------------------------------
# Sealing.
# ---------------------------------------------------------------------------
$secret = $env:VDIIAC_VCENTER_PASSWORD
if ([string]::IsNullOrEmpty($secret)) {
    Write-Error 'VDIIAC_VCENTER_PASSWORD is not set. The vCenter password is never accepted as an argument.'
    exit 2
}
$protected = [securestring]::new()
foreach ($character in $secret.ToCharArray()) { $protected.AppendChar($character) }
$protected.MakeReadOnly()
$credential = [pscredential]::new($VCenterUsername, $protected)
Remove-Variable -Name secret -ErrorAction SilentlyContinue
$env:VDIIAC_VCENTER_PASSWORD = $null

$prerequisite = Test-VSpherePrerequisite
if (-not $prerequisite.Satisfied) {
    Write-Error "The vSphere platform module is not available: $($prerequisite.ReasonCode)."
    exit 2
}

$connection = $null
try {
    $connection = Connect-VSpherePlatform -Server $VCenterServer -Credential $credential `
        -InsecureConnection $InsecureConnection
    $adapter = Get-VSpherePlatformAdapter -Connection $connection -EvidenceRoot $evidenceRoot

    $result = Invoke-CandidateSealing -RunId $runId -Nonce $nonce -CandidateName $CandidateName `
        -PackerSucceeded ($packerExitCode -eq 0) -CompletedPhases $phases `
        -RecipeDigest $recipeIdentity.RecipeDigest -RecipeInputVersion $recipeIdentity.RecipeInputVersion `
        -ManifestSchemaVersion $manifest.SchemaVersion -MediaId $mediaRecord.mediaId `
        -StartedUtc $startedUtc -Adapter $adapter -Confirm:$false
}
finally {
    Disconnect-VSpherePlatform -Connection $connection
}

Write-Information "build state       : $($result.BuildState)" -InformationAction Continue
Write-Information "reason            : $($result.ReasonCode)" -InformationAction Continue
Write-Information "evidence persisted: $($result.EvidencePersisted)" -InformationAction Continue
Write-Information "evidence          : $evidenceRoot" -InformationAction Continue

if ($result.BuildState -eq 'sealed') {
    Write-Information "sealed candidate  : $($result.ArtifactIdentity.managedObjectReference)" -InformationAction Continue
    exit 0
}

if (-not $result.EvidencePersisted) {
    Write-Error 'The sealing result could not be persisted. No durable record of this run exists.'
    exit 3
}

Write-Error "Sealing did not produce a candidate: $($result.ReasonCode). A reconciliation record was written."
exit 1
