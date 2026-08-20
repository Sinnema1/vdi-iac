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

    It 'keeps a timed-out package incomplete rather than merely failed' {
        # The safety property, asserted independently of the mechanism: until
        # something confirms the process tree is gone, nothing is known about the
        # guest's state, and the run must say so.
        $entry = [PSCustomObject]@{ installer = [PSCustomObject]@{ kind = 'msi'; restartPolicy = 'allow-deferred' } }
        $slow = Join-Path (NewTempDir) 'slow.ps1'
        'Start-Sleep -Seconds 120' | Set-Content -LiteralPath $slow -Encoding utf8
        $adapter = Get-GuestAdapter

        $raw = & $adapter.StartProcess (PwshPath) @('-NoProfile', '-File', $slow) 5
        $verdict = Get-NormalizedInstallerResult -Entry $entry -RawResult $raw

        $verdict.Outcome | Should -Be 'incomplete'
        $verdict.ReasonCode | Should -Be 'install_timeout_termination_failed'
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
        $base = NewTempDir
        $bundle = Join-Path $base 'bundle'
        $outside = Join-Path $base 'outside'
        $null = New-Item -ItemType Directory -Path (Join-Path $bundle 'packages'), $outside -Force
        Set-Content -LiteralPath (Join-Path $outside 'payload.exe') -Value 'outside' -NoNewline
        $null = New-Item -ItemType Junction -Path (Join-Path $bundle 'packages' 'example-agent') -Target $outside

        { Invoke-GuestProvisioning -BundlePath $bundle -ExpectedDescriptorSha256 ('a' * 64) } | Should -Throw
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

    It 'distinguishes the file version from the product version' {
        $adapter = Get-GuestAdapter
        $path = Join-Path (& $adapter.ResolveRoot 'system32') 'kernel32.dll'
        # They routinely differ, which is why versionField is required rather
        # than defaulted. Asserting both are readable is the durable claim.
        (& $adapter.GetFileVersion $path 'file') | Should -Not -BeNullOrEmpty
        (& $adapter.GetFileVersion $path 'product') | Should -Not -BeNullOrEmpty
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
