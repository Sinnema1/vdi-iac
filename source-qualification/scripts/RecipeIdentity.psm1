#Requires -Version 7.0

<#
.SYNOPSIS
    Builds the canonical recipe-input document and its digest.

.DESCRIPTION
    Increment 3 stage 3, governed by ADR 7. `recipeDigest` answers "what was
    built" and is determined by the inputs alone, so two builds from identical
    inputs share it and a build whose inputs differ in any way does not.

    Membership is decided by one rule: if changing something could change what
    is installed or whether the result is accepted, it is an input; if it only
    changes where or when the build ran, it is not. Run identifiers, timestamps,
    temporary paths, hostnames, datastores, and every vSphere identifier are
    therefore absent, and so is anything derived from a credential -- the digest
    is published in provenance.

    File inputs enter by their whole-file digest, which is deliberately coarser
    than their meaning: reformatting a provisioning script changes the recipe
    digest even though nothing installed changes. ADR 7 resolves that in favour
    of the conservative reading. The digest must never miss a change that
    matters, and may report one that does not; a rebuild is cheap, while two
    materially different images sharing an identity invalidates everything
    built on top of it.
#>

Set-StrictMode -Version 3.0

Import-Module (Join-Path $PSScriptRoot 'CanonicalJson.psm1')
Import-Module (Join-Path $PSScriptRoot 'JsonSafety.psm1')

# The version of the recipe-input document itself. Adding a field, removing one,
# or changing how a value is represented produces a new version: digests are
# only comparable within one, which is why the version travels beside the digest
# rather than being implied.
#
# Version 2 adds cpus, memoryMb, and guestOsType. They were build inputs the
# builder consumed while the digest ignored them, so two builds differing in
# processor count, memory, or the guest OS identifier vSphere presents to setup
# shared an identity. Version 1 was never emitted by a real build.
$script:RecipeInputVersion = 2

function ConvertTo-RecipeInput {
    <#
    .SYNOPSIS
        Converts the build inputs into the canonical recipe-input document.

    .DESCRIPTION
        Every argument is required. There is no partial recipe: a document
        missing an input would produce a digest that silently ignores it, which
        is the failure this exists to prevent, so an absent input is an error
        rather than an omitted field.

    .PARAMETER MediaReference
        The declared media reference. Its expected digest is included; an
        observed digest is a fact about one run and is not.

    .PARAMETER Manifest
        The result of Import-PackageManifest, which is validated against the
        committed schema and semantically checked. Nothing here re-derives that
        shape: an earlier version read fields the contract does not define and
        was only ever exercised against a fabricated fixture, so it terminated
        the first time a real manifest reached it.

    .PARAMETER AnswerFile
        TemplateDigest, DeclarationDigest, and the declared ImageSelection.

    .PARAMETER BuildLogic
        PackerConfigDigests and ProvisioningScriptDigests as name/digest pairs,
        and GuestContractVersion.

    .PARAMETER Hardware
        The virtual hardware and firmware selections.

    .PARAMETER Tooling
        Packer and plugin versions.

    .OUTPUTS
        An ordered dictionary ready for canonical serialization.
    #>
    [CmdletBinding()]
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    param(
        [Parameter(Mandatory)] $MediaReference,
        [Parameter(Mandatory)] $Manifest,
        [Parameter(Mandatory)] [hashtable] $AnswerFile,
        [Parameter(Mandatory)] [hashtable] $BuildLogic,
        [Parameter(Mandatory)] [hashtable] $Hardware,
        [Parameter(Mandatory)] [hashtable] $Tooling
    )

    $document = [ordered]@{
        recipeInputVersion = $script:RecipeInputVersion
        media              = NewMediaInput -Reference $MediaReference
        packages           = NewPackageInput -Manifest $Manifest
        answerFile         = NewAnswerFileInput -AnswerFile $AnswerFile
        buildLogic         = NewBuildLogicInput -BuildLogic $BuildLogic
        hardware           = NewHardwareInput -Hardware $Hardware
        tooling            = NewToolingInput -Tooling $Tooling
    }

    # The same rejection the contracts get. A control character reaching the
    # canonical form would be refused there anyway; refusing it here names the
    # field instead of the serializer's position.
    Assert-NoControlCharacter -Node $document -Location 'recipeInput' -Subject 'Recipe input'
    $document
}

