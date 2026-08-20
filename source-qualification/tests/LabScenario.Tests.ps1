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

Describe 'Get-LabScenarioObservation' {

    BeforeAll {
        Import-Module (Join-Path $script:RepoRoot 'scripts' 'ci' 'LabEvidence.psm1') -Force

        function WriteGuestEvidence {
            param(
                [string] $Directory, [string] $Phase, [string] $RunId,
                [string] $Outcome = 'failed', [string] $PackageReason = 'integrity_mismatch',
                [int] $Attempts = 0, [string] $TerminalReason = $null
            )
            # An unbound [string] parameter is '', not $null, and an empty string
            # satisfies neither the enum nor the null branch -- so the document
            # would fail validation and the reader would skip it silently.
            $terminal = if ([string]::IsNullOrEmpty($TerminalReason)) { $null } else { $TerminalReason }
            $document = @{
                resultSchemaVersion = 2; resultKind = 'guest-provisioning'
                runId = $RunId; manifestSchemaVersion = 2
                startedUtc = '2026-01-01T00:00:00.0000000Z'; completedUtc = '2026-01-01T00:00:01.0000000Z'
                outcome = $Outcome
                payload = @{
                    phase = $Phase; restartRequired = $false; packageCount = 1
                    passedCount = 0; failedRequiredCount = 1
                    installerAttemptCount = $Attempts
                    terminalReasonCode = $terminal
                    cleanupOutcome = 'not-attempted'
                    packages = @(@{ id = 'a'; version = '1.0'; order = 1; required = $true
                                    outcome = 'failed'; reasonCode = $PackageReason
                                    restartRequired = $false; installerAttempted = ($Attempts -gt 0) })
                }
            }
            $document | ConvertTo-Json -Depth 12 |
                Set-Content -LiteralPath (Join-Path $Directory "$Phase-guest-evidence.json") -Encoding utf8
        }

        function NewTempDirLocal {
            $d = Join-Path ([System.IO.Path]::GetTempPath()) ([guid]::NewGuid().ToString())
            $null = New-Item -ItemType Directory -Path $d -Force
            $d
        }
    }

    It 'reads the bounded reason and the attempt count from evidence' {
        $dir = NewTempDirLocal; $runId = Get-RunIdentifier
        WriteGuestEvidence -Directory $dir -Phase 'install' -RunId $runId -PackageReason 'integrity_mismatch' -Attempts 0

        $observation = Get-LabScenarioObservation -EvidenceDirectory $dir -RunId $runId
        $observation.ReasonCode | Should -Be 'integrity_mismatch'
        $observation.InstallerAttemptCount | Should -Be 0
    }

    It 'counts an installer that started and then failed as an attempt' {
        # The defect this replaced: inferring "did not run" from the phase not
        # printing 'passed', which reports a failed installer as never launched.
        $dir = NewTempDirLocal; $runId = Get-RunIdentifier
        WriteGuestEvidence -Directory $dir -Phase 'install' -RunId $runId -PackageReason 'installer_failed' -Attempts 1

        (Get-LabScenarioObservation -EvidenceDirectory $dir -RunId $runId).InstallerAttemptCount | Should -Be 1
    }

    It 'ignores evidence belonging to another run' {
        $dir = NewTempDirLocal
        WriteGuestEvidence -Directory $dir -Phase 'install' -RunId (Get-RunIdentifier) -Attempts 1
        $observation = Get-LabScenarioObservation -EvidenceDirectory $dir -RunId (Get-RunIdentifier)
        $observation.ReasonCode | Should -BeNullOrEmpty
        $observation.InstallerAttemptCount | Should -Be 0
    }

    It 'reports nothing when no evidence was retrieved, rather than a satisfied expectation' {
        $observation = Get-LabScenarioObservation -EvidenceDirectory (NewTempDirLocal) -RunId (Get-RunIdentifier)
        $observation.ReasonCode | Should -BeNullOrEmpty
        $observation.InstallerAttemptCount | Should -Be 0
    }
}

