#Requires -Version 7.0

<#
    Guest verification, execution, validation, and evidence.

    Every operating-system interaction goes through an injected adapter, so these
    run on any platform without installing software, creating a service, or
    rebooting anything. Exit-code policy in particular is exercised through fakes
    rather than real processes: POSIX masks a process exit status to eight bits,
    so a real child cannot return 3010 on Linux at all.
#>

# Evaluated at discovery: Pester resolves -Skip while discovering tests, before
# BeforeAll runs, so a probe placed there leaves every link test silently skipped.
$script:LinksSupported = $(
    $probe = Join-Path ([System.IO.Path]::GetTempPath()) ([guid]::NewGuid().ToString())
    $null = New-Item -ItemType Directory -Path $probe -Force
    try { $null = New-Item -ItemType SymbolicLink -Path (Join-Path $probe 'l') -Target $probe -ErrorAction Stop; $true }
    catch { $false }
    finally { Remove-Item -LiteralPath $probe -Recurse -Force -ErrorAction SilentlyContinue }
)

BeforeAll {
    $script:RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..' '..')).Path
    $scripts = Join-Path $script:RepoRoot 'source-qualification' 'scripts'
    foreach ($m in 'PackageManifest','RunIdentity','SourceQualification','Evidence','GuestAdapter','TransferBundle','GuestProvisioning') {
        Import-Module (Join-Path $scripts "$m.psm1") -Force
    }

    function NewTempDir {
        $d = Join-Path ([System.IO.Path]::GetTempPath()) ([guid]::NewGuid().ToString())
        $null = New-Item -ItemType Directory -Path $d -Force
        $d
    }

    function ExeEntry {
        # The local is not named $installer: PowerShell variable names are
        # case-insensitive, so $installer and the $Installer parameter would be
        # one object, and the copy below would modify what it is enumerating.
        param([hashtable] $Installer = @{}, $Validation)
        $spec = @{ kind = 'exe'; arguments = @('/quiet'); timeoutSeconds = 900
                   restartPolicy = 'allow-deferred'
                   exitCodes = [PSCustomObject]@{ success = @(0); restartRequired = @(3010) } }
        foreach ($k in $Installer.Keys) { $spec[$k] = $Installer[$k] }
        [PSCustomObject]@{
            id = 'example-agent'; version = '1.2.3'; order = 10; required = $true
            payloadPath = 'packages/example-agent/payload.exe'; sha256 = ('a' * 64)
            installer = [PSCustomObject] $spec
            validation = if ($PSBoundParameters.ContainsKey('Validation')) { $Validation } else { @() }
        }
    }

    function MsiEntry {
        param([hashtable] $Installer = @{})
        $spec = @{ kind = 'msi'; timeoutSeconds = 1800; restartPolicy = 'allow-deferred'
                   properties = [PSCustomObject]@{ ALLUSERS = '1' } }
        foreach ($k in $Installer.Keys) { $spec[$k] = $Installer[$k] }
        [PSCustomObject]@{
            id = 'example-runtime'; version = '4.2.1'; order = 20; required = $true
            payloadPath = 'packages/example-runtime/payload.msi'; sha256 = ('b' * 64)
            installer = [PSCustomObject] $spec; validation = @()
        }
    }

    function NewBundleScenario {
            <#
                A real bundle produced by the host path, so the guest phase is
                exercised against something the assembler actually built rather
                than a hand-written descriptor.
            #>
            param([switch] $CorruptPayloadAfterAssembly, [switch] $OptionalOnly)

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
                sha256 = $hash; order = 10; required = (-not $OptionalOnly)
                installer = @{ kind = 'exe'; arguments = @('/quiet'); timeoutSeconds = 900
                               restartPolicy = 'allow-deferred'
                               exitCodes = @{ success = @(0); restartRequired = @(3010) } }
                validation = @(@{ id = 'agent-binary'; kind = 'file-exists'
                                  root = 'programFiles'; relativePath = 'Example/Agent/agent.exe' })
            })} | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $manifestPath -Encoding utf8

            $bundle = New-TransferBundle -ManifestPath $manifestPath -SourceRoot $source -BundleRoot (Join-Path $base 'bundles')

            if ($CorruptPayloadAfterAssembly) {
                # Altering the payload after the host verified it is what guest
                # re-verification exists to catch.
                $payload = Join-Path $bundle.BundlePath 'packages' 'example-agent' 'payload.exe'
                Set-Content -LiteralPath $payload -Value 'tampered' -Encoding utf8 -NoNewline
            }

            $bundle
        }

    function ExpectedPath {
        # Built exactly as the module builds it, so the fake's keys agree with
        # what the module looks up on any platform. Concatenating a separator by
        # hand does not, because Windows normalizes separators across the whole
        # path.
        param([string] $Root, [string] $Relative)
        $path = $Root
        foreach ($segment in $Relative.Split('/')) { if ($segment) { $path = Join-Path $path $segment } }
        $path
    }

    function RawResult {
        param($ExitCode, [switch] $TimedOut, [bool] $Terminated = $true)
        [PSCustomObject]@{ ExitCode = $ExitCode; TimedOut = [bool] $TimedOut; Terminated = $Terminated }
    }

    function NewValidationRoot {
        <#
            A real directory, because confinement is a filesystem property: the
            resolver walks actual components looking for a redirection, so a
            fictional root cannot exercise it.
        #>
        param([string[]] $Files = @())
        $root = NewTempDir
        foreach ($relative in $Files) {
            $full = $root
            foreach ($segment in $relative.Split('/')) { $full = Join-Path $full $segment }
            $null = New-Item -ItemType Directory -Path (Split-Path -Parent $full) -Force
            Set-Content -LiteralPath $full -Value 'content' -NoNewline
        }
        $root
    }

    function FakeAdapter {
        <#
            Records what it was asked to do and returns what the test dictates.
            Nothing here touches the operating system.
        #>
        param(
            [scriptblock] $StartProcess = { [PSCustomObject]@{ ExitCode = 0; TimedOut = $false; Terminated = $true } },
            [string] $Root, [hashtable] $Versions = @{}, [string[]] $Services = @()
        )
        # Bound to locals before capture: static analysis cannot see a parameter
        # referenced only inside a closure, and would report each as unused.
        $rootPath = $Root
        $versionMap = $Versions
        $serviceNames = $Services

        [PSCustomObject]@{
            Name = 'fake'
            StartProcess = $StartProcess
            # A real directory. File presence is answered by the filesystem, so
            # the confinement walk has something to walk.
            ResolveRoot = { $rootPath }.GetNewClosure()
            TestFile = { param($p) Test-Path -LiteralPath $p -PathType Leaf }
            GetFileVersion = { param($p) if ($versionMap.ContainsKey($p)) { $versionMap[$p] } else { $null } }.GetNewClosure()
            TestService = { param($n) $serviceNames -contains $n }.GetNewClosure()
        }
    }
}

