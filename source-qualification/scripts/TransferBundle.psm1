#Requires -Version 7.0

<#
.SYNOPSIS
    Assembles the verified-only bundle a guest receives, and its descriptor.

.DESCRIPTION
    Implements ADR 3. The bundle is a first-class artifact, distinct from host
    staging and from the diagnostic content -KeepStaging retains. Staging is a
    working directory whose contents include failures; uploading either would
    move unverified files across the trust boundary.

    Only packages that pass host verification enter the bundle. A package that
    fails is removed from the bundle immediately rather than being left for a
    later filter to miss.

    The descriptor carries everything the guest needs to act, because the
    manifest does not travel and re-parsing it in the guest would duplicate
    validation the host already performed. Its contents are copied from a
    manifest already validated against schema version 2, never reinterpreted.

    The descriptor's own digest is returned so the orchestrator can deliver it to
    the guest out of band. Recording it only in host evidence would make a
    substituted descriptor visible to a later reader, after the guest had already
    acted, which is detection rather than a control.
#>

Set-StrictMode -Version 3.0

$script:DescriptorFileName = 'descriptor.json'
$script:PayloadDirectoryName = 'packages'
$script:DescriptorSchema = Join-Path $PSScriptRoot '..' '..' 'contracts' 'transfer-descriptor-1.schema.json'

function New-TransferBundle {
    <#
    .SYNOPSIS
        Builds a bundle from packages that pass host verification.

    .PARAMETER Manifest
        A schema version 2 manifest from Import-PackageManifest. Version 1 has no
        installer or validation data, so a guest could not act on it.

    .PARAMETER SourceRoot
        Directory manifest source references resolve beneath.

    .PARAMETER BundleRoot
        Parent directory. A run-specific subdirectory is reserved beneath it.

    .PARAMETER RunId
        Canonical lowercase UUID from the orchestrator. Generated only when this
        stage runs standalone.

    .OUTPUTS
        PSCustomObject with Outcome, RunId, BundlePath, DescriptorPath,
        DescriptorSha256, Packages, and CleanupOutcome.

        Outcome is 'passed' when every required package was verified and included,
        'failed' when a required package was not, and 'incomplete' when the bundle
        could not be removed after a failure.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([PSCustomObject])]
    param(
        [Parameter(Mandatory)] $Manifest,
        [Parameter(Mandatory)] [ValidateNotNullOrEmpty()] [string] $SourceRoot,
        [Parameter(Mandatory)] [ValidateNotNullOrEmpty()] [string] $BundleRoot,
        [Parameter()] [string] $RunId
    )

    if ([int] $Manifest.SchemaVersion -lt 2) {
        throw "A transfer bundle needs manifest schema version 2 or later; this manifest declares version $($Manifest.SchemaVersion). Version 1 carries no installer or validation data for the guest to act on."
    }
    if (-not (Test-Path -LiteralPath $SourceRoot -PathType Container)) {
        throw "Source root not found: $SourceRoot"
    }

    $runIdentifier = if ([string]::IsNullOrWhiteSpace($RunId)) { Get-RunIdentifier } else { Assert-RunIdentifier -RunId $RunId }

    # This function copies files and writes a descriptor, so it declares
    # ShouldProcess rather than being renamed to a non-state-changing verb.
    if (-not $PSCmdlet.ShouldProcess($BundleRoot, "Assemble transfer bundle for run $runIdentifier")) {
        return [PSCustomObject]@{
            Outcome = 'skipped'; RunId = $runIdentifier; BundlePath = $null
            DescriptorPath = $null; DescriptorSha256 = $null
            PackageCount = @($Manifest.Packages).Count; IncludedCount = 0
            FailedRequiredCount = 0; CleanupOutcome = 'not-attempted'; Packages = @()
        }
    }

    $bundlePath = New-RunDirectory -Root $BundleRoot -RunId $runIdentifier -Prefix 'bundle'
    $payloadRoot = Join-Path $bundlePath $script:PayloadDirectoryName
    $null = New-Item -ItemType Directory -Path $payloadRoot -Force

    $results = [System.Collections.Generic.List[PSCustomObject]]::new()
    $entries = [System.Collections.Generic.List[object]]::new()

    foreach ($package in $Manifest.Packages) {
        $result = [ordered]@{
            Id = $package.id; Version = $package.version; Order = $package.order
            Required = $package.required; Outcome = 'failed'; ReasonCode = $null; Included = $false
        }

        # Relative, and built from the package id rather than anything host-side,
        # so no part of the host layout travels with the bundle.
        $relativePath = "$script:PayloadDirectoryName/$($package.id)/$([System.IO.Path]::GetFileName($package.source))"
        $destination = Join-Path $payloadRoot $package.id

        try {
            $resolved = Resolve-PackageSource -Reference $package.source -SourceRoot $SourceRoot
            $staged = Copy-PackageToStaging -SourcePath $resolved -StagingDirectory $destination
            $integrity = Test-PackageIntegrity -Path $staged -ExpectedSha256 $package.sha256

            if ($integrity.Matched) {
                $result.Outcome = 'passed'
                $result.Included = $true
                $entries.Add([ordered]@{
                    id = $package.id; version = $package.version
                    order = $package.order; required = $package.required
                    payloadPath = $relativePath; sha256 = $package.sha256
                    installer = $package.installer; validation = $package.validation
                })
            }
            else {
                $result.ReasonCode = 'integrity_mismatch'
            }
        }
        catch {
            $code = $_.Exception.Data['ReasonCode']
            $result.ReasonCode = if ($code) { $code } else { 'unexpected_error' }
            Write-Verbose "Package '$($package.id)' excluded with $($result.ReasonCode): $($_.Exception.Message)"
        }

        if (-not $result.Included -and (Test-Path -LiteralPath $destination)) {
            # Remove immediately rather than filtering later. Unverified content
            # must never be present in a bundle that could be uploaded.
            Remove-Item -LiteralPath $destination -Recurse -Force -ErrorAction SilentlyContinue
        }

        $results.Add([PSCustomObject] $result)
    }

    $failedRequired = @($results | Where-Object { -not $_.Included -and $_.Required })
    $descriptorPath = $null
    $descriptorHash = $null
    $cleanupOutcome = 'retained'

    if ($failedRequired.Count -eq 0 -and $entries.Count -gt 0) {
        $descriptor = [ordered]@{
            descriptorVersion = 1
            runId = $runIdentifier
            manifestSchemaVersion = [int] $Manifest.SchemaVersion
            packages = @($entries | Sort-Object { $_.order })
        }
        $descriptorPath = Join-Path $bundlePath $script:DescriptorFileName
        $descriptor | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $descriptorPath -Encoding utf8

        $schemaErrors = $null
        $raw = Get-Content -LiteralPath $descriptorPath -Raw -Encoding utf8
        if (-not (Test-Json -Json $raw -SchemaFile $script:DescriptorSchema -ErrorAction SilentlyContinue -ErrorVariable schemaErrors)) {
            $detail = if ($schemaErrors) { ($schemaErrors | ForEach-Object { $_.ToString() }) -join '; ' } else { 'no detail reported' }
            throw "Generated descriptor does not satisfy its own schema: $detail"
        }

        $descriptorHash = (Get-FileHash -LiteralPath $descriptorPath -Algorithm SHA256).Hash.ToLowerInvariant()
    }
    else {
        # A bundle missing a required package must not be uploadable, so nothing
        # is left behind that a later stage could mistake for a complete one.
        try {
            Remove-Item -LiteralPath $bundlePath -Recurse -Force -ErrorAction Stop
            $cleanupOutcome = if (Test-Path -LiteralPath $bundlePath) { 'failed' } else { 'removed' }
        }
        catch {
            $cleanupOutcome = 'failed'
            Write-Verbose "Bundle cleanup failed: $($_.Exception.Message)"
        }
    }

    $outcome = if ($cleanupOutcome -eq 'failed') { 'incomplete' }
               elseif ($failedRequired.Count -gt 0 -or $entries.Count -eq 0) { 'failed' }
               else { 'passed' }

    [PSCustomObject]@{
        Outcome = $outcome
        RunId = $runIdentifier
        BundlePath = if ($outcome -eq 'passed') { $bundlePath } else { $null }
        DescriptorPath = $descriptorPath
        DescriptorSha256 = $descriptorHash
        PackageCount = $results.Count
        IncludedCount = @($results | Where-Object Included).Count
        FailedRequiredCount = $failedRequired.Count
        CleanupOutcome = $cleanupOutcome
        Packages = $results.ToArray()
    }
}

