#Requires -Version 7.0

# Discovery scope, deliberately. -Skip: is evaluated when Pester discovers the
# tests, before BeforeAll runs, so a probe set there leaves every packer case
# silently skipped -- which reads as a passing suite.
$script:PackerAvailable = $null -ne (Get-Command packer -ErrorAction SilentlyContinue)

BeforeAll {
    $script:RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..' '..')).Path
    $script:BuildDir = Join-Path $script:RepoRoot 'packer' 'builds'
    $script:Build = Get-Content -LiteralPath (Join-Path $script:BuildDir 'windows-image.pkr.hcl') -Raw

    # Configuration with the comments stripped. An assertion that something is
    # absent must read what Packer reads: this file explains why iso_paths and a
    # Windows Server identifier are not used, and a naive search finds those
    # words in the explanation and reports the opposite of the truth.
    $script:Configuration = ($script:Build -split "`n" |
        Where-Object { $_.TrimStart() -notlike '#*' }) -join "`n"

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
        Set-Content -LiteralPath (Join-Path $work 'bootstrap.ps1') -Value '# bootstrap' -NoNewline
        Set-Content -LiteralPath (Join-Path $work 'media.iso') -Value 'media' -NoNewline
        $null = New-Item -ItemType Directory -Path (Join-Path $work 'bundle') -Force
        Set-Content -LiteralPath (Join-Path $work 'qualification.json') -Value '{}' -NoNewline

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
            media_url                   = '"' + (($work + '/media.iso') -replace '\\', '/') + '"'
            media_checksum              = '"sha256:' + ('0' * 64) + '"'
            answer_file_path            = '"' + (($work + '/autounattend.xml') -replace '\\', '/') + '"'
            winrm_bootstrap_path        = '"' + (($work + '/bootstrap.ps1') -replace '\\', '/') + '"'
            bundle_path                 = '"' + (($work + '/bundle') -replace '\\', '/') + '"'
            media_qualification_record_path = '"' + (($work + '/qualification.json') -replace '\\', '/') + '"'
            vmware_tools_version        = '"12.5.0"'
            finalization_nonce          = '"' + ('0123456789abcdef' * 2) + '"'
            descriptor_sha256           = '"' + ('a' * 64) + '"'
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
            guest_os_type               = '"windows11_64Guest"'
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
        $script:Configuration | Should -Not -Match '(?m)^\s*default\s*='
    }
}