Describe 'Get-NormalizedInstallerResult' {

    Context 'MSI codes, which the platform fixes' {

        It 'treats 0 as success' {
            $v = Get-NormalizedInstallerResult -Entry (MsiEntry) -RawResult (RawResult 0)
            $v.Outcome | Should -Be 'passed'
            $v.RestartRequired | Should -BeFalse
        }

        It 'treats 3010 as success requiring a deferred restart' {
            $v = Get-NormalizedInstallerResult -Entry (MsiEntry) -RawResult (RawResult 3010)
            $v.Outcome | Should -Be 'passed'
            $v.RestartRequired | Should -BeTrue
        }

        It 'treats 1641 as failure, because the installer took the restart boundary' {
            $v = Get-NormalizedInstallerResult -Entry (MsiEntry) -RawResult (RawResult 1641)
            $v.Outcome | Should -Be 'failed'
            $v.ReasonCode | Should -Be 'installer_initiated_reboot'
        }

        It 'treats <code> as failure' -ForEach @(@{ code = 1603 }, @{ code = 1 }, @{ code = -1 }) {
            (Get-NormalizedInstallerResult -Entry (MsiEntry) -RawResult (RawResult $code)).Outcome | Should -Be 'failed'
        }
    }

    Context 'EXE codes, which the manifest declares' {

        It 'honours a declared success code' {
            $entry = ExeEntry -Installer @{ exitCodes = [PSCustomObject]@{ success = @(0, 5) } }
            (Get-NormalizedInstallerResult -Entry $entry -RawResult (RawResult 5)).Outcome | Should -Be 'passed'
        }

        It 'honours a declared restart-required code' {
            $v = Get-NormalizedInstallerResult -Entry (ExeEntry) -RawResult (RawResult 3010)
            $v.Outcome | Should -Be 'passed'
            $v.RestartRequired | Should -BeTrue
        }

        It 'fails an undeclared code' {
            (Get-NormalizedInstallerResult -Entry (ExeEntry) -RawResult (RawResult 7)).ReasonCode | Should -Be 'installer_failed'
        }

        It 'does not apply MSI conventions to an EXE' {
            # 3010 means restart only because this manifest said so. An EXE that
            # did not declare it must fail rather than inherit the MSI meaning.
            $entry = ExeEntry -Installer @{ exitCodes = [PSCustomObject]@{ success = @(0) } }
            (Get-NormalizedInstallerResult -Entry $entry -RawResult (RawResult 3010)).Outcome | Should -Be 'failed'
        }
    }

    Context 'restart policy' {

        It 'fails a restart-required result when the policy forbids one' {
            $entry = ExeEntry -Installer @{ restartPolicy = 'forbid' }
            $v = Get-NormalizedInstallerResult -Entry $entry -RawResult (RawResult 3010)
            $v.Outcome | Should -Be 'failed'
            $v.ReasonCode | Should -Be 'restart_forbidden'
            $v.RestartRequired | Should -BeFalse
        }

        It 'leaves a plain success alone under the same policy' {
            $entry = ExeEntry -Installer @{ restartPolicy = 'forbid' }
            (Get-NormalizedInstallerResult -Entry $entry -RawResult (RawResult 0)).Outcome | Should -Be 'passed'
        }
    }

    Context 'timeout' {

        It 'reports install_timeout when the process was terminated' {
            $v = Get-NormalizedInstallerResult -Entry (ExeEntry) -RawResult (RawResult $null -TimedOut -Terminated $true)
            $v.Outcome | Should -Be 'failed'
            $v.ReasonCode | Should -Be 'install_timeout'
        }

        It 'reports incomplete when termination could not be confirmed' {
            # The machine may still be being modified, so nothing is known about
            # its state. That is not a package failure.
            $v = Get-NormalizedInstallerResult -Entry (ExeEntry) -RawResult (RawResult $null -TimedOut -Terminated $false)
            $v.Outcome | Should -Be 'incomplete'
            $v.ReasonCode | Should -Be 'install_timeout_termination_failed'
        }
    }
}

