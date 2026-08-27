#Requires -Version 7.0

<#
    Stage 1 of Increment 2: the frozen version 1 digest, the version 2 schema,
    and version dispatch.

    Fixtures are built from a valid version 2 package and mutated one field at a
    time, so a rejection case names exactly one reason.
#>

BeforeAll {
    $script:RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..' '..')).Path
    Import-Module (Join-Path $script:RepoRoot 'source-qualification' 'scripts' 'PackageManifest.psm1') -Force
    $script:Contracts = Join-Path $script:RepoRoot 'contracts'

    function NewTempDir {
        $d = Join-Path ([System.IO.Path]::GetTempPath()) ([guid]::NewGuid().ToString())
        $null = New-Item -ItemType Directory -Path $d -Force
        $d
    }

    function BaseV2Package {
        @{
            id = 'example-agent'; version = '1.2.3'
            source = 'file://example-agent/1.2.3/agent.exe'
            sha256 = ('a' * 64); order = 10; required = $true
            installer = @{
                kind = 'exe'; arguments = @('/quiet')
                timeoutSeconds = 900; restartPolicy = 'allow-deferred'
                exitCodes = @{ success = @(0); restartRequired = @(3010) }
            }
            validation = @(@{ id = 'agent-binary'; kind = 'file-exists'
                              root = 'programFiles'; relativePath = 'Example/Agent/agent.exe' })
        }
    }

    function BaseMsiPackage {
        @{
            id = 'example-runtime'; version = '4.2.1'
            source = 'file://example-runtime/4.2.1/runtime.msi'
            sha256 = ('b' * 64); order = 20; required = $true
            installer = @{
                kind = 'msi'; properties = @{ ALLUSERS = '1' }
                timeoutSeconds = 1800; restartPolicy = 'forbid'
            }
            validation = @(@{ id = 'runtime-service'; kind = 'service-exists'; serviceName = 'ExampleRuntime' })
        }
    }

    function WriteManifest {
        param($Document)
        $path = Join-Path (NewTempDir) 'manifest.json'
        $Document | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $path -Encoding utf8
        $path
    }

    function V2Manifest {
        param([hashtable] $PackageOverride = @{}, [hashtable] $InstallerOverride = @{}, $Validation)
        $package = BaseV2Package
        foreach ($k in $InstallerOverride.Keys) {
            if ($null -eq $InstallerOverride[$k]) { $package.installer.Remove($k) }
            else { $package.installer[$k] = $InstallerOverride[$k] }
        }
        foreach ($k in $PackageOverride.Keys) {
            if ($null -eq $PackageOverride[$k]) { $package.Remove($k) }
            else { $package[$k] = $PackageOverride[$k] }
        }
        if ($PSBoundParameters.ContainsKey('Validation')) { $package.validation = $Validation }
        WriteManifest @{ schemaVersion = 2; packages = @($package) }
    }
}

