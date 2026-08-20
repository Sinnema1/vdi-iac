#Requires -Version 7.0

<#
    Level 2 of ADR 2: the production adapter against real Windows behavior.

    These use synthetic fixtures only. Nothing installs software, creates a
    persistent service, or reboots the runner, and the runner is not treated as
    a Packer guest. What they establish is the part no fake can: that a real
    child process receives the tokens we believe we sent, that real exit codes
    arrive intact, that a real timeout behaves as the contract says, and that
    real NTFS reparse points are refused.

    Every case skips off Windows, where the production adapter refuses to run at
    all by design.
#>

BeforeAll {
    $script:RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..' '..')).Path
    $scripts = Join-Path $script:RepoRoot 'source-qualification' 'scripts'
    foreach ($m in 'PackageManifest','RunIdentity','Evidence','SourceQualification','GuestAdapter','TransferBundle','GuestProvisioning') {
        Import-Module (Join-Path $scripts "$m.psm1") -Force
    }

    function NewTempDir {
        $d = Join-Path ([System.IO.Path]::GetTempPath()) ([guid]::NewGuid().ToString())
        $null = New-Item -ItemType Directory -Path $d -Force
        $d
    }

    function PwshPath { Join-Path $PSHOME ($(if ($IsWindows) { 'pwsh.exe' } else { 'pwsh' })) }

    function NewArgumentRecorder {
        <#
            A real child that writes the argv it received, one token per line.
            Comparing what arrives against what was sent is the only way to know
            the tokens survived the boundary.
        #>
        param([string] $OutputPath)
        $script = Join-Path (NewTempDir) 'record-args.ps1'
        @"
`$args | Set-Content -LiteralPath '$OutputPath' -Encoding utf8
"@ | Set-Content -LiteralPath $script -Encoding utf8
        $script
    }

    function NewExitCodeChild {
        param([int] $ExitCode)
        $script = Join-Path (NewTempDir) 'exit-with.ps1'
        "exit $ExitCode" | Set-Content -LiteralPath $script -Encoding utf8
        $script
    }

    function NewAuthenticatedBundle {
        <#
            A real bundle from the host path, with a real descriptor and its
            digest, so guest provisioning gets past descriptor authentication and
            actually reaches the payload.
        #>
        $base = NewTempDir
        $source = Join-Path $base 'src'
        $relative = 'example-agent/1.2.3/payload.exe'
        $full = Join-Path $source $relative
        $null = New-Item -ItemType Directory -Path (Split-Path -Parent $full) -Force
        Set-Content -LiteralPath $full -Value 'payload bytes' -Encoding utf8 -NoNewline
        $hash = (Get-FileHash -LiteralPath $full -Algorithm SHA256).Hash.ToLowerInvariant()

        $manifestPath = Join-Path $base 'manifest.json'
        @{ schemaVersion = 2; packages = @(@{
            id = 'example-agent'; version = '1.2.3'; source = "file://$relative"
            sha256 = $hash; order = 10; required = $true
            installer = @{ kind = 'exe'; arguments = @('/quiet'); timeoutSeconds = 900
                           restartPolicy = 'allow-deferred'
                           exitCodes = @{ success = @(0); restartRequired = @(3010) } }
            validation = @(@{ id = 'agent-binary'; kind = 'file-exists'
                              root = 'programFiles'; relativePath = 'Example/Agent/agent.exe' })
        })} | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $manifestPath -Encoding utf8

        New-TransferBundle -ManifestPath $manifestPath -SourceRoot $source -BundleRoot (Join-Path $base 'bundles')
    }

    function RecordingAdapter {
        # Records whether an installer was ever launched, so a test can assert
        # that a refusal happened before execution rather than after it.
        $state = [pscustomobject]@{ Started = $false }
        [PSCustomObject]@{
            State = $state
            StartProcess = { $state.Started = $true; [PSCustomObject]@{ ExitCode = 0; TimedOut = $false; Terminated = $true } }.GetNewClosure()
            ResolveRoot = { (Join-Path ([System.IO.Path]::GetTempPath()) 'absent-root') }
            TestFile = { $false }
            GetFileVersion = { $null }
            TestService = { $false }
        }
    }
}

Describe 'real child process argument handling' -Skip:(-not $IsWindows) {

    It 'delivers every token exactly as sent, including spaces and quotes' {
        # The measurement behind ADR 2. Joining tokens into a string and letting
        # the child re-split them loses both; this proves the adapter does not.
        $output = Join-Path (NewTempDir) 'argv.txt'
        $recorder = NewArgumentRecorder -OutputPath $output
        $adapter = Get-GuestAdapter

        $tokens = @('INSTALLDIR=C:\Program Files\Example', 'PROP="quoted"', '/norestart', 'TRAILING ')
        $result = & $adapter.StartProcess (PwshPath) (@('-NoProfile', '-File', $recorder) + $tokens) 120

        $result.ExitCode | Should -Be 0
        $received = @(Get-Content -LiteralPath $output)
        $received.Count | Should -Be $tokens.Count
        for ($i = 0; $i -lt $tokens.Count; $i++) {
            $received[$i] | Should -BeExactly $tokens[$i].TrimEnd("`r")
        }
    }

    It 'passes an installer invocation through without reinterpreting it' {
        $output = Join-Path (NewTempDir) 'argv.txt'
        $recorder = NewArgumentRecorder -OutputPath $output
        $entry = [PSCustomObject]@{
            id = 'example-agent'; version = '1.2.3'; order = 10; required = $true
            payloadPath = 'packages/example-agent/payload.exe'; sha256 = ('a' * 64)
            installer = [PSCustomObject]@{ kind = 'exe'; arguments = @('/quiet', '/log=C:\Temp\a b.log')
                                           timeoutSeconds = 120; restartPolicy = 'allow-deferred'
                                           exitCodes = [PSCustomObject]@{ success = @(0) } }
            validation = @()
        }
        $invocation = Get-InstallerInvocation -Entry $entry -PayloadPath $recorder -LogDirectory (NewTempDir)
        $adapter = Get-GuestAdapter
        $null = & $adapter.StartProcess (PwshPath) (@('-NoProfile', '-File', $invocation.FilePath) + $invocation.ArgumentList) 120

        @(Get-Content -LiteralPath $output) | Should -Be @('/quiet', '/log=C:\Temp\a b.log')
    }
}

