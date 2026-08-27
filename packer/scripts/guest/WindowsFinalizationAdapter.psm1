#Requires -Version 5.1

<#
.SYNOPSIS
    The production Windows implementations behind the finalization adapters.

.DESCRIPTION
    Every operation the finalizer performs against a real guest, and nothing
    else. The orchestration lives in Finalization.psm1 and is exercised against
    test doubles; this is the part that cannot be, and none of it has run
    against a real Windows guest.

    Windows PowerShell 5.1, deliberately. This runs from a scheduled task on a
    machine that is about to be generalized, and PowerShell 7 is not guaranteed
    to be there -- it is delivered by the build, and the build's delivery
    directory is one of the things being cleaned up.

    No VMware binary is committed. The RPC tool is located where Tools installs
    it, and its absence is reported rather than worked around.
#>

Set-StrictMode -Version 2.0

# Where VMware Tools puts its command-line interface on Windows. rpctool.exe is
# the current name; vmtoolsd.exe --cmd is the older path and is still present on
# builds that predate it. Both are tried, in that order, and neither is shipped
# here.
$script:ToolsCommandCandidates = @(
    @{ Path = 'C:\Program Files\VMware\VMware Tools\rpctool.exe';  Arguments = @() }
    @{ Path = 'C:\Program Files\VMware\VMware Tools\vmtoolsd.exe'; Arguments = @('--cmd') }
)

function Resolve-ToolsCommand {
    <#
        Returns the first present interface, or null. Callers treat null as
        terminal rather than falling back to anything.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param()

    foreach ($candidate in $script:ToolsCommandCandidates) {
        if (Test-Path -LiteralPath $candidate.Path -PathType Leaf) { return $candidate }
    }
    $null
}

function Invoke-ToolsRpc {
    <#
        Runs one RPC command. The value is passed as a single argument rather
        than through a shell, so nothing in it is interpreted.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)] [string] $Command)

    $tool = Resolve-ToolsCommand
    if (-not $tool) { throw 'The VMware Tools RPC interface was not found.' }

    $arguments = @($tool.Arguments) + @($Command)
    $output = & $tool.Path @arguments 2>&1
    if ($LASTEXITCODE -ne 0) { throw "The VMware Tools RPC command failed with exit code $LASTEXITCODE." }
    ($output | Out-String).Trim()
}

function Get-WindowsToolsAdapter {
    <#
    .SYNOPSIS
        The VMware Tools prerequisite checks, against a real guest.

    .DESCRIPTION
        Version comes from the installed product rather than from the RPC
        interface, because the interface answering does not establish which
        build is installed -- and the version is a recipe input.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param()

    @{
        GetToolsVersion = {
            # One defined source: the daemon binary's own file version.
            #
            # Win32_Product is not used and must not be reintroduced. Querying
            # it makes Windows Installer walk every installed MSI and can
            # trigger a reconfiguration of products it finds inconsistent --
            # on a machine mid-build, that is a repair pass nobody asked for
            # during a prerequisite check.
            $tool = Resolve-ToolsCommand
            if (-not $tool) { throw 'VMware Tools is not installed.' }
            [string] (Get-Item -LiteralPath $tool.Path).VersionInfo.FileVersion
        }
        GetToolsRunning = {
            $service = Get-Service -Name 'VMTools' -ErrorAction SilentlyContinue
            $null -ne $service -and $service.Status -eq 'Running'
        }
    }
}

