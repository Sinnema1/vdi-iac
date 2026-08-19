#Requires -Version 7.0

<#
    Bundle assembly and descriptor integrity.

    Fixtures build a real source tree and a schema version 2 manifest describing
    it, so expected hashes are computed from files the test just wrote. That is
    sound here because the subject is bundle assembly, not the provenance of the
    hash; production code takes expected values from the manifest.
#>

BeforeAll {
    $script:RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..' '..')).Path
    $scripts = Join-Path $script:RepoRoot 'source-qualification' 'scripts'
    foreach ($m in 'PackageManifest', 'RunIdentity', 'SourceQualification', 'TransferBundle') {
        Import-Module (Join-Path $scripts "$m.psm1") -Force
    }

    function NewTempDir {
        $d = Join-Path ([System.IO.Path]::GetTempPath()) ([guid]::NewGuid().ToString())
        $null = New-Item -ItemType Directory -Path $d -Force
        $d
    }

    function NewScenario {
        <#
            Two packages, one MSI and one EXE. CorruptIds names packages whose
            manifest hash will not match what is on disk; MissingIds names
            packages whose source file is absent.
        #>
        param([string[]] $CorruptIds = @(), [string[]] $MissingIds = @(), [string[]] $OptionalIds = @())

        $base = NewTempDir
        $source = Join-Path $base 'src'
        $packages = @()

        foreach ($spec in @(
            @{ id = 'example-runtime'; version = '4.2.1'; ext = 'msi'; order = 10 }
            @{ id = 'example-agent';   version = '1.2.3'; ext = 'exe'; order = 20 }
        )) {
            $relative = "$($spec.id)/$($spec.version)/payload.$($spec.ext)"
            $full = Join-Path $source $relative
            $null = New-Item -ItemType Directory -Path (Split-Path -Parent $full) -Force

            if ($MissingIds -notcontains $spec.id) {
                Set-Content -LiteralPath $full -Value "payload for $($spec.id)" -Encoding utf8 -NoNewline
            }

            $hash = if ($MissingIds -contains $spec.id -or $CorruptIds -contains $spec.id) {
                'f' * 64
            } else {
                (Get-FileHash -LiteralPath $full -Algorithm SHA256).Hash.ToLowerInvariant()
            }

            $installer = if ($spec.ext -eq 'msi') {
                @{ kind = 'msi'; properties = @{ ALLUSERS = '1' }; timeoutSeconds = 1800; restartPolicy = 'allow-deferred' }
            } else {
                @{ kind = 'exe'; arguments = @('/quiet'); timeoutSeconds = 900
                   restartPolicy = 'allow-deferred'; exitCodes = @{ success = @(0); restartRequired = @(3010) } }
            }

            $packages += @{
                id = $spec.id; version = $spec.version
                source = "file://$relative"; sha256 = $hash
                order = $spec.order; required = ($OptionalIds -notcontains $spec.id)
                installer = $installer
                validation = @(@{ id = 'primary'; kind = 'file-exists'; root = 'programFiles'
                                  relativePath = "Example/$($spec.id)/app.exe" })
            }
        }

        $manifestPath = Join-Path $base 'manifest.json'
        @{ schemaVersion = 2; packages = $packages } | ConvertTo-Json -Depth 12 |
            Set-Content -LiteralPath $manifestPath -Encoding utf8

        [PSCustomObject]@{
            Manifest = Import-PackageManifest -Path $manifestPath
            SourceRoot = $source
            BundleRoot = Join-Path $base 'bundles'
        }
    }
}

