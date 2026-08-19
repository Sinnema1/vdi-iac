#Requires -Version 7.0

<#
    Regression tests for source resolution, staging, and integrity verification.

    Where a test needs an expected hash that matches real content, it computes
    the hash of a fixture it just wrote. That is sound here because the subject
    under test is the comparison logic. Production code must never derive an
    expected hash from the artifact being checked -- see section 12.
#>

# Evaluated at discovery time, not inside BeforeAll: Pester resolves -Skip
# conditions while discovering tests, which happens before BeforeAll runs. A
# probe placed in BeforeAll is still $null when the condition is evaluated, and
# every link test silently skips.
#
# Link creation is unprivileged on Linux and macOS; on Windows it needs
# Developer Mode or elevation.
$script:LinksSupported = $(
    $probe = Join-Path ([System.IO.Path]::GetTempPath()) ([guid]::NewGuid().ToString())
    $null = New-Item -ItemType Directory -Path $probe -Force
    try {
        $null = New-Item -ItemType SymbolicLink -Path (Join-Path $probe 'probe-link') -Target $probe -ErrorAction Stop
        $true
    }
    catch { $false }
    finally { Remove-Item -LiteralPath $probe -Recurse -Force -ErrorAction SilentlyContinue }
)

BeforeAll {
    $script:RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..' '..')).Path
    $scripts = Join-Path $script:RepoRoot 'source-qualification' 'scripts'
    Import-Module (Join-Path $scripts 'PackageManifest.psm1') -Force
    Import-Module (Join-Path $scripts 'SourceQualification.psm1') -Force

    function NewTempDir {
        $d = Join-Path ([System.IO.Path]::GetTempPath()) ([guid]::NewGuid().ToString())
        $null = New-Item -ItemType Directory -Path $d -Force
        $d
    }

    function NewSourceTree {
        param([hashtable] $Files)   # relative path -> content
        $root = NewTempDir
        foreach ($rel in $Files.Keys) {
            $full = Join-Path $root $rel
            $null = New-Item -ItemType Directory -Path (Split-Path -Parent $full) -Force
            Set-Content -LiteralPath $full -Value $Files[$rel] -Encoding utf8 -NoNewline
        }
        $root
    }

    function Get-Sha { param([string] $Path) (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant() }


    function NewManifestObject {
        param([array] $Packages)
        [PSCustomObject]@{ SchemaVersion = 1; Packages = $Packages; Source = 'synthetic' }
    }
}

Describe 'Resolve-PackageSource' {

    It 'resolves a file reference beneath the source root' {
        $root = NewSourceTree @{ 'agent/1.0/agent.msi' = 'content' }
        $resolved = Resolve-PackageSource -Reference 'file://agent/1.0/agent.msi' -SourceRoot $root
        $resolved | Should -BeLike "*agent$([System.IO.Path]::DirectorySeparatorChar)1.0*"
        Test-Path -LiteralPath $resolved | Should -BeTrue
    }

    It 'rejects a reference that escapes the source root' {
        $root = NewSourceTree @{ 'agent/1.0/agent.msi' = 'content' }
        { Resolve-PackageSource -Reference 'file://../escape.msi' -SourceRoot $root } |
            Should -Throw '*outside the source root*'
    }

    It 'rejects a non-file scheme' {
        $root = NewSourceTree @{ 'agent/1.0/agent.msi' = 'content' }
        { Resolve-PackageSource -Reference 'https://example.invalid/agent.msi' -SourceRoot $root } |
            Should -Throw '*Unsupported source scheme*'
    }

    It 'rejects a directory link that points outside the source root' -Skip:(-not $script:LinksSupported) {
        $base = NewTempDir
        $root = Join-Path $base 'src'
        $outside = Join-Path $base 'outside'
        $null = New-Item -ItemType Directory -Path $root, $outside -Force
        Set-Content -LiteralPath (Join-Path $outside 'secret.bin') -Value 'outside content' -NoNewline
        $null = New-Item -ItemType SymbolicLink -Path (Join-Path $root 'link') -Target $outside

        { Resolve-PackageSource -Reference 'file://link/secret.bin' -SourceRoot $root } |
            Should -Throw '*is redirected*'
    }

    It 'rejects a file link that points outside the source root' -Skip:(-not $script:LinksSupported) {
        $base = NewTempDir
        $root = Join-Path $base 'src'
        $outside = Join-Path $base 'outside'
        $null = New-Item -ItemType Directory -Path $root, $outside -Force
        $target = Join-Path $outside 'secret.bin'
        Set-Content -LiteralPath $target -Value 'outside content' -NoNewline
        $null = New-Item -ItemType SymbolicLink -Path (Join-Path $root 'agent.msi') -Target $target

        { Resolve-PackageSource -Reference 'file://agent.msi' -SourceRoot $root } |
            Should -Throw '*is redirected*'
    }

    It 'rejects a link nested deeper in the chain' -Skip:(-not $script:LinksSupported) {
        $base = NewTempDir
        $root = Join-Path $base 'src'
        $outside = Join-Path $base 'outside'
        $null = New-Item -ItemType Directory -Path (Join-Path $root 'vendor'), $outside -Force
        Set-Content -LiteralPath (Join-Path $outside 'secret.bin') -Value 'outside content' -NoNewline
        $null = New-Item -ItemType SymbolicLink -Path (Join-Path $root 'vendor' 'link') -Target $outside

        { Resolve-PackageSource -Reference 'file://vendor/link/secret.bin' -SourceRoot $root } |
            Should -Throw '*is redirected*'
    }

    It 'still resolves a real file when the source root itself is reached through a link' -Skip:(-not $script:LinksSupported) {
        $base = NewTempDir
        $real = Join-Path $base 'real'
        $null = New-Item -ItemType Directory -Path (Join-Path $real 'agent' '1.0') -Force
        Set-Content -LiteralPath (Join-Path $real 'agent' '1.0' 'agent.msi') -Value 'content' -NoNewline
        $linkedRoot = Join-Path $base 'linked-root'
        $null = New-Item -ItemType SymbolicLink -Path $linkedRoot -Target $real

        $resolved = Resolve-PackageSource -Reference 'file://agent/1.0/agent.msi' -SourceRoot $linkedRoot
        Test-Path -LiteralPath $resolved | Should -BeTrue
    }

    It 'rejects an NTFS junction that points outside the source root' -Skip:(-not $IsWindows) {
        # A junction is a distinct reparse type from a symbolic link and needs no
        # elevation to create, so it is the form most likely to appear in a real
        # source tree on Windows.
        $base = NewTempDir
        $root = Join-Path $base 'src'
        $outside = Join-Path $base 'outside'
        $null = New-Item -ItemType Directory -Path $root, $outside -Force
        Set-Content -LiteralPath (Join-Path $outside 'secret.bin') -Value 'outside content' -NoNewline
        $null = New-Item -ItemType Junction -Path (Join-Path $root 'junction') -Target $outside

        { Resolve-PackageSource -Reference 'file://junction/secret.bin' -SourceRoot $root } |
            Should -Throw '*is redirected*'
    }

    It 'reports source_link_rejected for a redirected path' -Skip:(-not $script:LinksSupported) {
        $base = NewTempDir
        $root = Join-Path $base 'src'
        $outside = Join-Path $base 'outside'
        $null = New-Item -ItemType Directory -Path $root, $outside -Force
        Set-Content -LiteralPath (Join-Path $outside 'secret.bin') -Value 'outside' -NoNewline
        $null = New-Item -ItemType SymbolicLink -Path (Join-Path $root 'link') -Target $outside

        $code = $null
        try { $null = Resolve-PackageSource -Reference 'file://link/secret.bin' -SourceRoot $root }
        catch { $code = $_.Exception.Data['ReasonCode'] }
        $code | Should -Be 'source_link_rejected'
    }

    It 'carries a bounded reason code on every rejection' {
        $root = NewSourceTree @{ 'a/1/a.msi' = 'content' }
        $codes = @{}
        foreach ($case in @(
            @{ ref = 'file://../escape.msi';               expect = 'source_outside_root' }
            @{ ref = 'https://example.invalid/agent.msi';  expect = 'unsupported_scheme' }
        )) {
            try { $null = Resolve-PackageSource -Reference $case.ref -SourceRoot $root }
            catch { $codes[$case.expect] = $_.Exception.Data['ReasonCode'] }
        }
        $codes['source_outside_root'] | Should -Be 'source_outside_root'
        $codes['unsupported_scheme'] | Should -Be 'unsupported_scheme'
    }

    It 'throws when the source root does not exist' {
        { Resolve-PackageSource -Reference 'file://a/a.msi' -SourceRoot (Join-Path ([System.IO.Path]::GetTempPath()) 'absent-root') } |
            Should -Throw '*Source root not found*'
    }
}

Describe 'Test-PackageIntegrity' {

    It 'reports a match for the correct hash' {
        $root = NewSourceTree @{ 'a.msi' = 'known content' }
        $file = Join-Path $root 'a.msi'
        $result = Test-PackageIntegrity -Path $file -ExpectedSha256 (Get-Sha $file)
        $result.Matched | Should -BeTrue
    }

    It 'reports a mismatch when content differs' {
        $root = NewSourceTree @{ 'a.msi' = 'known content' }
        $file = Join-Path $root 'a.msi'
        $result = Test-PackageIntegrity -Path $file -ExpectedSha256 ('f' * 64)
        $result.Matched | Should -BeFalse
        $result.Actual | Should -Not -Be $result.Expected
    }

    It 'treats an uppercase expected hash as equal, not as a mismatch' {
        $root = NewSourceTree @{ 'a.msi' = 'known content' }
        $file = Join-Path $root 'a.msi'
        $result = Test-PackageIntegrity -Path $file -ExpectedSha256 (Get-Sha $file).ToUpperInvariant()
        $result.Matched | Should -BeTrue
    }

    It 'rejects a malformed expected hash before reading the file' {
        $root = NewSourceTree @{ 'a.msi' = 'known content' }
        { Test-PackageIntegrity -Path (Join-Path $root 'a.msi') -ExpectedSha256 'not-a-hash' } | Should -Throw
    }

    It 'throws when the file is absent' {
        { Test-PackageIntegrity -Path (Join-Path ([System.IO.Path]::GetTempPath()) 'absent.msi') -ExpectedSha256 ('a' * 64) } |
            Should -Throw '*not found*'
    }
}

Describe 'Invoke-SourceQualification' {

    It 'passes when every required package verifies' {
        $root = NewSourceTree @{ 'a/1/a.msi' = 'alpha'; 'b/1/b.msi' = 'beta' }
        $manifest = NewManifestObject @(
            [PSCustomObject]@{ id='a'; version='1'; source='file://a/1/a.msi'; sha256=(Get-Sha (Join-Path $root 'a/1/a.msi')); order=10; required=$true }
            [PSCustomObject]@{ id='b'; version='1'; source='file://b/1/b.msi'; sha256=(Get-Sha (Join-Path $root 'b/1/b.msi')); order=20; required=$true }
        )
        $result = Invoke-SourceQualification -Manifest $manifest -SourceRoot $root -StagingRoot (NewTempDir)

        $result.Outcome | Should -Be 'passed'
        $result.PassedCount | Should -Be 2
        $result.FailedRequiredCount | Should -Be 0
    }

    It 'fails the run when a required package mismatches' {
        $root = NewSourceTree @{ 'a/1/a.msi' = 'alpha' }
        $manifest = NewManifestObject @(
            [PSCustomObject]@{ id='a'; version='1'; source='file://a/1/a.msi'; sha256=('f' * 64); order=10; required=$true }
        )
        $result = Invoke-SourceQualification -Manifest $manifest -SourceRoot $root -StagingRoot (NewTempDir)

        $result.Outcome | Should -Be 'failed'
        $result.FailedRequiredCount | Should -Be 1
        $result.Packages[0].ReasonCode | Should -Be 'integrity_mismatch'
    }

    It 'records an optional failure without failing the run' {
        $root = NewSourceTree @{ 'a/1/a.msi' = 'alpha'; 'b/1/b.msi' = 'beta' }
        $manifest = NewManifestObject @(
            [PSCustomObject]@{ id='a'; version='1'; source='file://a/1/a.msi'; sha256=(Get-Sha (Join-Path $root 'a/1/a.msi')); order=10; required=$true }
            [PSCustomObject]@{ id='b'; version='1'; source='file://b/1/b.msi'; sha256=('f' * 64); order=20; required=$false }
        )
        $result = Invoke-SourceQualification -Manifest $manifest -SourceRoot $root -StagingRoot (NewTempDir)

        $result.Outcome | Should -Be 'passed'
        $result.FailedOptionalCount | Should -Be 1
        $result.FailedRequiredCount | Should -Be 0
    }

    It 'records a missing source as a failure rather than throwing' {
        $root = NewSourceTree @{ 'a/1/a.msi' = 'alpha' }
        $manifest = NewManifestObject @(
            [PSCustomObject]@{ id='absent'; version='1'; source='file://absent/1/absent.msi'; sha256=('a' * 64); order=10; required=$true }
        )
        $result = Invoke-SourceQualification -Manifest $manifest -SourceRoot $root -StagingRoot (NewTempDir)

        $result.Outcome | Should -Be 'failed'
        $result.Packages[0].ReasonCode | Should -Be 'source_not_found'
    }

    It 'removes staging when the run completes' {
        $root = NewSourceTree @{ 'a/1/a.msi' = 'alpha' }
        $stagingRoot = NewTempDir
        $manifest = NewManifestObject @(
            [PSCustomObject]@{ id='a'; version='1'; source='file://a/1/a.msi'; sha256=(Get-Sha (Join-Path $root 'a/1/a.msi')); order=10; required=$true }
        )
        $null = Invoke-SourceQualification -Manifest $manifest -SourceRoot $root -StagingRoot $stagingRoot

        @(Get-ChildItem -LiteralPath $stagingRoot -Force).Count | Should -Be 0
    }

    It 'removes staging even when a package fails' {
        $root = NewSourceTree @{ 'a/1/a.msi' = 'alpha' }
        $stagingRoot = NewTempDir
        $manifest = NewManifestObject @(
            [PSCustomObject]@{ id='a'; version='1'; source='file://a/1/a.msi'; sha256=('f' * 64); order=10; required=$true }
        )
        $null = Invoke-SourceQualification -Manifest $manifest -SourceRoot $root -StagingRoot $stagingRoot

        @(Get-ChildItem -LiteralPath $stagingRoot -Force).Count | Should -Be 0
    }

    It 'retains staging when asked to' {
        $root = NewSourceTree @{ 'a/1/a.msi' = 'alpha' }
        $stagingRoot = NewTempDir
        $manifest = NewManifestObject @(
            [PSCustomObject]@{ id='a'; version='1'; source='file://a/1/a.msi'; sha256=(Get-Sha (Join-Path $root 'a/1/a.msi')); order=10; required=$true }
        )
        $null = Invoke-SourceQualification -Manifest $manifest -SourceRoot $root -StagingRoot $stagingRoot -KeepStaging

        @(Get-ChildItem -LiteralPath $stagingRoot -Force).Count | Should -Be 1
    }

    It 'fails the whole run when the source root is absent, not each package' {
        $manifest = NewManifestObject @(
            [PSCustomObject]@{ id='a'; version='1'; source='file://a/1/a.msi'; sha256=('a' * 64); order=10; required=$true }
        )
        { Invoke-SourceQualification -Manifest $manifest -SourceRoot (Join-Path ([System.IO.Path]::GetTempPath()) 'absent-root') -StagingRoot (NewTempDir) } |
            Should -Throw '*Source root not found*'
    }

    It 'reports cleanup outcome on a normal run' {
        $root = NewSourceTree @{ 'a/1/a.msi' = 'alpha' }
        $manifest = NewManifestObject @(
            [PSCustomObject]@{ id='a'; version='1'; source='file://a/1/a.msi'; sha256=(Get-Sha (Join-Path $root 'a/1/a.msi')); order=10; required=$true }
        )
        $result = Invoke-SourceQualification -Manifest $manifest -SourceRoot $root -StagingRoot (NewTempDir)
        $result.CleanupOutcome | Should -Be 'removed'
        $result.Outcome | Should -Be 'passed'
    }

    It 'reports retained cleanup when staging is kept' {
        $root = NewSourceTree @{ 'a/1/a.msi' = 'alpha' }
        $manifest = NewManifestObject @(
            [PSCustomObject]@{ id='a'; version='1'; source='file://a/1/a.msi'; sha256=(Get-Sha (Join-Path $root 'a/1/a.msi')); order=10; required=$true }
        )
        $result = Invoke-SourceQualification -Manifest $manifest -SourceRoot $root -StagingRoot (NewTempDir) -KeepStaging
        $result.CleanupOutcome | Should -Be 'retained'
    }

    It 'cannot report success when cleanup fails' {
        $root = NewSourceTree @{ 'a/1/a.msi' = 'alpha' }
        $manifest = NewManifestObject @(
            [PSCustomObject]@{ id='a'; version='1'; source='file://a/1/a.msi'; sha256=(Get-Sha (Join-Path $root 'a/1/a.msi')); order=10; required=$true }
        )

        # Every package qualifies; only cleanup fails. Without the cleanup
        # outcome feeding the aggregate, this run would report 'passed' while
        # leaving staged content behind.
        Mock -ModuleName SourceQualification Remove-Item { throw 'staging is locked' }

        $result = Invoke-SourceQualification -Manifest $manifest -SourceRoot $root -StagingRoot (NewTempDir)

        $result.PassedCount | Should -Be 1
        $result.FailedRequiredCount | Should -Be 0
        $result.CleanupOutcome | Should -Be 'failed'
        $result.Outcome | Should -Be 'incomplete'
    }

    It 'gives each run a distinct identifier' {
        $root = NewSourceTree @{ 'a/1/a.msi' = 'alpha' }
        $manifest = NewManifestObject @(
            [PSCustomObject]@{ id='a'; version='1'; source='file://a/1/a.msi'; sha256=(Get-Sha (Join-Path $root 'a/1/a.msi')); order=10; required=$true }
        )
        $first = Invoke-SourceQualification -Manifest $manifest -SourceRoot $root -StagingRoot (NewTempDir)
        $second = Invoke-SourceQualification -Manifest $manifest -SourceRoot $root -StagingRoot (NewTempDir)

        $first.RunId | Should -Not -Be $second.RunId
    }
}
