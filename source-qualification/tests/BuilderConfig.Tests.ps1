#Requires -Version 7.0

# Discovery scope, deliberately. -Skip: is evaluated when Pester discovers the
# tests, before BeforeAll runs, so a probe set there leaves every packer case
# silently skipped -- which reads as a passing suite.
$script:PackerAvailable = $null -ne (Get-Command packer -ErrorAction SilentlyContinue)

BeforeAll {
    $script:RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..' '..')).Path
    $script:BuildDir = Join-Path $script:RepoRoot 'packer' 'builds'
    $script:Build = Get-Content -LiteralPath (Join-Path $script:BuildDir 'windows-image.pkr.hcl') -Raw

    function NewTempDir {
        $d = Join-Path ([System.IO.Path]::GetTempPath()) ([guid]::NewGuid().ToString())
        $null = New-Item -ItemType Directory -Path $d -Force
        $d
    }

    function NewVarFile {
        <#
            Every input the build declares. Values are synthetic placeholders and
            name no real platform; the point is that the configuration resolves,
            not that it could connect anywhere.
        #>
        param([hashtable] $Override = @{})
        $work = NewTempDir
        $null = New-Item -ItemType Directory -Path (Join-Path $work 'evidence') -Force
        Set-Content -LiteralPath (Join-Path $work 'autounattend.xml') -Value '<x/>' -NoNewline

        $values = [ordered]@{
            vcenter_server              = '"vcenter.example"'
            vcenter_username            = '"builder@example"'
            vcenter_password            = '"placeholder"'
            vcenter_insecure_connection = 'false'
            datacenter                  = '"example-datacenter"'
            cluster                     = '"example-cluster"'
            datastore                   = '"example-datastore"'
            network                     = '"example-network"'
            folder                      = '"example-folder"'
            run_id                      = '"3f2504e0-4f89-41d3-9a0c-0305e82c3301"'
            candidate_name              = '"windows-candidate"'
            media_path                  = '"[example-datastore] iso/windows.iso"'
            answer_file_path            = '"' + (($work + '/autounattend.xml') -replace '\\', '/') + '"'
            tools_source_dir            = '"' + ((Join-Path $script:RepoRoot 'source-qualification' 'scripts') -replace '\\', '/') + '"'
            guest_scripts_dir           = '"' + ((Join-Path $script:RepoRoot 'packer' 'scripts' 'guest') -replace '\\', '/') + '"'
            contracts_source_dir        = '"' + ((Join-Path $script:RepoRoot 'contracts') -replace '\\', '/') + '"'
            evidence_output_dir         = '"' + (($work + '/evidence') -replace '\\', '/') + '"'
            hardware_version            = '21'
            firmware                    = '"efi-secure"'
            virtual_tpm                 = 'true'
            disk_controller_type        = '"pvscsi"'
            disk_size_gb                = '80'
            cpus                        = '4'
            memory_mb                   = '8192'
            build_username              = '"Administrator"'
            build_password              = '"placeholder"'
        }
        foreach ($key in $Override.Keys) { $values[$key] = $Override[$key] }

        $path = Join-Path $work 'vars.pkrvars.hcl'
        (($values.GetEnumerator() | ForEach-Object { "$($_.Key) = $($_.Value)" }) -join "`n") |
            Set-Content -LiteralPath $path -Encoding utf8
        $path
    }

    function PackerValidate {
        param([string] $VarFile)
        $previous = $ErrorActionPreference
        # A native command's stderr becomes a terminating error under Stop, so
        # packer's expected complaint would fail the test before it is read.
        $ErrorActionPreference = 'Continue'
        try {
            $output = (& packer validate "-var-file=$VarFile" $script:BuildDir 2>&1) -join "`n"
            [PSCustomObject]@{ ExitCode = $LASTEXITCODE; Output = $output }
        }
        finally { $ErrorActionPreference = $previous }
    }

}

