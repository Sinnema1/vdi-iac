#Requires -Version 7.0

BeforeAll {
    $script:RepoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    Import-Module (Join-Path $script:RepoRoot 'source-qualification' 'scripts' 'RecipeIdentity.psm1') -Force

    function NewInputs {
        <#
            One complete set of build inputs, returned as fresh objects each call
            so a mutation in one case cannot leak into the next.
        #>
        @{
            MediaReference = [PSCustomObject]@{
                mediaId   = 'windows-baseline'
                integrity = [PSCustomObject]@{ algorithm = 'SHA256'; digest = ('a' * 64) }
                image     = [PSCustomObject]@{ edition = 'Windows Enterprise'; index = 1 }
                platform  = [PSCustomObject]@{ architecture = 'x64'; language = 'en-US' }
            }
            Manifest = [PSCustomObject]@{
                schemaVersion = 2
                packages = @(
                    [PSCustomObject]@{
                        id = 'agent'; version = '1.2.3'; order = 10; required = $true
                        source = [PSCustomObject]@{ expectedSha256 = ('b' * 64) }
                        installer = [PSCustomObject]@{
                            kind = 'msi'; timeoutSeconds = 600; restartPolicy = 'forbid'
                            properties = [PSCustomObject]@{ ALLUSERS = '1'; INSTALLDIR = 'C:/app' }
                        }
                        validation = @([PSCustomObject]@{
                            id = 'present'; type = 'file-exists'
                            root = 'programFiles'; relativePath = 'app/app.exe' })
                    }
                    [PSCustomObject]@{
                        id = 'tool'; version = '2.0.0'; order = 20; required = $false
                        source = [PSCustomObject]@{ expectedSha256 = ('c' * 64) }
                        installer = [PSCustomObject]@{
                            kind = 'exe'; timeoutSeconds = 900; restartPolicy = 'allow-deferred'
                            arguments = @('/quiet', '/norestart')
                            exitCodes = [PSCustomObject]@{ success = @(0); restartRequired = @(3010) }
                        }
                        validation = @([PSCustomObject]@{
                            id = 'service'; type = 'service-exists'; serviceName = 'ToolSvc' })
                    })
            }
            AnswerFile = @{
                TemplateDigest = ('d' * 64); DeclarationDigest = ('e' * 64)
                ImageSelection = [PSCustomObject]@{
                    edition = 'Windows Enterprise'; index = 1; architecture = 'x64'; language = 'en-US' }
            }
            BuildLogic = @{
                PackerConfigDigests = @{ 'build.pkr.hcl' = ('1' * 64); 'sources.pkr.hcl' = ('2' * 64) }
                ProvisioningScriptDigests = @{ 'Invoke-GuestPhase.ps1' = ('3' * 64) }
                GuestContractVersion = 2
            }
            Hardware = @{
                HardwareVersion = 21; Firmware = 'efi'; SecureBoot = $true
                DiskControllerType = 'pvscsi'; DiskSizeGb = 80; VirtualTpm = $true
            }
            Tooling = @{ PackerVersion = '1.15.4'; PluginVersions = @{ vsphere = '1.4.2' } }
        }
    }

    function DigestOf {
        param([hashtable] $Inputs)
        (Get-RecipeDigest -RecipeInput (ConvertTo-RecipeInput @Inputs)).RecipeDigest
    }

    function Baseline { DigestOf -Inputs (NewInputs) }
}

Describe 'recipe digest stability' {

    It 'is the same for the same inputs' {
        DigestOf -Inputs (NewInputs) | Should -Be (DigestOf -Inputs (NewInputs))
    }

    It 'does not depend on the order keys were added to a property map' {
        # A digest over a hashtable's enumeration order would pass a test that
        # only checks the digest is non-empty, and fail in production the first
        # time two machines enumerated differently.
        $one = NewInputs
        $one.Manifest.packages[0].installer.properties = [PSCustomObject]@{ ALLUSERS = '1'; INSTALLDIR = 'C:/app' }
        $two = NewInputs
        $two.Manifest.packages[0].installer.properties = [PSCustomObject]@{ INSTALLDIR = 'C:/app'; ALLUSERS = '1' }

        DigestOf -Inputs $one | Should -Be (DigestOf -Inputs $two)
    }

    It 'does not depend on the order build-logic files were listed' {
        $one = NewInputs
        $one.BuildLogic.PackerConfigDigests = [ordered]@{ 'build.pkr.hcl' = ('1' * 64); 'sources.pkr.hcl' = ('2' * 64) }
        $two = NewInputs
        $two.BuildLogic.PackerConfigDigests = [ordered]@{ 'sources.pkr.hcl' = ('2' * 64); 'build.pkr.hcl' = ('1' * 64) }

        DigestOf -Inputs $one | Should -Be (DigestOf -Inputs $two)
    }

    It 'reports the input version alongside the digest' {
        # Two digests are only comparable within one input version, so the
        # version has to travel with it rather than be implied.
        $inputs = NewInputs
        $result = Get-RecipeDigest -RecipeInput (ConvertTo-RecipeInput @inputs)
        $result.RecipeInputVersion | Should -Be 1
        $result.RecipeDigest | Should -Match '^[0-9a-f]{64}$'
    }
}

