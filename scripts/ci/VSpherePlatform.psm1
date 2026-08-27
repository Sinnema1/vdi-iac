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

function Connect-VSpherePlatform {
    <#
    .SYNOPSIS
        Establishes the authenticated session every operation runs inside.

    .DESCRIPTION
        Without this the credential is constructed and never used, and every
        PowerCLI call runs against whatever ambient session happens to exist --
        or none. -NotDefault keeps it out of the global default list, so a
        session opened here cannot be picked up implicitly by something else.

        Certificate handling is an explicit argument rather than a default. It
        has to agree with the connection setting the build itself used: a build
        that accepted an unverified certificate and a seal that refuses one
        describe two different trust decisions about the same platform.

    .OUTPUTS
        The connection. Callers close it in a finally block.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [ValidateNotNullOrEmpty()] [string] $Server,
        [Parameter(Mandatory)] [pscredential] $Credential,
        [Parameter(Mandatory)] [bool] $InsecureConnection
    )

    $action = if ($InsecureConnection) { 'Ignore' } else { 'Fail' }
    Set-PowerCLIConfiguration -InvalidCertificateAction $action -Scope Session -Confirm:$false | Out-Null

    Connect-VIServer -Server $Server -Credential $Credential -NotDefault -ErrorAction Stop
}

function Disconnect-VSpherePlatform {
    <#
        Closes the session. Never throws: it runs in a finally block, and an
        exception here would replace whatever failure is already being reported.
    #>
    [CmdletBinding()]
    param([Parameter()] $Connection)

    if (-not $Connection) { return }
    try { Disconnect-VIServer -Server $Connection -Confirm:$false -ErrorAction Stop | Out-Null }
    catch { Write-Warning ('the vCenter session could not be closed: {0}' -f $_.Exception.GetType().Name) }
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
        [Parameter(Mandatory)] $Connection,
        [Parameter(Mandatory)] [ValidateNotNullOrEmpty()] [string] $EvidenceRoot,
        [Parameter()] [string] $RunAnnotationPrefix = 'vdi-iac-run:'
    )

    # Every operation runs against this connection explicitly. Passing a server
    # name instead would let a call resolve to some other session, and the whole
    # point of resolving the machine by run identity is that operations act on
    # one known object.
    $settings = @{
        Connection = $Connection
        EvidenceRoot = $EvidenceRoot; AnnotationPrefix = $RunAnnotationPrefix
    }

    @{
        ResolveVirtualMachine = {
            param($RunId, $Name)
            # Name and run annotation together. The name narrows the search; the
            # annotation is what establishes identity.
            $candidates = @(Get-VM -Name $Name -Server $settings.Connection -ErrorAction SilentlyContinue)
            $expected = $settings.AnnotationPrefix + $RunId
            # Exact, not contained. A substring match would accept a note that
            # merely mentions the run -- including one naming several runs, or a
            # longer identifier this one is a prefix of.
            $matching = @($candidates | Where-Object {
                $_.Notes -and [string]::Equals($_.Notes.Trim(), $expected, [System.StringComparison]::Ordinal)
            })
            # Exactly one, or none. Two machines claiming one run is a state
            # nothing here should resolve by picking.
            if ($matching.Count -eq 1) { $matching[0] } else { $null }
        }.GetNewClosure()

        GetPowerState = {
            param($Machine)
            # Re-read through the connection rather than trusting the object
            # this function was handed, which was captured earlier.
            [string] (Get-VM -Id $Machine.Id -Server $settings.Connection -ErrorAction Stop).PowerState
        }.GetNewClosure()

        ReadGuestInfo = {
            param($Machine, $Key)
            $entry = Get-AdvancedSetting -Entity $Machine -Name $Key -Server $settings.Connection -ErrorAction SilentlyContinue
            if ($entry) { [string] $entry.Value } else { '' }
        }.GetNewClosure()

        ClearGuestInfo = {
            param($Machine, $Key)
            $entry = Get-AdvancedSetting -Entity $Machine -Name $Key -Server $settings.Connection -ErrorAction SilentlyContinue
            if ($entry) { Remove-AdvancedSetting -AdvancedSetting $entry -Confirm:$false -ErrorAction Stop | Out-Null }
            $true
        }.GetNewClosure()

        ConvertToTemplate = {
            param($Machine)
            Set-VM -VM $Machine -ToTemplate -Confirm:$false -Server $settings.Connection -ErrorAction Stop | Out-Null
            $true
        }.GetNewClosure()

        GetArtifactIdentity = {
            param($Machine)
            # Both views scoped to this connection. An instance identifier read
            # from a different session would name the wrong vCenter, and the
            # reference is unique only within the instance that issued it.
            $view = Get-View -Id $Machine.Id -Server $settings.Connection -ErrorAction Stop
            $service = Get-View ServiceInstance -Server $settings.Connection -ErrorAction Stop
            [PSCustomObject]@{
                vCenterInstanceId      = $service.Content.About.InstanceUuid
                managedObjectReference = $view.MoRef.Value
                instanceUuid           = $view.Config.InstanceUuid
                recordedName           = $view.Name
            }
        }.GetNewClosure()

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

Export-ModuleMember -Function Test-VSpherePrerequisite, Connect-VSpherePlatform,
    Disconnect-VSpherePlatform, Get-VSpherePlatformAdapter
