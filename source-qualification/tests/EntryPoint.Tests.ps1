#Requires -Version 7.0

<#
    Exit-code tests for Invoke-SourceQualification.ps1.

    These run the script as a real subprocess and assert the process exit code.
    That is the point: the evidence-write defect existed precisely at this
    boundary -- an unguarded write terminated the script and surfaced as 1,
    claiming a required package had failed -- and no in-process test of the
    module functions could have caught it. Manual verification does not survive
    a refactor; these do.
#>

BeforeAll {
    $script:RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..' '..')).Path
    $script:EntryPoint = Join-Path $script:RepoRoot 'source-qualification' 'scripts' 'Invoke-SourceQualification.ps1'

    # Invoke the same PowerShell that is running the tests, rather than trusting
    # PATH to resolve to the same build.
    $script:Pwsh = Join-Path $PSHOME ($(if ($IsWindows) { 'pwsh.exe' } else { 'pwsh' }))

    function NewTempDir {
        $d = Join-Path ([System.IO.Path]::GetTempPath()) ([guid]::NewGuid().ToString())
        $null = New-Item -ItemType Directory -Path $d -Force
        $d
    }

    function NewMissingSourceFixture {
        <#
            A manifest referencing a source that does not exist. This is the path
            the original evidence leak took: the absolute source root arrived in
            evidence through a raw exception message, and only this path produced
            it. An integrity mismatch never carried the root, so a test built on
            a corrupt hash cannot detect that defect.
        #>
        $base = NewTempDir
        $source = Join-Path $base 'src'
        $null = New-Item -ItemType Directory -Path $source -Force

        $manifest = Join-Path $base 'manifest.json'
        @{ schemaVersion = 1; packages = @(@{
            id = 'example-agent'; version = '1.2.3'
            source = 'file://example-agent/1.2.3/agent.msi'
            sha256 = ('a' * 64); order = 10; required = $true
        })} | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $manifest -Encoding utf8

        [PSCustomObject]@{ Base = $base; SourceRoot = $source; Manifest = $manifest }
    }

    function NewFixture {
        <#
            Builds a source tree and a manifest describing it. The expected hash
            is computed from the fixture this function just wrote, which is sound
            because the subject under test is the entry point's exit behavior,
            not the provenance of the hash.
        #>
        param([string] $Content = 'synthetic installer payload', [switch] $Corrupt)

        $base = NewTempDir
        $source = Join-Path $base 'src'
        $null = New-Item -ItemType Directory -Path (Join-Path $source 'example-agent' '1.2.3') -Force
        $file = Join-Path $source 'example-agent' '1.2.3' 'agent.msi'
        Set-Content -LiteralPath $file -Value $Content -Encoding utf8 -NoNewline

        $hash = if ($Corrupt) { 'f' * 64 } else { (Get-FileHash -LiteralPath $file -Algorithm SHA256).Hash.ToLowerInvariant() }
        $manifest = Join-Path $base 'manifest.json'
        @{ schemaVersion = 1; packages = @(@{
            id = 'example-agent'; version = '1.2.3'
            source = 'file://example-agent/1.2.3/agent.msi'
            sha256 = $hash; order = 10; required = $true
        })} | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $manifest -Encoding utf8

        [PSCustomObject]@{ Base = $base; SourceRoot = $source; Manifest = $manifest }
    }

    function RunEntryPoint {
        param([string[]] $Arguments)
        $output = & $script:Pwsh -NoProfile -File $script:EntryPoint @Arguments 2>&1
        [PSCustomObject]@{ ExitCode = $LASTEXITCODE; Output = ($output | Out-String) }
    }
}