Describe 'every included input changes the digest' {

    It 'changes when the package sequence is reordered' {
        # Package order is semantic. Sorting it away is the most natural mistake
        # to make, and it would make two different images share an identity.
        $reordered = NewInputs
        $reordered.Manifest.packages = @($reordered.Manifest.packages[1], $reordered.Manifest.packages[0])

        DigestOf -Inputs $reordered | Should -Not -Be (Baseline)
    }

    It 'changes when EXE argument order changes' {
        # Arguments are positional.
        $changed = NewInputs
        $changed.Manifest.packages[1].installer.arguments = @('/norestart', '/quiet')
        DigestOf -Inputs $changed | Should -Not -Be (Baseline)
    }

    It 'changes when <field> changes' -ForEach @(
        @{ field = 'media id';          apply = { param($i) $i.MediaReference.mediaId = 'other-baseline' } }
        @{ field = 'media digest';      apply = { param($i) $i.MediaReference.integrity.digest = 'f' * 64 } }
        @{ field = 'media algorithm';   apply = { param($i) $i.MediaReference.integrity.algorithm = 'SHA512' } }
        @{ field = 'media edition';     apply = { param($i) $i.MediaReference.image.edition = 'Windows Pro' } }
        @{ field = 'media index';       apply = { param($i) $i.MediaReference.image.index = 4 } }
        @{ field = 'architecture';      apply = { param($i) $i.MediaReference.platform.architecture = 'arm64' } }
        @{ field = 'language';          apply = { param($i) $i.MediaReference.platform.language = 'de-DE' } }
        @{ field = 'manifest version';  apply = { param($i) $i.Manifest.schemaVersion = 3 } }
        @{ field = 'package id';        apply = { param($i) $i.Manifest.packages[0].id = 'renamed' } }
        @{ field = 'package version';   apply = { param($i) $i.Manifest.packages[0].version = '9.9.9' } }
        @{ field = 'package hash';      apply = { param($i) $i.Manifest.packages[0].source.expectedSha256 = '9' * 64 } }
        @{ field = 'package order';     apply = { param($i) $i.Manifest.packages[0].order = 15 } }
        @{ field = 'package required';  apply = { param($i) $i.Manifest.packages[0].required = $false } }
        @{ field = 'installer kind';    apply = { param($i) $i.Manifest.packages[0].installer.kind = 'exe' } }
        @{ field = 'timeout';           apply = { param($i) $i.Manifest.packages[0].installer.timeoutSeconds = 1200 } }
        @{ field = 'restart policy';    apply = { param($i) $i.Manifest.packages[0].installer.restartPolicy = 'allow-deferred' } }
        @{ field = 'MSI property';      apply = { param($i) $i.Manifest.packages[0].installer.properties = [PSCustomObject]@{ ALLUSERS = '2'; INSTALLDIR = 'C:/app' } } }
        @{ field = 'exit-code policy';  apply = { param($i) $i.Manifest.packages[1].installer.exitCodes = [PSCustomObject]@{ success = @(0, 1); restartRequired = @(3010) } } }
        @{ field = 'validation check';  apply = { param($i) $i.Manifest.packages[0].validation = @([PSCustomObject]@{ id = 'present'; type = 'file-exists'; root = 'programFiles'; relativePath = 'app/other.exe' }) } }
        @{ field = 'template digest';   apply = { param($i) $i.AnswerFile.TemplateDigest = '7' * 64 } }
        @{ field = 'declaration digest'; apply = { param($i) $i.AnswerFile.DeclarationDigest = '8' * 64 } }
        @{ field = 'image selection';   apply = { param($i) $i.AnswerFile.ImageSelection.index = 3 } }
        @{ field = 'packer config';     apply = { param($i) $i.BuildLogic.PackerConfigDigests['build.pkr.hcl'] = '4' * 64 } }
        @{ field = 'provisioning script'; apply = { param($i) $i.BuildLogic.ProvisioningScriptDigests['Invoke-GuestPhase.ps1'] = '5' * 64 } }
        @{ field = 'guest contract';    apply = { param($i) $i.BuildLogic.GuestContractVersion = 3 } }
        @{ field = 'hardware version';  apply = { param($i) $i.Hardware.HardwareVersion = 20 } }
        @{ field = 'firmware';          apply = { param($i) $i.Hardware.Firmware = 'bios' } }
        @{ field = 'secure boot';       apply = { param($i) $i.Hardware.SecureBoot = $false } }
        @{ field = 'disk controller';   apply = { param($i) $i.Hardware.DiskControllerType = 'lsilogic' } }
        @{ field = 'disk size';         apply = { param($i) $i.Hardware.DiskSizeGb = 120 } }
        @{ field = 'virtual TPM';       apply = { param($i) $i.Hardware.VirtualTpm = $false } }
        @{ field = 'packer version';    apply = { param($i) $i.Tooling.PackerVersion = '1.16.0' } }
        @{ field = 'plugin version';    apply = { param($i) $i.Tooling.PluginVersions['vsphere'] = '1.5.0' } }
    ) {
        # One case per input. A digest that ignores an input it claims to cover
        # is the failure this mechanism is most exposed to, and it is invisible
        # until two different images collide.
        $inputs = NewInputs
        & $apply $inputs
        DigestOf -Inputs $inputs | Should -Not -Be (Baseline) -Because "$field is a recipe input"
    }

    It 'gives every included field a distinct digest' {
        # Guards against two changes accidentally producing one digest, which
        # would mean a field is not reaching the document at all.
        $digests = @(
            (Baseline)
            (& { $i = NewInputs; $i.Hardware.Firmware = 'bios'; DigestOf -Inputs $i })
            (& { $i = NewInputs; $i.Hardware.SecureBoot = $false; DigestOf -Inputs $i })
            (& { $i = NewInputs; $i.Hardware.VirtualTpm = $false; DigestOf -Inputs $i })
        )
        ($digests | Sort-Object -Unique).Count | Should -Be 4
    }
}

