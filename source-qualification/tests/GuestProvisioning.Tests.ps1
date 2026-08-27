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
            -ExpectedDescriptorSha256 $bundle.DescriptorSha256 -RunId $bundle.RunId -Adapter (FakeAdapter)

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
            -ExpectedDescriptorSha256 $bundle.DescriptorSha256 -RunId $bundle.RunId -Adapter $adapter

        $evidence.outcome | Should -Be 'failed'
        $evidence.payload.packages[0].reasonCode | Should -Be 'integrity_mismatch'
    }

    It 'refuses a descriptor whose digest does not match' {
        $bundle = NewBundleScenario
        { Invoke-GuestProvisioning -BundlePath $bundle.BundlePath -ExpectedDescriptorSha256 ('f' * 64) -RunId $bundle.RunId -Adapter (FakeAdapter) } |
            Should -Throw '*digest mismatch*'
    }

    It 'reports that a restart is required without triggering one' {
        $bundle = NewBundleScenario
        $adapter = FakeAdapter -StartProcess { [PSCustomObject]@{ ExitCode = 3010; TimedOut = $false; Terminated = $true } }
        $evidence = Invoke-GuestProvisioning -BundlePath $bundle.BundlePath `
            -ExpectedDescriptorSha256 $bundle.DescriptorSha256 -RunId $bundle.RunId -Adapter $adapter

        $evidence.outcome | Should -Be 'passed'
        $evidence.payload.restartRequired | Should -BeTrue
    }

    It 'stops the batch when a timed-out installer could not be terminated' {
        $bundle = NewBundleScenario
        $adapter = FakeAdapter -StartProcess { [PSCustomObject]@{ ExitCode = $null; TimedOut = $true; Terminated = $false } }
        $evidence = Invoke-GuestProvisioning -BundlePath $bundle.BundlePath `
            -ExpectedDescriptorSha256 $bundle.DescriptorSha256 -RunId $bundle.RunId -Adapter $adapter

        $evidence.outcome | Should -Be 'incomplete'
        $evidence.payload.terminalReasonCode | Should -Be 'install_timeout_termination_failed'
    }

    It 'runs validation only in the validate phase' {
        # Validation belongs on the far side of the restart. Running it during
        # install would observe a state the machine will not be in afterwards.
        $bundle = NewBundleScenario
        $install = Invoke-GuestProvisioning -BundlePath $bundle.BundlePath `
            -ExpectedDescriptorSha256 $bundle.DescriptorSha256 -RunId $bundle.RunId -Adapter (FakeAdapter)
        $install.payload.packages[0].validation | Should -BeNullOrEmpty

        $root = NewValidationRoot -Files @('Example/Agent/agent.exe')
        $validate = Invoke-GuestProvisioning -BundlePath $bundle.BundlePath -Phase validate `
            -ExpectedDescriptorSha256 $bundle.DescriptorSha256 -RunId $bundle.RunId -Adapter (FakeAdapter -Root $root)

        $validate.outcome | Should -Be 'passed'
        $validate.payload.packages[0].validation.Count | Should -Be 1
    }

    It 'fails the validate phase when the expected state is absent' {
        $bundle = NewBundleScenario
        $evidence = Invoke-GuestProvisioning -BundlePath $bundle.BundlePath -Phase validate `
            -ExpectedDescriptorSha256 $bundle.DescriptorSha256 -RunId $bundle.RunId -Adapter (FakeAdapter -Root (NewValidationRoot))
        $evidence.outcome | Should -Be 'failed'
        $evidence.payload.packages[0].reasonCode | Should -Be 'validation_failed'
    }

    It 'keeps arguments and paths out of evidence' {
        # The rule ADR 5 states: a failed install is exactly when someone wants
        # the command line, and that is exactly when it must not be recorded.
        $bundle = NewBundleScenario
        $adapter = FakeAdapter -StartProcess { [PSCustomObject]@{ ExitCode = 7; TimedOut = $false; Terminated = $true } }
        $evidence = Invoke-GuestProvisioning -BundlePath $bundle.BundlePath `
            -ExpectedDescriptorSha256 $bundle.DescriptorSha256 -RunId $bundle.RunId -Adapter $adapter

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
            -ExpectedDescriptorSha256 $bundle.DescriptorSha256 -RunId $bundle.RunId -Adapter (FakeAdapter -Root (NewValidationRoot))

        $evidence.outcome | Should -Be 'failed'
        $evidence.payload.packages[0].reasonCode | Should -Be 'path_rejected'
    }
}

