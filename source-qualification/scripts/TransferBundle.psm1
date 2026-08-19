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

# Imported here rather than relied upon from the caller's session, so the trust
# boundary this module enforces cannot be bypassed by importing it alone.
# Without -Force: it would unload these from the importing session as well as
# loading them here, so a caller that had already imported RunIdentity would
# find its functions gone.
foreach ($dependency in 'PackageManifest', 'RunIdentity', 'SourceQualification') {
    Import-Module (Join-Path $PSScriptRoot "$dependency.psm1") -ErrorAction Stop
}

$script:DescriptorFileName = 'descriptor.json'
$script:PayloadDirectoryName = 'packages'
$script:DescriptorSchema = Join-Path $PSScriptRoot '..' '..' 'contracts' 'transfer-descriptor-1.schema.json'

function New-TransferBundle {
    <#
    .SYNOPSIS
        Builds a bundle from packages that pass host verification.

    .PARAMETER ManifestPath
        Path to a manifest. It is validated here, against the committed schema
        and the semantic rules, before any value from it reaches a path.

        A caller-supplied manifest *object* is not accepted. A package identifier
        becomes a directory name beneath the bundle, and that directory is later
        removed recursively, so an object that never passed validation can direct
        a delete outside the bundle root. Reproduced before this was changed: an
        identifier of '../../../sentinel' removed a directory outside BundleRoot.

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
        [Parameter(Mandatory)] [ValidateNotNullOrEmpty()] [string] $ManifestPath,
        [Parameter(Mandatory)] [ValidateNotNullOrEmpty()] [string] $SourceRoot,
        [Parameter(Mandatory)] [ValidateNotNullOrEmpty()] [string] $BundleRoot,
        [Parameter()] [string] $RunId
    )

    $Manifest = Import-PackageManifest -Path $ManifestPath

    # Exactly 2, not "2 or later". A future version may add fields this
    # assembler does not understand, and silently building a bundle from them
    # would produce a descriptor whose contents nothing here validated.
    if ([int] $Manifest.SchemaVersion -ne 2) {
        throw "A transfer bundle needs manifest schema version 2; this manifest declares version $($Manifest.SchemaVersion). Version 1 carries no installer or validation data for the guest to act on."
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
    $descriptorPath = $null
    $descriptorHash = $null
    $terminal = $null

    # Everything after the reservation runs inside this block. Any terminal error
    # leaves a partially assembled bundle on disk, and a partial bundle a later
    # stage mistakes for a complete one is the failure this guards against.
    try {
        foreach ($package in $Manifest.Packages) {
            $result = [ordered]@{
                Id = $package.id; Version = $package.version; Order = $package.order
                Required = $package.required; Outcome = 'failed'; ReasonCode = $null; Included = $false
            }

            # Relative, and built from the validated package id, so no part of the
            # host layout travels with the bundle.
            $relativePath = "$script:PayloadDirectoryName/$($package.id)/$([System.IO.Path]::GetFileName($package.source))"
            $destination = Join-Path $payloadRoot $package.id

            # Defence in depth. The schema constrains an id to lowercase
            # alphanumerics and hyphens, so this cannot fire for a validated
            # manifest -- which is the point: if it ever fires, validation was
            # bypassed and the run stops before anything is written or removed.
            $payloadRootFull = [System.IO.Path]::GetFullPath($payloadRoot)
            $destinationFull = [System.IO.Path]::GetFullPath($destination)
            $separator = [System.IO.Path]::DirectorySeparatorChar
            $prefix = $payloadRootFull.TrimEnd($separator) + $separator
            if (-not $destinationFull.StartsWith($prefix, [System.StringComparison]::Ordinal)) {
                throw "Package id '$($package.id)' resolves outside the bundle payload directory."
            }

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
                # Removed immediately, and a failure to remove is terminal. An
                # optional package whose payload cannot be deleted would otherwise
                # leave unverified content in a bundle that still reports success.
                try {
                    Remove-Item -LiteralPath $destination -Recurse -Force -ErrorAction Stop
                }
                catch {
                    throw "Could not remove unverified payload for package '$($package.id)': $($_.Exception.Message)"
                }
                if (Test-Path -LiteralPath $destination) {
                    throw "Unverified payload for package '$($package.id)' is still present after removal."
                }
            }

            $results.Add([PSCustomObject] $result)
        }

        $failedRequired = @($results | Where-Object { -not $_.Included -and $_.Required })
        if ($failedRequired.Count -gt 0) {
            throw "A required package was not verified, so this bundle must not be uploaded."
        }
        if ($entries.Count -eq 0) {
            throw "No package was verified, so there is nothing to transfer."
        }

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
    catch {
        $terminal = $_.Exception.Message
        Write-Verbose "Bundle assembly failed: $terminal"
    }

    $cleanupOutcome = 'retained'
    if ($terminal) {
        try {
            Remove-Item -LiteralPath $bundlePath -Recurse -Force -ErrorAction Stop
            $cleanupOutcome = if (Test-Path -LiteralPath $bundlePath) { 'failed' } else { 'removed' }
        }
        catch {
            $cleanupOutcome = 'failed'
            Write-Verbose "Bundle cleanup failed: $($_.Exception.Message)"
        }
        $descriptorPath = $null
        $descriptorHash = $null
    }

    $failedRequiredCount = @($results | Where-Object { -not $_.Included -and $_.Required }).Count
    $outcome = if ($cleanupOutcome -eq 'failed') { 'incomplete' }
               elseif ($terminal) { 'failed' }
               else { 'passed' }

    [PSCustomObject]@{
        Outcome = $outcome
        RunId = $runIdentifier
        # Never a usable path unless the bundle is complete and verified.
        BundlePath = if ($outcome -eq 'passed') { $bundlePath } else { $null }
        DescriptorPath = $descriptorPath
        DescriptorSha256 = $descriptorHash
        PackageCount = $results.Count
        IncludedCount = @($results | Where-Object Included).Count
        FailedRequiredCount = $failedRequiredCount
        CleanupOutcome = $cleanupOutcome
        Reason = $terminal
        Packages = $results.ToArray()
    }
}