function Test-TransferDescriptor {
    <#
    .SYNOPSIS
        Authenticates a descriptor against an expected digest, then validates it.

    .DESCRIPTION
        The order is deliberate: read the raw bytes, hash them, compare against
        the digest delivered out of band, and only then parse. Parsing first
        would mean acting on attacker-controlled structure before authenticating
        it.

        Schema validation proves a descriptor is well formed. It does not prove
        it is the one the host sent, and an attacker able to rewrite the bundle
        can rewrite the descriptor and the payload hashes together so that every
        in-bundle check still passes.

    .OUTPUTS
        The parsed descriptor. Throws if the digest does not match or the
        document does not satisfy its schema.
    #>
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param(
        [Parameter(Mandatory)] [ValidateNotNullOrEmpty()] [string] $Path,
        [Parameter(Mandatory)] [ValidatePattern('\A[a-fA-F0-9]{64}\z')] [string] $ExpectedSha256,
        [Parameter()] [ValidateNotNullOrEmpty()] [string] $SchemaPath = $script:DescriptorSchema
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "Descriptor not found: $Path"
    }

    $actual = (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
    $expected = $ExpectedSha256.ToLowerInvariant()
    if (-not [string]::Equals($actual, $expected, [System.StringComparison]::Ordinal)) {
        $exception = [System.Exception]::new("Descriptor digest mismatch. Expected $expected, observed $actual.")
        $exception.Data['ReasonCode'] = 'descriptor_digest_mismatch'
        throw $exception
    }

    $raw = Get-Content -LiteralPath $Path -Raw -Encoding utf8
    $schemaErrors = $null
    if (-not (Test-Json -Json $raw -SchemaFile $SchemaPath -ErrorAction SilentlyContinue -ErrorVariable schemaErrors)) {
        $detail = if ($schemaErrors) { ($schemaErrors | ForEach-Object { $_.ToString() }) -join '; ' } else { 'no detail reported' }
        $exception = [System.Exception]::new("Descriptor failed schema validation: $detail")
        $exception.Data['ReasonCode'] = 'descriptor_invalid'
        throw $exception
    }

    $raw | ConvertFrom-Json
}

Export-ModuleMember -Function New-TransferBundle, Test-TransferDescriptor