Describe 'the build seals what it constructed' {

    It 'does not convert to a template at this stage' {
        # Converting makes an artifact immutable, which is why it must not
        # happen yet. At this point the VM still holds an enabled build account
        # with a known password, a reachable WinRM listener, and possible
        # answer-file residue, and it has not been generalized. Sealing that
        # state produces an immutable artifact nobody can fix and a later stage
        # might mistake for a candidate.
        $script:Configuration | Should -Match 'convert_to_template\s*=\s*false'
        $script:Configuration | Should -Not -Match 'convert_to_template\s*=\s*true'
    }

    It 'waits for a shutdown it does not perform' {
        # An absent shutdown command lets the builder ask VMware Tools for a
        # graceful shutdown, which would power off a VM whose finalizer had
        # failed -- removing the one signal the fail-closed design rests on.
        $script:Configuration | Should -Match 'disable_shutdown\s*=\s*true'
        $script:Configuration | Should -Match 'shutdown_timeout\s*='
        $script:Configuration | Should -Not -Match 'shutdown_command\s*='
    }

    It 'delivers the answer file and its bootstrap as removable media' {
        # A credential typed at a boot prompt is visible to anything watching
        # the console and is recorded in the configuration itself. A
        # boot_command is not prohibited -- a bounded, non-secret key sequence
        # may prove necessary to start the installer -- so what is asserted is
        # that no credential variable is interpolated into one.
        $script:Build | Should -Match 'cd_files\s*=\s*\[var\.answer_file_path, var\.winrm_bootstrap_path\]'

        $bootCommand = [regex]::Match($script:Build, '(?s)boot_command\s*=\s*\[.*?\]')
        if ($bootCommand.Success) {
            $bootCommand.Value | Should -Not -Match 'password'
            $bootCommand.Value | Should -Not -Match 'var\.build_password|var\.vcenter_password'
        }
    }

    It 'verifies the media it was handed rather than naming a datastore artifact' {
        # iso_paths would name a datastore artifact nothing here has seen, so the
        # bytes verified locally would not be the bytes vSphere consumes.
        $script:Configuration | Should -Match 'iso_url\s*=\s*var\.media_url'
        $script:Configuration | Should -Match 'iso_checksum\s*=\s*var\.media_checksum'
        $script:Configuration | Should -Not -Match 'iso_paths'
    }

    It 'authenticates the way the listener is configured to accept' {
        # Packer defaults to Basic, and the bootstrap disables Basic on the
        # listener. Without NTLM stated the two disagree and the build fails at
        # connection with an error describing neither cause.
        $script:Configuration | Should -Match 'winrm_use_ntlm\s*=\s*true'

        $bootstrap = Get-Content -LiteralPath (Join-Path $script:RepoRoot 'packer' 'unattended' 'Enable-BuildWinRM.ps1') -Raw
        $bootstrap | Should -Match "Auth\\Basic' -Value \`$false"
        $bootstrap | Should -Match "Auth\\Negotiate' -Value \`$true"
    }

    It 'reaches the guest over an encrypted listener' {
        # A fresh installation has no listener at all; the answer file creates
        # one. Plaintext would carry the administrator password on the wire.
        $script:Build | Should -Match 'winrm_use_ssl\s*=\s*true'
        $script:Build | Should -Match 'winrm_port\s*=\s*5986'
    }

    It 'authenticates as the account the answer file configures' {
        # Supplied by ConvertTo-BuildVariableSet from the declaration, so the two
        # cannot disagree.
        $declaration = Get-Content -LiteralPath (Join-Path $script:RepoRoot 'packer' 'unattended' 'autounattend.template.json') -Raw | ConvertFrom-Json
        $declaration.buildSettings.buildUsername | Should -Be 'Administrator'
        $template = Get-Content -LiteralPath (Join-Path $script:RepoRoot 'packer' 'unattended' 'autounattend.xml.template') -Raw
        $template | Should -Match '<Username>\{\{BUILD_USERNAME\}\}</Username>'
    }

    It 'permits only the account it actually configures' {
        # The answer file sets AdministratorPassword and creates no other user.
        # Any other name would be an account setup never creates and never
        # assigns that password to, so AutoLogon and WinRM would both fail.
        # Supporting a separately created account is a contract revision.
        $schema = Get-Content -LiteralPath (Join-Path $script:RepoRoot 'contracts' 'answer-file-template-1.schema.json') -Raw | ConvertFrom-Json
        $schema.properties.buildSettings.properties.buildUsername.const | Should -Be 'Administrator'
    }

    It 'reconciles the installed Windows against the record it uploaded' {
        # The check reads a qualification record, so the build has to put one
        # there. An earlier draft downloaded evidence nothing created; this is
        # the same defect in the other direction.
        $script:Configuration | Should -Match 'media_qualification_record_path'
        $script:Configuration | Should -Match 'Test-PreGeneralizationReadiness'
    }

    It 'runs the pre-generalization checks only after provisioning is accepted' {
        $gate = $script:Configuration.IndexOf('Test-ProvisioningComplete')
        $checks = $script:Configuration.IndexOf('Test-PreGeneralizationReadiness')
        $gate | Should -BeGreaterThan 0
        $gate | Should -BeLessThan $checks
    }

    It 'removes residue after the checks that examine the machine' {
        # The checks look at a machine that still has everything on it. Removing
        # first would hide what they exist to observe.
        $checks = $script:Configuration.IndexOf('Test-PreGeneralizationReadiness')
        $removal = $script:Configuration.IndexOf('Invoke-AnswerFileResidueRemoval')
        $checks | Should -BeLessThan $removal
    }

    It 'retrieves the evidence for both phases' {
        foreach ($phase in 'pre-generalization', 'credential-residue') {
            $script:Configuration | Should -Match ([regex]::Escape("$phase-`${local.evidence_name}"))
        }
    }

    It 'refuses to continue when either phase did not pass' {
        # Fails closed on both, so nothing downstream runs against a machine
        # whose state was never established.
        ([regex]::Matches($script:Configuration, "if \(\`$result\.Outcome -ne 'passed'\) \{ throw")).Count |
            Should -Be 2
    }

    It 'checks VMware Tools before launching the finalizer' {
        # A finalizer discovering this would refuse to shut down, correctly, but
        # only after disabling the account and removing the listener.
        $tools = $script:Configuration.IndexOf('Test-VMwareToolsPrerequisite')
        $launch = $script:Configuration.IndexOf('Start-DetachedFinalizer.ps1')
        $tools | Should -BeGreaterThan 0
        $tools | Should -BeLessThan $launch
    }

    It 'passes the workspace the finalizer must remove' {
        # Without it the finalizer cannot name what to delete, and the build
        # scripts, contracts, evidence, and log travel into the image.
        $script:Configuration | Should -Match '-WorkspaceRoot'
    }

    It 'launches the finalizer detached, as the last WinRM operation' {
        # Everything after this happens in a session that survives the removal
        # of the listener the command arrived on.
        $script:Configuration | Should -Match 'Start-DetachedFinalizer\.ps1'
    }

    It 'schedules nothing after the finalizer launch' {
        # The finalizer removes the listener, so a later provisioner has nothing
        # to connect to. This is the invariant the whole design rests on.
        $launch = $script:Configuration.IndexOf('Start-DetachedFinalizer.ps1')
        $remainder = $script:Configuration.Substring($launch)

        $remainder | Should -Not -Match 'provisioner "file"'
        ([regex]::Matches($remainder, 'provisioner "')).Count | Should -Be 0
    }

    It 'seals nowhere inside the build' {
        # Conversion is static configuration and cannot be a gate, so it happens
        # on the host after Packer exits.
        $script:Configuration | Should -Not -Match 'Invoke-CandidateSealing'
        $script:Configuration | Should -Match 'convert_to_template\s*=\s*false'
    }

    It 'configures nothing beyond the steps it implements' {
        # Steps 1 and 2 provision and prove it worked. Everything that turns a
        # provisioned VM into an image is absent and unimplemented.
        $script:Configuration | Should -Not -Match 'Sysprep\.exe'
        $script:Configuration | Should -Not -Match 'Remove-SetupResidue'
        $script:Build | Should -Match 'STAGE 5 STEPS 1 AND 2 ONLY'
    }

    It 'reuses the Increment 2 entry point rather than a parallel format' {
        # A second package-transfer path would need its own verification, its
        # own evidence, and its own reasons to be trusted.
        $script:Configuration | Should -Match 'Invoke-GuestPhase\.ps1'
        $script:Configuration | Should -Match '-Phase install'
        $script:Configuration | Should -Match '-Phase validate'
    }

    It 'delivers the descriptor digest out of band' {
        # A digest carried inside the bundle would be rewritten by whoever
        # rewrote the bundle.
        $script:Configuration | Should -Match 'VDIIAC_DESCRIPTOR_SHA256=\$\{var\.descriptor_sha256\}'
        $script:Configuration | Should -Not -Match 'descriptor_sha256.*bundle_path'
    }

    It 'accepts the logical-failure exit code on the guest phases' {
        # 200 means the phase decided not to proceed and wrote bounded evidence
        # saying why. That is a result to retrieve, not a transport failure.
        ([regex]::Matches($script:Configuration, 'valid_exit_codes = \[0, 200\]')).Count | Should -Be 2
    }

    It 'runs install before validate, with a restart between them' {
        $install = $script:Configuration.IndexOf('-Phase install')
        $restart = $script:Configuration.IndexOf('windows-restart')
        $validate = $script:Configuration.IndexOf('-Phase validate')

        $install | Should -BeGreaterThan 0
        $install | Should -BeLessThan $restart
        $restart | Should -BeLessThan $validate
    }

    It 'retrieves install evidence before the restart gate' {
        # A failing provisioner stops the ones after it, so evidence collected
        # later than the gate would never be collected at all.
        $download = $script:Configuration.IndexOf('install-${local.evidence_name}"')
        $gate = $script:Configuration.IndexOf('Test-RestartAuthorization')
        $download | Should -BeGreaterThan 0
        $download | Should -BeLessThan $gate
    }

    It 'verifies both evidence documents before deleting the bundle' {
        # Deleting first would destroy the packages the evidence describes while
        # the evidence was still unverified.
        $gate = $script:Configuration.IndexOf('Test-ProvisioningComplete')
        $cleanup = $script:Configuration.IndexOf('Remove-GuestBundle')
        $gate | Should -BeGreaterThan 0
        $gate | Should -BeLessThan $cleanup
    }

    It 'stops the build when the provisioning gate refuses' {
        # Fails closed. Nothing after this point is reversible, and
        # convert_to_template cannot be a gate because it is static
        # configuration -- what keeps a failed build from being sealed is that
        # this throws.
        $script:Configuration | Should -Match 'if \(-not \$decision\.Authorized\) \{ throw'
    }

    It 'derives what it deletes from the staging root, not the descriptor' {
        # Cleanup has to work after descriptor tampering, so what gets deleted
        # must not depend on a document an attacker may have rewritten.
        $script:Configuration | Should -Match "Remove-GuestBundle -StagingRoot '\$\{local\.guest_root\}' -RunId '\$\{var\.run_id\}'"
    }

    It 'finds the bootstrap by volume label, not a drive letter' {
        # cd_files produces CD media and no letter is reserved for it. A: is a
        # floppy convention, and the CD's letter depends on how many volumes
        # setup has already assigned. A wrong guess fails at first logon, before
        # WinRM exists, so the build is unreachable and the reason is invisible.
        $template = Get-Content -LiteralPath (Join-Path $script:RepoRoot 'packer' 'unattended' 'autounattend.xml.template') -Raw
        $commands = [regex]::Matches($template, '<CommandLine>(?<c>[^<]*)</CommandLine>')
        $commands.Count | Should -BeGreaterThan 0

        foreach ($match in $commands) {
            $match.Groups['c'].Value | Should -Not -Match '(?i)\b[A-Z]:\\' -Because 'no first-logon command may assume a drive letter'
        }

        $template | Should -Match 'OEMDRV'
        $template | Should -Match 'Enable-BuildWinRM\.ps1'
    }

    It 'labels the media it then searches for' {
        # The label the answer file resolves and the label the build applies are
        # the same string, and nothing else enforces that.
        $script:Configuration | Should -Match 'cd_label\s*=\s*"OEMDRV"'
    }

    It 'restricts the guest OS identifier to a desktop one' {
        # The artifact is a desktop image; the identifier was a Windows Server
        # one. It also changes the device model vSphere presents to setup, which
        # is why it is a recipe input.
        $script:Configuration | Should -Match 'windows11_64Guest'
        $script:Configuration | Should -Not -Match 'windows9Server64Guest'
    }

    It 'marks every credential variable sensitive' {
        foreach ($name in 'vcenter_password', 'build_password') {
            $pattern = 'variable "' + $name + '" \{[^}]*sensitive\s*=\s*true'
            $script:Build | Should -Match $pattern -Because "$name must not be printed"
        }
    }
}

