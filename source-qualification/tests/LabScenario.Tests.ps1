#Requires -Version 7.0

<#
    The lab scenarios, and the tampering they apply.

    A scenario whose tampering silently did nothing would pass for the wrong
    reason: the run would refuse nothing and report success, and the suite would
    call that a working negative test. These assert that each tampering actually
    changes what it claims to change, which is checkable without a target.
#>

BeforeAll {
    $script:RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..' '..')).Path
    foreach ($m in 'PackageManifest', 'RunIdentity', 'Evidence', 'SourceQualification', 'TransferBundle') {
        Import-Module (Join-Path $script:RepoRoot 'source-qualification' 'scripts' "$m.psm1") -Force
    }
    Import-Module (Join-Path $script:RepoRoot 'scripts' 'ci' 'LabScenario.psm1') -Force

    function NewTempDir {
        $d = Join-Path ([System.IO.Path]::GetTempPath()) ([guid]::NewGuid().ToString())
        $null = New-Item -ItemType Directory -Path $d -Force
        $d
    }

    function NewBundle {
        $base = NewTempDir
        $source = Join-Path $base 'src'
        $relative = 'example-agent/1.2.3/payload.exe'
        $full = Join-Path $source $relative
        $null = New-Item -ItemType Directory -Path (Split-Path -Parent $full) -Force
        Set-Content -LiteralPath $full -Value 'payload bytes' -Encoding utf8 -NoNewline
        $hash = (Get-FileHash -LiteralPath $full -Algorithm SHA256).Hash.ToLowerInvariant()

        $manifest = Join-Path $base 'manifest.json'
        @{ schemaVersion = 2; packages = @(@{
            id = 'example-agent'; version = '1.2.3'; source = "file://$relative"
            sha256 = $hash; order = 10; required = $true
            installer = @{ kind = 'exe'; arguments = @('/quiet'); timeoutSeconds = 900
                           restartPolicy = 'allow-deferred'
                           exitCodes = @{ success = @(0); restartRequired = @(3010) } }
            validation = @(@{ id = 'agent-binary'; kind = 'file-exists'
                              root = 'programFiles'; relativePath = 'Example/Agent/agent.exe' })
        })} | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $manifest -Encoding utf8

        New-TransferBundle -ManifestPath $manifest -SourceRoot $source `
            -BundleRoot (Join-Path $base 'bundles') -RunId (Get-RunIdentifier)
    }

    function DescriptorDigest {
        param([string] $BundlePath)
        (Get-FileHash -LiteralPath (Join-Path $BundlePath 'descriptor.json') -Algorithm SHA256).Hash.ToLowerInvariant()
    }
}

Describe 'the three scenarios ADR 3 requires' {

    It 'defines all three' {
        (Get-LabScenario).Name | Should -Be @('descriptor-tamper', 'payload-tamper', 'positive')
    }

    It 'expects <name> to end as <outcome>' -ForEach @(
        @{ name = 'positive';          outcome = 'passed' }
        @{ name = 'payload-tamper';    outcome = 'failed' }
        @{ name = 'descriptor-tamper'; outcome = 'incomplete' }
    ) {
        (Get-LabScenario -Name $name).ExpectedOutcome | Should -Be $outcome
    }

    It 'expects no installer to run in either negative scenario' {
        foreach ($name in 'payload-tamper', 'descriptor-tamper') {
            (Get-LabScenario -Name $name).ExpectInstalled | Should -BeFalse -Because "$name must refuse before execution"
        }
    }

    It 'names a distinct expected reason code for each negative scenario' {
        # They defeat different controls, so a shared reason code would hide one
        # of them passing for the other's reason.
        $payload = (Get-LabScenario -Name 'payload-tamper').ExpectedReasonCode
        $descriptor = (Get-LabScenario -Name 'descriptor-tamper').ExpectedReasonCode
        $payload | Should -Be 'integrity_mismatch'
        $descriptor | Should -Be 'descriptor_digest_mismatch'
        $payload | Should -Not -Be $descriptor
    }
}

Describe 'Set-LabBundleTampering' {

    It 'leaves a bundle untouched for the positive scenario' {
        $bundle = NewBundle
        $before = DescriptorDigest -BundlePath $bundle.BundlePath
        $digest = Set-LabBundleTampering -BundlePath $bundle.BundlePath -OriginalDigest $bundle.DescriptorSha256 -Tamper none
        (DescriptorDigest -BundlePath $bundle.BundlePath) | Should -Be $before
        $digest | Should -Be $bundle.DescriptorSha256
    }

    It 'alters a payload and leaves the descriptor describing the original' {
        # The per-package hash comparison is what refuses this one.
        $bundle = NewBundle
        $descriptorBefore = DescriptorDigest -BundlePath $bundle.BundlePath

        $null = Set-LabBundleTampering -BundlePath $bundle.BundlePath -OriginalDigest $bundle.DescriptorSha256 -Tamper payload

        $descriptor = Get-Content -LiteralPath (Join-Path $bundle.BundlePath 'descriptor.json') -Raw | ConvertFrom-Json
        $payload = Join-Path $bundle.BundlePath ($descriptor.packages[0].payloadPath -replace '/', [System.IO.Path]::DirectorySeparatorChar)
        $observed = (Get-FileHash -LiteralPath $payload -Algorithm SHA256).Hash.ToLowerInvariant()

        $observed | Should -Not -Be $descriptor.packages[0].sha256 -Because 'the payload must no longer match what the descriptor records'
        (DescriptorDigest -BundlePath $bundle.BundlePath) | Should -Be $descriptorBefore -Because 'the descriptor itself is untouched in this scenario'
    }

    It 'rewrites the descriptor to match the altered payload' {
        # Every in-bundle check now passes. Only the out-of-band digest disagrees,
        # which is the control this scenario exists to exercise.
        $bundle = NewBundle
        $digest = Set-LabBundleTampering -BundlePath $bundle.BundlePath -OriginalDigest $bundle.DescriptorSha256 -Tamper descriptor

        $descriptor = Get-Content -LiteralPath (Join-Path $bundle.BundlePath 'descriptor.json') -Raw | ConvertFrom-Json
        $payload = Join-Path $bundle.BundlePath ($descriptor.packages[0].payloadPath -replace '/', [System.IO.Path]::DirectorySeparatorChar)
        $observed = (Get-FileHash -LiteralPath $payload -Algorithm SHA256).Hash.ToLowerInvariant()

        $observed | Should -Be $descriptor.packages[0].sha256 -Because 'the in-bundle check must pass for this scenario to mean anything'
        (DescriptorDigest -BundlePath $bundle.BundlePath) | Should -Not -Be $bundle.DescriptorSha256
        $digest | Should -Be $bundle.DescriptorSha256 -Because 'the caller still presents the digest delivered out of band'
    }

    It 'produces a bundle the guest refuses, for <tamper> tampering' -ForEach @(
        @{ tamper = 'payload';    expected = 'integrity_mismatch' }
        @{ tamper = 'descriptor'; expected = 'descriptor_digest_mismatch' }
    ) {
        # Run against the real guest logic with a fake adapter, so the scenario is
        # shown to be refused rather than assumed to be.
        Import-Module (Join-Path $script:RepoRoot 'source-qualification' 'scripts' 'GuestProvisioning.psm1') -Force

        $bundle = NewBundle
        $digest = Set-LabBundleTampering -BundlePath $bundle.BundlePath -OriginalDigest $bundle.DescriptorSha256 -Tamper $tamper

        $started = $false
        $adapter = [PSCustomObject]@{
            StartProcess   = { $script:installerStarted = $true; [PSCustomObject]@{ ExitCode = 0; TimedOut = $false; Terminated = $true } }
            ResolveRoot    = { (Join-Path ([System.IO.Path]::GetTempPath()) 'absent') }
            TestFile       = { $false }
            GetFileVersion = { $null }
            TestService    = { $false }
        }
        $script:installerStarted = $started

        if ($tamper -eq 'descriptor') {
            $code = $null
            try {
                $null = Invoke-GuestProvisioning -BundlePath $bundle.BundlePath `
                    -ExpectedDescriptorSha256 $digest -RunId $bundle.RunId -Adapter $adapter
            }
            catch { $code = $_.Exception.Data['ReasonCode'] }
            $code | Should -Be $expected
        }
        else {
            $evidence = Invoke-GuestProvisioning -BundlePath $bundle.BundlePath `
                -ExpectedDescriptorSha256 $digest -RunId $bundle.RunId -Adapter $adapter
            $evidence.payload.packages[0].reasonCode | Should -Be $expected
        }

        $script:installerStarted | Should -BeFalse -Because 'both negatives must refuse before any installer runs'
    }
}
