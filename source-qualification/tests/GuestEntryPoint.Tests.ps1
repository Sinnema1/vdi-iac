#Requires -Version 7.0

<#
    The guest entry script, invoked the way Packer invokes it.

    Every other harness test reads configuration text. None of them executes this
    script, which is how it shipped calling Invoke-GuestProvisioning with a
    parameter that function does not have: all 25 harness tests stayed green
    while every real phase would have failed parameter binding and exited 1.

    These run it as a subprocess with the environment Packer sets, and assert on
    its exit code and the evidence it writes.

    The wiring case runs everywhere: a binding error is visible on any platform.
    The cases that need the phase to actually execute are Windows-only, because
    the production adapter refuses every other platform by design and the entry
    script takes no injected adapter -- it is the production path.
#>

BeforeAll {
    $script:RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..' '..')).Path
    $script:Scripts = Join-Path $script:RepoRoot 'source-qualification' 'scripts'
    $script:EntryPoint = Join-Path $script:RepoRoot 'packer' 'scripts' 'guest' 'Invoke-GuestPhase.ps1'
    $script:Pwsh = Join-Path $PSHOME ($(if ($IsWindows) { 'pwsh.exe' } else { 'pwsh' }))

    foreach ($m in 'PackageManifest', 'RunIdentity', 'Evidence', 'SourceQualification', 'TransferBundle') {
        Import-Module (Join-Path $script:Scripts "$m.psm1") -Force
    }

    function NewTempDir {
        $d = Join-Path ([System.IO.Path]::GetTempPath()) ([guid]::NewGuid().ToString())
        $null = New-Item -ItemType Directory -Path $d -Force
        $d
    }

    function NewBundle {
        param([string] $RunId)
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
            -BundleRoot (Join-Path $base 'bundles') -RunId $RunId
    }

    function RunEntryPoint {
        <#
            Invoked as a subprocess with the environment Packer provides, so the
            script is exercised exactly as the harness runs it.
        #>
        param(
            [string] $BundlePath, [string] $Phase, [string] $EvidencePath,
            [string] $Digest, [string] $RunId, [switch] $OmitDigest, [switch] $OmitRunId
        )

        $previousDigest = $env:VDIIAC_DESCRIPTOR_SHA256
        $previousRunId = $env:VDIIAC_RUN_ID
        try {
            $env:VDIIAC_DESCRIPTOR_SHA256 = if ($OmitDigest) { '' } else { $Digest }
            $env:VDIIAC_RUN_ID = if ($OmitRunId) { '' } else { $RunId }

            $output = & $script:Pwsh -NoProfile -File $script:EntryPoint `
                -BundlePath $BundlePath -ToolsPath $script:Scripts `
                -Phase $Phase -EvidencePath $EvidencePath 2>&1

            [PSCustomObject]@{ ExitCode = $LASTEXITCODE; Output = ($output | Out-String) }
        }
        finally {
            $env:VDIIAC_DESCRIPTOR_SHA256 = $previousDigest
            $env:VDIIAC_RUN_ID = $previousRunId
        }
    }
}

