#Requires -Version 7.0

# The production seams: the Windows guest adapters, the vSphere platform
# adapter, and the sealing entry point. None of these can be executed here --
# they talk to VMware Tools, WinRM, Sysprep, and vCenter -- so what is asserted
# is their shape, their contracts, and the properties that must hold before any
# of them is pointed at a real machine.

BeforeAll {
    $script:RepoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    $script:GuestScripts = Join-Path $script:RepoRoot 'packer' 'scripts' 'guest'
    $script:CiScripts = Join-Path $script:RepoRoot 'scripts' 'ci'

    function ParsedFile {
        param([string] $Path)
        $errors = $null
        $null = [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref] $null, [ref] $errors)
        $errors
    }

    function CodeOf {
        param([string] $Path)
        (Get-Content -LiteralPath $Path | Where-Object { $_.TrimStart() -notlike '#*' }) -join "`n"
    }
}

Describe 'the production files parse' {

    It '<file> has no syntax errors' -ForEach @(
        @{ file = 'packer/scripts/guest/WindowsFinalizationAdapter.psm1' }
        @{ file = 'packer/scripts/guest/Invoke-Finalization.ps1' }
        @{ file = 'packer/scripts/guest/Start-DetachedFinalizer.ps1' }
        @{ file = 'scripts/ci/VSpherePlatform.psm1' }
        @{ file = 'scripts/ci/Invoke-Sealing.ps1' }
    ) {
        # These cannot be executed here, so parsing is the only check that they
        # are code at all rather than plausible-looking text.
        ParsedFile -Path (Join-Path $script:RepoRoot $file) | Should -BeNullOrEmpty
    }
}

Describe 'the Windows guest adapter' {

    BeforeAll {
        $script:Adapter = Join-Path $script:GuestScripts 'WindowsFinalizationAdapter.psm1'
        $script:AdapterCode = CodeOf -Path $script:Adapter
    }

    It 'supplies every operation the finalizer invokes' {
        # A missing member is a runtime failure on a machine that is about to
        # generalize itself, which is the worst possible place to discover it.
        foreach ($operation in 'ConfirmResidueAbsent', 'DisableAccount', 'RemoveListener',
                               'RemoveFirewallRule', 'Verify', 'PublishAttestation', 'InvokeSysprep') {
            $script:AdapterCode | Should -Match "$operation\s*=" -Because "the finalizer calls $operation"
        }
    }

    It 'supplies every fact the Tools prerequisite asks for' {
        foreach ($fact in 'GetToolsVersion', 'GetToolsRunning') {
            $script:AdapterCode | Should -Match "$fact\s*="
        }
    }

    It 'uses the supported Windows Tools command paths' {
        # rpctool.exe is current; vmtoolsd.exe --cmd is the older path and is
        # still present on builds that predate it. vmware-rpctool is the Linux
        # name and is not what this uses.
        $script:AdapterCode | Should -Match 'rpctool\.exe'
        $script:AdapterCode | Should -Match 'vmtoolsd\.exe'
        $script:AdapterCode | Should -Not -Match 'vmware-rpctool'
    }

    It 'confirms the publish by reading the value back' {
        # A publish that reported success without storing the value would leave
        # the sealing phase refusing a machine that had actually finished.
        $script:AdapterCode | Should -Match 'info-set'
        $script:AdapterCode | Should -Match 'info-get'
    }

    It 'generalizes with a shutdown rather than a reboot' {
        # The build is waiting for a power-off. A reboot would satisfy nothing
        # and leave the machine running.
        $script:AdapterCode | Should -Match "'/generalize', '/oobe', '/shutdown'"
        $script:AdapterCode | Should -Not -Match '/reboot'
    }

    It 'confirms teardown by re-reading rather than by return codes' {
        # netsh and net report their own success; what matters is whether the
        # listener and the account are actually gone.
        $script:AdapterCode | Should -Match ([regex]::Escape("Get-ChildItem -Path 'WSMan:\localhost\Listener'"))
        $script:AdapterCode | Should -Match 'Win32_UserAccount'
    }

    It 'commits no vendor binary' {
        # The tool is located where Tools installs it; its absence is reported
        # rather than worked around.
        Test-Path -LiteralPath (Join-Path $script:GuestScripts 'rpctool.exe') | Should -BeFalse
        Test-Path -LiteralPath (Join-Path $script:GuestScripts 'vmtoolsd.exe') | Should -BeFalse
    }
}

