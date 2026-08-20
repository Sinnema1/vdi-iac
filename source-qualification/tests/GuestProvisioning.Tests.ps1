#Requires -Version 7.0

<#
    Guest verification, execution, validation, and evidence.

    Every operating-system interaction goes through an injected adapter, so these
    run on any platform without installing software, creating a service, or
    rebooting anything. Exit-code policy in particular is exercised through fakes
    rather than real processes: POSIX masks a process exit status to eight bits,
    so a real child cannot return 3010 on Linux at all.
#>

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

    function RawResult {
        param($ExitCode, [switch] $TimedOut, [bool] $Terminated = $true)
        [PSCustomObject]@{ ExitCode = $ExitCode; TimedOut = [bool] $TimedOut; Terminated = $Terminated }
    }

    function FakeAdapter {
        <#
            Records what it was asked to do and returns what the test dictates.
            Nothing here touches the operating system.
        #>
        param(
            [scriptblock] $StartProcess = { [PSCustomObject]@{ ExitCode = 0; TimedOut = $false; Terminated = $true } },
            [hashtable] $Files = @{}, [hashtable] $Versions = @{}, [string[]] $Services = @(),
            [scriptblock] $ResolveRoot = { param($r) '/roots/' + $r }
        )
        # Bound to locals before capture: static analysis cannot see a parameter
        # referenced only inside a closure, and would report each as unused.
        $fileMap = $Files
        $versionMap = $Versions
        $serviceNames = $Services

        [PSCustomObject]@{
            Name = 'fake'
            StartProcess = $StartProcess
            ResolveRoot = $ResolveRoot
            TestFile = { param($p) $fileMap.ContainsKey($p) }.GetNewClosure()
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
        $adapter = FakeAdapter -Files @{ ('/roots/programFiles' + [System.IO.Path]::DirectorySeparatorChar + 'Example' + [System.IO.Path]::DirectorySeparatorChar + 'a.exe') = $true }
        (Invoke-PackageValidation -Entry (ExeEntry -Validation $checks) -Adapter $adapter).Outcome | Should -Be 'passed'
    }

    It 'fails when a file is absent' {
        $checks = @([PSCustomObject]@{ id = 'present'; kind = 'file-exists'; root = 'programFiles'; relativePath = 'Example/a.exe' })
        $result = Invoke-PackageValidation -Entry (ExeEntry -Validation $checks) -Adapter (FakeAdapter)
        $result.Outcome | Should -Be 'failed'
        $result.Checks[0].ReasonCode | Should -Be 'file_absent'
    }

    It 'reports inconclusive, not failed, when a check could not run' {
        # An adapter that threw established nothing. Calling that a failure would
        # claim knowledge the run does not have.
        $checks = @([PSCustomObject]@{ id = 'svc'; kind = 'service-exists'; serviceName = 'ExampleAgent' })
        $adapter = FakeAdapter
        $adapter.TestService = { throw 'service control manager unavailable' }
        $result = Invoke-PackageValidation -Entry (ExeEntry -Validation $checks) -Adapter $adapter
        $result.Outcome | Should -Be 'inconclusive'
        $result.Checks[0].ReasonCode | Should -Be 'check_error'
    }

    It 'reports inconclusive when a file carries no version information' {
        $path = '/roots/programFiles' + [System.IO.Path]::DirectorySeparatorChar + 'Example' + [System.IO.Path]::DirectorySeparatorChar + 'a.exe'
        $checks = @([PSCustomObject]@{ id = 'ver'; kind = 'file-version'; root = 'programFiles'
                                       relativePath = 'Example/a.exe'; versionField = 'file'; expectedVersion = '4.2.1' })
        $adapter = FakeAdapter -Files @{ $path = $true }
        $result = Invoke-PackageValidation -Entry (ExeEntry -Validation $checks) -Adapter $adapter
        $result.Outcome | Should -Be 'inconclusive'
        $result.Checks[0].ReasonCode | Should -Be 'version_unavailable'
    }

    It 'treats <observed> as equal to expected 7.0.1024' -ForEach @(
        @{ observed = '7.0.1024' }, @{ observed = '7.0.1024.0' }
    ) {
        $path = '/roots/programFiles' + [System.IO.Path]::DirectorySeparatorChar + 'Example' + [System.IO.Path]::DirectorySeparatorChar + 'a.exe'
        $checks = @([PSCustomObject]@{ id = 'ver'; kind = 'file-version'; root = 'programFiles'
                                       relativePath = 'Example/a.exe'; versionField = 'file'; expectedVersion = '7.0.1024' })
        $adapter = FakeAdapter -Files @{ $path = $true } -Versions @{ $path = $observed }
        (Invoke-PackageValidation -Entry (ExeEntry -Validation $checks) -Adapter $adapter).Outcome | Should -Be 'passed'
    }

    It 'reports a version mismatch as failed' {
        $path = '/roots/programFiles' + [System.IO.Path]::DirectorySeparatorChar + 'Example' + [System.IO.Path]::DirectorySeparatorChar + 'a.exe'
        $checks = @([PSCustomObject]@{ id = 'ver'; kind = 'file-version'; root = 'programFiles'
                                       relativePath = 'Example/a.exe'; versionField = 'file'; expectedVersion = '7.0.1024' })
        $adapter = FakeAdapter -Files @{ $path = $true } -Versions @{ $path = '7.0.1024.1' }
        $result = Invoke-PackageValidation -Entry (ExeEntry -Validation $checks) -Adapter $adapter
        $result.Outcome | Should -Be 'failed'
        $result.Checks[0].ReasonCode | Should -Be 'version_mismatch'
    }

    It 'lets one failed check outrank an inconclusive one' {
        $checks = @(
            [PSCustomObject]@{ id = 'absent'; kind = 'file-exists'; root = 'programFiles'; relativePath = 'Example/a.exe' }
            [PSCustomObject]@{ id = 'svc'; kind = 'service-exists'; serviceName = 'ExampleAgent' }
        )
        $adapter = FakeAdapter
        $adapter.TestService = { throw 'unavailable' }
        (Invoke-PackageValidation -Entry (ExeEntry -Validation $checks) -Adapter $adapter).Outcome | Should -Be 'failed'
    }
}

