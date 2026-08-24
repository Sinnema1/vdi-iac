#Requires -Version 7.0

<#
.SYNOPSIS
    Qualifies the installation media a build constructs from.

.DESCRIPTION
    Stage 1 of Increment 3, governed by ADR 6. Media is a distinct artifact class
    from software packages: it is not a manifest entry, it is orders of magnitude
    larger, and it never travels the guest package-staging path. What it shares
    with a package is the rule that matters -- an expected digest established in
    version control before runtime, never computed from the artifact and then
    treated as the expectation.

    The independence of the checksum authority is the point of this stage. A
    digest published beside the artifact it claims to verify proves only that the
    file was not corrupted in transit; an attacker who can replace the artifact
    can replace its neighbour. The reference records where the digest came from,
    and qualification refuses an authority that names the media's own location.
#>

Set-StrictMode -Version 3.0

Import-Module (Join-Path $PSScriptRoot 'RunIdentity.psm1')

$script:ReferenceSchema = Join-Path $PSScriptRoot '..' '..' 'contracts' 'media-reference-1.schema.json'
$script:RecordSchema = Join-Path $PSScriptRoot '..' '..' 'contracts' 'media-qualification-1.schema.json'

# Hard-coded, never derived from a declared value. Length is checked against the
# algorithm so a SHA256 digest cannot be presented as a SHA512 expectation.
$script:DigestLength = @{ SHA256 = 64; SHA384 = 96; SHA512 = 128 }

function NewMediaError {
    param([string] $Code, [string] $Message)
    $exception = [System.Exception]::new($Message)
    $exception.Data['ReasonCode'] = $Code
    $exception
}

function Import-MediaReference {
    <#
    .SYNOPSIS
        Reads and validates a media reference declaration.

    .DESCRIPTION
        Schema validation plus the semantic rules a schema cannot express: the
        digest length has to match the algorithm named beside it, and the
        checksum authority has to be independent of the artifact.

    .OUTPUTS
        The parsed reference.
    #>
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param(
        [Parameter(Mandatory)] [ValidateNotNullOrEmpty()] [string] $Path
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw (NewMediaError -Code 'media_not_found' -Message "Media reference not found: $Path")
    }

    $raw = Get-Content -LiteralPath $Path -Raw -Encoding utf8
    if (-not (Test-Json -Json $raw -SchemaFile $script:ReferenceSchema -ErrorAction SilentlyContinue)) {
        throw (NewMediaError -Code 'media_reference_invalid' -Message "Media reference does not satisfy the contract: $Path")
    }

    $reference = $raw | ConvertFrom-Json

    $expectedLength = $script:DigestLength[$reference.integrity.algorithm]
    if ($reference.integrity.digest.Length -ne $expectedLength) {
        throw (NewMediaError -Code 'digest_length_mismatch' `
                -Message "A $($reference.integrity.algorithm) digest is $expectedLength characters; this reference declares $($reference.integrity.digest.Length).")
    }

    Assert-ChecksumAuthorityIndependent -Reference $reference

    $reference
}

function Assert-ChecksumAuthorityIndependent {
    <#
    .SYNOPSIS
        Refuses a checksum authority that is the artifact's own neighbour.

    .DESCRIPTION
        The rule ADR 6 turns on. A digest is only evidence if it was obtained
        somewhere the artifact's publisher-of-record controls and the artifact's
        host does not. This cannot catch every dependent authority -- a citation
        is free text and a determined author can write anything -- so it refuses
        the specific, checkable case: a citation naming the same directory the
        media is read from, which is how the mistake is actually made.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] $Reference)

    $mediaDirectory = Split-Path -Path $Reference.reference.locator -Parent
    if (-not $mediaDirectory) { return }

    $normalize = { param([string] $Value) ($Value -replace '\\', '/').TrimEnd('/').ToLowerInvariant() }
    $citation = & $normalize $Reference.integrity.authority.citation
    $directory = & $normalize $mediaDirectory

    if ($citation.StartsWith($directory, [System.StringComparison]::Ordinal)) {
        throw (NewMediaError -Code 'authority_not_independent' `
                -Message 'The checksum authority names the location the media is read from. A digest stored beside the artifact it verifies is not an independent authority.')
    }
}

