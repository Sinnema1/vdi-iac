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

    The task is scheduled rather than started. Starting it here races this
    script: the finalizer removes the WinRM listener, and this script is still
    talking to Packer over that listener, so a fast teardown makes a correct
    build look like a transport failure. The delay is the handoff -- registered
    here, fired after this session has ended.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $RunId,
    [Parameter(Mandatory)] [string] $Nonce,
    [Parameter(Mandatory)] [string] $BuildUsername,
    [Parameter(Mandatory)] [string] $ToolsPath,
    [Parameter(Mandatory)] [string] $GuestScriptsPath,
    [Parameter(Mandatory)] [string] $WorkspaceRoot,
    [Parameter()] [string] $TaskName = 'vdi-iac-finalize',
    [Parameter()] [int] $HandoffSeconds = 120
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
    '-ToolsPath', "`"$ToolsPath`"",
    '-WorkspaceRoot', "`"$WorkspaceRoot`""
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

# A delayed trigger, not an immediate start.
#
# Starting the task here is a race: it removes the WinRM listener, and this
# script is still talking to Packer over that listener. If teardown wins, Packer
# sees the connection drop during a command that had not returned, and reports a
# transport failure for a build that was working correctly.
#
# The delay is the handoff. This script registers the task, confirms it is
# scheduled, and exits; the trigger fires afterwards, by which time Packer has
# collected this provisioner's result and closed the session it no longer needs.
$startAt = (Get-Date).AddSeconds($HandoffSeconds)
$trigger = New-ScheduledTaskTrigger -Once -At $startAt

Register-ScheduledTask -TaskName $TaskName -Action $action -Principal $principal `
    -Settings $settings -Trigger $trigger -Force | Out-Null

# Registered and scheduled, which is the whole of this script's job. It does not
# start the task, does not wait for it, and reports nothing about its outcome --
# that reaches the host through the guest RPC channel and the machine's power
# state, both read from the platform.
$task = Get-ScheduledTask -TaskName $TaskName -ErrorAction Stop
if (-not $task) { throw "The finalizer task was not registered." }

$scheduled = @($task.Triggers).Count -gt 0
if (-not $scheduled) { throw "The finalizer task has no trigger and would never run." }

Write-Output ("finalizer task '{0}' registered; it begins at {1:o} and this session ends first" -f
    $TaskName, $startAt)