function Get-WindowsFinalizationAdapter {
    <#
    .SYNOPSIS
        The terminal transition's operations, against a real guest.

    .DESCRIPTION
        Each returns true only on affirmative confirmation. A step that cannot
        establish it worked reports false, and the finalizer then refuses to
        shut down -- which is the behaviour that keeps a failed finalization
        visible as a machine still running.

    .PARAMETER BuildUsername
        The account the answer file configured, disabled here.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)] [string] $BuildUsername,
        [Parameter(Mandatory)] [string] $SystemDrive,
        [Parameter(Mandatory)] [string] $ToolsPath,
        [Parameter(Mandatory)] [string] $WorkspaceRoot,
        [Parameter()] [string] $TaskName = 'vdi-iac-finalize',
        [Parameter()] [string] $CertificateSubject = $env:COMPUTERNAME
    )

    # Captured into one object the closures read from. A parameter referenced
    # only inside a closure is invisible to static analysis, and the assignment
    # is the form it can see -- the same shape the test doubles use.
    $settings = @{
        BuildUsername = $BuildUsername
        SystemDrive   = $SystemDrive
        ToolsPath     = $ToolsPath
        WorkspaceRoot = $WorkspaceRoot
        TaskName      = $TaskName
        CertSubject   = $CertificateSubject
        FirewallRule  = 'WinRM HTTPS (build)'
    }

    @{
        ConfirmResidueAbsent = {
            Import-Module (Join-Path $settings.ToolsPath 'AnswerFile.psm1') -Force
            @(Get-SetupResidue -SystemDrive $settings.SystemDrive).Count -eq 0
        }.GetNewClosure()

        DisableAccount = {
            # Disabled rather than deleted: the account is built in, and
            # removing it is not something a generalized image should carry.
            & net.exe user $settings.BuildUsername /active:no | Out-Null
            $account = Get-CimInstance -ClassName Win32_UserAccount -Filter "Name='$($settings.BuildUsername)'" -ErrorAction SilentlyContinue
            $null -ne $account -and $account.Disabled
        }.GetNewClosure()

        RemoveListener = {
            Get-ChildItem -Path 'WSMan:\localhost\Listener' -ErrorAction SilentlyContinue |
                ForEach-Object { Remove-Item -Path $_.PSPath -Recurse -Force -ErrorAction SilentlyContinue }
            Set-Service -Name WinRM -StartupType Disabled -ErrorAction SilentlyContinue
            Stop-Service -Name WinRM -Force -ErrorAction SilentlyContinue

            # Confirmed by re-reading. A removal that reported success while a
            # listener survived would ship an image with a way in.
            @(Get-ChildItem -Path 'WSMan:\localhost\Listener' -ErrorAction SilentlyContinue).Count -eq 0
        }.GetNewClosure()

        RemoveFirewallRule = {
            # Object-based, not netsh text. Matching the English phrase 'No
            # rules match' reports the rule as removed on any machine that
            # answers in another language, which is the kind of check that
            # passes everywhere it was written and fails where it is deployed.
            Get-NetFirewallRule -DisplayName $settings.FirewallRule -ErrorAction SilentlyContinue |
                Remove-NetFirewallRule -ErrorAction SilentlyContinue

            $null -eq (Get-NetFirewallRule -DisplayName $settings.FirewallRule -ErrorAction SilentlyContinue)
        }.GetNewClosure()

        RemoveCertificate = {
            # The listener's certificate and its private key. A generalized
            # image carrying the private key of a listener it used to run is an
            # image that ships with the means to impersonate one, and Sysprep
            # removes neither.
            Get-ChildItem -Path 'Cert:\LocalMachine\My' -ErrorAction SilentlyContinue |
                Where-Object { $_.Subject -eq "CN=$($settings.CertSubject)" } |
                ForEach-Object { Remove-Item -Path $_.PSPath -DeleteKey -Force -ErrorAction SilentlyContinue }

            $remaining = @(Get-ChildItem -Path 'Cert:\LocalMachine\My' -ErrorAction SilentlyContinue |
                Where-Object { $_.Subject -eq "CN=$($settings.CertSubject)" })
            $remaining.Count -eq 0
        }.GetNewClosure()

        UnregisterTask = {
            # The finalizer's own task. It is still running this code, and
            # unregistering a running task is permitted -- what would not be is
            # leaving it in the image, where it would name a script that no
            # longer exists and run as SYSTEM at every boot.
            Unregister-ScheduledTask -TaskName $settings.TaskName -Confirm:$false -ErrorAction SilentlyContinue
            $null -eq (Get-ScheduledTask -TaskName $settings.TaskName -ErrorAction SilentlyContinue)
        }.GetNewClosure()

        RemoveWorkspace = {
            # Scripts, contracts, retrieved evidence, and the finalization log.
            # None of it belongs in an image, and the log is the last thing to
            # go because everything before this point may need to write to it.
            Remove-Item -LiteralPath $settings.WorkspaceRoot -Recurse -Force -ErrorAction SilentlyContinue
            -not (Test-Path -LiteralPath $settings.WorkspaceRoot)
        }.GetNewClosure()

        Verify = {
            # The whole state, re-read once more. Each step confirmed itself;
            # this asks whether they are all still true together, which is the
            # claim the attestation makes.
            #
            # Nothing here reads from the workspace: it has just been removed,
            # and a verification that needed it could never run. The residue
            # paths are the ones Windows Setup writes, which is why they can
            # still be checked.
            $residuePaths = @(
                '$Windows.~BT/Sources/Panther/unattend.xml'
                'Windows/Panther/unattend.xml'
                'Windows/Panther/unattend.orig.xml'
                'Windows/System32/Sysprep/unattend.xml'
                'Windows/Panther/Unattend/unattend.xml'
            )
            $residue = @($residuePaths |
                ForEach-Object { Join-Path $settings.SystemDrive $_ } |
                Where-Object { Test-Path -LiteralPath $_ -PathType Leaf }).Count -eq 0

            $listeners = @(Get-ChildItem -Path 'WSMan:\localhost\Listener' -ErrorAction SilentlyContinue).Count -eq 0
            $service = Get-Service -Name WinRM -ErrorAction SilentlyContinue
            $winrmStopped = $null -eq $service -or
                ($service.Status -ne 'Running' -and $service.StartType -eq 'Disabled')

            $firewall = $null -eq (Get-NetFirewallRule -DisplayName $settings.FirewallRule -ErrorAction SilentlyContinue)

            $certificate = @(Get-ChildItem -Path 'Cert:\LocalMachine\My' -ErrorAction SilentlyContinue |
                Where-Object { $_.Subject -eq "CN=$($settings.CertSubject)" }).Count -eq 0

            $task = $null -eq (Get-ScheduledTask -TaskName $settings.TaskName -ErrorAction SilentlyContinue)
            $workspace = -not (Test-Path -LiteralPath $settings.WorkspaceRoot)

            $account = Get-CimInstance -ClassName Win32_UserAccount -Filter "Name='$($settings.BuildUsername)'" -ErrorAction SilentlyContinue
            $disabled = $null -ne $account -and $account.Disabled

            $residue -and $listeners -and $winrmStopped -and $firewall -and
                $certificate -and $task -and $workspace -and $disabled
        }.GetNewClosure()

        PublishAttestation = {
            param($Key, $Json)
            # info-set writes a guestinfo value readable from the platform after
            # the guest is gone. The value is passed as one argument; nothing
            # in it reaches a shell.
            $null = Invoke-ToolsRpc -Command ("info-set {0} {1}" -f $Key, $Json)

            # Read back. A publish that reported success without storing the
            # value would leave the sealing phase refusing a machine that had
            # actually finished.
            $stored = Invoke-ToolsRpc -Command ("info-get {0}" -f $Key)
            $stored -eq $Json
        }.GetNewClosure()

        InvokeSysprep = {
            # /shutdown, not /reboot: the machine must power off, and Packer is
            # waiting for exactly that.
            $sysprep = Join-Path $env:SystemRoot 'System32\Sysprep\Sysprep.exe'
            if (-not (Test-Path -LiteralPath $sysprep -PathType Leaf)) { return $false }

            Start-Process -FilePath $sysprep `
                -ArgumentList '/generalize', '/oobe', '/shutdown', '/quiet' -NoNewWindow
            # Started, not finished: it powers the machine off, so there is
            # nothing to wait for and nothing to report afterwards.
            $true
        }.GetNewClosure()
    }
}

Export-ModuleMember -Function Resolve-ToolsCommand, Invoke-ToolsRpc,
    Get-WindowsToolsAdapter, Get-WindowsFinalizationAdapter
