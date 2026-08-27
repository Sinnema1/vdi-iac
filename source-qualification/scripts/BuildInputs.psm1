#Requires -Version 7.0

<#
.SYNOPSIS
    Turns validated build artifacts into the variables the Packer build consumes.

.DESCRIPTION
    The handoff between the host-side checks and the build configuration. It
    exists because that handoff is where the two halves can disagree without
    either being wrong on its own: a media path verified locally handed to a
    variable the builder treats as a datastore reference, or a communicator
    username that does not match the account the answer file created.

    Every value here comes from something already validated -- the qualification
    record the build re-verified, the answer-file declaration -- so no caller
    restates a value that exists elsewhere. A value restated is a value that can
    drift.
#>

Set-StrictMode -Version 3.0

function ConvertTo-BuildVariableSet {
    <#
    .SYNOPSIS
        Builds the Packer variable set from validated inputs.

    .PARAMETER QualifiedMedia
        The result of Assert-QualifiedMedia: media whose digest was recomputed
        at the build's input boundary.

    .PARAMETER Declaration
        The imported answer-file declaration, which names the account the answer
        file creates.

    .OUTPUTS
        The variables the build needs from this repository. Platform values --
        vCenter, cluster, datastore, network -- are supplied per environment and
        are deliberately not produced here.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)] $QualifiedMedia,
        [Parameter(Mandatory)] $Declaration,
        [Parameter(Mandatory)] [hashtable] $Hardware,
        [Parameter(Mandatory)] [ValidateNotNullOrEmpty()] [string] $AnswerFilePath,
        [Parameter(Mandatory)] [ValidateNotNullOrEmpty()] [string] $RunId
    )

    $record = $QualifiedMedia.Record

    # The same hashtable the recipe digest is computed over. Passing it to both
    # is what makes the digest describe the machine that was actually built; two
    # separately maintained copies would drift, and the digest would name a
    # configuration nobody used.
    foreach ($key in 'HardwareVersion', 'Firmware', 'VirtualTpm', 'DiskControllerType',
                     'DiskSizeGb', 'Cpus', 'MemoryMb', 'GuestOsType') {
        if (-not $Hardware.ContainsKey($key)) {
            throw "The build hardware set is missing '$key'. The builder and the recipe digest must see the same hardware."
        }
    }

    @{
        # The local file the boundary verified, and the digest it was verified
        # against. Packer checks the same file against the same expectation.
        media_url      = $QualifiedMedia.MediaPath
        media_checksum = '{0}:{1}' -f $record.integrity.algorithm.ToLowerInvariant(), $record.integrity.expectedDigest

        answer_file_path = $AnswerFilePath
        run_id           = $RunId

        # The account the answer file actually creates. Accepting an arbitrary
        # username would let the communicator try to authenticate as someone
        # setup never configured, and the build would sit at a WinRM timeout
        # with nothing explaining why.
        build_username = $Declaration.buildSettings.buildUsername

        hardware_version     = $Hardware.HardwareVersion
        firmware             = $Hardware.Firmware
        virtual_tpm          = $Hardware.VirtualTpm
        disk_controller_type = $Hardware.DiskControllerType
        disk_size_gb         = $Hardware.DiskSizeGb
        cpus                 = $Hardware.Cpus
        memory_mb            = $Hardware.MemoryMb
        guest_os_type        = $Hardware.GuestOsType
    }
}

function Test-ToolsVersionAgreement {
    <#
    .SYNOPSIS
        Returns a reason when the VMware Tools version is not one value, or null.

    .DESCRIPTION
        Four places name it: the manifest package that installs it, the builder
        variable the prerequisite gate compares against, the recipe input the
        digest covers, and the provenance that results. They must be one value.

        Disagreement is not cosmetic. If the manifest installs one build and the
        recipe records another, the digest names a machine that was never
        constructed -- and the gate would either refuse a correct build or pass
        an incorrect one, depending which pair happened to match.

        The installed version is not checked here. That happens in the guest,
        against the same builder value, because only the guest can see it.

    .OUTPUTS
        A reason describing the disagreement, or null.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)] $Manifest,
        [Parameter(Mandatory)] [ValidateNotNullOrEmpty()] [string] $BuilderVersion,
        [Parameter(Mandatory)] [hashtable] $Tooling,
        [Parameter()] [string] $PackageId = 'vmware-tools'
    )

    $package = @($Manifest.Packages | Where-Object { $_.id -eq $PackageId })
    if ($package.Count -eq 0) {
        # The prerequisite gate would then check for software nothing installs,
        # and the build would fail at the gate having done everything right.
        return "the manifest has no '$PackageId' package, so nothing installs the tooling the attestation channel needs"
    }
    if ($package.Count -gt 1) { return "the manifest declares '$PackageId' more than once" }

    if (-not $Tooling.ContainsKey('VMwareToolsVersion')) {
        return 'the recipe tooling does not record a VMware Tools version'
    }

    $manifestVersion = [string] $package[0].version
    $recipeVersion = [string] $Tooling.VMwareToolsVersion

    if (-not [string]::Equals($manifestVersion, $BuilderVersion, [System.StringComparison]::Ordinal)) {
        return "the manifest installs $manifestVersion and the build checks for $BuilderVersion"
    }
    if (-not [string]::Equals($manifestVersion, $recipeVersion, [System.StringComparison]::Ordinal)) {
        return "the manifest installs $manifestVersion and the recipe records $recipeVersion"
    }

    $null
}

Export-ModuleMember -Function ConvertTo-BuildVariableSet, Test-ToolsVersionAgreement