Describe 'the guest entry script runs' {

    It 'binds every parameter it passes to the provisioning function' {
        # The regression. A parameter the function does not accept fails binding
        # at run time and cannot be seen by reading configuration.
        $runId = Get-RunIdentifier
        $bundle = NewBundle -RunId $runId
        $evidence = Join-Path (NewTempDir) 'install-evidence.json'

        $run = RunEntryPoint -BundlePath $bundle.BundlePath -Phase install -EvidencePath $evidence `
            -Digest $bundle.DescriptorSha256 -RunId $runId

        # Runs on every platform, because the defect it guards is wiring, not
        # behavior. Off Windows the production adapter refuses by design, so the
        # assertion is about which failure occurred: a binding error means the
        # script and the function disagree about their interface.
        $run.Output | Should -Not -Match 'A parameter cannot be found'
        $run.Output | Should -Not -Match 'parameter set cannot be resolved'

        if (-not $IsWindows) {
            # A bounded reason code, not the exception text: the script reports
            # what went wrong without echoing a message into an artifact.
            $run.Output | Should -Match 'adapter_unsupported' -Because 'the only expected failure here is the adapter refusing this platform'
        }
        else {
            $run.ExitCode | Should -Not -Be 1 -Because "the script must run, not fail to start: $($run.Output)"
        }
    }

    It 'writes schema-valid evidence carrying the run identifier' -Skip:(-not $IsWindows) {
        $runId = Get-RunIdentifier
        $bundle = NewBundle -RunId $runId
        $evidence = Join-Path (NewTempDir) 'install-evidence.json'

        $null = RunEntryPoint -BundlePath $bundle.BundlePath -Phase install -EvidencePath $evidence `
            -Digest $bundle.DescriptorSha256 -RunId $runId

        Test-Path -LiteralPath $evidence | Should -BeTrue -Because 'evidence is what the host evaluates'
        $parsed = Get-Content -LiteralPath $evidence -Raw | ConvertFrom-Json
        $parsed.resultKind | Should -Be 'guest-provisioning'
        $parsed.resultSchemaVersion | Should -Be 2
        $parsed.runId | Should -Be $runId
        $parsed.payload.phase | Should -Be 'install'
    }

    It 'refuses a bundle belonging to a different run' -Skip:(-not $IsWindows) {
        # A bundle authenticates against its own digest perfectly well. Only the
        # out-of-band identifier says whether it belongs to this run.
        $bundle = NewBundle -RunId (Get-RunIdentifier)
        $evidence = Join-Path (NewTempDir) 'install-evidence.json'

        $run = RunEntryPoint -BundlePath $bundle.BundlePath -Phase install -EvidencePath $evidence `
            -Digest $bundle.DescriptorSha256 -RunId (Get-RunIdentifier)

        # 200, not 1: the phase now writes bounded evidence and halts, so the
        # harness can retrieve the record of the refusal before failing the build.
        $run.ExitCode | Should -Be 200
        $run.Output | Should -Match 'run_id_mismatch'
    }

    It 'leaves bounded evidence when a phase cannot run' {
        # A phase that failed before producing evidence used to leave nothing to
        # retrieve, so the host could not tell a refused bundle from a lost
        # communicator. Exercised here through the adapter refusal, which is the
        # failure available on every platform.
        $runId = Get-RunIdentifier
        $bundle = NewBundle -RunId $runId
        $evidence = Join-Path (NewTempDir) 'install-evidence.json'
        $halt = Join-Path (NewTempDir) 'halt.txt'

        $previousHalt = $env:VDIIAC_HALT_PATH
        try {
            $env:VDIIAC_HALT_PATH = $halt
            $null = RunEntryPoint -BundlePath $bundle.BundlePath -Phase install -EvidencePath $evidence `
                -Digest $bundle.DescriptorSha256 -RunId $runId
        }
        finally { $env:VDIIAC_HALT_PATH = $previousHalt }

        if ($IsWindows) {
            Set-ItResult -Skipped -Because 'the adapter does not refuse on Windows, so this path needs a different trigger there'
            return
        }

        Test-Path -LiteralPath $evidence | Should -BeTrue
        $parsed = Get-Content -LiteralPath $evidence -Raw | ConvertFrom-Json
        $parsed.outcome | Should -Be 'incomplete'
        $parsed.payload.terminalReasonCode | Should -Be 'adapter_unsupported'
        $parsed.runId | Should -Be $runId

        # The halt marker is what stops the harness before the restart.
        Test-Path -LiteralPath $halt | Should -BeTrue
    }

    It 'refuses to start when <missing> is absent from the environment' -ForEach @(
        @{ missing = 'the descriptor digest'; omitDigest = $true;  omitRunId = $false }
        @{ missing = 'the run identifier';    omitDigest = $false; omitRunId = $true }
    ) {
        $runId = Get-RunIdentifier
        $bundle = NewBundle -RunId $runId
        $evidence = Join-Path (NewTempDir) 'install-evidence.json'

        $run = RunEntryPoint -BundlePath $bundle.BundlePath -Phase install -EvidencePath $evidence `
            -Digest $bundle.DescriptorSha256 -RunId $runId `
            -OmitDigest:$omitDigest -OmitRunId:$omitRunId

        $run.ExitCode | Should -Be 1
        Test-Path -LiteralPath $evidence | Should -BeFalse
    }

    It 'refuses a tampered descriptor before installing anything' -Skip:(-not $IsWindows) {
        $runId = Get-RunIdentifier
        $bundle = NewBundle -RunId $runId
        $evidence = Join-Path (NewTempDir) 'install-evidence.json'

        $run = RunEntryPoint -BundlePath $bundle.BundlePath -Phase install -EvidencePath $evidence `
            -Digest ('f' * 64) -RunId $runId

        $run.ExitCode | Should -Not -Be 0
        $run.Output | Should -Match 'descriptor_digest_mismatch'

        # The refusal is recorded rather than merely reported, so the host can
        # tell a refused bundle from a lost communicator.
        Test-Path -LiteralPath $evidence | Should -BeTrue
        $parsed = Get-Content -LiteralPath $evidence -Raw | ConvertFrom-Json
        $parsed.outcome | Should -Be 'incomplete'
        $parsed.payload.terminalReasonCode | Should -Be 'descriptor_digest_mismatch'
    }
}
