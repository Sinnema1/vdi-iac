#Requires -Version 5.1
<#
.SYNOPSIS
    Registers and starts the detached finalizer, then returns.

.DESCRIPTION
    The last operation Packer performs over WinRM. It hands the terminal
    transition to a scheduled task running as SYSTEM and returns immediately, so
    the connection this command arrived on is not the connection the teardown
    destroys.

    Nothing may be scheduled after this. The finalizer removes the WinRM
    listener, so a later provisioner has nothing to connect to -- that is a
    design error rather than a timeout to tune.

    This does not wait for the finalizer, and deliberately reports nothing about
    its outcome. The outcome reaches the host through the guest RPC channel and
    the machine's power state, both read from the platform.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $RunId,
    [Parameter(Mandatory)] [string] $Nonce,
    [Parameter(Mandatory)] [string] $BuildUsername,
    [Parameter(Mandatory)] [string] $ToolsPath,
    [Parameter(Mandatory)] [string] $GuestScriptsPath,
    [Parameter()] [string] $TaskName = 'vdi-iac-finalize'
)

$ErrorActionPreference = 'Stop'

$finalizer = Join-Path $GuestScriptsPath 'Invoke-Finalization.ps1'
if (-not (Test-Path -LiteralPath $finalizer -PathType Leaf)) {
    throw "The finalizer script was not delivered: $finalizer"
}

# The nonce is an argument rather than an environment variable because a
# scheduled task does not inherit this session's environment. It is not a
# credential: it is a value the host generated to recognise its own run, and it
# is published in the attestation anyway.
$arguments = @(
    '-NoProfile', '-ExecutionPolicy', 'Bypass', '-NonInteractive',
    '-File', "`"$finalizer`"",
    '-RunId', $RunId,
    '-Nonce', $Nonce,
    '-BuildUsername', $BuildUsername,
    '-ToolsPath', "`"$ToolsPath`""
) -join ' '

$action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument $arguments

# SYSTEM, so the task is not tied to the build account this run is about to
# disable, and highest privileges, because it edits WinRM configuration and runs
# Sysprep.
$principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest

# No execution time limit: Sysprep decides when this ends by powering the
# machine off, and a task the scheduler kills part way through would leave the
# guest in exactly the half-torn-down state everything else here avoids.
$settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries `
    -DontStopIfGoingOnBatteries -ExecutionTimeLimit ([TimeSpan]::Zero)

Register-ScheduledTask -TaskName $TaskName -Action $action -Principal $principal `
    -Settings $settings -Force | Out-Null

Start-ScheduledTask -TaskName $TaskName

# Confirmed as started, not as finished. Waiting for completion would mean
# waiting for a machine that powers itself off, and this session dies with the
# listener long before that.
$state = (Get-ScheduledTask -TaskName $TaskName).State
Write-Output "finalizer task '$TaskName' state: $state"

if ($state -eq 'Ready') {
    # Ready means it is registered and not running: it either finished
    # instantly or never started, and neither is what launching it should look
    # like.
    throw "The finalizer task did not start; it is '$state'."
}
