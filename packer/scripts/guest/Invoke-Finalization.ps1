#Requires -Version 5.1
<#
.SYNOPSIS
    The finalizer entry point, run detached as SYSTEM.

.DESCRIPTION
    Started by the scheduled task the last WinRM operation registers, and
    running in a session that survives the removal of the listener Packer
    reached the guest through.

    Nothing here reports back over WinRM, because by design there is nothing to
    report back to. The result reaches the host through the guest RPC channel
    before the machine shuts down, and the host reads it from the platform
    afterwards.

    Windows PowerShell 5.1: the build's PowerShell 7 delivery directory is one
    of the things being cleaned up, and this runs after that.

    Never run against a machine you want to keep.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $RunId,
    [Parameter(Mandatory)] [string] $Nonce,
    [Parameter(Mandatory)] [string] $BuildUsername,
    [Parameter(Mandatory)] [string] $ToolsPath,
    [Parameter(Mandatory)] [string] $WorkspaceRoot,
    [Parameter()] [string] $SystemDrive = 'C:/',
    [Parameter()] [string] $LogPath
)

# The log lives in the workspace the finalizer removes. Everything before that
# step can write to it; nothing after can, which is why removal is second to
# last and verification reads nothing from disk.
if (-not $LogPath) { $LogPath = Join-Path $WorkspaceRoot 'finalization.log' }

$ErrorActionPreference = 'Stop'

function Write-FinalizationLog {
    <#
        Bounded, and local. Nothing written here carries a credential or a build
        path.

        The log lives in the workspace, which the finalizer removes as its
        second-to-last step. So it is what an operator has while the machine is
        still running -- which is exactly the case that matters, since a
        finalizer that refused leaves the machine up -- and it is gone by the
        time the machine becomes an image.

        A logging failure is reported and never fatal. The finalizer's job is
        the teardown, and losing a log line must not stop it half way -- but
        swallowing the reason silently would leave nothing to explain a missing
        log either.
    #>
    param([string] $Message, [string] $Path)

    $line = '{0}Z {1}' -f ([datetime]::UtcNow.ToString('s')), $Message
    try { Add-Content -LiteralPath $Path -Value $line -ErrorAction Stop }
    catch { Write-Warning ('finalization: the log could not be written -- {0}' -f $_.Exception.GetType().Name) }
    Write-Output $line
}

try {
    Import-Module (Join-Path $ToolsPath 'Finalization.psm1') -Force
    Import-Module (Join-Path $PSScriptRoot 'WindowsFinalizationAdapter.psm1') -Force

    Write-FinalizationLog -Path $LogPath -Message 'finalization: starting'

    $adapter = Get-WindowsFinalizationAdapter -BuildUsername $BuildUsername `
        -SystemDrive $SystemDrive -ToolsPath $ToolsPath -WorkspaceRoot $WorkspaceRoot

    $result = Invoke-GuestFinalization -RunId $RunId -Nonce $Nonce -Adapter $adapter

    Write-FinalizationLog -Path $LogPath -Message ('finalization: outcome {0}{1}' -f $result.Outcome,
        $(if ($result.ReasonCode) { " ($($result.ReasonCode))" } else { '' }))

    if (-not $result.SysprepInvoked) {
        # Deliberate. The machine stays powered on, and the build sees a
        # shutdown that never came -- which is the signal that something here
        # refused.
        Write-FinalizationLog -Path $LogPath -Message 'finalization: did not generalize; the machine stays running on purpose'
        exit 1
    }

    Write-FinalizationLog -Path $LogPath -Message 'finalization: generalization started; the machine will power off'
    exit 0
}
catch {
    # The message is written locally and never published: an exception quotes
    # whatever it failed on, and the attestation is a bounded document.
    Write-FinalizationLog -Path $LogPath -Message ('finalization: terminated -- {0}' -f $_.Exception.GetType().Name)
    exit 1
}
