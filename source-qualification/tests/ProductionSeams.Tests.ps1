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
        @{ file = 'scripts/ci/Invoke-ImageBuild.ps1' }
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
                               'RemoveFirewallRule', 'RemoveCertificate', 'UnregisterTask',
                               'RemoveWorkspace', 'Verify', 'PublishAttestation', 'InvokeSysprep') {
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

    It 'removes the build access Sysprep leaves behind' {
        # Sysprep removes none of these. A generalized image carrying the
        # private key of a listener it used to run ships with the means to
        # impersonate one; the finalizer's own task would run as SYSTEM at every
        # boot naming a script that no longer exists; and the workspace holds
        # the scripts, contracts, evidence, and log.
        $script:AdapterCode | Should -Match 'DeleteKey'
        $script:AdapterCode | Should -Match 'Unregister-ScheduledTask'
        $script:AdapterCode | Should -Match 'Remove-Item -LiteralPath \$settings\.WorkspaceRoot'
    }

    It 'verifies the whole teardown, not the parts it removed last' {
        # Each step confirmed itself; this asks whether they are all still true
        # together, which is the claim the attestation makes.
        foreach ($condition in 'winrmStopped', 'firewall', 'certificate', 'task', 'workspace', 'disabled') {
            $script:AdapterCode | Should -Match "\`$$condition\s*=" -Because "verification must cover $condition"
        }
    }

    It 'reads nothing from the workspace during verification' {
        # The workspace has just been removed. A verification that needed it
        # could never run.
        $verify = [regex]::Match($script:AdapterCode, '(?s)Verify\s*=\s*\{.*?\}\.GetNewClosure\(\)')
        $verify.Success | Should -BeTrue
        $verify.Value | Should -Not -Match 'ToolsPath'
        $verify.Value | Should -Not -Match 'Import-Module'
    }

    It 'never queries Win32_Product' {
        # Querying it makes Windows Installer walk every installed MSI and can
        # trigger a reconfiguration of products it finds inconsistent -- a
        # repair pass nobody asked for, during a prerequisite check.
        $script:AdapterCode | Should -Not -Match 'Win32_Product'
    }

    It 'reads the Tools version from one defined source' {
        $script:AdapterCode | Should -Match 'VersionInfo\.FileVersion'
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

    It 'schedules the task instead of starting it' {
        # Starting it here races this script: the finalizer removes the WinRM
        # listener, and this script is still talking to Packer over it, so a
        # fast teardown makes a correct build look like a transport failure.
        $script:Launcher | Should -Match 'New-ScheduledTaskTrigger -Once -At'
        $script:Launcher | Should -Not -Match 'Start-ScheduledTask'
    }

    It 'gives the handoff a delay this session can finish inside' {
        $script:Launcher | Should -Match '\$HandoffSeconds = 120'
        $script:Launcher | Should -Match 'AddSeconds\(\$HandoffSeconds\)'
    }

    It 'does not wait for the finalizer' {
        $script:Launcher | Should -Not -Match 'Wait-Job|Wait-Process|while \('
    }

    It 'fails when the task was registered without a trigger' {
        # A task with no trigger is registered and would never run, which looks
        # like success and produces a build that waits for a shutdown nothing
        # will perform.
        $script:Launcher | Should -Match '\$scheduled = @\(\$task\.Triggers\)\.Count -gt 0'
        $script:Launcher | Should -Match 'would never run'
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

Describe 'the host orchestration entry point' {

    BeforeAll {
        $script:Entry = CodeOf -Path (Join-Path $script:CiScripts 'Invoke-ImageBuild.ps1')
    }

    It 'invokes packer and captures the exit code itself' {
        # A script that accepts "the build succeeded" as a parameter will
        # eventually be handed that value by something that did not check.
        $script:Entry | Should -Match '& packer @arguments'
        $script:Entry | Should -Match '\$packerExitCode = \$LASTEXITCODE'
    }

    It 'accepts no build result, provenance, or identity from its caller' {
        # The previous seam let a caller assert every fact the seal reports.
        foreach ($forbidden in 'PackerExitCode', 'PackerSucceeded', 'RecipeDigest',
                               'RecipeInputVersion', 'ManifestSchemaVersion', 'MediaId',
                               'StartedUtc', '\$RunId', '\$Nonce') {
            $parameters = [regex]::Match($script:Entry, '(?s)^param\((?<p>.*?)^\)', 'Multiline')
            $parameters.Groups['p'].Value | Should -Not -Match $forbidden `
                -Because "$forbidden must be derived, not supplied"
        }
    }

    It 'generates and records the run identity before anything runs' {
        # A run that crashes before its first provisioner still leaves a record
        # of what it was.
        $script:Entry | Should -Match '\$runId = Get-RunIdentifier'
        $script:Entry | Should -Match '\$nonce = Get-FinalizationNonce'
        $script:Entry | Should -Match "Set-Content -LiteralPath \(Join-Path \`$runRoot 'run.json'\)"
    }

    It 'computes the recipe digest rather than accepting one' {
        # A supplied digest is a claim about inputs nobody re-read.
        $script:Entry | Should -Match 'ConvertTo-RecipeInput'
        $script:Entry | Should -Match 'Get-RecipeDigest -RecipeInput \$recipe'
    }

    It 'qualifies and re-verifies the media itself' {
        $script:Entry | Should -Match 'Invoke-MediaQualification'
        $script:Entry | Should -Match 'Assert-QualifiedMedia'
    }

    It 'checks the tooling version agrees before building' {
        $script:Entry | Should -Match 'Test-ToolsVersionAgreement'
    }

    It 'reads the phase evidence the build downloaded' {
        # A hard-coded list of passed phases asserted the thing the seal exists
        # to establish.
        $script:Entry | Should -Match 'Read-BuildPhaseEvidence'
        $script:Entry | Should -Not -Match "outcome = 'passed' \}"
    }

    It 'derives success from the exit code it captured' {
        $script:Entry | Should -Match '-PackerSucceeded \(\$packerExitCode -eq 0\)'
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

Describe 'the run annotation the builder writes and the resolver expects' {

    BeforeAll {
        $script:BuildConfig = CodeOf -Path (Join-Path $script:RepoRoot 'packer' 'builds' 'windows-image.pkr.hcl')
        $script:PlatformCode = CodeOf -Path (Join-Path $script:CiScripts 'VSpherePlatform.psm1')

        # The prefix each side uses, read from each side rather than restated
        # here. A constant written into this test would agree with itself while
        # the two implementations drifted apart.
        $script:BuilderNote = ([regex]::Match($script:BuildConfig, 'notes\s*=\s*"(?<v>[^"]+)"')).Groups['v'].Value
        $script:ResolverPrefix = ([regex]::Match($script:PlatformCode,
            "RunAnnotationPrefix\s*=\s*'(?<v>[^']+)'")).Groups['v'].Value
    }

    It 'the builder writes an annotation at all' {
        # Without this the resolver searches for something nothing ever sets,
        # and every seal fails to find the machine it just built.
        $script:BuilderNote | Should -Not -BeNullOrEmpty
    }

    It 'the resolver declares the prefix it searches for' {
        $script:ResolverPrefix | Should -Not -BeNullOrEmpty
    }

    It 'produces exactly the string the resolver requires' {
        # The end-to-end check: substitute a run identifier into the builder's
        # template and into the resolver's construction, and require the two to
        # be the same string. Anything else -- a stray space, a different
        # separator, a prefix that drifted -- makes the seal unable to find a
        # machine that exists.
        $runId = '3f2504e0-4f89-41d3-9a0c-0305e82c3301'

        $written = $script:BuilderNote -replace '\$\{var\.run_id\}', $runId
        $expected = $script:ResolverPrefix + $runId

        $written | Should -Be $expected
    }

    It 'compares the annotation exactly rather than by substring' {
        # A substring match would accept a note that merely mentions the run --
        # including one naming several runs, or a longer identifier this one is
        # a prefix of.
        $script:PlatformCode | Should -Match '\[string\]::Equals\(\$_\.Notes\.Trim\(\), \$expected'
        $script:PlatformCode | Should -Not -Match '\$_\.Notes\.Contains'
    }

    It 'carries no value beyond the run identity' {
        # The note is an identifier, not a description. Anything else in it
        # would have to survive an exact comparison, and would be published on
        # the artifact.
        $script:BuilderNote | Should -Match '^[a-z-]+:\$\{var\.run_id\}$'
    }
}

Describe 'removable media does not travel into the image' {

    It 'detaches the CD before the artifact is accepted' {
        # The OEMDRV volume carries the rendered answer file, which holds a
        # working credential. Neither it nor the installation media belongs
        # attached to a machine about to become an image.
        $build = CodeOf -Path (Join-Path $script:RepoRoot 'packer' 'builds' 'windows-image.pkr.hcl')
        $build | Should -Match 'remove_cdrom\s*=\s*true'
    }
}

Describe 'the attestation contract version' {

    It 'leaves version 1 byte-stable' {
        # A published contract version is never edited in place, so version 2 is
        # a new file and version 1 keeps validating what it always validated.
        (Get-FileHash -LiteralPath (Join-Path $script:RepoRoot 'contracts' 'finalization-attestation-1.schema.json') `
            -Algorithm SHA256).Hash.ToLowerInvariant() |
            Should -Be '53d5d4b7ae01dae102fc3786fd2887ae2d0c08b53605ca18054bcab64b496f29'
    }

    It 'version 2 knows the steps version 1 did not' {
        $v1 = Get-Content -LiteralPath (Join-Path $script:RepoRoot 'contracts' 'finalization-attestation-1.schema.json') -Raw | ConvertFrom-Json
        $v2 = Get-Content -LiteralPath (Join-Path $script:RepoRoot 'contracts' 'finalization-attestation-2.schema.json') -Raw | ConvertFrom-Json

        foreach ($step in 'certificate-removed', 'task-unregistered', 'workspace-removed') {
            $v2.properties.steps.items.properties.name.enum | Should -Contain $step
            $v1.properties.steps.items.properties.name.enum | Should -Not -Contain $step
        }
    }

    It 'version 2 declares its own version' {
        $v2 = Get-Content -LiteralPath (Join-Path $script:RepoRoot 'contracts' 'finalization-attestation-2.schema.json') -Raw | ConvertFrom-Json
        $v2.properties.attestationSchemaVersion.const | Should -Be 2
    }
}