function Invoke-MediaQualification {
    <#
    .SYNOPSIS
        Verifies the declared media and produces the record a build consumes.

    .DESCRIPTION
        Resolution is confined to a media root the caller supplies, using the
        same two-part rule source qualification uses: normalize to catch
        dot-segment traversal, then refuse any reparse point beneath the root
        rather than following it. A resolved link target can be replaced between
        the check and the read, so refusing is the behavior a reader can reason
        about.

        A failure produces a record with outcome 'failed' and a bounded reason,
        not an absent file. A build that finds no record cannot tell a refusal
        from a stage that never ran.

    .OUTPUTS
        The qualification record.
    #>
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param(
        [Parameter(Mandatory)] [ValidateNotNullOrEmpty()] [string] $ReferencePath,
        [Parameter(Mandatory)] [ValidateNotNullOrEmpty()] [string] $MediaRoot,
        [Parameter()] [string] $RunId
    )

    $runIdentifier = if ($RunId) { Assert-RunIdentifier -RunId $RunId } else { Get-RunIdentifier }
    $reference = Import-MediaReference -Path $ReferencePath

    $record = [ordered]@{
        schemaVersion = 1
        runId         = $runIdentifier
        qualifiedUtc  = [datetime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ss.fffffffZ')
        outcome       = 'failed'
        reasonCode    = 'unexpected_error'
        mediaId       = $reference.mediaId
        reference     = [ordered]@{
            kind      = $reference.reference.kind
            locator   = $reference.reference.locator
            fileName  = $reference.reference.fileName
        }
        integrity     = [ordered]@{
            algorithm      = $reference.integrity.algorithm
            expectedDigest = $reference.integrity.digest
            observedDigest = $null
            authority      = [ordered]@{
                kind         = $reference.integrity.authority.kind
                citation     = $reference.integrity.authority.citation
                retrievedUtc = $reference.integrity.authority.retrievedUtc
            }
        }
        image         = [ordered]@{ edition = $reference.image.edition; index = $reference.image.index }
        platform      = [ordered]@{ architecture = $reference.platform.architecture; language = $reference.platform.language }
    }
    if ($reference.reference.PSObject.Properties.Name -contains 'sizeBytes' -and $reference.reference.sizeBytes) {
        $record.reference.sizeBytes = $reference.reference.sizeBytes
    }

    try {
        $mediaPath = Resolve-MediaPath -Locator $reference.reference.locator -MediaRoot $MediaRoot

        $item = Get-Item -LiteralPath $mediaPath -Force
        if ($item.Name -cne $reference.reference.fileName) {
            throw (NewMediaError -Code 'media_name_mismatch' `
                    -Message "Media resolved to '$($item.Name)', but the reference declares '$($reference.reference.fileName)'.")
        }

        # Checked before hashing, because hashing gigabytes to discover a size
        # mismatch wastes the run. It is never a substitute for the digest.
        if ($record.reference.Contains('sizeBytes') -and $item.Length -ne $record.reference.sizeBytes) {
            throw (NewMediaError -Code 'media_size_mismatch' `
                    -Message "Media is $($item.Length) bytes; the reference declares $($record.reference.sizeBytes).")
        }

        $observed = (Get-FileHash -LiteralPath $mediaPath -Algorithm $reference.integrity.algorithm).Hash.ToLowerInvariant()
        $record.integrity.observedDigest = $observed

        # Ordinal, case-normalized on both sides. The expectation came from the
        # reference; the observation came from the artifact. They are never
        # sourced from the same place.
        if (-not [string]::Equals($observed, $reference.integrity.digest, [System.StringComparison]::Ordinal)) {
            throw (NewMediaError -Code 'integrity_mismatch' `
                    -Message "Media digest does not match the expected value for '$($reference.mediaId)'.")
        }

        $record.outcome = 'passed'
        $record.reasonCode = $null
    }
    catch {
        $code = if ($_.Exception.Data['ReasonCode']) { $_.Exception.Data['ReasonCode'] } else { 'unexpected_error' }
        $record.outcome = 'failed'
        $record.reasonCode = $code
    }

    [PSCustomObject]$record
}

function Resolve-MediaPath {
    <#
    .SYNOPSIS
        Resolves a media locator to a real path confined beneath the media root.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)] [ValidateNotNullOrEmpty()] [string] $Locator,
        [Parameter(Mandatory)] [ValidateNotNullOrEmpty()] [string] $MediaRoot
    )

    if (-not (Test-Path -LiteralPath $MediaRoot -PathType Container)) {
        throw (NewMediaError -Code 'media_not_found' -Message "Media root not found: $MediaRoot")
    }

    $rootItem = Get-Item -LiteralPath $MediaRoot -Force
    $rootTarget = if ($rootItem.LinkTarget) { $rootItem.ResolveLinkTarget($true) } else { $null }
    $rootFull = if ($rootTarget) { [System.IO.Path]::GetFullPath($rootTarget.FullName) }
                else { [System.IO.Path]::GetFullPath($rootItem.FullName) }

    $candidate = [System.IO.Path]::GetFullPath([System.IO.Path]::Combine($rootFull, $Locator))

    $separator = [System.IO.Path]::DirectorySeparatorChar
    $rootPrefix = $rootFull.TrimEnd($separator) + $separator
    if (-not $candidate.StartsWith($rootPrefix, [System.StringComparison]::Ordinal)) {
        throw (NewMediaError -Code 'media_outside_root' -Message "Media locator '$Locator' resolves outside the media root.")
    }

    $walked = $rootFull.TrimEnd($separator)
    foreach ($segment in $candidate.Substring($rootPrefix.Length).Split($separator)) {
        if ([string]::IsNullOrEmpty($segment)) { continue }
        $walked = Join-Path $walked $segment
        if (-not (Test-Path -LiteralPath $walked)) { continue }
        $item = Get-Item -LiteralPath $walked -Force
        $isReparsePoint = ($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -eq [System.IO.FileAttributes]::ReparsePoint
        if ($item.LinkTarget -or $isReparsePoint) {
            throw (NewMediaError -Code 'media_link_rejected' `
                    -Message "Media locator '$Locator' is redirected at '$segment'. Reparse points beneath the media root are not followed.")
        }
    }

    if (-not (Test-Path -LiteralPath $candidate -PathType Leaf)) {
        throw (NewMediaError -Code 'media_not_found' -Message "Media not found beneath the media root: $Locator")
    }

    $candidate
}

function Test-MediaQualificationRecord {
    <#
    .SYNOPSIS
        Returns a reason string when a record contradicts itself, or null.

    .DESCRIPTION
        These rules are deliberately not in the schema. Test-Json does not
        enforce draft-07 if/then -- a conditional written there validates
        everything and looks like a constraint, which is worse than no rule at
        all. Verified before relying on it, and the coupling lives here instead.

        A passed record with no observed digest is the case that matters: it
        claims a comparison that never happened.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)] $Record)

    if ($Record.outcome -eq 'passed') {
        if ($Record.reasonCode) { return 'a passed record carries a reason code' }
        if (-not $Record.integrity.observedDigest) { return 'a passed record has no observed digest' }
        if (-not [string]::Equals($Record.integrity.observedDigest, $Record.integrity.expectedDigest, [System.StringComparison]::Ordinal)) {
            return 'a passed record reports digests that do not match'
        }
    }
    if ($Record.outcome -eq 'failed' -and -not $Record.reasonCode) {
        return 'a failed record carries no reason code'
    }

    $null
}

