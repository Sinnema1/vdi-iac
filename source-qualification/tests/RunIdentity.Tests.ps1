#Requires -Version 7.0

<#
    Run identifier validation and run-directory reservation.

    The collision case lands here, before any recursive cleanup exists. Once
    cleanup is implemented, a test that gets collision handling wrong deletes a
    directory it does not own.
#>

BeforeAll {
    $script:RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..' '..')).Path
    Import-Module (Join-Path $script:RepoRoot 'source-qualification' 'scripts' 'RunIdentity.psm1') -Force

    function NewTempDir {
        $d = Join-Path ([System.IO.Path]::GetTempPath()) ([guid]::NewGuid().ToString())
        $null = New-Item -ItemType Directory -Path $d -Force
        $d
    }
}

Describe 'Get-RunIdentifier' {

    It 'produces a canonical lowercase UUID' {
        $id = Get-RunIdentifier
        { Assert-RunIdentifier -RunId $id } | Should -Not -Throw
        $id | Should -MatchExactly '^[0-9a-f-]+$'
    }

    It 'produces a distinct value each time' {
        (Get-RunIdentifier) | Should -Not -Be (Get-RunIdentifier)
    }
}

Describe 'Assert-RunIdentifier' {

    It 'accepts a canonical lowercase UUID' {
        Assert-RunIdentifier -RunId '3f2504e0-4f89-41d3-9a0c-0305e82c3301' |
            Should -Be '3f2504e0-4f89-41d3-9a0c-0305e82c3301'
    }

    It 'rejects <label>' -ForEach @(
        @{ label = 'an uppercase UUID';        value = '3F2504E0-4F89-41D3-9A0C-0305E82C3301' }
        @{ label = 'a mixed-case UUID';        value = '3f2504e0-4F89-41d3-9a0c-0305e82c3301' }
        @{ label = 'a UUID without hyphens';   value = '3f2504e04f8941d39a0c0305e82c3301' }
        @{ label = 'a truncated UUID';         value = '3f2504e0-4f89-41d3-9a0c' }
        @{ label = 'an empty string';          value = '' }
        @{ label = 'whitespace';               value = '   ' }
        @{ label = 'a path separator';         value = '../../etc' }
        @{ label = 'a dot segment';            value = '3f2504e0-4f89-41d3-9a0c-0305e82c3301/..' }
        @{ label = 'a trailing newline';       value = "3f2504e0-4f89-41d3-9a0c-0305e82c3301`n" }
        @{ label = 'arbitrary text';           value = 'not-a-uuid' }
    ) {
        { Assert-RunIdentifier -RunId $value } | Should -Throw
    }
}

Describe 'New-RunDirectory' {

    It 'creates a directory named for the run' {
        $root = NewTempDir
        $id = Get-RunIdentifier
        $path = New-RunDirectory -Root $root -RunId $id
        Test-Path -LiteralPath $path -PathType Container | Should -BeTrue
        (Split-Path -Leaf $path) | Should -Be "run-$id"
    }

    It 'creates the parent root when it does not exist yet' {
        $root = Join-Path (NewTempDir) 'nested' 'root'
        { New-RunDirectory -Root $root -RunId (Get-RunIdentifier) } | Should -Not -Throw
    }

    It 'distinguishes concurrent directories for one run by prefix' {
        $root = NewTempDir
        $id = Get-RunIdentifier
        $staging = New-RunDirectory -Root $root -RunId $id -Prefix 'staging'
        $bundle = New-RunDirectory -Root $root -RunId $id -Prefix 'bundle'
        $staging | Should -Not -Be $bundle
        @(Get-ChildItem -LiteralPath $root -Directory).Count | Should -Be 2
    }

    It 'refuses to reuse a run identifier' {
        # Syntax validation passes a reused identifier. Only the create-or-fail
        # reservation catches it, and the directory is later deleted recursively.
        $root = NewTempDir
        $id = Get-RunIdentifier
        $null = New-RunDirectory -Root $root -RunId $id
        { New-RunDirectory -Root $root -RunId $id } | Should -Throw '*already exists*'
    }

    It 'reports run_id_collision on reuse' {
        $root = NewTempDir
        $id = Get-RunIdentifier
        $null = New-RunDirectory -Root $root -RunId $id
        $code = $null
        try { $null = New-RunDirectory -Root $root -RunId $id } catch { $code = $_.Exception.Data['ReasonCode'] }
        $code | Should -Be 'run_id_collision'
    }

    It 'does not adopt a directory that already holds content' {
        # The failure this prevents: adopting another run's directory and then
        # removing it, with its contents, at the end of this one.
        $root = NewTempDir
        $id = Get-RunIdentifier
        $existing = New-RunDirectory -Root $root -RunId $id
        Set-Content -LiteralPath (Join-Path $existing 'other-run.txt') -Value 'content' -NoNewline

        { New-RunDirectory -Root $root -RunId $id } | Should -Throw '*already exists*'
        Test-Path -LiteralPath (Join-Path $existing 'other-run.txt') | Should -BeTrue
    }

    It 'validates the identifier before creating anything' {
        $root = NewTempDir
        { New-RunDirectory -Root $root -RunId '../escape' } | Should -Throw '*canonical lowercase UUID*'
        @(Get-ChildItem -LiteralPath $root -Force).Count | Should -Be 0
    }

    It 'rejects a malformed prefix' {
        $root = NewTempDir
        { New-RunDirectory -Root $root -RunId (Get-RunIdentifier) -Prefix '../x' } | Should -Throw
    }
}