Describe 'New-TransferBundle' {

    It 'includes every verified package and writes a descriptor' {
        $s = NewScenario
        $bundle = New-TransferBundle -Manifest $s.Manifest -SourceRoot $s.SourceRoot -BundleRoot $s.BundleRoot

        $bundle.Outcome | Should -Be 'passed'
        $bundle.IncludedCount | Should -Be 2
        Test-Path -LiteralPath $bundle.DescriptorPath | Should -BeTrue
        $bundle.DescriptorSha256 | Should -MatchExactly '^[a-f0-9]{64}$'
    }

    It 'orders descriptor entries deterministically' {
        $s = NewScenario
        $bundle = New-TransferBundle -Manifest $s.Manifest -SourceRoot $s.SourceRoot -BundleRoot $s.BundleRoot
        $descriptor = Get-Content -LiteralPath $bundle.DescriptorPath -Raw | ConvertFrom-Json
        $descriptor.packages.order | Should -Be @(10, 20)
    }

    It 'carries the execution data a guest needs' {
        # The manifest does not travel, so anything absent here is unavailable to
        # the guest no matter what the manifest said.
        $s = NewScenario
        $bundle = New-TransferBundle -Manifest $s.Manifest -SourceRoot $s.SourceRoot -BundleRoot $s.BundleRoot
        $entry = (Get-Content -LiteralPath $bundle.DescriptorPath -Raw | ConvertFrom-Json).packages |
            Where-Object id -EQ 'example-agent'

        $entry.installer.kind | Should -Be 'exe'
        $entry.installer.arguments | Should -Be @('/quiet')
        $entry.installer.timeoutSeconds | Should -Be 900
        $entry.installer.restartPolicy | Should -Be 'allow-deferred'
        $entry.installer.exitCodes.success | Should -Be @(0)
        $entry.validation[0].kind | Should -Be 'file-exists'
        $entry.sha256 | Should -MatchExactly '^[a-f0-9]{64}$'
    }

    It 'uses relative payload paths only' {
        # An absolute path would carry host layout into the guest.
        $s = NewScenario
        $bundle = New-TransferBundle -Manifest $s.Manifest -SourceRoot $s.SourceRoot -BundleRoot $s.BundleRoot
        $descriptor = Get-Content -LiteralPath $bundle.DescriptorPath -Raw | ConvertFrom-Json

        foreach ($entry in $descriptor.packages) {
            $entry.payloadPath | Should -MatchExactly '^packages/'
            $entry.payloadPath | Should -Not -Match '^[A-Za-z]:'
            Test-Path -LiteralPath (Join-Path $bundle.BundlePath $entry.payloadPath) | Should -BeTrue
        }
    }

    It 'never leaves unverified content in a bundle' {
        # The property that matters: an optional package failing integrity is
        # recorded, and its payload is not in the bundle.
        $s = NewScenario -CorruptIds 'example-agent' -OptionalIds 'example-agent'
        $bundle = New-TransferBundle -Manifest $s.Manifest -SourceRoot $s.SourceRoot -BundleRoot $s.BundleRoot

        $bundle.Outcome | Should -Be 'passed'
        $bundle.IncludedCount | Should -Be 1
        ($bundle.Packages | Where-Object Id -EQ 'example-agent').ReasonCode | Should -Be 'integrity_mismatch'
        Test-Path -LiteralPath (Join-Path $bundle.BundlePath 'packages' 'example-agent') | Should -BeFalse

        $descriptor = Get-Content -LiteralPath $bundle.DescriptorPath -Raw | ConvertFrom-Json
        $descriptor.packages.id | Should -Not -Contain 'example-agent'
    }

    It 'fails and removes the bundle when a required package does not verify' {
        $s = NewScenario -CorruptIds 'example-agent'
        $bundle = New-TransferBundle -Manifest $s.Manifest -SourceRoot $s.SourceRoot -BundleRoot $s.BundleRoot

        $bundle.Outcome | Should -Be 'failed'
        $bundle.FailedRequiredCount | Should -Be 1
        $bundle.BundlePath | Should -BeNullOrEmpty
        $bundle.CleanupOutcome | Should -Be 'removed'
        @(Get-ChildItem -LiteralPath $s.BundleRoot -Directory).Count | Should -Be 0
    }

    It 'records a missing source as a per-package reason' {
        $s = NewScenario -MissingIds 'example-agent' -OptionalIds 'example-agent'
        $bundle = New-TransferBundle -Manifest $s.Manifest -SourceRoot $s.SourceRoot -BundleRoot $s.BundleRoot
        ($bundle.Packages | Where-Object Id -EQ 'example-agent').ReasonCode | Should -Be 'source_not_found'
    }

    It 'creates nothing under -WhatIf' {
        $s = NewScenario
        $result = New-TransferBundle -Manifest $s.Manifest -SourceRoot $s.SourceRoot -BundleRoot $s.BundleRoot -WhatIf
        $result.Outcome | Should -Be 'skipped'
        Test-Path -LiteralPath $s.BundleRoot | Should -BeFalse
    }

    It 'refuses a version 1 manifest' {
        $manifest = Import-PackageManifest -Path (Join-Path $script:RepoRoot 'packer' 'manifests' 'example-baseline.json')
        { New-TransferBundle -Manifest $manifest -SourceRoot (NewTempDir) -BundleRoot (NewTempDir) } |
            Should -Throw '*schema version 2 or later*'
    }

    It 'refuses a reused run identifier' {
        $s = NewScenario
        $id = Get-RunIdentifier
        $null = New-TransferBundle -Manifest $s.Manifest -SourceRoot $s.SourceRoot -BundleRoot $s.BundleRoot -RunId $id
        { New-TransferBundle -Manifest $s.Manifest -SourceRoot $s.SourceRoot -BundleRoot $s.BundleRoot -RunId $id } |
            Should -Throw '*already exists*'
    }

    It 'refuses a malformed run identifier before creating anything' {
        $s = NewScenario
        { New-TransferBundle -Manifest $s.Manifest -SourceRoot $s.SourceRoot -BundleRoot $s.BundleRoot -RunId '../escape' } |
            Should -Throw '*canonical lowercase UUID*'
    }
}