Describe 'Get-InstallerInvocation' {

    It 'gives msiexec the switches and lets the manifest contribute only properties' {
        $invocation = Get-InstallerInvocation -Entry (MsiEntry) -PayloadPath '/bundle/payload.msi' -LogDirectory '/logs'
        $invocation.FilePath | Should -Be 'msiexec.exe'
        $invocation.ArgumentList | Should -Contain '/qn'
        $invocation.ArgumentList | Should -Contain '/norestart'
        $invocation.ArgumentList | Should -Contain 'ALLUSERS=1'
    }

    It 'passes each token separately rather than as one string' {
        # The property this protects: a value containing a space stays one token.
        $entry = MsiEntry -Installer @{ properties = [PSCustomObject]@{ INSTALLDIR = 'C:/Program Files/Example' } }
        $invocation = Get-InstallerInvocation -Entry $entry -PayloadPath '/bundle/payload.msi' -LogDirectory '/logs'
        $invocation.ArgumentList | Should -Contain 'INSTALLDIR=C:/Program Files/Example'
    }

    It 'runs an EXE payload directly with its declared tokens' {
        $invocation = Get-InstallerInvocation -Entry (ExeEntry) -PayloadPath '/bundle/payload.exe' -LogDirectory '/logs'
        $invocation.FilePath | Should -Be '/bundle/payload.exe'
        $invocation.ArgumentList | Should -Be @('/quiet')
    }
}