Describe 'real exit codes' -Skip:(-not $IsWindows) {

    It 'returns <code> unchanged from a real process' -ForEach @(
        @{ code = 0 }, @{ code = 1 }, @{ code = 1603 }, @{ code = 3010 }, @{ code = 1641 }
    ) {
        # Windows exit codes are 32-bit. POSIX masks them to eight, which is why
        # this cannot be established on the Linux leg: 3010 arrives there as 194.
        $adapter = Get-GuestAdapter
        $result = & $adapter.StartProcess (PwshPath) @('-NoProfile', '-File', (NewExitCodeChild -ExitCode $code)) 120
        $result.ExitCode | Should -Be $code
        $result.TimedOut | Should -BeFalse
    }

    It 'normalizes a real 3010 into a deferred restart' {
        $entry = [PSCustomObject]@{ installer = [PSCustomObject]@{ kind = 'msi'; restartPolicy = 'allow-deferred' } }
        $adapter = Get-GuestAdapter
        $raw = & $adapter.StartProcess (PwshPath) @('-NoProfile', '-File', (NewExitCodeChild -ExitCode 3010)) 120
        $verdict = Get-NormalizedInstallerResult -Entry $entry -RawResult $raw

        $verdict.Outcome | Should -Be 'passed'
        $verdict.RestartRequired | Should -BeTrue
    }

    It 'normalizes a real 1641 into a failure' {
        $entry = [PSCustomObject]@{ installer = [PSCustomObject]@{ kind = 'msi'; restartPolicy = 'allow-deferred' } }
        $adapter = Get-GuestAdapter
        $raw = & $adapter.StartProcess (PwshPath) @('-NoProfile', '-File', (NewExitCodeChild -ExitCode 1641)) 120
        $verdict = Get-NormalizedInstallerResult -Entry $entry -RawResult $raw

        $verdict.Outcome | Should -Be 'failed'
        $verdict.ReasonCode | Should -Be 'installer_initiated_reboot'
    }
}