function Test-TransferDescriptor {
    <#
    .SYNOPSIS
        Authenticates a descriptor against an expected digest, then validates it.

    .DESCRIPTION
        The order is deliberate: read the bytes once, hash that buffer, compare
        against the digest delivered out of band, decode the same buffer, and only
        then validate and parse. Hashing a file and then re-reading it would
        authenticate one set of bytes and parse another, which a file changing
        between the two reads turns into a real difference rather than a
        theoretical one.

        Schema validation proves a descriptor is well formed. It does not prove
        it is the one the host sent, and an attacker able to rewrite the bundle
        can rewrite the descriptor and the payload hashes together so that every
        in-bundle check still passes.

        The schema is the committed one and cannot be substituted by a caller: a
        permissive replacement would make any well-formed document acceptable.

    .OUTPUTS
        The parsed descriptor.
    #>
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param(
        [Parameter(Mandatory)] [ValidateNotNullOrEmpty()] [string] $Path,
        [Parameter(Mandatory)] [ValidatePattern('\A[a-fA-F0-9]{64}\z')] [string] $ExpectedSha256
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "Descriptor not found: $Path"
    }

    # One read. Everything below works from this buffer.
    $bytes = [System.IO.File]::ReadAllBytes((Resolve-Path -LiteralPath $Path).Path)

    $sha256 = [System.Security.Cryptography.SHA256]::Create()
    try {
        $actual = [System.BitConverter]::ToString($sha256.ComputeHash($bytes)).Replace('-', '').ToLowerInvariant()
    }
    finally {
        $sha256.Dispose()
    }

    $expected = $ExpectedSha256.ToLowerInvariant()
    if (-not [string]::Equals($actual, $expected, [System.StringComparison]::Ordinal)) {
        $exception = [System.Exception]::new("Descriptor digest mismatch. Expected $expected, observed $actual.")
        $exception.Data['ReasonCode'] = 'descriptor_digest_mismatch'
        throw $exception
    }

    # Strict UTF-8: malformed byte sequences throw rather than becoming
    # replacement characters, which would silently alter authenticated content.
    $payload = $bytes
    if ($payload.Length -ge 3 -and $payload[0] -eq 0xEF -and $payload[1] -eq 0xBB -and $payload[2] -eq 0xBF) {
        $payload = $payload[3..($payload.Length - 1)]
    }
    $decoder = [System.Text.UTF8Encoding]::new($false, $true)
    try {
        $raw = $decoder.GetString($payload)
    }
    catch {
        $exception = [System.Exception]::new("Descriptor is not valid UTF-8: $($_.Exception.Message)")
        $exception.Data['ReasonCode'] = 'descriptor_invalid'
        throw $exception
    }

    $schemaErrors = $null
    if (-not (Test-Json -Json $raw -SchemaFile $script:DescriptorSchema -ErrorAction SilentlyContinue -ErrorVariable schemaErrors)) {
        $detail = if ($schemaErrors) { ($schemaErrors | ForEach-Object { $_.ToString() }) -join '; ' } else { 'no detail reported' }
        $exception = [System.Exception]::new("Descriptor failed schema validation: $detail")
        $exception.Data['ReasonCode'] = 'descriptor_invalid'
        throw $exception
    }

    $descriptor = $raw | ConvertFrom-Json

    # Semantic checks the schema cannot make. Its runId pattern anchors with ^
    # and $, and in .NET $ also matches before a trailing newline, so a value
    # ending in one satisfies the pattern and then names a directory.
    try {
        $null = Assert-RunIdentifier -RunId $descriptor.runId
    }
    catch {
        $exception = [System.Exception]::new("Descriptor run identifier is not canonical: $($_.Exception.Message)")
        $exception.Data['ReasonCode'] = 'descriptor_invalid'
        throw $exception
    }

    AssertDescriptorHasNoControlCharacters -Node $descriptor

    $descriptor
}