Describe 'Test-RestartAuthorization' {

    BeforeAll {
        $script:Schema = Join-Path $script:RepoRoot 'contracts' 'evidence-envelope-2.schema.json'

        function WriteInstallEvidence {
            param(
                [string] $Path, [string] $RunId,
                [string] $Outcome = 'passed', [string] $Phase = 'install',
                [string] $Kind = 'guest-provisioning',
                [string] $PackageOutcome = 'passed', [string] $TerminalReason,
                [int] $PackageCount = 1, [int] $PassedCount = 1, [int] $AttemptCount = 1
            )
            $terminal = if ([string]::IsNullOrEmpty($TerminalReason)) { $null } else { $TerminalReason }
            @{
                resultSchemaVersion = 2; resultKind = $Kind
                runId = $RunId; manifestSchemaVersion = 2
                startedUtc = '2026-01-01T00:00:00.0000000Z'; completedUtc = '2026-01-01T00:00:01.0000000Z'
                outcome = $Outcome
                payload = @{
                    phase = $Phase; restartRequired = $false
                    packageCount = $PackageCount; passedCount = $PassedCount
                    failedRequiredCount = $(if ($PackageOutcome -eq 'passed') { 0 } else { 1 })
                    installerAttemptCount = $AttemptCount
                    terminalReasonCode = $terminal
                    cleanupOutcome = 'not-attempted'
                    packages = @(@{ id = 'example-agent'; version = '1.2.3'; order = 10; required = $true
                                    outcome = $PackageOutcome; reasonCode = $(if ($PackageOutcome -eq 'passed') { $null } else { 'installer_failed' })
                                    restartRequired = $false; installerAttempted = ($AttemptCount -gt 0) })
                }
            } | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $Path -Encoding utf8
        }

        function WriteQualificationEvidence {
            # A complete, schema-valid envelope of another result kind. The
            # earlier fixture kept a guest payload under a qualification kind,
            # which the schema rejects outright -- so the test could not tell the
            # wrong-kind rule from a malformed document, and accepted either.
            param([string] $Path, [string] $RunId)
            @{
                resultSchemaVersion = 2; resultKind = 'source-qualification'
                runId = $RunId; manifestSchemaVersion = 2
                startedUtc = '2026-01-01T00:00:00.0000000Z'; completedUtc = '2026-01-01T00:00:01.0000000Z'
                outcome = 'passed'
                payload = @{
                    packageCount = 1; passedCount = 1
                    failedRequiredCount = 0; failedOptionalCount = 0
                    cleanupOutcome = 'not-attempted'
                    packages = @(@{ id = 'example-agent'; version = '1.2.3'; order = 10
                                    required = $true; outcome = 'passed'; reasonCode = $null })
                }
            } | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $Path -Encoding utf8
        }
    }

    It 'authorizes a complete, self-consistent install' {
        $runId = Get-RunIdentifier
        $path = Join-Path (NewTempDir) 'install.json'
        WriteInstallEvidence -Path $path -RunId $runId
        (Test-RestartAuthorization -EvidencePath $path -RunId $runId -SchemaPath $script:Schema).Authorized | Should -BeTrue
    }

    It 'refuses validate-phase evidence' {
        # It is schema-valid, carries the right run, and reports a completed
        # outcome. Only the phase says it cannot authorize a restart.
        $runId = Get-RunIdentifier
        $path = Join-Path (NewTempDir) 'install.json'
        WriteInstallEvidence -Path $path -RunId $runId -Phase 'validate'
        $decision = Test-RestartAuthorization -EvidencePath $path -RunId $runId -SchemaPath $script:Schema
        $decision.Authorized | Should -BeFalse
        $decision.ReasonCode | Should -Be 'evidence_wrong_phase'
    }

    It 'refuses a schema-valid envelope from another stage' {
        # Valid against the contract, carrying this run, reporting a pass. Only
        # the result kind disqualifies it, so the expectation is exact.
        $runId = Get-RunIdentifier
        $path = Join-Path (NewTempDir) 'install.json'
        WriteQualificationEvidence -Path $path -RunId $runId

        $raw = Get-Content -LiteralPath $path -Raw -Encoding utf8
        Test-Json -Json $raw -SchemaFile $script:Schema -ErrorAction SilentlyContinue |
            Should -BeTrue -Because 'the fixture must reach the kind check rather than fail validation'

        $decision = Test-RestartAuthorization -EvidencePath $path -RunId $runId -SchemaPath $script:Schema
        $decision.Authorized | Should -BeFalse
        $decision.ReasonCode | Should -Be 'evidence_wrong_kind'
    }

    It 'refuses a package whose installer outlived termination, with no terminal reason' {
        # The dangerous case: the payload reports a clean failure and says
        # nothing about termination, while a package records that its process
        # could not be killed. A reboot must never meet a process still running.
        $runId = Get-RunIdentifier
        $path = Join-Path (NewTempDir) 'install.json'
        $evidence = @{
            resultSchemaVersion = 2; resultKind = 'guest-provisioning'
            runId = $runId; manifestSchemaVersion = 2
            startedUtc = '2026-01-01T00:00:00.0000000Z'; completedUtc = '2026-01-01T00:00:01.0000000Z'
            outcome = 'failed'
            payload = @{
                phase = 'install'; restartRequired = $false
                packageCount = 1; passedCount = 0; failedRequiredCount = 1
                installerAttemptCount = 1; cleanupOutcome = 'not-attempted'
                packages = @(@{ id = 'example-agent'; version = '1.2.3'; order = 10; required = $true
                                outcome = 'failed'; reasonCode = 'install_timeout_termination_failed'
                                restartRequired = $false; installerAttempted = $true })
            }
        }
        $evidence | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $path -Encoding utf8

        $decision = Test-RestartAuthorization -EvidencePath $path -RunId $runId -SchemaPath $script:Schema
        $decision.Authorized | Should -BeFalse
        $decision.ReasonCode | Should -Be 'install_termination_unconfirmed'
    }

    It 'refuses a passed result carrying a failed required package' {
        # Every counter agrees with the package list, so the arithmetic rules
        # pass. What contradicts the result is the required package that did not.
        $runId = Get-RunIdentifier
        $path = Join-Path (NewTempDir) 'install.json'
        $evidence = @{
            resultSchemaVersion = 2; resultKind = 'guest-provisioning'
            runId = $runId; manifestSchemaVersion = 2
            startedUtc = '2026-01-01T00:00:00.0000000Z'; completedUtc = '2026-01-01T00:00:01.0000000Z'
            outcome = 'passed'
            payload = @{
                phase = 'install'; restartRequired = $false
                packageCount = 2; passedCount = 1; failedRequiredCount = 0
                installerAttemptCount = 2; cleanupOutcome = 'not-attempted'
                packages = @(
                    @{ id = 'example-agent'; version = '1.2.3'; order = 10; required = $true
                       outcome = 'passed'; reasonCode = $null; restartRequired = $false; installerAttempted = $true }
                    @{ id = 'example-tool'; version = '2.0.0'; order = 20; required = $true
                       outcome = 'failed'; reasonCode = 'installer_failed'; restartRequired = $false; installerAttempted = $true })
            }
        }
        $evidence | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $path -Encoding utf8

        $decision = Test-RestartAuthorization -EvidencePath $path -RunId $runId -SchemaPath $script:Schema
        $decision.Authorized | Should -BeFalse
        $decision.ReasonCode | Should -Be 'evidence_inconsistent'
    }

    It 'refuses internally inconsistent install evidence' {
        # Counters that disagree with the package list describe two different
        # runs, and neither of them authorizes anything.
        $runId = Get-RunIdentifier
        $path = Join-Path (NewTempDir) 'install.json'
        WriteInstallEvidence -Path $path -RunId $runId -PackageCount 3 -PassedCount 3
        $decision = Test-RestartAuthorization -EvidencePath $path -RunId $runId -SchemaPath $script:Schema
        $decision.Authorized | Should -BeFalse
        $decision.ReasonCode | Should -Be 'evidence_inconsistent'
    }

    It 'refuses an attempt count that disagrees with the package flags' {
        $runId = Get-RunIdentifier
        $path = Join-Path (NewTempDir) 'install.json'
        WriteInstallEvidence -Path $path -RunId $runId -AttemptCount 5
        (Test-RestartAuthorization -EvidencePath $path -RunId $runId -SchemaPath $script:Schema).ReasonCode |
            Should -Be 'evidence_inconsistent'
    }

    It 'refuses a completed result carrying a terminal halt reason' {
        $runId = Get-RunIdentifier
        $path = Join-Path (NewTempDir) 'install.json'
        WriteInstallEvidence -Path $path -RunId $runId -Outcome 'failed' -PackageOutcome 'failed' `
            -PassedCount 0 -TerminalReason 'install_timeout_termination_failed'
        (Test-RestartAuthorization -EvidencePath $path -RunId $runId -SchemaPath $script:Schema).ReasonCode |
            Should -Be 'install_not_complete'
    }

    It 'refuses <case>' -ForEach @(
        @{ case = 'missing evidence';   expected = 'evidence_missing' }
        @{ case = 'malformed evidence'; expected = 'evidence_malformed' }
    ) {
        $runId = Get-RunIdentifier
        $path = Join-Path (NewTempDir) 'install.json'
        if ($case -eq 'malformed evidence') { '{ not json' | Set-Content -LiteralPath $path -Encoding utf8 }
        (Test-RestartAuthorization -EvidencePath $path -RunId $runId -SchemaPath $script:Schema).ReasonCode |
            Should -Be $expected
    }

    It 'refuses evidence belonging to another run' {
        $path = Join-Path (NewTempDir) 'install.json'
        WriteInstallEvidence -Path $path -RunId (Get-RunIdentifier)
        (Test-RestartAuthorization -EvidencePath $path -RunId (Get-RunIdentifier) -SchemaPath $script:Schema).ReasonCode |
            Should -Be 'evidence_run_id_mismatch'
    }

    It 'refuses when the halt marker is present, whatever the evidence says' {
        $runId = Get-RunIdentifier
        $dir = NewTempDir
        $path = Join-Path $dir 'install.json'
        $halt = Join-Path $dir 'halt.txt'
        WriteInstallEvidence -Path $path -RunId $runId
        Set-Content -LiteralPath $halt -Value 'halted' -NoNewline

        (Test-RestartAuthorization -EvidencePath $path -RunId $runId -SchemaPath $script:Schema -HaltMarkerPath $halt).ReasonCode |
            Should -Be 'halt_marker_present'
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

    It 'refuses a directory whose sentinel belongs to another invocation' {
        # The collision this exists for, executed rather than read: a colliding
        # run refuses the existing directory and never writes a sentinel, so
        # presence alone would authorize deleting the previous run's content.
        $run = NewStagedRun
        Set-Content -LiteralPath (Join-Path $run.BundlePath 'witness.txt') -Value 'prior run content' -NoNewline
        Set-Content -LiteralPath (Join-Path $run.StagingRoot 'sentinel.txt') -Value 'nonce-from-a-previous-invocation' -NoNewline

        # Cleanup authorized by nonce, not by the directory existing.
        $decision = Test-CleanupAuthorization -SentinelPath (Join-Path $run.StagingRoot 'sentinel.txt') -ExpectedNonce 'nonce-for-this-invocation'
        $decision | Should -BeFalse

        Test-Path -LiteralPath (Join-Path $run.BundlePath 'witness.txt') | Should -BeTrue
    }

    It 'authorizes cleanup when the sentinel matches this invocation' {
        $run = NewStagedRun
        $nonce = 'nonce-for-this-invocation'
        Set-Content -LiteralPath (Join-Path $run.StagingRoot 'sentinel.txt') -Value $nonce -NoNewline
        Test-CleanupAuthorization -SentinelPath (Join-Path $run.StagingRoot 'sentinel.txt') -ExpectedNonce $nonce | Should -BeTrue
    }

    It 'refuses cleanup when no sentinel was ever written' {
        $run = NewStagedRun
        Test-CleanupAuthorization -SentinelPath (Join-Path $run.StagingRoot 'absent.txt') -ExpectedNonce 'anything' | Should -BeFalse
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
            -ExpectedDescriptorSha256 $bundle.DescriptorSha256 -RunId $bundle.RunId -Adapter (FakeAdapter -Root (NewValidationRoot))

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

        { Invoke-GuestProvisioning -BundlePath $bundle.BundlePath -ExpectedDescriptorSha256 $bundle.DescriptorSha256 -RunId $bundle.RunId } |
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
               failedRequiredCount = 0; installerAttemptCount = 0
               cleanupOutcome = 'not-attempted'; packages = @() }
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
                                 installerAttempted = $false; commandLine = 'msiexec /i thing.msi' })
        { ConvertTo-EvidenceEnvelope -ResultKind guest-provisioning -RunId (Get-RunIdentifier) -Outcome passed `
            -StartedUtc ([datetime]::UtcNow) -ManifestSchemaVersion 2 -Payload $payload } |
            Should -Throw '*envelope schema*'
    }

    It 'refuses a reason code outside the bounded set' {
        # Reason codes are enumerated, so a free-form string cannot carry a path
        # or an exception message in a field that looks legitimate.
        $payload = ValidGuestPayload
        $payload.packages = @(@{ id = 'a'; version = '1.0'; order = 1; required = $true
                                 outcome = 'failed'; restartRequired = $false; installerAttempted = $false
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
                                 outcome = 'passed'; reasonCode = $null; restartRequired = $false
                                 installerAttempted = $false })
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

Describe 'Invoke-GuestCleanup' {

    BeforeAll {
        function NewOwnedRun {
            <#
                A run directory as a previous invocation would have left it:
                its own nonce in the sentinel, its bundle beneath the root, and
                an evidence file standing in for the witness a wrong deletion
                destroys.
            #>
            param([string] $Nonce)
            $root = Join-Path (NewTempDir) 'vdi-iac-lab'
            $runId = Get-RunIdentifier
            $null = New-Item -ItemType Directory -Path (Join-Path $root "bundle-$runId") -Force
            $sentinel = Join-Path $root 'owner.nonce'
            Set-Content -LiteralPath $sentinel -Value $Nonce -NoNewline
            $witness = Join-Path $root 'install-guest-evidence.json'
            Set-Content -LiteralPath $witness -Value '{"witness":true}' -NoNewline
            [PSCustomObject]@{ Root = $root; RunId = $runId; Sentinel = $sentinel; Witness = $witness }
        }
    }

    It 'removes the run root when the sentinel is this invocation' {
        $run = NewOwnedRun -Nonce 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
        $result = Invoke-GuestCleanup -StagingRoot $run.Root -RunId $run.RunId `
            -SentinelPath $run.Sentinel -ExpectedNonce 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'

        $result.Authorized | Should -BeTrue
        $result.BundleOutcome | Should -Be 'removed'
        $result.RootRemoved | Should -BeTrue
        Test-Path -LiteralPath $run.Witness | Should -BeFalse
    }

    It 'leaves another invocation''s run root and witness intact on the normal path' {
        # The collision this exists to survive. A run that collides on its
        # identifier refuses the existing directory and never writes a sentinel,
        # so the nonce it holds belongs to the run that owns it. Deleting on
        # presence alone would destroy that run's evidence.
        $run = NewOwnedRun -Nonce 'old-nonce-from-the-previous-run00'

        { Invoke-GuestCleanup -StagingRoot $run.Root -RunId $run.RunId `
            -SentinelPath $run.Sentinel -ExpectedNonce 'new-nonce-for-this-invocation000' } |
            Should -Throw -ExpectedMessage '*Refusing to remove anything*'

        Test-Path -LiteralPath $run.Witness | Should -BeTrue
        Test-Path -LiteralPath $run.Root | Should -BeTrue
        (Get-Content -LiteralPath $run.Witness -Raw) | Should -Be '{"witness":true}'
        Test-Path -LiteralPath (Join-Path $run.Root "bundle-$($run.RunId)") | Should -BeTrue
    }

    It 'leaves another invocation''s run root and witness intact on the error path' {
        # The path that runs after a failure, including a preflight that never
        # identified the target. It reports rather than throwing, and must still
        # delete nothing.
        $run = NewOwnedRun -Nonce 'old-nonce-from-the-previous-run00'

        $result = Invoke-GuestCleanup -StagingRoot $run.Root -RunId $run.RunId `
            -SentinelPath $run.Sentinel -ExpectedNonce 'new-nonce-for-this-invocation000' -ErrorPath

        $result.Authorized | Should -BeFalse
        $result.RootRemoved | Should -BeFalse
        Test-Path -LiteralPath $run.Witness | Should -BeTrue
        (Get-Content -LiteralPath $run.Witness -Raw) | Should -Be '{"witness":true}'
        Test-Path -LiteralPath (Join-Path $run.Root "bundle-$($run.RunId)") | Should -BeTrue
    }

    It 'refuses on both paths when the sentinel is absent entirely' {
        # A target that never identified itself. Presence-based authorization
        # would have treated a missing sentinel as nothing to protect.
        $run = NewOwnedRun -Nonce 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
        Remove-Item -LiteralPath $run.Sentinel -Force

        (Invoke-GuestCleanup -StagingRoot $run.Root -RunId $run.RunId -SentinelPath $run.Sentinel `
            -ExpectedNonce 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa' -ErrorPath).Authorized | Should -BeFalse
        { Invoke-GuestCleanup -StagingRoot $run.Root -RunId $run.RunId -SentinelPath $run.Sentinel `
            -ExpectedNonce 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa' } | Should -Throw

        Test-Path -LiteralPath $run.Witness | Should -BeTrue
    }

    It 'removes the run root on the error path when this invocation owns it' {
        $run = NewOwnedRun -Nonce 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb'
        $result = Invoke-GuestCleanup -StagingRoot $run.Root -RunId $run.RunId `
            -SentinelPath $run.Sentinel -ExpectedNonce 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb' -ErrorPath

        $result.Authorized | Should -BeTrue
        # The error path does not run the derived-target removal: it exists to
        # clear staging after a failure, not to report a bundle outcome.
        $result.BundleOutcome | Should -Be 'not-attempted'
        $result.RootRemoved | Should -BeTrue
    }
}

Describe 'Test-ProvisioningComplete' {

    BeforeAll {
        $script:Schema = Join-Path $script:RepoRoot 'contracts' 'evidence-envelope-2.schema.json'

        function WritePhaseEvidence {
            <#
                A phase document, self-consistent by construction so a case fails
                for the rule it is about rather than an unrelated contradiction.
            #>
            param(
                [string] $Path, [string] $RunId, [string] $Phase,
                [string] $Outcome = 'passed',
                [string] $PackageOutcome = 'passed',
                [bool] $Required = $true,
                [bool] $RestartRequired = $false,
                [string] $PackageId = 'example-agent',
                [string] $PackageVersion = '1.2.3',
                [string] $Kind = 'guest-provisioning',
                [int] $ManifestSchemaVersion = 2,
                [string] $TerminalReason
            )
            $failedRequired = if ($PackageOutcome -ne 'passed' -and $Required) { 1 } else { 0 }
            $document = @{
                resultSchemaVersion = 2; resultKind = $Kind
                runId = $RunId; manifestSchemaVersion = $ManifestSchemaVersion
                startedUtc = '2026-01-01T00:00:00.0000000Z'; completedUtc = '2026-01-01T00:00:01.0000000Z'
                outcome = $Outcome
                payload = @{
                    phase = $Phase; restartRequired = $RestartRequired
                    packageCount = 1
                    passedCount = $(if ($PackageOutcome -eq 'passed') { 1 } else { 0 })
                    failedRequiredCount = $failedRequired
                    installerAttemptCount = 1
                    terminalReasonCode = $(if ([string]::IsNullOrEmpty($TerminalReason)) { $null } else { $TerminalReason })
                    cleanupOutcome = 'not-attempted'
                    packages = @(@{
                        id = $PackageId; version = $PackageVersion; order = 10; required = $Required
                        outcome = $PackageOutcome
                        reasonCode = $(if ($PackageOutcome -eq 'passed') { $null } else { 'installer_failed' })
                        restartRequired = $false; installerAttempted = $true })
                }
            }
            $document | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $Path -Encoding utf8
        }

        function NewEvidencePair {
            # The locals are named ...Path deliberately. PowerShell variables are
            # case-insensitive, so $install and the [hashtable] $Install
            # parameter are one variable, and assigning a path to it fails the
            # parameter's type rather than shadowing it.
            param([string] $RunId, [hashtable] $Install = @{}, [hashtable] $Validate = @{})
            $dir = NewTempDir
            $installPath = Join-Path $dir 'install-guest-evidence.json'
            $validatePath = Join-Path $dir 'validate-guest-evidence.json'
            WritePhaseEvidence -Path $installPath -RunId $RunId -Phase 'install' @Install
            WritePhaseEvidence -Path $validatePath -RunId $RunId -Phase 'validate' @Validate
            [PSCustomObject]@{ Directory = $dir; Install = $installPath; Validate = $validatePath }
        }

        function Gate {
            param($Pair, [string] $RunId)
            Test-ProvisioningComplete -InstallEvidencePath $Pair.Install `
                -ValidateEvidencePath $Pair.Validate -RunId $RunId -SchemaPath $script:Schema
        }
    }

    It 'authorizes a run whose phases both passed' {
        $runId = Get-RunIdentifier
        (Gate -Pair (NewEvidencePair -RunId $runId) -RunId $runId).Authorized | Should -BeTrue
    }

    It 'refuses when the <phase> evidence is missing' -ForEach @(
        @{ phase = 'install' }, @{ phase = 'validate' }
    ) {
        # An absent document is not an implicit pass, and nothing downstream can
        # tell an absent file from a stage that never ran.
        $runId = Get-RunIdentifier
        $pair = NewEvidencePair -RunId $runId
        Remove-Item -LiteralPath (Join-Path $pair.Directory "$phase-guest-evidence.json") -Force

        (Gate -Pair $pair -RunId $runId).ReasonCode | Should -Be 'evidence_missing'
    }

    It 'refuses malformed evidence' {
        $runId = Get-RunIdentifier
        $pair = NewEvidencePair -RunId $runId
        '{ not json' | Set-Content -LiteralPath $pair.Validate -Encoding utf8

        (Gate -Pair $pair -RunId $runId).ReasonCode | Should -Be 'evidence_malformed'
    }

    It 'refuses evidence belonging to another run' {
        # It would attach one execution's provisioning to another's image.
        $pair = NewEvidencePair -RunId (Get-RunIdentifier)
        (Gate -Pair $pair -RunId (Get-RunIdentifier)).ReasonCode | Should -Be 'evidence_run_id_mismatch'
    }

    It 'refuses a validate document written to the install path' {
        # The file name does not establish the phase. Without this check a single
        # document copied twice satisfies both reads.
        $runId = Get-RunIdentifier
        $pair = NewEvidencePair -RunId $runId
        Copy-Item -LiteralPath $pair.Validate -Destination $pair.Install -Force

        (Gate -Pair $pair -RunId $runId).ReasonCode | Should -Be 'evidence_wrong_phase'
    }

    It 'refuses evidence from another stage' {
        $runId = Get-RunIdentifier
        $dir = NewTempDir
        $installPath = Join-Path $dir 'install-guest-evidence.json'
        $validatePath = Join-Path $dir 'validate-guest-evidence.json'
        WritePhaseEvidence -Path $installPath -RunId $runId -Phase 'install'
        WritePhaseEvidence -Path $validatePath -RunId $runId -Phase 'validate' -Kind 'build-orchestration'

        (Test-ProvisioningComplete -InstallEvidencePath $installPath -ValidateEvidencePath $validatePath `
            -RunId $runId -SchemaPath $script:Schema).ReasonCode |
            Should -BeIn @('evidence_wrong_kind', 'evidence_malformed')
    }

    It 'refuses two phases describing different packages' {
        # An install of one package validated against another is the
        # substitution neither document can detect alone.
        $runId = Get-RunIdentifier
        $pair = NewEvidencePair -RunId $runId -Validate @{ PackageId = 'example-tool' }

        (Gate -Pair $pair -RunId $runId).ReasonCode | Should -Be 'evidence_inconsistent'
    }

    It 'refuses two phases describing different versions' {
        $runId = Get-RunIdentifier
        $pair = NewEvidencePair -RunId $runId -Validate @{ PackageVersion = '9.9.9' }

        (Gate -Pair $pair -RunId $runId).ReasonCode | Should -Be 'evidence_inconsistent'
    }

    It 'refuses when the <phase> phase did not pass' -ForEach @(
        @{ phase = 'install' }, @{ phase = 'validate' }
    ) {
        # Nothing after this gate is reversible, so a phase that did not pass
        # stops the build rather than being carried into generalization.
        $runId = Get-RunIdentifier
        $overrides = @{ Outcome = 'failed'; PackageOutcome = 'failed'; TerminalReason = 'installer_failed' }
        $pair = if ($phase -eq 'install') { NewEvidencePair -RunId $runId -Install $overrides }
                else { NewEvidencePair -RunId $runId -Validate $overrides }

        # The phase outcome is checked before the package list, so this reports
        # the phase rather than the package. Both refuse; the more general fact
        # is the one reported first.
        (Gate -Pair $pair -RunId $runId).ReasonCode | Should -Be "${phase}_not_passed"
    }

    It 'refuses a phase claiming success over a package that failed' {
        # The contradiction that must not be resolved in favour of continuing.
        # Which rule catches it is not asserted, and deliberately so: under a
        # passed outcome any failed package also breaks the counter rules, so
        # several refuse it and no single one can be isolated. What matters is
        # that the gate does not authorize.
        $runId = Get-RunIdentifier
        $pair = NewEvidencePair -RunId $runId
        $document = Get-Content -LiteralPath $pair.Validate -Raw | ConvertFrom-Json
        $document.payload.packages[0].outcome = 'failed'
        $document.payload.packages[0].reasonCode = 'validation_failed'
        $document | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $pair.Validate -Encoding utf8

        (Gate -Pair $pair -RunId $runId).Authorized | Should -BeFalse
    }

    It 'permits an optional package to have failed' {
        # Only required packages stop the build. An optional one that did not
        # install is recorded and does not make the image unusable.
        $runId = Get-RunIdentifier
        $pair = NewEvidencePair -RunId $runId `
            -Install @{ Outcome = 'failed'; PackageOutcome = 'failed'; Required = $false; TerminalReason = 'installer_failed' } `
            -Validate @{ Outcome = 'failed'; PackageOutcome = 'failed'; Required = $false; TerminalReason = 'installer_failed' }

        (Gate -Pair $pair -RunId $runId).ReasonCode | Should -Be 'install_not_passed'
    }

    It 'refuses a run with a restart still outstanding' {
        # The machine is not in the state the validation observed, and
        # generalizing would seal that half-applied state into the image.
        $runId = Get-RunIdentifier
        $pair = NewEvidencePair -RunId $runId -Validate @{ RestartRequired = $true }

        (Gate -Pair $pair -RunId $runId).ReasonCode | Should -Be 'restart_still_required'
    }

    It 'refuses an install-only record however complete it looks' {
        # The deliberate pre-restart halt that makes an install-only record
        # legitimate is a build that stopped, not one that may continue.
        $runId = Get-RunIdentifier
        $pair = NewEvidencePair -RunId $runId
        Remove-Item -LiteralPath $pair.Validate -Force

        (Gate -Pair $pair -RunId $runId).Authorized | Should -BeFalse
    }
}