function Get-RecipeDigest {
    <#
    .SYNOPSIS
        Returns the SHA-256 identity of a recipe-input document.

    .OUTPUTS
        The digest and the input version it was computed under. The version
        travels with it because two digests are only comparable within one.
    #>
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param([Parameter(Mandatory)] $RecipeInput)

    [PSCustomObject]@{
        RecipeInputVersion = $RecipeInput.recipeInputVersion
        RecipeDigest       = Get-CanonicalJsonDigest -Node $RecipeInput
    }
}

function RequireKeys {
    param([hashtable] $Table, [string[]] $Keys, [string] $Subject)
    foreach ($key in $Keys) {
        if (-not $Table.ContainsKey($key)) {
            throw "The recipe input for $Subject is missing '$key'. A recipe with a missing input digests as though it did not exist."
        }
    }
}

function NewMediaInput {
    param($Reference)

    [ordered]@{
        mediaId        = $Reference.mediaId
        algorithm      = $Reference.integrity.algorithm
        expectedDigest = $Reference.integrity.digest
        edition        = $Reference.image.edition
        index          = [int] $Reference.image.index
        architecture   = $Reference.platform.architecture
        language       = $Reference.platform.language
    }
}

function NewPackageInput {
    param($Manifest)

    # Ascending `order` is the installation sequence, and it is the sequence
    # that is canonical -- not the order the packages happen to appear in the
    # JSON. Reordering the file without changing an `order` value describes the
    # same installation and must digest the same; changing an `order` value
    # describes a different one and must not.
    $ordered = @($Manifest.Packages | Sort-Object -Property @{ Expression = { [int] $_.order } })

    $packages = foreach ($package in $ordered) {
        $entry = [ordered]@{
            id             = $package.id
            version        = $package.version
            # The contract names this `sha256` at the package root. It is not
            # nested under `source`, which is the reference string.
            expectedSha256 = $package.sha256
            order          = [int] $package.order
            required       = [bool] $package.required
            installerKind  = $package.installer.kind
            timeoutSeconds = [int] $package.installer.timeoutSeconds
            restartPolicy  = $package.installer.restartPolicy
        }

        # Arguments are positional, so their order is part of the input.
        if ($package.installer.PSObject.Properties.Name -contains 'arguments' -and $null -ne $package.installer.arguments) {
            $entry.arguments = @($package.installer.arguments)
        }

        # A property map has no inherent order, so it is emitted as an object and
        # the serializer sorts its keys.
        if ($package.installer.PSObject.Properties.Name -contains 'properties' -and $null -ne $package.installer.properties) {
            $map = [ordered]@{}
            foreach ($property in $package.installer.properties.PSObject.Properties) { $map[$property.Name] = $property.Value }
            $entry.properties = $map
        }

        if ($package.installer.PSObject.Properties.Name -contains 'exitCodes' -and $null -ne $package.installer.exitCodes) {
            $exitCodes = $package.installer.exitCodes
            $entry.exitCodes = [ordered]@{
                success = @($exitCodes.success | ForEach-Object { [int] $_ })
            }
            # restartRequired is optional in the contract, and reading an absent
            # property throws under StrictMode. Included only when the manifest
            # declares it, so a schema-valid manifest without one still produces
            # a recipe -- and so an empty list is not conflated with an absent
            # policy, which would digest the same while meaning something else.
            if ($exitCodes.PSObject.Properties.Name -contains 'restartRequired' -and $null -ne $exitCodes.restartRequired) {
                $entry.exitCodes.restartRequired = @($exitCodes.restartRequired | ForEach-Object { [int] $_ })
            }
        }

        # Validation definitions are inputs, not separate policy: a change to
        # what is checked changes whether an image is accepted, and an image
        # accepted under weaker checks is not interchangeable with one accepted
        # under stronger ones.
        $entry.validation = @(foreach ($check in $package.validation) {
            $definition = [ordered]@{}
            # The serializer sorts object keys anyway; this only makes the
            # intermediate document readable in a failure message.
            foreach ($property in $check.PSObject.Properties) {
                $definition[$property.Name] = $property.Value
            }
            $definition
        })

        $entry
    }

    [ordered]@{
        manifestSchemaVersion = [int] $Manifest.SchemaVersion
        entries               = @($packages)
    }
}

