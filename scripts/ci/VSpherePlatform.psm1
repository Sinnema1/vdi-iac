#Requires -Version 7.0

<#
.SYNOPSIS
    The production vSphere operations behind the sealing adapter.

.DESCRIPTION
    The seam between the sealing coordinator and a real platform. The
    coordinator is exercised against test doubles; this is the part that cannot
    be, and none of it has run against vCenter.

    PowerCLI is not vendored and not pinned here. It is a prerequisite the entry
    point checks for, the way VMware Tools is checked in the guest, so a missing
    module is a clear refusal rather than a command-not-found part way through a
    seal.

    Credentials arrive as a PSCredential from the caller's runtime secret
    mechanism. Nothing here accepts a password as a string, writes one to a log,
    or puts one in an argument list.
#>

Set-StrictMode -Version 3.0

function Test-VSpherePrerequisite {
    <#
    .SYNOPSIS
        Confirms the platform module is available before anything is attempted.
    #>
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param([Parameter()] [string] $ModuleName = 'VMware.PowerCLI')

    $module = Get-Module -ListAvailable -Name $ModuleName | Select-Object -First 1
    if (-not $module) {
        return [PSCustomObject]@{ Satisfied = $false; ReasonCode = 'platform_module_missing'; Version = $null }
    }
    [PSCustomObject]@{ Satisfied = $true; ReasonCode = $null; Version = $module.Version.ToString() }
}

function Get-VSpherePlatformAdapter {
    <#
    .SYNOPSIS
        The sealing coordinator's platform operations, against real vCenter.

    .DESCRIPTION
        Every operation targets the machine resolved for the exact run. The
        resolver matches on a run-identifying annotation rather than on the
        name, because a name is mutable and reusable and sealing whatever
        answers to it is how one build's artifact acquires another's provenance.

    .PARAMETER EvidenceRoot
        Where host evidence is written. Writes are atomic: content goes to a
        temporary file in the same directory and is moved into place, so an
        interrupted write cannot leave a partial document that looks like a
        record.

    .PARAMETER Credential
        vCenter credential. Never logged, never placed in an argument list.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)] [ValidateNotNullOrEmpty()] [string] $Server,
        [Parameter(Mandatory)] [pscredential] $Credential,
        [Parameter(Mandatory)] [ValidateNotNullOrEmpty()] [string] $EvidenceRoot,
        [Parameter()] [string] $RunAnnotationPrefix = 'vdi-iac-run:'
    )

    $settings = @{
        Server = $Server; Credential = $Credential
        EvidenceRoot = $EvidenceRoot; AnnotationPrefix = $RunAnnotationPrefix
    }

    @{
        ResolveVirtualMachine = {
            param($RunId, $Name)
            # Name and run annotation together. The name narrows the search; the
            # annotation is what establishes identity.
            $candidates = @(Get-VM -Name $Name -Server $settings.Server -ErrorAction SilentlyContinue)
            $matching = @($candidates | Where-Object {
                $_.Notes -and $_.Notes.Contains($settings.AnnotationPrefix + $RunId)
            })
            # Exactly one, or none. Two machines claiming one run is a state
            # nothing here should resolve by picking.
            if ($matching.Count -eq 1) { $matching[0] } else { $null }
        }.GetNewClosure()

        GetPowerState = { param($Machine) [string] $Machine.PowerState }

        ReadGuestInfo = {
            param($Machine, $Key)
            $entry = Get-AdvancedSetting -Entity $Machine -Name $Key -ErrorAction SilentlyContinue
            if ($entry) { [string] $entry.Value } else { '' }
        }

        ClearGuestInfo = {
            param($Machine, $Key)
            $entry = Get-AdvancedSetting -Entity $Machine -Name $Key -ErrorAction SilentlyContinue
            if ($entry) { Remove-AdvancedSetting -AdvancedSetting $entry -Confirm:$false -ErrorAction Stop | Out-Null }
            $true
        }

        ConvertToTemplate = {
            param($Machine)
            Set-VM -VM $Machine -ToTemplate -Confirm:$false -ErrorAction Stop | Out-Null
            $true
        }

        GetArtifactIdentity = {
            param($Machine)
            $view = Get-View -Id $Machine.Id -ErrorAction Stop
            [PSCustomObject]@{
                # The instance the reference is scoped to. A managed object
                # reference means nothing without it.
                vCenterInstanceId      = (Get-View ServiceInstance -ErrorAction Stop).Content.About.InstanceUuid
                managedObjectReference = $view.MoRef.Value
                instanceUuid           = $view.Config.InstanceUuid
                recordedName           = $view.Name
            }
        }

        WriteHostEvidence = {
            param($Name, $Content)
            # Atomic: written beside the target and moved into place. A partial
            # document that survived an interruption would be worse than none,
            # because it would look like a record.
            $target = Join-Path $settings.EvidenceRoot $Name
            $staging = "$target.$([guid]::NewGuid().ToString('n')).partial"
            try {
                Set-Content -LiteralPath $staging -Value $Content -Encoding utf8 -NoNewline -ErrorAction Stop
                Move-Item -LiteralPath $staging -Destination $target -Force -ErrorAction Stop
                $true
            }
            catch {
                Remove-Item -LiteralPath $staging -Force -ErrorAction SilentlyContinue
                $false
            }
        }.GetNewClosure()

        ReadHostEvidence = {
            param($Name)
            $target = Join-Path $settings.EvidenceRoot $Name
            if (Test-Path -LiteralPath $target -PathType Leaf) {
                Get-Content -LiteralPath $target -Raw -Encoding utf8
            }
            else { $null }
        }.GetNewClosure()
    }
}

Export-ModuleMember -Function Test-VSpherePrerequisite, Get-VSpherePlatformAdapter