Describe 'the handoff from verified media to the build' {

    BeforeAll {
        $scripts = Join-Path $script:RepoRoot 'source-qualification' 'scripts'
        foreach ($module in 'RunIdentity', 'MediaQualification', 'AnswerFile', 'BuildInputs') {
            Import-Module (Join-Path $scripts "$module.psm1") -Force
        }

        function NewQualifiedInputs {
            <#
                The real path: qualify media, re-verify it at the build's input
                boundary, and hand the result to the variable set. The previous
                coverage passed a synthetic datastore string, which exercised
                neither end of this.
            #>
            $runId = Get-RunIdentifier
            $root = NewTempDir
            $mediaPath = Join-Path $root 'windows.iso'
            Set-Content -LiteralPath $mediaPath -Value 'installation-media-content' -NoNewline -Encoding utf8
            $digest = (Get-FileHash -LiteralPath $mediaPath -Algorithm SHA256).Hash.ToLowerInvariant()

            $referencePath = Join-Path $root 'media.json'
            [ordered]@{
                schemaVersion = 1; mediaId = 'windows-baseline'
                reference = [ordered]@{ kind = 'file'; locator = 'windows.iso'; fileName = 'windows.iso' }
                integrity = [ordered]@{
                    algorithm = 'SHA256'; digest = $digest
                    authority = [ordered]@{
                        kind = 'vendor-published'
                        citation = 'https://vendor.example/security/checksums'
                        retrievedUtc = '2026-01-01T00:00:00Z' } }
                image = [ordered]@{ edition = 'Windows Enterprise'; index = 1 }
                platform = [ordered]@{ architecture = 'x64'; language = 'en-US' }
            } | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $referencePath -Encoding utf8

            $record = Invoke-MediaQualification -ReferencePath $referencePath -MediaRoot $root -RunId $runId
            $recordPath = Join-Path $root 'qualification.json'
            Save-MediaQualificationRecord -Record $record -Path $recordPath | Out-Null

            [PSCustomObject]@{
                RunId    = $runId
                Root     = $root
                Digest   = $digest
                Verified = Assert-QualifiedMedia -RecordPath $recordPath -MediaRoot $root -RunId $runId
            }
        }

        function BuildHardware {
            @{
                HardwareVersion = 21; Firmware = 'efi-secure'; SecureBoot = $true
                DiskControllerType = 'pvscsi'; DiskSizeGb = 80; VirtualTpm = $true
                Cpus = 4; MemoryMb = 8192; GuestOsType = 'windows11_64Guest'
            }
        }
    }

    It 'hands the build the file it verified, not a name for one' {
        $qualified = NewQualifiedInputs
        $declaration = Import-AnswerFileTemplate -Path (Join-Path $script:RepoRoot 'packer' 'unattended' 'autounattend.template.json')

        $variables = ConvertTo-BuildVariableSet -QualifiedMedia $qualified.Verified -Declaration $declaration `
            -Hardware (BuildHardware) -AnswerFilePath (Join-Path $qualified.Root 'rendered.xml') -RunId $qualified.RunId

        $variables['media_url'] | Should -Be $qualified.Verified.MediaPath
        Test-Path -LiteralPath $variables['media_url'] | Should -BeTrue
    }

    It 'gives Packer the same expectation the boundary verified against' {
        # Algorithm-prefixed, which is the form iso_checksum takes, and the same
        # digest the record was qualified against rather than one recomputed
        # here.
        $qualified = NewQualifiedInputs
        $declaration = Import-AnswerFileTemplate -Path (Join-Path $script:RepoRoot 'packer' 'unattended' 'autounattend.template.json')

        $variables = ConvertTo-BuildVariableSet -QualifiedMedia $qualified.Verified -Declaration $declaration `
            -Hardware (BuildHardware) -AnswerFilePath (Join-Path $qualified.Root 'rendered.xml') -RunId $qualified.RunId

        $variables['media_checksum'] | Should -Be ('sha256:' + $qualified.Digest)
    }

    It 'authenticates as the account the answer file configures' {
        $qualified = NewQualifiedInputs
        $declaration = Import-AnswerFileTemplate -Path (Join-Path $script:RepoRoot 'packer' 'unattended' 'autounattend.template.json')

        $variables = ConvertTo-BuildVariableSet -QualifiedMedia $qualified.Verified -Declaration $declaration `
            -Hardware (BuildHardware) -AnswerFilePath (Join-Path $qualified.Root 'rendered.xml') -RunId $qualified.RunId

        $variables['build_username'] | Should -Be $declaration.buildSettings.buildUsername
    }

    It 'refuses a hardware set missing an input the digest covers' {
        # The builder and the recipe digest must see the same hardware. A
        # missing key here would mean the digest names a configuration the build
        # did not use.
        $qualified = NewQualifiedInputs
        $declaration = Import-AnswerFileTemplate -Path (Join-Path $script:RepoRoot 'packer' 'unattended' 'autounattend.template.json')
        $hardware = BuildHardware
        $hardware.Remove('GuestOsType')

        { ConvertTo-BuildVariableSet -QualifiedMedia $qualified.Verified -Declaration $declaration `
            -Hardware $hardware -AnswerFilePath (Join-Path $qualified.Root 'rendered.xml') -RunId $qualified.RunId } |
            Should -Throw -ExpectedMessage '*must see the same hardware*'
    }

    It 'produces a variable set the build configuration actually validates' -Skip:(-not $script:PackerAvailable) {
        # The end of the handoff: the values this function produces are written
        # as a var file and validated against the real configuration. A name
        # that does not match a declared variable fails here rather than in a lab.
        $qualified = NewQualifiedInputs
        $declaration = Import-AnswerFileTemplate -Path (Join-Path $script:RepoRoot 'packer' 'unattended' 'autounattend.template.json')
        Set-Content -LiteralPath (Join-Path $qualified.Root 'rendered.xml') -Value '<x/>' -NoNewline
        Set-Content -LiteralPath (Join-Path $qualified.Root 'bootstrap.ps1') -Value '# bootstrap' -NoNewline
        $bundleDir = Join-Path $qualified.Root 'bundle'
        $evidenceDir = Join-Path $qualified.Root 'evidence'
        $null = New-Item -ItemType Directory -Path $bundleDir, $evidenceDir -Force

        $variables = ConvertTo-BuildVariableSet -QualifiedMedia $qualified.Verified -Declaration $declaration `
            -Hardware (BuildHardware) -AnswerFilePath (Join-Path $qualified.Root 'rendered.xml') -RunId $qualified.RunId

        # Platform values are supplied per environment and are deliberately not
        # produced by the handoff.
        $platform = [ordered]@{
            vcenter_server = 'vcenter.example'; vcenter_username = 'builder@example'
            vcenter_password = 'placeholder'; vcenter_insecure_connection = $false
            datacenter = 'example-datacenter'; cluster = 'example-cluster'
            datastore = 'example-datastore'; network = 'example-network'; folder = 'example-folder'
            candidate_name = 'windows-candidate'; build_password = 'placeholder'
            winrm_bootstrap_path = (Join-Path $qualified.Root 'bootstrap.ps1')
            bundle_path = $bundleDir
            media_qualification_record_path = (Join-Path $qualified.Root 'qualification.json')
            vmware_tools_version = '12.5.0'
            finalization_nonce = ('0123456789abcdef' * 2)
            descriptor_sha256 = ('a' * 64)
            tools_source_dir = (Join-Path $script:RepoRoot 'source-qualification' 'scripts')
            guest_scripts_dir = (Join-Path $script:RepoRoot 'packer' 'scripts' 'guest')
            contracts_source_dir = (Join-Path $script:RepoRoot 'contracts')
            evidence_output_dir = $evidenceDir
        }

        $lines = foreach ($pair in ($variables.GetEnumerator() + $platform.GetEnumerator())) {
            $value = switch ($pair.Value) {
                { $_ -is [bool] } { $_.ToString().ToLowerInvariant(); break }
                { $_ -is [int] }  { $_.ToString(); break }
                default           { '"' + (($_ -as [string]) -replace '\\', '/') + '"' }
            }
            "$($pair.Key) = $value"
        }
        $varFile = Join-Path $qualified.Root 'vars.pkrvars.hcl'
        ($lines -join "`n") | Set-Content -LiteralPath $varFile -Encoding utf8

        $result = PackerValidate -VarFile $varFile
        $result.Output | Should -Match 'The configuration is valid'
        $result.ExitCode | Should -Be 0
    }
}