function NewAnswerFileInput {
    param([hashtable] $AnswerFile)

    RequireKeys -Table $AnswerFile -Subject 'the answer file' `
        -Keys @('TemplateDigest', 'DeclarationDigest', 'ImageSelection')

    $selection = $AnswerFile.ImageSelection
    [ordered]@{
        # The committed template and declaration, by whole-file digest. Never the
        # rendered file, which contains a credential.
        templateDigest    = $AnswerFile.TemplateDigest
        declarationDigest = $AnswerFile.DeclarationDigest
        imageSelection    = [ordered]@{
            edition      = $selection.edition
            index        = [int] $selection.index
            architecture = $selection.architecture
            language     = $selection.language
        }
    }
}

function NewBuildLogicInput {
    param([hashtable] $BuildLogic)

    RequireKeys -Table $BuildLogic -Subject 'build logic' `
        -Keys @('PackerConfigDigests', 'ProvisioningScriptDigests', 'GuestContractVersion')

    # Sets, not sequences: these files do not execute in the order they happen to
    # be listed, so they are sorted by name and the ordering carries no meaning.
    [ordered]@{
        packerConfig         = SortedDigestList -Pairs $BuildLogic.PackerConfigDigests
        provisioningScripts  = SortedDigestList -Pairs $BuildLogic.ProvisioningScriptDigests
        guestContractVersion = [int] $BuildLogic.GuestContractVersion
    }
}

function OrdinalKeys {
    param([hashtable] $Table)
    $names = [string[]] @($Table.Keys)
    [System.Array]::Sort($names, [System.StringComparer]::Ordinal)
    $names
}

function SortedDigestList {
    param($Pairs)

    # Ordinal, matching the canonical serializer. Sort-Object -CaseSensitive is
    # culture-aware and would order these differently in another locale.
    $names = [string[]] @($Pairs.Keys)
    [System.Array]::Sort($names, [System.StringComparer]::Ordinal)
    @(foreach ($name in $names) {
        [ordered]@{ name = $name; digest = $Pairs[$name] }
    })
}

function NewHardwareInput {
    param([hashtable] $Hardware)

    RequireKeys -Table $Hardware -Subject 'hardware' `
        -Keys @('HardwareVersion', 'Firmware', 'SecureBoot', 'DiskControllerType', 'DiskSizeGb',
                'VirtualTpm', 'Cpus', 'MemoryMb', 'GuestOsType')

    # Firmware and secure boot change what installs and how it boots; a vTPM
    # changes what the installed system can require.
    [ordered]@{
        hardwareVersion    = [int] $Hardware.HardwareVersion
        firmware           = $Hardware.Firmware
        secureBoot         = [bool] $Hardware.SecureBoot
        diskControllerType = $Hardware.DiskControllerType
        diskSizeGb         = [int] $Hardware.DiskSizeGb
        virtualTpm         = [bool] $Hardware.VirtualTpm
        # Added in recipe-input-2. The builder consumed these while the digest
        # ignored them, so two builds differing in any of them shared an
        # identity. The guest OS identifier changes the device model vSphere
        # presents to setup, which changes what gets installed.
        cpus               = [int] $Hardware.Cpus
        memoryMb           = [int] $Hardware.MemoryMb
        guestOsType        = $Hardware.GuestOsType
    }
}

function NewToolingInput {
    param([hashtable] $Tooling)

    RequireKeys -Table $Tooling -Subject 'tooling' -Keys @('PackerVersion', 'PluginVersions')

    [ordered]@{
        packerVersion = $Tooling.PackerVersion
        plugins       = @(foreach ($name in (OrdinalKeys -Table $Tooling.PluginVersions)) {
            [ordered]@{ name = $name; version = $Tooling.PluginVersions[$name] }
        })
    }
}

Export-ModuleMember -Function ConvertTo-RecipeInput, Get-RecipeDigest