Describe 'no excluded value changes the digest' {

    It 'ignores <field>, which describes the run rather than the image' -ForEach @(
        @{ field = 'a run identifier'; apply = { param($i) $i.MediaReference | Add-Member -NotePropertyName runId -NotePropertyValue '3f2504e0-4f89-41d3-9a0c-0305e82c3301' } }
        @{ field = 'a timestamp';      apply = { param($i) $i.MediaReference | Add-Member -NotePropertyName qualifiedUtc -NotePropertyValue '2026-01-01T00:00:00Z' } }
        @{ field = 'an observed digest'; apply = { param($i) $i.MediaReference.integrity | Add-Member -NotePropertyName observedDigest -NotePropertyValue ('a' * 64) } }
        @{ field = 'a checksum authority'; apply = { param($i) $i.MediaReference.integrity | Add-Member -NotePropertyName authority -NotePropertyValue ([PSCustomObject]@{ citation = 'https://vendor.example/x' }) } }
        @{ field = 'a datastore name'; apply = { param($i) $i.Hardware['Datastore'] = 'shared-datastore-01' } }
        @{ field = 'a cluster name';   apply = { param($i) $i.Hardware['Cluster'] = 'build-cluster' } }
        @{ field = 'a vCenter host';   apply = { param($i) $i.Tooling['VCenterHost'] = 'vcenter.example' } }
        @{ field = 'a temporary path'; apply = { param($i) $i.BuildLogic['WorkRoot'] = '/tmp/whatever' } }
        @{ field = 'a credential';     apply = { param($i) $i.Tooling['BuildPassword'] = 'Zq7-CanaryPassword-3nR' } }
        @{ field = 'a package outcome'; apply = { param($i) $i.Manifest.packages[0] | Add-Member -NotePropertyName outcome -NotePropertyValue 'passed' } }
    ) {
        # A digest including any of these would differ between two builds that
        # ought to be recognised as identical, or between two sites building the
        # same recipe -- and in the credential's case, would publish something
        # that narrows a secret.
        $inputs = NewInputs
        & $apply $inputs
        DigestOf -Inputs $inputs | Should -Be (Baseline) -Because "$field is not a recipe input"
    }

    It 'keeps a supplied credential out of the serialized document entirely' {
        # Not merely absent from the digest: absent from the document, so it
        # cannot reach provenance, a log, or a failure message.
        $inputs = NewInputs
        $inputs.Tooling['BuildPassword'] = 'Zq7-CanaryPassword-3nR'
        $document = ConvertTo-RecipeInput @inputs

        ($document | ConvertTo-Json -Depth 20) | Should -Not -Match 'Zq7-CanaryPassword-3nR'
    }
}

Describe 'a recipe cannot be partly specified' {

    It 'refuses a missing <section> input' -ForEach @(
        @{ section = 'answer file'; table = 'AnswerFile'; key = 'TemplateDigest' }
        @{ section = 'build logic'; table = 'BuildLogic'; key = 'GuestContractVersion' }
        @{ section = 'hardware';    table = 'Hardware';   key = 'Firmware' }
        @{ section = 'tooling';     table = 'Tooling';    key = 'PackerVersion' }
    ) {
        # An absent input would otherwise digest as though it did not exist,
        # which is exactly the silent collision this guards against.
        $inputs = NewInputs
        $inputs[$table].Remove($key)
        { ConvertTo-RecipeInput @inputs } | Should -Throw -ExpectedMessage "*missing '$key'*"
    }

    It 'refuses a control character anywhere in the document' {
        $inputs = NewInputs
        $inputs.MediaReference.mediaId = "windows-baseline`n"
        { ConvertTo-RecipeInput @inputs } | Should -Throw -ExpectedMessage '*control character 0x0A*'
    }
}