Describe 'Invoke-GuestProvisioning' {

    BeforeAll {
        function NewBundleScenario {
            <#
                A real bundle produced by the host path, so the guest phase is
                exercised against something the assembler actually built rather
                than a hand-written descriptor.
            #>
            param([switch] $CorruptPayloadAfterAssembly)

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

            $bundle = New-TransferBundle -ManifestPath $manifestPath -SourceRoot $source -BundleRoot (Join-Path $base 'bundles')

            if ($CorruptPayloadAfterAssembly) {
                # Altering the payload after the host verified it is what guest
                # re-verification exists to catch.
                $payload = Join-Path $bundle.BundlePath 'packages' 'example-agent' 'payload.exe'
                Set-Content -LiteralPath $payload -Value 'tampered' -Encoding utf8 -NoNewline
            }

            $bundle
        }
    }

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
        $evidence.payload.packages[0].ReasonCode | Should -Be 'integrity_mismatch'
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
        $install.payload.packages[0].Validation | Should -BeNullOrEmpty

        $path = '/roots/programFiles' + [System.IO.Path]::DirectorySeparatorChar + 'Example' + [System.IO.Path]::DirectorySeparatorChar + 'Agent' + [System.IO.Path]::DirectorySeparatorChar + 'agent.exe'
        $validate = Invoke-GuestProvisioning -BundlePath $bundle.BundlePath -Phase validate `
            -ExpectedDescriptorSha256 $bundle.DescriptorSha256 -Adapter (FakeAdapter -Files @{ $path = $true })

        $validate.outcome | Should -Be 'passed'
        $validate.payload.packages[0].Validation.Count | Should -Be 1
    }

    It 'fails the validate phase when the expected state is absent' {
        $bundle = NewBundleScenario
        $evidence = Invoke-GuestProvisioning -BundlePath $bundle.BundlePath -Phase validate `
            -ExpectedDescriptorSha256 $bundle.DescriptorSha256 -Adapter (FakeAdapter)
        $evidence.outcome | Should -Be 'failed'
        $evidence.payload.packages[0].ReasonCode | Should -Be 'validation_failed'
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
        $evidence.payload.packages[0].ReasonCode | Should -Be 'installer_failed'
    }
}

Describe 'ConvertTo-EvidenceEnvelope' {

    It 'refuses a payload carrying <key>' -ForEach @(
        @{ key = 'arguments' }, @{ key = 'commandLine' }, @{ key = 'properties' }
        @{ key = 'stdout' }, @{ key = 'exception' }, @{ key = 'password' }
    ) {
        { ConvertTo-EvidenceEnvelope -ResultKind guest-provisioning -RunId (Get-RunIdentifier) -Outcome passed `
            -StartedUtc ([datetime]::UtcNow) -Payload @{ $key = 'value' } } |
            Should -Throw "*'$key'*"
    }

    It 'refuses a forbidden key nested inside the payload' {
        { ConvertTo-EvidenceEnvelope -ResultKind guest-provisioning -RunId (Get-RunIdentifier) -Outcome passed `
            -StartedUtc ([datetime]::UtcNow) -Payload @{ packages = @(@{ id = 'a'; arguments = @('/quiet') }) } } |
            Should -Throw '*arguments*'
    }

    It 'refuses a non-canonical run identifier' {
        { ConvertTo-EvidenceEnvelope -ResultKind guest-provisioning -RunId 'NOT-A-UUID' -Outcome passed `
            -StartedUtc ([datetime]::UtcNow) -Payload @{} } | Should -Throw '*canonical lowercase UUID*'
    }

    It 'stamps the result version rather than the manifest version' {
        $e = ConvertTo-EvidenceEnvelope -ResultKind source-qualification -RunId (Get-RunIdentifier) -Outcome passed `
            -StartedUtc ([datetime]::UtcNow) -ManifestSchemaVersion 1 -Payload @{}
        $e.resultSchemaVersion | Should -Be 2
        $e.manifestSchemaVersion | Should -Be 1
        $e.PSObject.Properties.Name | Should -Not -Contain 'schemaVersion'
    }
}