Describe 'real timeout' -Skip:(-not $IsWindows) {

    It 'reports a timeout rather than waiting for a process that will not finish' {
        $slow = Join-Path (NewTempDir) 'slow.ps1'
        'Start-Sleep -Seconds 120' | Set-Content -LiteralPath $slow -Encoding utf8
        $adapter = Get-GuestAdapter

        $elapsed = Measure-Command {
            $script:timeoutResult = & $adapter.StartProcess (PwshPath) @('-NoProfile', '-File', $slow) 5
        }

        $script:timeoutResult.TimedOut | Should -BeTrue
        $script:timeoutResult.ExitCode | Should -BeNullOrEmpty
        $elapsed.TotalSeconds | Should -BeLessThan 90
    }

    It 'stops a descendant the installer spawned, not only the installer' {
        # The earlier fixture was a single sleeping process, so parent-only Kill
        # passed and removing the kill passed too: the elapsed-time bound was the
        # only thing being measured. This one has a real descendant writing a
        # heartbeat, and asserts the writing stops.
        $work = NewTempDir
        $heartbeat = Join-Path $work 'heartbeat.txt'
        $childPidFile = Join-Path $work 'child-pid.txt'

        $childScript = Join-Path $work 'child.ps1'
        @'
param($HeartbeatPath)
while ($true) {
    Add-Content -LiteralPath $HeartbeatPath -Value ([datetime]::UtcNow.Ticks)
    Start-Sleep -Milliseconds 150
}
'@ | Set-Content -LiteralPath $childScript -Encoding utf8

        $parentScript = Join-Path $work 'parent.ps1'
        @"
param(`$HeartbeatPath, `$PidPath)
`$child = Start-Process -FilePath '$(PwshPath)' ``
    -ArgumentList '-NoProfile', '-File', '$childScript', `$HeartbeatPath ``
    -PassThru -WindowStyle Hidden
`$child.Id | Set-Content -LiteralPath `$PidPath
Start-Sleep -Seconds 300
"@ | Set-Content -LiteralPath $parentScript -Encoding utf8

        try {
            $adapter = Get-GuestAdapter
            $raw = & $adapter.StartProcess (PwshPath) @('-NoProfile', '-File', $parentScript, $heartbeat, $childPidFile) 5

            $raw.TimedOut | Should -BeTrue
            Test-Path -LiteralPath $heartbeat | Should -BeTrue -Because 'the descendant must have been running'

            # Settle, sample, wait, sample again. A surviving descendant keeps
            # appending; a stopped one does not.
            Start-Sleep -Seconds 2
            $before = (Get-Content -LiteralPath $heartbeat).Count
            Start-Sleep -Seconds 3
            $after = (Get-Content -LiteralPath $heartbeat).Count

            $after | Should -Be $before -Because 'the descendant must stop writing once the tree is terminated'

            # The safety property is unchanged: nothing confirms the tree is
            # gone, so the run stays incomplete. This case shows the
            # representative behavior, not a general confirmation mechanism.
            $entry = [PSCustomObject]@{ installer = [PSCustomObject]@{ kind = 'msi'; restartPolicy = 'allow-deferred' } }
            $verdict = Get-NormalizedInstallerResult -Entry $entry -RawResult $raw
            $raw.Terminated | Should -BeFalse
            $verdict.Outcome | Should -Be 'incomplete'
            $verdict.ReasonCode | Should -Be 'install_timeout_termination_failed'
        }
        finally {
            # Never leave a fixture process running on the runner.
            if (Test-Path -LiteralPath $childPidFile) {
                $childPid = (Get-Content -LiteralPath $childPidFile -Raw).Trim()
                if ($childPid) {
                    Get-Process -Id ([int] $childPid) -ErrorAction SilentlyContinue |
                        Stop-Process -Force -ErrorAction SilentlyContinue
                }
            }
        }
    }
}