Describe 'Invoke-PackageValidation' {

    It 'passes when every check passes' {
        $checks = @([PSCustomObject]@{ id = 'present'; kind = 'file-exists'; root = 'programFiles'; relativePath = 'Example/a.exe' })
        $adapter = FakeAdapter -Root (NewValidationRoot -Files @('Example/a.exe'))
        (Invoke-PackageValidation -Entry (ExeEntry -Validation $checks) -Adapter $adapter).Outcome | Should -Be 'passed'
    }

    It 'fails when a file is absent' {
        $checks = @([PSCustomObject]@{ id = 'present'; kind = 'file-exists'; root = 'programFiles'; relativePath = 'Example/a.exe' })
        $result = Invoke-PackageValidation -Entry (ExeEntry -Validation $checks) -Adapter (FakeAdapter -Root (NewValidationRoot))
        $result.Outcome | Should -Be 'failed'
        $result.Checks[0].reasonCode | Should -Be 'file_absent'
    }

    It 'reports inconclusive, not failed, when a check could not run' {
        # An adapter that threw established nothing. Calling that a failure would
        # claim knowledge the run does not have.
        $checks = @([PSCustomObject]@{ id = 'svc'; kind = 'service-exists'; serviceName = 'ExampleAgent' })
        $adapter = FakeAdapter -Root (NewValidationRoot)
        $adapter.TestService = { throw 'service control manager unavailable' }
        $result = Invoke-PackageValidation -Entry (ExeEntry -Validation $checks) -Adapter $adapter
        $result.Outcome | Should -Be 'inconclusive'
        $result.Checks[0].reasonCode | Should -Be 'check_error'
    }

    It 'reports inconclusive when a file carries no version information' {
        # No version registered for this path, so the adapter returns null: the
        # file is present but the check established nothing.
        $root = NewValidationRoot -Files @('Example/a.exe')
        $checks = @([PSCustomObject]@{ id = 'ver'; kind = 'file-version'; root = 'programFiles'
                                       relativePath = 'Example/a.exe'; versionField = 'file'; expectedVersion = '4.2.1' })
        $adapter = FakeAdapter -Root $root
        $result = Invoke-PackageValidation -Entry (ExeEntry -Validation $checks) -Adapter $adapter
        $result.Outcome | Should -Be 'inconclusive'
        $result.Checks[0].reasonCode | Should -Be 'version_unavailable'
    }

    It 'treats <observed> as equal to expected 7.0.1024' -ForEach @(
        @{ observed = '7.0.1024' }, @{ observed = '7.0.1024.0' }
    ) {
        $root = NewValidationRoot -Files @('Example/a.exe')
        $path = ExpectedPath $root 'Example/a.exe'
        $checks = @([PSCustomObject]@{ id = 'ver'; kind = 'file-version'; root = 'programFiles'
                                       relativePath = 'Example/a.exe'; versionField = 'file'; expectedVersion = '7.0.1024' })
        $adapter = FakeAdapter -Root $root -Versions @{ $path = $observed }
        (Invoke-PackageValidation -Entry (ExeEntry -Validation $checks) -Adapter $adapter).Outcome | Should -Be 'passed'
    }

    It 'reports a version mismatch as failed' {
        $root = NewValidationRoot -Files @('Example/a.exe')
        $path = ExpectedPath $root 'Example/a.exe'
        $checks = @([PSCustomObject]@{ id = 'ver'; kind = 'file-version'; root = 'programFiles'
                                       relativePath = 'Example/a.exe'; versionField = 'file'; expectedVersion = '7.0.1024' })
        $adapter = FakeAdapter -Root $root -Versions @{ $path = '7.0.1024.1' }
        $result = Invoke-PackageValidation -Entry (ExeEntry -Validation $checks) -Adapter $adapter
        $result.Outcome | Should -Be 'failed'
        $result.Checks[0].reasonCode | Should -Be 'version_mismatch'
    }

    It 'lets one failed check outrank an inconclusive one' {
        $checks = @(
            [PSCustomObject]@{ id = 'absent'; kind = 'file-exists'; root = 'programFiles'; relativePath = 'Example/a.exe' }
            [PSCustomObject]@{ id = 'svc'; kind = 'service-exists'; serviceName = 'ExampleAgent' }
        )
        $adapter = FakeAdapter -Root (NewValidationRoot)
        $adapter.TestService = { throw 'unavailable' }
        (Invoke-PackageValidation -Entry (ExeEntry -Validation $checks) -Adapter $adapter).Outcome | Should -Be 'failed'
    }
}