Describe 'the build configuration is complete' {

    It 'is formatted as packer fmt would write it' -Skip:(-not $script:PackerAvailable) {
        & packer fmt -check -recursive $script:BuildDir | Out-Null
        $LASTEXITCODE | Should -Be 0
    }

    It 'passes a full validate against the pinned plugin' -Skip:(-not $script:PackerAvailable) {
        # Not -syntax-only: a full validate resolves the file provisioner
        # sources, so a build pointing at a directory that does not exist fails
        # here rather than in a lab.
        $result = PackerValidate -VarFile (NewVarFile)
        $result.Output | Should -Match 'The configuration is valid'
        $result.ExitCode | Should -Be 0
    }

    It 'refuses to validate with nothing configured' -Skip:(-not $script:PackerAvailable) {
        # No usable defaults. An unset input must be an error, never a fallback
        # to whatever happens to be reachable -- which is usually someone else's
        # environment.
        $previous = $ErrorActionPreference
        $ErrorActionPreference = 'Continue'
        try { $null = & packer validate $script:BuildDir 2>&1 }
        finally { $ErrorActionPreference = $previous }
        $LASTEXITCODE | Should -Not -Be 0
    }

    It 'refuses a run identifier that is not a canonical UUID' -Skip:(-not $script:PackerAvailable) {
        $result = PackerValidate -VarFile (NewVarFile -Override @{ run_id = '"NOT-A-UUID"' })
        $result.ExitCode | Should -Not -Be 0
        $result.Output | Should -Match 'lowercase canonical UUID'
    }

    It 'refuses BIOS firmware' -Skip:(-not $script:PackerAvailable) {
        # A Windows desktop image built without UEFI cannot later require secure
        # boot, and the choice is not reversible after the image exists.
        $result = PackerValidate -VarFile (NewVarFile -Override @{ firmware = '"bios"' })
        $result.ExitCode | Should -Not -Be 0
        $result.Output | Should -Match 'efi or efi-secure'
    }

    It 'refuses a disk too small to service' -Skip:(-not $script:PackerAvailable) {
        $result = PackerValidate -VarFile (NewVarFile -Override @{ disk_size_gb = '20' })
        $result.ExitCode | Should -Not -Be 0
    }
}

Describe 'the build pins what it depends on' {

    It 'pins the Packer version' {
        $script:Build | Should -Match 'required_version\s*=\s*"1\.15\.4"'
    }

    It 'pins the vSphere plugin to an exact version' {
        # A plugin that moves under a running configuration changes what is
        # built without changing anything in this repository.
        $script:Build | Should -Match 'version\s*=\s*"=\s*1\.4\.2"'
    }

    It 'declares no default for any variable' {
        # A default is a value someone else chose for an environment they were
        # thinking of. Every input is supplied per run.
        $script:Build | Should -Not -Match '(?m)^\s*default\s*='
    }
}

Describe 'the build seals what it constructed' {

    It 'converts the result to a template' {
        # What makes the artifact immutable: a template cannot be powered on and
        # modified in place.
        $script:Build | Should -Match 'convert_to_template\s*=\s*true'
    }

    It 'owns the shutdown rather than letting the guest take it' {
        # A guest script shutting itself down would race the sealing step.
        $script:Build | Should -Match 'shutdown_command\s*='
        $script:Build | Should -Match 'shutdown_timeout\s*='
    }

    It 'removes credential residue before generalizing' {
        # Setup's answer-file copies hold the administrator password in plain
        # text. Generalizing first would carry them into the sealed image.
        $residue = $script:Build.IndexOf('Remove-SetupResidue')
        $generalize = $script:Build.IndexOf('Sysprep.exe')
        $residue | Should -BeGreaterThan 0
        $residue | Should -BeLessThan $generalize
    }

    It 'runs pre-generalization checks before generalizing' {
        $checks = $script:Build.IndexOf('Get-SetupResidue')
        $generalize = $script:Build.IndexOf('Sysprep.exe')
        $checks | Should -BeGreaterThan 0
        $checks | Should -BeLessThan $generalize
    }

    It 'retrieves evidence before generalizing' {
        # A failing provisioner stops the ones after it, so evidence collected
        # later than this may never be collected at all.
        $download = $script:Build.IndexOf('direction   = "download"')
        $generalize = $script:Build.IndexOf('Sysprep.exe')
        $download | Should -BeGreaterThan 0
        $download | Should -BeLessThan $generalize
    }

    It 'fails the build when residue cannot be removed' {
        # Reporting it would let a sealed image carry a working credential.
        $script:Build | Should -Match 'if \(-not \$outcome\.Clean\) \{ throw'
    }

    It 'delivers the answer file as removable media, not a boot command' {
        # A credential typed at a boot prompt is visible to anything watching
        # the console and is recorded in the configuration itself.
        $script:Build | Should -Match 'cd_files\s*=\s*\[var\.answer_file_path\]'
        $script:Build | Should -Not -Match 'boot_command'
    }

    It 'marks every credential variable sensitive' {
        foreach ($name in 'vcenter_password', 'build_password') {
            $pattern = 'variable "' + $name + '" \{[^}]*sensitive\s*=\s*true'
            $script:Build | Should -Match $pattern -Because "$name must not be printed"
        }
    }
}
