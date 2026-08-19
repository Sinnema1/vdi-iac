#Requires -Version 7.0

<#
    Regression tests for manifest reading and validation.

    Fixtures are written to a temporary directory at run time. Hashes used as
    "expected" values are either fixed placeholders, or computed from a fixture
    the test itself created -- which is legitimate here because the subject under
    test is the comparison, not the provenance of the expected value. Production
    code must never derive an expected hash from the artifact it is checking.
#>

BeforeAll {
    $script:RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..' '..')).Path
    Import-Module (Join-Path $script:RepoRoot 'source-qualification' 'scripts' 'PackageManifest.psm1') -Force
    $script:SchemaPath = Join-Path $script:RepoRoot 'contracts' 'package-manifest.schema.json'

    function NewManifestFile {
        param([hashtable] $Override = @{}, [switch] $Raw, [string] $RawText)
        $dir = Join-Path ([System.IO.Path]::GetTempPath()) ([guid]::NewGuid().ToString())
        $null = New-Item -ItemType Directory -Path $dir -Force
        $path = Join-Path $dir 'manifest.json'
        if ($Raw) {
            Set-Content -LiteralPath $path -Value $RawText -Encoding utf8
            return $path
        }
        $package = @{
            id = 'example-agent'; version = '1.2.3'
            source = 'file://example-agent/1.2.3/agent.msi'
            sha256 = ('a' * 64); order = 10; required = $true
        }
        foreach ($k in $Override.Keys) { $package[$k] = $Override[$k] }
        @{ schemaVersion = 1; packages = @($package) } |
            ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $path -Encoding utf8
        $path
    }
}