Describe 'Invoke-GuestProvisioning' {

    It 'installs a verified package and returns an evidence envelope' {
        $bundle = NewBundleScenario
        $evidence = Invoke-GuestProvisioning -BundlePath $bundle.BundlePath `
            -ExpectedDescriptorSha256 $bundle.DescriptorSha256 -Adapter (FakeAdapter)

        $evidence.resultSchemaVersion | Should -Be 2
        $evidence.resultKind | Should -Be 'guest-provisioning'
        $evidence.manifestSchemaVersion | Should -Be 2
        $evidence.runId | Should -Be $bundle.RunId
        $evidence.outcome | Should -Be 'passed'
        $evidence.payload.passedCount | Should -Be 1
    }

    It 're-verifies the payload in the guest and refuses tampering' {
        # The host verified this file. It changed afterwards, and only the guest
        # check stands between that and execution.
        $bundle = NewBundleScenario -CorruptPayloadAfterAssembly
        $started = $false
        $adapter = FakeAdapter -StartProcess { $script:started = $true; [PSCustomObject]@{ ExitCode = 0; TimedOut = $false; Terminated = $true } }

        $evidence = Invoke-GuestProvisioning -BundlePath $bundle.BundlePath `
            -ExpectedDescriptorSha256 $bundle.DescriptorSha256 -Adapter $adapter

        $evidence.outcome | Should -Be 'failed'
        $evidence.payload.packages[0].reasonCode | Should -Be 'integrity_mismatch'
    }

    It 'refuses a descriptor whose digest does not match' {
        $bundle = NewBundleScenario
        { Invoke-GuestProvisioning -BundlePath $bundle.BundlePath -ExpectedDescriptorSha256 ('f' * 64) -Adapter (FakeAdapter) } |
            Should -Throw '*digest mismatch*'
    }

    It 'reports that a restart is required without triggering one' {
        $bundle = NewBundleScenario
        $adapter = FakeAdapter -StartProcess { [PSCustomObject]@{ ExitCode = 3010; TimedOut = $false; Terminated = $true } }
        $evidence = Invoke-GuestProvisioning -BundlePath $bundle.BundlePath `
            -ExpectedDescriptorSha256 $bundle.DescriptorSha256 -Adapter $adapter

        $evidence.outcome | Should -Be 'passed'
        $evidence.payload.restartRequired | Should -BeTrue
    }

    It 'stops the batch when a timed-out installer could not be terminated' {
        $bundle = NewBundleScenario
        $adapter = FakeAdapter -StartProcess { [PSCustomObject]@{ ExitCode = $null; TimedOut = $true; Terminated = $false } }
        $evidence = Invoke-GuestProvisioning -BundlePath $bundle.BundlePath `
            -ExpectedDescriptorSha256 $bundle.DescriptorSha256 -Adapter $adapter

        $evidence.outcome | Should -Be 'incomplete'
        $evidence.payload.terminalReasonCode | Should -Be 'install_timeout_termination_failed'
    }

    It 'runs validation only in the validate phase' {
        # Validation belongs on the far side of the restart. Running it during
        # install would observe a state the machine will not be in afterwards.
        $bundle = NewBundleScenario
        $install = Invoke-GuestProvisioning -BundlePath $bundle.BundlePath `
            -ExpectedDescriptorSha256 $bundle.DescriptorSha256 -Adapter (FakeAdapter)
        $install.payload.packages[0].validation | Should -BeNullOrEmpty

        $root = NewValidationRoot -Files @('Example/Agent/agent.exe')
        $validate = Invoke-GuestProvisioning -BundlePath $bundle.BundlePath -Phase validate `
            -ExpectedDescriptorSha256 $bundle.DescriptorSha256 -Adapter (FakeAdapter -Root $root)

        $validate.outcome | Should -Be 'passed'
        $validate.payload.packages[0].validation.Count | Should -Be 1
    }

    It 'fails the validate phase when the expected state is absent' {
        $bundle = NewBundleScenario
        $evidence = Invoke-GuestProvisioning -BundlePath $bundle.BundlePath -Phase validate `
            -ExpectedDescriptorSha256 $bundle.DescriptorSha256 -Adapter (FakeAdapter -Root (NewValidationRoot))
        $evidence.outcome | Should -Be 'failed'
        $evidence.payload.packages[0].reasonCode | Should -Be 'validation_failed'
    }

    It 'keeps arguments and paths out of evidence' {
        # The rule ADR 5 states: a failed install is exactly when someone wants
        # the command line, and that is exactly when it must not be recorded.
        $bundle = NewBundleScenario
        $adapter = FakeAdapter -StartProcess { [PSCustomObject]@{ ExitCode = 7; TimedOut = $false; Terminated = $true } }
        $evidence = Invoke-GuestProvisioning -BundlePath $bundle.BundlePath `
            -ExpectedDescriptorSha256 $bundle.DescriptorSha256 -Adapter $adapter

        $json = $evidence | ConvertTo-Json -Depth 16
        $json | Should -Not -Match '/quiet'
        $json | Should -Not -Match ([regex]::Escape($bundle.BundlePath))
        $evidence.payload.packages[0].reasonCode | Should -Be 'installer_failed'
    }
}