Describe 'Invoke-SourceQualification.ps1 exit codes' {

    It 'returns 0 when every required package qualifies' {
        $f = NewFixture
        $run = RunEntryPoint @('-ManifestPath', $f.Manifest, '-SourceRoot', $f.SourceRoot, '-StagingRoot', (NewTempDir))
        $run.ExitCode | Should -Be 0
    }

    It 'returns 0 when staging is deliberately retained' {
        # Retained staging is an explicit request, not a cleanup failure, so it
        # must not be conflated with the incomplete outcome.
        $f = NewFixture
        $run = RunEntryPoint @('-ManifestPath', $f.Manifest, '-SourceRoot', $f.SourceRoot, '-StagingRoot', (NewTempDir), '-KeepStaging')
        $run.ExitCode | Should -Be 0
    }

    It 'returns 1 when a required package fails integrity' {
        $f = NewFixture -Corrupt
        $run = RunEntryPoint @('-ManifestPath', $f.Manifest, '-SourceRoot', $f.SourceRoot, '-StagingRoot', (NewTempDir))
        $run.ExitCode | Should -Be 1
    }

    It 'returns 2 when the manifest is invalid' {
        $f = NewFixture
        $bad = Join-Path $f.Base 'bad.json'
        '{ "schemaVersion": 9, "packages": [] }' | Set-Content -LiteralPath $bad -Encoding utf8
        $run = RunEntryPoint @('-ManifestPath', $bad, '-SourceRoot', $f.SourceRoot, '-StagingRoot', (NewTempDir))
        $run.ExitCode | Should -Be 2
    }

    It 'returns 2 when the manifest does not exist' {
        $f = NewFixture
        $run = RunEntryPoint @('-ManifestPath', (Join-Path $f.Base 'absent.json'), '-SourceRoot', $f.SourceRoot, '-StagingRoot', (NewTempDir))
        $run.ExitCode | Should -Be 2
    }

    It 'returns 2 when the source root is unusable' {
        $f = NewFixture
        $run = RunEntryPoint @('-ManifestPath', $f.Manifest, '-SourceRoot', (Join-Path $f.Base 'absent-root'), '-StagingRoot', (NewTempDir))
        $run.ExitCode | Should -Be 2
    }

    It 'returns 2 when evidence cannot be written' {
        # A file where a directory must be. This is the regression that motivated
        # the suite: it previously returned 1, which claims a package failed.
        $f = NewFixture
        $blocker = Join-Path $f.Base 'blocker'
        Set-Content -LiteralPath $blocker -Value 'not a directory' -NoNewline
        $evidence = Join-Path $blocker 'nested' 'evidence.json'

        $run = RunEntryPoint @('-ManifestPath', $f.Manifest, '-SourceRoot', $f.SourceRoot, '-StagingRoot', (NewTempDir), '-EvidencePath', $evidence)
        $run.ExitCode | Should -Be 2
    }

    It 'does not leak the source root when a source is missing' {
        # The regression this suite exists for. Asserting against an integrity
        # mismatch instead would pass on the defective implementation, because a
        # hash mismatch never produced a message containing the source root.
        $f = NewMissingSourceFixture
        $evidence = Join-Path (NewTempDir) 'evidence.json'
        $run = RunEntryPoint @('-ManifestPath', $f.Manifest, '-SourceRoot', $f.SourceRoot, '-StagingRoot', (NewTempDir), '-EvidencePath', $evidence)

        $run.ExitCode | Should -Be 1
        Test-Path -LiteralPath $evidence | Should -BeTrue

        $parsed = Get-Content -LiteralPath $evidence -Raw | ConvertFrom-Json
        $parsed.Packages[0].ReasonCode | Should -Be 'source_not_found'

        $written = Get-Content -LiteralPath $evidence -Raw
        $written | Should -Not -Match ([regex]::Escape($f.SourceRoot))
        # The staged path is derived from the source root and would leak the same
        # information by another route.
        $written | Should -Not -Match ([regex]::Escape($f.Base))
    }

    It 'writes evidence carrying a reason code and no absolute path' {
        $f = NewFixture -Corrupt
        $evidence = Join-Path (NewTempDir) 'evidence.json'
        $run = RunEntryPoint @('-ManifestPath', $f.Manifest, '-SourceRoot', $f.SourceRoot, '-StagingRoot', (NewTempDir), '-EvidencePath', $evidence)

        $run.ExitCode | Should -Be 1
        Test-Path -LiteralPath $evidence | Should -BeTrue

        $written = Get-Content -LiteralPath $evidence -Raw
        $written | Should -Match 'integrity_mismatch'
        # The source root is the value that previously leaked through a raw
        # exception message.
        $written | Should -Not -Match ([regex]::Escape($f.SourceRoot))
    }
}