function Save-MediaQualificationRecord {
    <#
    .SYNOPSIS
        Writes a qualification record, validating it against its contract first.

    .DESCRIPTION
        Validated before writing, not after. A record that does not satisfy the
        contract is a defect in this module, and writing it would hand the
        builder a document it will refuse at its own boundary -- after the
        expensive part of the build has already started.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)] $Record,
        [Parameter(Mandatory)] [ValidateNotNullOrEmpty()] [string] $Path
    )

    $json = $Record | ConvertTo-Json -Depth 12
    if (-not (Test-Json -Json $json -SchemaFile $script:RecordSchema -ErrorAction SilentlyContinue)) {
        throw (NewMediaError -Code 'unexpected_error' -Message 'The qualification record does not satisfy its own contract.')
    }

    $contradiction = Test-MediaQualificationRecord -Record $Record
    if ($contradiction) {
        throw (NewMediaError -Code 'unexpected_error' -Message "The qualification record contradicts itself: $contradiction.")
    }

    if ($PSCmdlet.ShouldProcess($Path, 'Write the media qualification record')) {
        Set-Content -LiteralPath $Path -Value $json -Encoding utf8
    }
    $Path
}

Export-ModuleMember -Function Import-MediaReference, Invoke-MediaQualification, Resolve-MediaPath, Test-MediaQualificationRecord, Save-MediaQualificationRecord