Describe 'guest path confinement' {

    It 'refuses a validation path redirected by a link' -Skip:(-not $script:LinksSupported) {
        # A link beneath a validation root would let a check report on a file
        # outside it. Portable case now; the NTFS junction equivalent is a
        # Stage 4 Windows component test.
        $base = NewTempDir
        $root = Join-Path $base 'root'
        $outside = Join-Path $base 'outside'
        $null = New-Item -ItemType Directory -Path $root, $outside -Force
        Set-Content -LiteralPath (Join-Path $outside 'a.exe') -Value 'outside' -NoNewline
        $null = New-Item -ItemType SymbolicLink -Path (Join-Path $root 'Example') -Target $outside

        $checks = @([PSCustomObject]@{ id = 'linked'; kind = 'file-exists'; root = 'programFiles'; relativePath = 'Example/a.exe' })
        $result = Invoke-PackageValidation -Entry (ExeEntry -Validation $checks) -Adapter (FakeAdapter -Root $root)

        $result.Outcome | Should -Be 'failed'
        $result.Checks[0].reasonCode | Should -Be 'path_rejected'
    }

    It 'refuses a validation path that escapes its root' {
        $checks = @([PSCustomObject]@{ id = 'escape'; kind = 'file-exists'; root = 'programFiles'; relativePath = 'Example/../../outside.exe' })
        $result = Invoke-PackageValidation -Entry (ExeEntry -Validation $checks) -Adapter (FakeAdapter -Root (NewValidationRoot))
        $result.Checks[0].reasonCode | Should -Be 'path_rejected'
    }

    It 'refuses a bundle payload reached through a link' -Skip:(-not $script:LinksSupported) {
        # A link inside an uploaded bundle would let a verified hash stand in for
        # a file somewhere else entirely.
        $bundle = NewBundleScenario
        $payloadDir = Join-Path $bundle.BundlePath 'packages' 'example-agent'
        $outside = Join-Path (NewTempDir) 'elsewhere'
        $null = New-Item -ItemType Directory -Path $outside -Force
        Copy-Item -LiteralPath (Join-Path $payloadDir 'payload.exe') -Destination (Join-Path $outside 'payload.exe')
        Remove-Item -LiteralPath $payloadDir -Recurse -Force
        $null = New-Item -ItemType SymbolicLink -Path $payloadDir -Target $outside

        $evidence = Invoke-GuestProvisioning -BundlePath $bundle.BundlePath `
            -ExpectedDescriptorSha256 $bundle.DescriptorSha256 -Adapter (FakeAdapter -Root (NewValidationRoot))

        $evidence.outcome | Should -Be 'failed'
        $evidence.payload.packages[0].reasonCode | Should -Be 'path_rejected'
    }
}

Describe 'Remove-GuestBundle' {

    BeforeAll {
        function NewStagedRun {
            param([switch] $WithoutBundle)
            $staging = NewTempDir
            $id = Get-RunIdentifier
            if (-not $WithoutBundle) {
                $bundle = Join-Path $staging "bundle-$id"
                $null = New-Item -ItemType Directory -Path $bundle -Force
                Set-Content -LiteralPath (Join-Path $bundle 'descriptor.json') -Value '{}' -NoNewline
            }
            [PSCustomObject]@{ StagingRoot = $staging; RunId = $id; BundlePath = (Join-Path $staging "bundle-$id") }
        }
    }

    It 'removes the run it owns and says so' {
        $run = NewStagedRun
        Remove-GuestBundle -StagingRoot $run.StagingRoot -RunId $run.RunId | Should -Be 'removed'
        Test-Path -LiteralPath $run.BundlePath | Should -BeFalse
    }

    It 'leaves the staging root itself in place' {
        $run = NewStagedRun
        $null = Remove-GuestBundle -StagingRoot $run.StagingRoot -RunId $run.RunId
        Test-Path -LiteralPath $run.StagingRoot | Should -BeTrue
    }

    It 'cannot be aimed at a directory outside the staging root' {
        # Reproduced against an unrelated temporary directory before the target
        # was derived rather than accepted.
        $witness = NewTempDir
        Set-Content -LiteralPath (Join-Path $witness 'unrelated.txt') -Value 'must survive' -NoNewline
        $run = NewStagedRun

        { Remove-GuestBundle -StagingRoot $run.StagingRoot -RunId '../../escape' } | Should -Throw
        { Remove-GuestBundle -StagingRoot $witness -RunId 'not-a-uuid' } | Should -Throw

        Test-Path -LiteralPath (Join-Path $witness 'unrelated.txt') | Should -BeTrue
    }

    It 'refuses a redirected target rather than following it' -Skip:(-not $script:LinksSupported) {
        $witness = NewTempDir
        Set-Content -LiteralPath (Join-Path $witness 'unrelated.txt') -Value 'must survive' -NoNewline
        $run = NewStagedRun -WithoutBundle
        $null = New-Item -ItemType SymbolicLink -Path $run.BundlePath -Target $witness

        { Remove-GuestBundle -StagingRoot $run.StagingRoot -RunId $run.RunId } | Should -Throw '*redirected*'
        Test-Path -LiteralPath (Join-Path $witness 'unrelated.txt') | Should -BeTrue
    }

    It 'reports removed when there was nothing to remove' {
        $run = NewStagedRun -WithoutBundle
        Remove-GuestBundle -StagingRoot $run.StagingRoot -RunId $run.RunId | Should -Be 'removed'
    }

    It 'reports retained when asked to keep the bundle' {
        $run = NewStagedRun
        Remove-GuestBundle -StagingRoot $run.StagingRoot -RunId $run.RunId -KeepBundle | Should -Be 'retained'
        Test-Path -LiteralPath $run.BundlePath | Should -BeTrue
    }

    It 'reports failed rather than throwing when removal will not go' {
        $run = NewStagedRun
        Mock -ModuleName GuestProvisioning Remove-Item { throw 'in use' }
        Remove-GuestBundle -StagingRoot $run.StagingRoot -RunId $run.RunId | Should -Be 'failed'
    }

    It 'removes nothing under -WhatIf' {
        $run = NewStagedRun
        Remove-GuestBundle -StagingRoot $run.StagingRoot -RunId $run.RunId -WhatIf | Should -Be 'not-attempted'
        Test-Path -LiteralPath $run.BundlePath | Should -BeTrue
    }

    It 'is not called by the provisioning phase, which cannot know evidence was retrieved' {
        # The boundary this records: ordering belongs to the host. Stage 5 runs
        # evidence retrieval, then cleanup, then host cleanup, then evaluation.
        $bundle = NewBundleScenario
        $evidence = Invoke-GuestProvisioning -BundlePath $bundle.BundlePath `
            -ExpectedDescriptorSha256 $bundle.DescriptorSha256 -Adapter (FakeAdapter -Root (NewValidationRoot))

        $evidence.payload.cleanupOutcome | Should -Be 'not-attempted'
        Test-Path -LiteralPath $bundle.BundlePath | Should -BeTrue
    }
}