Describe 'the detached launcher' {

    BeforeAll {
        $script:Launcher = CodeOf -Path (Join-Path $script:GuestScripts 'Start-DetachedFinalizer.ps1')
    }

    It 'runs the task as SYSTEM' {
        # Not as the build account: this run is about to disable it.
        $script:Launcher | Should -Match "UserId 'SYSTEM'"
        $script:Launcher | Should -Match 'RunLevel Highest'
    }

    It 'places no time limit on the task' {
        # Sysprep decides when this ends by powering the machine off. A task the
        # scheduler killed part way would leave the guest half torn down.
        $script:Launcher | Should -Match 'ExecutionTimeLimit \(\[TimeSpan\]::Zero\)'
    }

    It 'starts the task and does not wait for it' {
        $script:Launcher | Should -Match 'Start-ScheduledTask'
        $script:Launcher | Should -Not -Match 'Wait-Job|Wait-Process|while \('
    }

    It 'fails when the task did not start' {
        # Registered but not running means it either finished instantly or never
        # started, and neither is what launching it should look like.
        $script:Launcher | Should -Match "if \(\`$state -eq 'Ready'\)"
        $script:Launcher | Should -Match 'throw'
    }

    It 'carries no credential into the task arguments' {
        # A scheduled task's arguments are readable by anything that can read
        # the task. The nonce is not a credential; a password would be.
        $script:Launcher | Should -Not -Match 'Password|password'
    }
}

Describe 'the vSphere platform adapter' {

    BeforeAll {
        $script:Platform = CodeOf -Path (Join-Path $script:CiScripts 'VSpherePlatform.psm1')
    }

    It 'supplies every operation the coordinator invokes' {
        foreach ($operation in 'ResolveVirtualMachine', 'GetPowerState', 'ReadGuestInfo', 'ClearGuestInfo',
                               'ConvertToTemplate', 'GetArtifactIdentity', 'WriteHostEvidence', 'ReadHostEvidence') {
            $script:Platform | Should -Match "$operation\s*=" -Because "the coordinator calls $operation"
        }
    }

    It 'resolves by run annotation, not by name alone' {
        # A name is mutable and reusable, and sealing whatever answers to it is
        # how one build's artifact acquires another build's provenance.
        $script:Platform | Should -Match 'AnnotationPrefix'
        $script:Platform | Should -Match '\$matching\.Count -eq 1'
    }

    It 'refuses to choose when two machines claim one run' {
        $script:Platform | Should -Match 'else \{ \$null \}'
    }

    It 'writes host evidence atomically' {
        # A partial document that survived an interruption would be worse than
        # none, because it would look like a record.
        $script:Platform | Should -Match 'partial'
        $script:Platform | Should -Match 'Move-Item'
    }

    It 'removes the staging file when an atomic write fails' {
        $script:Platform | Should -Match 'Remove-Item -LiteralPath \$staging'
    }

    It 'scopes the artifact identity to its vCenter instance' {
        # A managed object reference means nothing without the instance it is
        # unique within.
        $script:Platform | Should -Match 'InstanceUuid'
        $script:Platform | Should -Match 'MoRef\.Value'
    }

    It 'takes a credential object rather than a password string' {
        $script:Platform | Should -Match '\[pscredential\] \$Credential'
        $script:Platform | Should -Not -Match '\[string\] \$Password'
    }
}

Describe 'the sealing entry point' {

    BeforeAll {
        $script:Entry = CodeOf -Path (Join-Path $script:CiScripts 'Invoke-Sealing.ps1')
    }

    It 'derives success from the Packer exit code' {
        # A wrapper passing a flag would let a failed build be sealed by a
        # script that forgot to check.
        $script:Entry | Should -Match '\$packerSucceeded = \(\$PackerExitCode -eq 0\)'
        $script:Entry | Should -Not -Match '\[bool\] \$PackerSucceeded'
    }

    It 'takes the password from the environment, never a parameter' {
        # A parameter is visible to anything enumerating processes and lands in
        # shell history.
        $script:Entry | Should -Match '\$env:VDIIAC_VCENTER_PASSWORD'
        $script:Entry | Should -Not -Match '\$VCenterPassword'
    }

    It 'clears the secret from the process and the environment' {
        $script:Entry | Should -Match 'Remove-Variable -Name secret'
        $script:Entry | Should -Match '\$env:VDIIAC_VCENTER_PASSWORD = \$null'
    }

    It 'checks the platform module before attempting anything' {
        $script:Entry | Should -Match 'Test-VSpherePrerequisite'
    }

    It 'exits non-zero when evidence could not be persisted' {
        # Worse than a failed seal: nothing durable records what happened, so
        # nothing downstream can reconcile whatever exists on the platform.
        $script:Entry | Should -Match 'if \(-not \$result\.EvidencePersisted\)'
        $script:Entry | Should -Match 'exit 3'
    }

    It 'exits zero only for a sealed candidate' {
        $script:Entry | Should -Match "if \(\`$result\.BuildState -eq 'sealed'\)"
        ([regex]::Matches($script:Entry, '(?m)^exit 0$')).Count | Should -Be 0
    }
}