Describe 'real reparse points' -Skip:(-not $IsWindows) {

    It 'refuses a guest validation path reached through an NTFS junction' {
        # A junction needs no elevation to create, which makes it the form most
        # likely to appear in a real guest.
        $base = NewTempDir
        $root = Join-Path $base 'root'
        $outside = Join-Path $base 'outside'
        $null = New-Item -ItemType Directory -Path $root, $outside -Force
        Set-Content -LiteralPath (Join-Path $outside 'a.exe') -Value 'outside' -NoNewline
        $null = New-Item -ItemType Junction -Path (Join-Path $root 'Example') -Target $outside

        $entry = [PSCustomObject]@{
            validation = @([PSCustomObject]@{ id = 'linked'; kind = 'file-exists'
                                              root = 'programFiles'; relativePath = 'Example/a.exe' })
        }
        $adapter = [PSCustomObject]@{
            ResolveRoot = { $root }.GetNewClosure()
            TestFile = { param($p) Test-Path -LiteralPath $p -PathType Leaf }
            GetFileVersion = { $null }
            TestService = { $false }
        }

        $result = Invoke-PackageValidation -Entry $entry -Adapter $adapter
        $result.Outcome | Should -Be 'failed'
        $result.Checks[0].reasonCode | Should -Be 'path_rejected'
    }

    It 'refuses a bundle payload reached through an NTFS junction' {
        # Built as a real authenticated bundle. An earlier version of this test
        # created no descriptor, so provisioning threw during authentication and
        # never reached the payload: it passed with reparse protection removed.
        $bundle = NewAuthenticatedBundle
        $packageDir = Join-Path $bundle.BundlePath 'packages' 'example-agent'

        $outside = NewTempDir
        Set-Content -LiteralPath (Join-Path $outside 'payload.exe') -Value 'outside content' -Encoding utf8 -NoNewline
        Set-Content -LiteralPath (Join-Path $outside 'witness.txt') -Value 'must survive' -Encoding utf8 -NoNewline

        Remove-Item -LiteralPath $packageDir -Recurse -Force
        $null = New-Item -ItemType Junction -Path $packageDir -Target $outside

        $adapter = RecordingAdapter
        $evidence = Invoke-GuestProvisioning -BundlePath $bundle.BundlePath `
            -ExpectedDescriptorSha256 $bundle.DescriptorSha256 -RunId $bundle.RunId -Adapter $adapter

        # Bounded evidence, not merely a thrown exception.
        $evidence.outcome | Should -Be 'failed'
        $evidence.payload.packages[0].reasonCode | Should -Be 'path_rejected'

        # Refused before execution, not after.
        $adapter.State.Started | Should -BeFalse

        (Get-Content -LiteralPath (Join-Path $outside 'witness.txt') -Raw) | Should -Be 'must survive'
    }

    It 'refuses a cleanup target that is an NTFS junction' {
        $witness = NewTempDir
        Set-Content -LiteralPath (Join-Path $witness 'unrelated.txt') -Value 'must survive' -NoNewline
        $staging = NewTempDir
        $id = Get-RunIdentifier
        $null = New-Item -ItemType Junction -Path (Join-Path $staging "bundle-$id") -Target $witness

        { Remove-GuestBundle -StagingRoot $staging -RunId $id } | Should -Throw '*redirected*'
        Test-Path -LiteralPath (Join-Path $witness 'unrelated.txt') | Should -BeTrue
    }
}

Describe 'real file version information' -Skip:(-not $IsWindows) {

    It 'reads a version from a real signed system binary' {
        # A system binary rather than a fixture: nothing in this repository can
        # produce a file carrying real version resources.
        $adapter = Get-GuestAdapter
        $path = Join-Path (& $adapter.ResolveRoot 'system32') 'kernel32.dll'
        $version = & $adapter.GetFileVersion $path 'file'

        $version | Should -Not -BeNullOrEmpty
        $version | Should -Match '^\d+\.\d+'
    }

    It 'selects the field it was asked for' {
        # Asserting both calls return text passes when both wrongly return
        # FileVersion. This compares each against the field it should have read,
        # on a binary where the two differ, so swapping or collapsing the mapping
        # fails.
        $adapter = Get-GuestAdapter
        $system32 = & $adapter.ResolveRoot 'system32'

        $candidate = $null
        foreach ($name in 'kernel32.dll', 'ntdll.dll', 'shell32.dll', 'user32.dll', 'notepad.exe', 'cmd.exe') {
            $path = Join-Path $system32 $name
            if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { continue }
            $info = [System.Diagnostics.FileVersionInfo]::GetVersionInfo($path)
            if ($info.FileVersion -and $info.ProductVersion -and $info.FileVersion.Trim() -ne $info.ProductVersion.Trim()) {
                $candidate = [PSCustomObject]@{ Path = $path; Info = $info }
                break
            }
        }

        if (-not $candidate) {
            Set-ItResult -Skipped -Because 'no system binary on this runner has differing file and product versions'
            return
        }

        (& $adapter.GetFileVersion $candidate.Path 'file') | Should -BeExactly $candidate.Info.FileVersion.Trim()
        (& $adapter.GetFileVersion $candidate.Path 'product') | Should -BeExactly $candidate.Info.ProductVersion.Trim()
    }

    It 'resolves every allowlisted root to a real directory' {
        $adapter = Get-GuestAdapter
        foreach ($root in 'programFiles', 'programFilesX86', 'programData', 'windows', 'system32') {
            $resolved = & $adapter.ResolveRoot $root
            $resolved | Should -Not -BeNullOrEmpty
            Test-Path -LiteralPath $resolved -PathType Container | Should -BeTrue -Because "$root must resolve"
        }
    }
}