Describe 'production guest adapter' {

    It 'refuses at acquisition on a platform it cannot support' -Skip:$IsWindows {
        # Guarding only inside each member meant the first failure happened in
        # the package loop, where it was caught and recorded as a package
        # outcome. An unsupported runtime is a property of the run.
        { Get-GuestAdapter } | Should -Throw '*Windows*'
    }

    It 'refuses a run with no adapter injected, before touching anything' -Skip:$IsWindows {
        # An optional-only bundle is the case that hid the defect: the guard
        # fired inside the loop, the package was optional, and the run returned
        # passed with a log directory already created.
        $bundle = NewBundleScenario -OptionalOnly
        $logDirectory = Join-Path $bundle.BundlePath 'logs'

        { Invoke-GuestProvisioning -BundlePath $bundle.BundlePath -ExpectedDescriptorSha256 $bundle.DescriptorSha256 } |
            Should -Throw '*Windows*'

        Test-Path -LiteralPath $logDirectory | Should -BeFalse
    }
}

Describe 'ConvertTo-EvidenceEnvelope' {

    BeforeAll {
        # In BeforeAll, not bare in the Describe: Pester discovers It blocks
        # before running Describe-level statements, so a function defined
        # directly here is not in scope when a test runs.
        function ValidGuestPayload {
            @{ phase = 'install'; restartRequired = $false; packageCount = 0; passedCount = 0
               failedRequiredCount = 0; cleanupOutcome = 'not-attempted'; packages = @() }
        }
    }

    It 'accepts a payload matching the closed definition for its kind' {
        { ConvertTo-EvidenceEnvelope -ResultKind guest-provisioning -RunId (Get-RunIdentifier) -Outcome passed `
            -StartedUtc ([datetime]::UtcNow) -ManifestSchemaVersion 2 -Payload (ValidGuestPayload) } | Should -Not -Throw
    }

    It 'refuses a payload carrying the extra field <field>' -ForEach @(
        @{ field = 'arguments' }, @{ field = 'commandLine' }, @{ field = 'properties' }
        @{ field = 'stdout' }, @{ field = 'exception' }, @{ field = 'sourcePath' }
    ) {
        # The payload is a closed definition, not an open object filtered by a
        # denylist. A value that must never appear cannot be carried under a
        # different name, because any unlisted name is refused.
        $payload = ValidGuestPayload
        $payload[$field] = 'value'
        { ConvertTo-EvidenceEnvelope -ResultKind guest-provisioning -RunId (Get-RunIdentifier) -Outcome passed `
            -StartedUtc ([datetime]::UtcNow) -ManifestSchemaVersion 2 -Payload $payload } |
            Should -Throw '*envelope schema*'
    }

    It 'refuses an extra field nested in a package record' {
        $payload = ValidGuestPayload
        $payload.packages = @(@{ id = 'a'; version = '1.0'; order = 1; required = $true
                                 outcome = 'passed'; reasonCode = $null; restartRequired = $false
                                 commandLine = 'msiexec /i thing.msi' })
        { ConvertTo-EvidenceEnvelope -ResultKind guest-provisioning -RunId (Get-RunIdentifier) -Outcome passed `
            -StartedUtc ([datetime]::UtcNow) -ManifestSchemaVersion 2 -Payload $payload } |
            Should -Throw '*envelope schema*'
    }

    It 'refuses a reason code outside the bounded set' {
        # Reason codes are enumerated, so a free-form string cannot carry a path
        # or an exception message in a field that looks legitimate.
        $payload = ValidGuestPayload
        $payload.packages = @(@{ id = 'a'; version = '1.0'; order = 1; required = $true
                                 outcome = 'failed'; restartRequired = $false
                                 reasonCode = 'failed opening /var/folders/secret/path' })
        { ConvertTo-EvidenceEnvelope -ResultKind guest-provisioning -RunId (Get-RunIdentifier) -Outcome failed `
            -StartedUtc ([datetime]::UtcNow) -ManifestSchemaVersion 2 -Payload $payload } |
            Should -Throw '*envelope schema*'
    }

    It 'refuses a source-qualification payload under the guest kind' {
        # The discriminator selects the definition, so a payload valid for one
        # stage is not silently accepted for another.
        $payload = @{ packageCount = 0; passedCount = 0; failedRequiredCount = 0
                      failedOptionalCount = 0; cleanupOutcome = 'removed'; packages = @() }
        { ConvertTo-EvidenceEnvelope -ResultKind guest-provisioning -RunId (Get-RunIdentifier) -Outcome passed `
            -StartedUtc ([datetime]::UtcNow) -ManifestSchemaVersion 2 -Payload $payload } |
            Should -Throw '*envelope schema*'
    }

    It 'requires the manifest version, so an envelope cannot carry only the result version' {
        # Asserted through metadata and the schema rather than by omitting the
        # argument: a missing mandatory parameter prompts for input rather than
        # throwing, which would hang the suite rather than fail it.
        $attribute = (Get-Command ConvertTo-EvidenceEnvelope).Parameters['ManifestSchemaVersion'].Attributes |
            Where-Object { $_ -is [System.Management.Automation.ParameterAttribute] }
        $attribute.Mandatory | Should -Contain $true

        $withoutVersion = @{
            resultSchemaVersion = 2; resultKind = 'guest-provisioning'
            runId = (Get-RunIdentifier)
            startedUtc = '2026-01-01T00:00:00.0000000Z'; completedUtc = '2026-01-01T00:00:01.0000000Z'
            outcome = 'passed'; payload = (ValidGuestPayload)
        } | ConvertTo-Json -Depth 12

        $schema = Join-Path $script:RepoRoot 'contracts' 'evidence-envelope-2.schema.json'
        Test-Json -Json $withoutVersion -SchemaFile $schema -ErrorAction SilentlyContinue | Should -BeFalse
    }

    It 'refuses free-form text in a <kind> package version' -ForEach @(
        @{ kind = 'guest-provisioning' }, @{ kind = 'source-qualification' }
    ) {
        # The payload keys are closed, but an allowed field accepting arbitrary
        # printable text still carried error text and a guest path.
        $package = @{ id = 'a'; version = 'error opening C:\guest\staging\secret.msi'
                      order = 1; required = $false; outcome = 'failed' }
        if ($kind -eq 'guest-provisioning') {
            $package.reasonCode = 'installer_failed'
            $package.restartRequired = $false
            $payload = ValidGuestPayload
            $payload.packageCount = 1
            $payload.packages = @($package)
        }
        else {
            $package.reasonCode = 'integrity_mismatch'
            $payload = @{ packageCount = 1; passedCount = 0; failedRequiredCount = 0
                          failedOptionalCount = 1; cleanupOutcome = 'removed'; packages = @($package) }
        }

        { ConvertTo-EvidenceEnvelope -ResultKind $kind -RunId (Get-RunIdentifier) -Outcome failed `
            -StartedUtc ([datetime]::UtcNow) -ManifestSchemaVersion 2 -Payload $payload } |
            Should -Throw '*envelope schema*'
    }

    It 'accepts a version the manifest contract would accept' {
        $payload = ValidGuestPayload
        $payload.packageCount = 1
        $payload.packages = @(@{ id = 'a'; version = '1.0.0-rc.1'; order = 1; required = $false
                                 outcome = 'passed'; reasonCode = $null; restartRequired = $false })
        { ConvertTo-EvidenceEnvelope -ResultKind guest-provisioning -RunId (Get-RunIdentifier) -Outcome passed `
            -StartedUtc ([datetime]::UtcNow) -ManifestSchemaVersion 2 -Payload $payload } | Should -Not -Throw
    }

    It 'refuses a non-canonical run identifier' {
        { ConvertTo-EvidenceEnvelope -ResultKind guest-provisioning -RunId 'NOT-A-UUID' -Outcome passed `
            -StartedUtc ([datetime]::UtcNow) -ManifestSchemaVersion 2 -Payload (ValidGuestPayload) } |
            Should -Throw '*canonical lowercase UUID*'
    }

    It 'stamps the result version rather than the manifest version' {
        $e = ConvertTo-EvidenceEnvelope -ResultKind guest-provisioning -RunId (Get-RunIdentifier) -Outcome passed `
            -StartedUtc ([datetime]::UtcNow) -ManifestSchemaVersion 1 -Payload (ValidGuestPayload)
        $e.resultSchemaVersion | Should -Be 2
        $e.manifestSchemaVersion | Should -Be 1
        $e.PSObject.Properties.Name | Should -Not -Contain 'schemaVersion'
    }
}