Describe 'a scenario fails when its expectations are not met' {

    It 'passes when everything matches' {
        # The production decision, not a copy of it. A test-only evaluator proves
        # the copy works while the runner is free to diverge from it silently.
        $verdict = Get-LabScenarioVerdict -Definition (Get-LabScenario -Name 'payload-tamper') `
            -Outcome 'failed' -ObservedReasonCode 'integrity_mismatch' -InstallerAttemptCount 0 `
            -HostCleanupOutcome 'removed' -GuestCleanupOutcome 'removed'
        $verdict.Passed | Should -BeTrue
    }

    It 'fails on the wrong reason code, even with the expected outcome' {
        # 'incomplete' is reachable through missing evidence or a failed cleanup,
        # so the outcome alone cannot carry the assertion.
        $verdict = Get-LabScenarioVerdict -Definition (Get-LabScenario -Name 'descriptor-tamper') `
            -Outcome 'incomplete' -ObservedReasonCode 'integrity_mismatch' -InstallerAttemptCount 0 `
            -HostCleanupOutcome 'removed' -GuestCleanupOutcome 'removed'
        $verdict.Passed | Should -BeFalse
        ($verdict.Failures -join ' ') | Should -Match 'reason code'
    }

    It 'fails when the installer started and then failed' {
        $verdict = Get-LabScenarioVerdict -Definition (Get-LabScenario -Name 'payload-tamper') `
            -Outcome 'failed' -ObservedReasonCode 'integrity_mismatch' -InstallerAttemptCount 1 `
            -HostCleanupOutcome 'removed' -GuestCleanupOutcome 'removed'
        $verdict.Passed | Should -BeFalse
        ($verdict.Failures -join ' ') | Should -Match 'installer attempts'
    }

    It 'fails when <side> cleanup did not complete' -ForEach @(
        @{ side = 'host';  hostOutcome = 'failed';  guestOutcome = 'removed' }
        @{ side = 'guest'; hostOutcome = 'removed'; guestOutcome = 'not-attempted' }
    ) {
        $verdict = Get-LabScenarioVerdict -Definition (Get-LabScenario -Name 'payload-tamper') `
            -Outcome 'failed' -ObservedReasonCode 'integrity_mismatch' -InstallerAttemptCount 0 `
            -HostCleanupOutcome $hostOutcome -GuestCleanupOutcome $guestOutcome
        $verdict.Passed | Should -BeFalse
        ($verdict.Failures -join ' ') | Should -Match 'cleanup'
    }

    It 'reports every failure rather than only the first' {
        $verdict = Get-LabScenarioVerdict -Definition (Get-LabScenario -Name 'payload-tamper') `
            -Outcome 'passed' -ObservedReasonCode 'installer_failed' -InstallerAttemptCount 1 `
            -HostCleanupOutcome 'failed' -GuestCleanupOutcome 'failed'
        $verdict.Failures.Count | Should -BeGreaterOrEqual 4
    }
}

Describe 'the scenario runner passes every variable the harness requires' {

    It 'supplies each runtime variable that has no default' {
        # Driven from the harness itself, so adding a required variable later
        # fails here rather than at the first lab run. Two were added and the
        # runner was not updated: packer rejected every scenario before the guest
        # was reached.
        $harness = Get-Content -LiteralPath (Join-Path $script:RepoRoot 'packer' 'harness' 'lab-null.pkr.hcl') -Raw
        $runner = Get-Content -LiteralPath (Join-Path $script:RepoRoot 'scripts' 'ci' 'Invoke-LabScenario.ps1') -Raw
        $example = Get-Content -LiteralPath (Join-Path $script:RepoRoot 'packer' 'harness' 'lab.auto.pkrvars.hcl.example') -Raw

        $declared = [regex]::Matches($harness, '(?m)^variable\s+"(?<name>[a-z_]+)"') | ForEach-Object { $_.Groups['name'].Value }

        foreach ($name in $declared) {
            $suppliedByRunner = $runner -match [regex]::Escape("`"$name=")
            $suppliedByOperator = $example -match "(?m)^\s*$([regex]::Escape($name))\s*="
            ($suppliedByRunner -or $suppliedByOperator) | Should -BeTrue -Because "'$name' must come from the runner or the operator's var file"
        }
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