function AssertDescriptorHasNoControlCharacters {
    <#
    .SYNOPSIS
        Refuses a control character anywhere in a descriptor's string values.

    .DESCRIPTION
        Module-internal. Same gap as the manifest side: pattern anchors admit a
        trailing newline, and these values name paths and services in a guest.

        Descent is bounded by type. Probing whether a node has properties
        descends into primitives whose own properties are of the same type, which
        recurses without end.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [AllowNull()] $Node,
        [Parameter()] [string] $Location = 'descriptor',
        [Parameter()] [int] $Depth = 0
    )

    if ($Depth -gt 32) { throw 'Descriptor nests deeper than expected.' }
    if ($null -eq $Node) { return }

    if ($Node -is [string]) {
        foreach ($character in $Node.ToCharArray()) {
            if ([char]::IsControl($character)) {
                $code = '0x{0:X2}' -f [int] $character
                $exception = [System.Exception]::new("Descriptor value at $Location contains control character $code.")
                $exception.Data['ReasonCode'] = 'descriptor_invalid'
                throw $exception
            }
        }
        return
    }

    if ($Node -is [System.Collections.IList]) {
        for ($i = 0; $i -lt $Node.Count; $i++) {
            AssertDescriptorHasNoControlCharacters -Node $Node[$i] -Location "$Location[$i]" -Depth ($Depth + 1)
        }
        return
    }

    if ($Node -is [System.Management.Automation.PSCustomObject]) {
        foreach ($property in $Node.PSObject.Properties) {
            AssertDescriptorHasNoControlCharacters -Node $property.Value -Location "$Location.$($property.Name)" -Depth ($Depth + 1)
        }
    }
}

Export-ModuleMember -Function New-TransferBundle, Test-TransferDescriptor