Describe 'schema version 1 is frozen' {

    It 'matches its recorded digest byte for byte' {
        # The digest recorded in ADR 1 and section 32. If this fails, either the
        # file was edited -- which the freeze forbids -- or the digest is wrong,
        # and both need a decision rather than an update to this number.
        #
        # This first failed on Windows and not on Linux: Git rewrote the file to
        # CRLF at checkout, so the bytes on disk were not the bytes committed.
        # .gitattributes marks contracts/ as non-text to stop that. A frozen
        # artifact whose bytes depend on the platform that checked it out is not
        # frozen, so the guard was right and the repository was wrong.
        $path = Join-Path $script:Contracts 'package-manifest.schema.json'
        (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant() |
            Should -Be 'd05796232c677cb2c7b5c19e54fc02a75bf579d8dc1b33897f90e1eddfccb16d'
    }

    It 'still validates the version 1 manifest that validated before version 2 existed' {
        $manifest = Import-PackageManifest -Path (Join-Path $script:RepoRoot 'packer' 'manifests' 'example-baseline.json')
        $manifest.SchemaVersion | Should -Be 1
        $manifest.Packages.Count | Should -Be 3
    }
}

Describe 'version dispatch' {

    It 'validates the committed version 2 manifest' {
        $path = Join-Path $script:RepoRoot 'packer' 'manifests' 'example-baseline-v2.json'
        $manifest = Import-PackageManifest -Path $path
        $manifest.SchemaVersion | Should -Be 2

        # Counted from the file rather than hard-coded. This case is about
        # version dispatch, and adding a package to the example should not fail
        # a test that is not about the example's contents.
        $declared = (Get-Content -LiteralPath $path -Raw | ConvertFrom-Json).packages.Count
        $manifest.Packages.Count | Should -Be $declared
        $manifest.Packages.Count | Should -BeGreaterThan 1
    }

    It 'accepts an MSI package alongside an EXE package' {
        $path = WriteManifest @{ schemaVersion = 2; packages = @((BaseV2Package), (BaseMsiPackage)) }
        { Import-PackageManifest -Path $path } | Should -Not -Throw
    }

    It 'rejects an unsupported declared version rather than falling back' {
        # The failure that matters: no newest-schema fallback. A version 3
        # manifest must not be validated by the version 2 schema.
        $path = WriteManifest @{ schemaVersion = 3; packages = @(BaseV2Package) }
        { Import-PackageManifest -Path $path } | Should -Throw '*unsupported schemaVersion 3*'
    }

    It 'rejects a non-integer declared version' {
        $path = WriteManifest @{ schemaVersion = '2'; packages = @(BaseV2Package) }
        { Import-PackageManifest -Path $path } | Should -Throw '*integer schemaVersion*'
    }

    It 'rejects a missing declared version' {
        $path = WriteManifest @{ packages = @(BaseV2Package) }
        { Import-PackageManifest -Path $path } | Should -Throw '*integer schemaVersion*'
    }

    It 'reports malformed JSON as such, before any version lookup' {
        $path = Join-Path (NewTempDir) 'manifest.json'
        '{ "schemaVersion": 2, ' | Set-Content -LiteralPath $path -Encoding utf8
        { Import-PackageManifest -Path $path } | Should -Throw '*not valid JSON*'
    }

    It 'throws when the mapped schema file is absent' {
        # Exercised through the module-internal resolver, because the public
        # function deliberately offers no way to point at another directory.
        $empty = NewTempDir
        InModuleScope PackageManifest -Parameters @{ Directory = $empty } {
            param($Directory)
            # Bound outside the assertion scriptblock so static analysis can see
            # the parameter is used; it cannot look inside a nested block.
            $target = $Directory
            { ResolveSchemaPath -Version 2 -Directory $target } | Should -Throw '*schema not found*'
        }
    }

    It 'refuses an unknown version at the resolver, not only at the caller' {
        InModuleScope PackageManifest {
            { ResolveSchemaPath -Version 99 -Directory '.' } | Should -Throw '*unsupported schemaVersion 99*'
        }
    }
}

Describe 'schema version 2 rejections' {

    It 'rejects a version 1 shaped package, which has no installer or validation' {
        $bare = @{ id = 'a'; version = '1'; source = 'file://a/1/a.msi'; sha256 = ('a' * 64); order = 1; required = $true }
        $path = WriteManifest @{ schemaVersion = 2; packages = @($bare) }
        { Import-PackageManifest -Path $path } | Should -Throw '*schema validation*'
    }

    It 'rejects installer kind <kind>' -ForEach @(@{ kind = 'msp' }, @{ kind = 'MSI' }, @{ kind = 'script' }) {
        { Import-PackageManifest -Path (V2Manifest -InstallerOverride @{ kind = $kind }) } |
            Should -Throw '*schema validation*'
    }

    It 'rejects timeoutSeconds of <timeout>' -ForEach @(@{ timeout = 59 }, @{ timeout = 7201 }, @{ timeout = 0 }, @{ timeout = -1 }) {
        { Import-PackageManifest -Path (V2Manifest -InstallerOverride @{ timeoutSeconds = $timeout }) } |
            Should -Throw '*schema validation*'
    }

    It 'rejects a missing timeout' {
        { Import-PackageManifest -Path (V2Manifest -InstallerOverride @{ timeoutSeconds = $null }) } |
            Should -Throw '*schema validation*'
    }

    It 'rejects restartPolicy <policy>' -ForEach @(@{ policy = 'immediate' }, @{ policy = 'allow' }, @{ policy = '' }) {
        { Import-PackageManifest -Path (V2Manifest -InstallerOverride @{ restartPolicy = $policy }) } |
            Should -Throw '*schema validation*'
    }

    It 'rejects more than 32 argument tokens' {
        { Import-PackageManifest -Path (V2Manifest -InstallerOverride @{ arguments = @(1..33 | ForEach-Object { "/flag$_" }) }) } |
            Should -Throw '*schema validation*'
    }

    It 'rejects an argument token carrying a control character' {
        { Import-PackageManifest -Path (V2Manifest -InstallerOverride @{ arguments = @("/quiet`r`n/extra") }) } |
            Should -Throw '*schema validation*'
    }

    It 'rejects an empty argument token' {
        { Import-PackageManifest -Path (V2Manifest -InstallerOverride @{ arguments = @('') }) } |
            Should -Throw '*schema validation*'
    }

    It 'rejects an MSI property outside the allowlist: <name>' -ForEach @(
        @{ name = 'TRANSFORMS' }, @{ name = 'REBOOT' }, @{ name = 'REINSTALLMODE' }, @{ name = 'CUSTOMFLAG' }
    ) {
        $package = BaseMsiPackage
        $package.installer.properties = @{ $name = 'x' }
        $path = WriteManifest @{ schemaVersion = 2; packages = @($package) }
        { Import-PackageManifest -Path $path } | Should -Throw '*schema validation*'
    }

    It 'rejects an MSI installer carrying EXE-only fields' {
        $package = BaseMsiPackage
        $package.installer.exitCodes = @{ success = @(0) }
        $path = WriteManifest @{ schemaVersion = 2; packages = @($package) }
        { Import-PackageManifest -Path $path } | Should -Throw '*schema validation*'
    }

    It 'rejects an EXE installer without an exit-code policy' {
        { Import-PackageManifest -Path (V2Manifest -InstallerOverride @{ exitCodes = $null }) } |
            Should -Throw '*schema validation*'
    }

    It 'rejects an empty validation array' {
        { Import-PackageManifest -Path (V2Manifest -Validation @()) } | Should -Throw '*schema validation*'
    }

    It 'rejects more than eight validation checks' {
        $checks = 1..9 | ForEach-Object {
            @{ id = "check-$_"; kind = 'file-exists'; root = 'programFiles'; relativePath = "Example/f$_.exe" }
        }
        { Import-PackageManifest -Path (V2Manifest -Validation @($checks)) } | Should -Throw '*schema validation*'
    }

    It 'rejects validation root <root>' -ForEach @(@{ root = 'userProfile' }, @{ root = 'C:' }, @{ root = 'temp' }) {
        $check = @{ id = 'a'; kind = 'file-exists'; root = $root; relativePath = 'Example/a.exe' }
        { Import-PackageManifest -Path (V2Manifest -Validation @($check)) } | Should -Throw '*schema validation*'
    }

    It 'rejects relativePath <path>' -ForEach @(
        @{ path = '/Example/a.exe' }, @{ path = 'C:/Example/a.exe' }, @{ path = 'Example/../a.exe' }
        @{ path = './a.exe' }, @{ path = 'Example/*.exe' }
    ) {
        $check = @{ id = 'a'; kind = 'file-exists'; root = 'programFiles'; relativePath = $path }
        { Import-PackageManifest -Path (V2Manifest -Validation @($check)) } | Should -Throw '*schema validation*'
    }

    It 'accepts version component <version>, the top of the permitted range' -ForEach @(
        @{ version = '65535' }, @{ version = '65535.65535.65535.65535' }, @{ version = '0' }
    ) {
        $check = @{ id = 'a'; kind = 'file-version'; root = 'programFiles'
                    relativePath = 'Example/a.exe'; versionField = 'file'; expectedVersion = $version }
        { Import-PackageManifest -Path (V2Manifest -Validation @($check)) } | Should -Not -Throw
    }

    It 'rejects version component <version>, above the permitted range' -ForEach @(
        @{ version = '65536' }, @{ version = '65536.0' }, @{ version = '1.2.99999' }
    ) {
        # The schema pattern bounds shape at five digits, so 65536 satisfies it.
        # ADR 4 bounds the value at 65535, which is a semantic check.
        $check = @{ id = 'a'; kind = 'file-version'; root = 'programFiles'
                    relativePath = 'Example/a.exe'; versionField = 'file'; expectedVersion = $version }
        { Import-PackageManifest -Path (V2Manifest -Validation @($check)) } |
            Should -Throw '*outside the permitted range 0 to 65535*'
    }

    It 'rejects file-version without an explicit versionField' {
        $check = @{ id = 'a'; kind = 'file-version'; root = 'programFiles'
                    relativePath = 'Example/a.exe'; expectedVersion = '1.0.0.4096' }
        { Import-PackageManifest -Path (V2Manifest -Validation @($check)) } | Should -Throw '*schema validation*'
    }

    It 'rejects a service-exists check that names a root' {
        $check = @{ id = 'a'; kind = 'service-exists'; serviceName = 'ExampleAgent'; root = 'programFiles' }
        { Import-PackageManifest -Path (V2Manifest -Validation @($check)) } | Should -Throw '*schema validation*'
    }

    It 'rejects a malformed serviceName' {
        $check = @{ id = 'a'; kind = 'service-exists'; serviceName = 'Example Agent!' }
        { Import-PackageManifest -Path (V2Manifest -Validation @($check)) } | Should -Throw '*schema validation*'
    }
}

Describe 'schema version 2 cross-field rules' {

    It 'rejects an installer kind that disagrees with the source extension' {
        { Import-PackageManifest -Path (V2Manifest -PackageOverride @{ source = 'file://example-agent/1.2.3/agent.msi' }) } |
            Should -Throw "*declares installer kind 'exe' but its source ends in '.msi'*"
    }

    It 'rejects exit code 1641 in <field>' -ForEach @(@{ field = 'success' }, @{ field = 'restartRequired' }) {
        $codes = @{ success = @(0); restartRequired = @(3010) }
        $codes[$field] = @($codes[$field] + 1641)
        { Import-PackageManifest -Path (V2Manifest -InstallerOverride @{ exitCodes = $codes }) } |
            Should -Throw '*initiated a reboot outside*'
    }

    It 'rejects an exit code listed as both success and restart-required' {
        $codes = @{ success = @(0, 3010); restartRequired = @(3010) }
        { Import-PackageManifest -Path (V2Manifest -InstallerOverride @{ exitCodes = $codes }) } |
            Should -Throw '*both success and restart-required*'
    }

    It 'rejects duplicate validation check ids' {
        $checks = @(
            @{ id = 'same'; kind = 'file-exists'; root = 'programFiles'; relativePath = 'Example/a.exe' }
            @{ id = 'same'; kind = 'file-exists'; root = 'programFiles'; relativePath = 'Example/b.exe' }
        )
        { Import-PackageManifest -Path (V2Manifest -Validation $checks) } |
            Should -Throw '*duplicate validation check ids*'
    }

    It 'still rejects duplicate package ids and orders at version 2' {
        $first = BaseV2Package
        $second = BaseV2Package
        $path = WriteManifest @{ schemaVersion = 2; packages = @($first, $second) }
        { Import-PackageManifest -Path $path } | Should -Throw '*duplicate package ids*'
    }
}