Describe 'Test-TransferDescriptor' {

    BeforeAll {
        $script:Scenario = NewScenario
        $script:Bundle = New-TransferBundle -Manifest $script:Scenario.Manifest `
            -SourceRoot $script:Scenario.SourceRoot -BundleRoot $script:Scenario.BundleRoot
    }

    It 'accepts a descriptor matching its digest' {
        $descriptor = Test-TransferDescriptor -Path $script:Bundle.DescriptorPath -ExpectedSha256 $script:Bundle.DescriptorSha256
        $descriptor.descriptorVersion | Should -Be 1
        $descriptor.packages.Count | Should -Be 2
    }

    It 'accepts an uppercase expected digest' {
        { Test-TransferDescriptor -Path $script:Bundle.DescriptorPath -ExpectedSha256 $script:Bundle.DescriptorSha256.ToUpperInvariant() } |
            Should -Not -Throw
    }

    It 'refuses a descriptor rewritten together with its payload hashes' {
        # The attack every in-bundle check passes: the descriptor is altered and
        # the payloads are rewritten to match its new hashes, so per-package
        # verification succeeds. Only the out-of-band digest catches it.
        $copy = Join-Path (NewTempDir) 'descriptor.json'
        $document = Get-Content -LiteralPath $script:Bundle.DescriptorPath -Raw | ConvertFrom-Json
        $document.packages[0].installer.timeoutSeconds = 60
        $document | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $copy -Encoding utf8

        { Test-TransferDescriptor -Path $copy -ExpectedSha256 $script:Bundle.DescriptorSha256 } |
            Should -Throw '*digest mismatch*'
    }

    It 'reports descriptor_digest_mismatch' {
        $copy = Join-Path (NewTempDir) 'descriptor.json'
        Set-Content -LiteralPath $copy -Value 'not the descriptor' -NoNewline
        $code = $null
        try { $null = Test-TransferDescriptor -Path $copy -ExpectedSha256 $script:Bundle.DescriptorSha256 }
        catch { $code = $_.Exception.Data['ReasonCode'] }
        $code | Should -Be 'descriptor_digest_mismatch'
    }

    It 'refuses a malformed descriptor whose digest matches' {
        # Digest first, schema second: both gates are required, and neither
        # substitutes for the other.
        $copy = Join-Path (NewTempDir) 'descriptor.json'
        '{ "descriptorVersion": 1 }' | Set-Content -LiteralPath $copy -Encoding utf8
        $digest = (Get-FileHash -LiteralPath $copy -Algorithm SHA256).Hash.ToLowerInvariant()

        $code = $null
        try { $null = Test-TransferDescriptor -Path $copy -ExpectedSha256 $digest }
        catch { $code = $_.Exception.Data['ReasonCode'] }
        $code | Should -Be 'descriptor_invalid'
    }

    It 'throws when the descriptor is absent' {
        { Test-TransferDescriptor -Path (Join-Path (NewTempDir) 'absent.json') -ExpectedSha256 ('a' * 64) } |
            Should -Throw '*not found*'
    }

    It 'rejects a malformed expected digest before reading the file' {
        { Test-TransferDescriptor -Path $script:Bundle.DescriptorPath -ExpectedSha256 'not-a-digest' } | Should -Throw
    }
}