Describe 'Import-PackageManifest' {

    Context 'accepting a conforming manifest' {

        It 'reads the committed example manifest' {
            $path = Join-Path $script:RepoRoot 'packer' 'manifests' 'example-baseline.json'
            $manifest = Import-PackageManifest -Path $path
            $manifest.SchemaVersion | Should -Be 1
            $manifest.Packages.Count | Should -Be 3
        }

        It 'sorts packages by order regardless of file sequence' {
            $dir = Join-Path ([System.IO.Path]::GetTempPath()) ([guid]::NewGuid().ToString())
            $null = New-Item -ItemType Directory -Path $dir -Force
            $path = Join-Path $dir 'manifest.json'
            $out = @{ schemaVersion = 1; packages = @(
                @{ id='third';  version='1'; source='file://c/1/c.msi'; sha256=('c'*64); order=30; required=$true }
                @{ id='first';  version='1'; source='file://a/1/a.msi'; sha256=('a'*64); order=10; required=$true }
                @{ id='second'; version='1'; source='file://b/1/b.msi'; sha256=('b'*64); order=20; required=$true }
            )}
            $out | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $path -Encoding utf8

            $manifest = Import-PackageManifest -Path $path
            $manifest.Packages.id | Should -Be @('first', 'second', 'third')
        }
    }

    Context 'rejecting malformed input' {

        It 'throws when the manifest does not exist' {
            { Import-PackageManifest -Path (Join-Path ([System.IO.Path]::GetTempPath()) 'absent.json') } |
                Should -Throw '*not found*'
        }

        It 'throws on an empty file' {
            $path = NewManifestFile -Raw -RawText ''
            { Import-PackageManifest -Path $path } | Should -Throw '*empty*'
        }

        It 'throws on malformed JSON' {
            $path = NewManifestFile -Raw -RawText '{ "schemaVersion": 1, '
            { Import-PackageManifest -Path $path } | Should -Throw
        }

        It 'exposes no way for a caller to choose the schema' {
            # A caller-supplied schema path or directory is a bypass: pairing an
            # invalid manifest with a permissive schema makes it validate. The
            # resolver is module-internal, and this asserts the public surface
            # cannot reach it.
            $parameters = (Get-Command Import-PackageManifest).Parameters.Keys
            $parameters | Should -Not -Contain 'SchemaPath'
            $parameters | Should -Not -Contain 'SchemaDirectory'
        }
    }

    Context 'enforcing schema rules' {

        It 'rejects <name>' -ForEach @(
            @{ name = 'an uppercase sha256';     override = @{ sha256 = ('A' * 64) } }
            @{ name = 'a truncated sha256';      override = @{ sha256 = 'abc' } }
            @{ name = 'a wildcard version';      override = @{ version = '1.*' } }
            @{ name = 'an http source';          override = @{ source = 'http://example.invalid/a.msi' } }
            @{ name = 'a negative order';        override = @{ order = -1 } }
            @{ name = 'an uppercase id';         override = @{ id = 'Example-Agent' } }
            @{ name = 'an unknown field';        override = @{ installerType = 'msi' } }
        ) {
            $path = NewManifestFile -Override $override
            { Import-PackageManifest -Path $path } | Should -Throw '*schema validation*'
        }

        It 'rejects the moving version reference <version>' -ForEach @(
            @{ version = 'latest' }, @{ version = 'LATEST' }, @{ version = 'Latest' }
            @{ version = 'newest' }, @{ version = 'CURRENT' }, @{ version = 'stable' }
            @{ version = 'head' },   @{ version = 'any' }
        ) {
            $path = NewManifestFile -Override @{ version = $version }
            { Import-PackageManifest -Path $path } | Should -Throw '*schema validation*'
        }

        It 'rejects the version range or wildcard <version>' -ForEach @(
            @{ version = '1.*' },   @{ version = '>=1.0' }, @{ version = '~1.2' }
            @{ version = '^2.0' }
            # A whole segment of x or X, in any position. Rejecting only a
            # trailing .x left 'x', '1.x.0' and '1.2.x+meta' accepted while the
            # contract claimed wildcards were refused.
            @{ version = 'x' },     @{ version = 'X' }
            @{ version = '1.x' },   @{ version = 'x.1' }
            @{ version = '1.x.0' }, @{ version = '1.X.0' }
            @{ version = '1.2.x+meta' }, @{ version = '1-x' }
        ) {
            $path = NewManifestFile -Override @{ version = $version }
            { Import-PackageManifest -Path $path } | Should -Throw '*schema validation*'
        }

        It 'accepts the exact version <version>' -ForEach @(
            @{ version = '1.2.3' }, @{ version = '2026.08.1' }, @{ version = '1.0.0-rc.1' }
            # A segment that merely starts with x is a real version component,
            # not a wildcard, and must survive the rule above.
            @{ version = '1.0.0-x64' }, @{ version = '10.0.19045' }
        ) {
            $path = NewManifestFile -Override @{ version = $version }
            { Import-PackageManifest -Path $path } | Should -Not -Throw
        }

        It 'rejects the traversing source reference <source>' -ForEach @(
            @{ source = 'file://packages/../../outside/x.bin' }
            @{ source = 'file://./x.bin' }
            @{ source = 'file://a/./b.msi' }
            @{ source = 'file://a/../b.msi' }
        ) {
            $path = NewManifestFile -Override @{ source = $source }
            { Import-PackageManifest -Path $path } | Should -Throw '*schema validation*'
        }

        It 'rejects an empty package list' {
            $dir = Join-Path ([System.IO.Path]::GetTempPath()) ([guid]::NewGuid().ToString())
            $null = New-Item -ItemType Directory -Path $dir -Force
            $path = Join-Path $dir 'manifest.json'
            '{ "schemaVersion": 1, "packages": [] }' | Set-Content -LiteralPath $path -Encoding utf8
            { Import-PackageManifest -Path $path } | Should -Throw '*schema validation*'
        }

        It 'rejects an unsupported schema version' {
            $dir = Join-Path ([System.IO.Path]::GetTempPath()) ([guid]::NewGuid().ToString())
            $null = New-Item -ItemType Directory -Path $dir -Force
            $path = Join-Path $dir 'manifest.json'
            '{ "schemaVersion": 2, "packages": [] }' | Set-Content -LiteralPath $path -Encoding utf8
            { Import-PackageManifest -Path $path } | Should -Throw '*schema validation*'
        }
    }

    Context 'enforcing semantic rules the schema cannot express' {

        It 'rejects duplicate package ids' {
            $dir = Join-Path ([System.IO.Path]::GetTempPath()) ([guid]::NewGuid().ToString())
            $null = New-Item -ItemType Directory -Path $dir -Force
            $path = Join-Path $dir 'manifest.json'
            @{ schemaVersion = 1; packages = @(
                @{ id='same'; version='1'; source='file://a/1/a.msi'; sha256=('a'*64); order=10; required=$true }
                @{ id='same'; version='2'; source='file://a/2/a.msi'; sha256=('b'*64); order=20; required=$true }
            )} | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $path -Encoding utf8

            { Import-PackageManifest -Path $path } | Should -Throw '*duplicate package ids*'
        }

        It 'rejects duplicate order values as non-deterministic' {
            $dir = Join-Path ([System.IO.Path]::GetTempPath()) ([guid]::NewGuid().ToString())
            $null = New-Item -ItemType Directory -Path $dir -Force
            $path = Join-Path $dir 'manifest.json'
            @{ schemaVersion = 1; packages = @(
                @{ id='one'; version='1'; source='file://a/1/a.msi'; sha256=('a'*64); order=10; required=$true }
                @{ id='two'; version='1'; source='file://b/1/b.msi'; sha256=('b'*64); order=10; required=$true }
            )} | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $path -Encoding utf8

            { Import-PackageManifest -Path $path } | Should -Throw '*duplicate order*'
        }
    }
}
