#Requires -Version 7.0

<#
.SYNOPSIS
    Resolves, stages, and verifies package sources before a build consumes them.

.DESCRIPTION
    Implements the host side of the integrity model in section 12 of the charter.
    The expected SHA-256 comes from the manifest, which is version controlled and
    established before runtime. This module computes the hash of the staged copy
    and compares it. It never derives an expected value from the artifact it is
    checking.

    Verification is fail-closed. A missing source, an unreadable file, or a hash
    mismatch is terminal for the package. Whether that fails the run depends on
    the package's required flag, and the aggregate result records both outcomes
    explicitly rather than leaving a caller to infer them.
#>

Set-StrictMode -Version 3.0

foreach ($dependency in 'RunIdentity', 'Evidence') {
    Import-Module (Join-Path $PSScriptRoot "$dependency.psm1")
}

function NewQualificationError {
    <#
    .SYNOPSIS
        Builds an exception carrying a bounded reason code.

    .NOTES
        Module-internal. The name deliberately omits a dash: it constructs an
        object rather than changing state, and an approved state-changing verb
        would misdescribe it.

    .DESCRIPTION
        Structured evidence records the code, never the message. Messages contain
        absolute paths and other runtime-derived values that may not be safe to
        publish; codes are a closed set defined in this module.
    #>
    [CmdletBinding()]
    [OutputType([System.Exception])]
    param(
        [Parameter(Mandatory)] [ValidateSet(
            'source_root_not_found', 'source_not_found', 'source_outside_root',
            'source_link_rejected', 'unsupported_scheme', 'integrity_mismatch',
            'staging_failed', 'cleanup_failed')]
        [string] $Code,
        [Parameter(Mandatory)] [string] $Message
    )
    $exception = [System.Exception]::new($Message)
    $exception.Data['ReasonCode'] = $Code
    $exception
}


function Resolve-PackageSource {
    <#
    .SYNOPSIS
        Maps a manifest source reference to a path beneath the source root.

    .DESCRIPTION
        Only the file scheme is resolvable in schema version 1. The resolved path
        is confined to the source root: a reference that escapes it is rejected
        even if the schema pattern admitted it, because the schema cannot know
        what the root is.

        Confinement is enforced twice, because a lexical check alone is not
        sufficient. Normalizing the combined path rejects dot-segment traversal.
        It does not resolve symbolic links, junctions, or other reparse points,
        so a link placed beneath the root and pointing outside it would satisfy a
        prefix comparison while reading an arbitrary file. Every existing
        component beneath the root is therefore checked, and any redirection is
        rejected rather than followed.

        Detection uses two independent signals. LinkTarget is populated for
        symbolic links and NTFS junctions. The ReparsePoint file attribute
        covers the wider family -- mount points, and Windows reparse types for
        which LinkTarget is empty -- so a redirection is refused even when the
        runtime cannot name its target.

        Links are refused rather than resolved-and-rechecked. A resolved target
        can be replaced between the check and the copy, and refusing is the
        behavior a reader can reason about without knowing the filesystem's
        state.

        Trust assumption: the source tree is under the control of the build
        identity and does not change during qualification. This function cannot
        close a time-of-check to time-of-use gap on its own; a source tree that
        mutates mid-run is outside the model in section 12.

    .PARAMETER Reference
        The manifest source value, for example file://example-agent/1.2.3/agent.msi.

    .PARAMETER SourceRoot
        Directory the reference is relative to.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)] [ValidateNotNullOrEmpty()] [string] $Reference,
        [Parameter(Mandatory)] [ValidateNotNullOrEmpty()] [string] $SourceRoot
    )

    if ($Reference -notmatch '^file://(?<relative>.+)$') {
        throw (NewQualificationError -Code 'unsupported_scheme' -Message "Unsupported source scheme in reference '$Reference'. Schema version 1 resolves only file://.")
    }
    $relative = $Matches['relative']

    if (-not (Test-Path -LiteralPath $SourceRoot -PathType Container)) {
        throw (NewQualificationError -Code 'source_root_not_found' -Message "Source root not found: $SourceRoot")
    }

    # Canonicalize the root itself. The root may legitimately be reached through
    # a link; what must not happen is a link *beneath* it escaping containment.
    $rootItem = Get-Item -LiteralPath $SourceRoot -Force
    $rootTarget = if ($rootItem.LinkTarget) { $rootItem.ResolveLinkTarget($true) } else { $null }
    $rootFull = if ($rootTarget) {
        [System.IO.Path]::GetFullPath($rootTarget.FullName)
    }
    else {
        [System.IO.Path]::GetFullPath($rootItem.FullName)
    }

    # Combine then normalize, so dot-segment traversal is caught by comparison
    # rather than by pattern matching on the reference.
    $candidate = [System.IO.Path]::GetFullPath([System.IO.Path]::Combine($rootFull, $relative))

    $separator = [System.IO.Path]::DirectorySeparatorChar
    $rootPrefix = $rootFull.TrimEnd($separator) + $separator
    if (-not $candidate.StartsWith($rootPrefix, [System.StringComparison]::Ordinal)) {
        throw (NewQualificationError -Code 'source_outside_root' -Message "Source reference '$Reference' resolves outside the source root.")
    }

    # Reject a reparse point anywhere in the chain beneath the root. A lexical
    # prefix comparison cannot see one, and following it would read content the
    # source root was supposed to bound.
    $walked = $rootFull.TrimEnd($separator)
    foreach ($segment in $candidate.Substring($rootPrefix.Length).Split($separator)) {
        if ([string]::IsNullOrEmpty($segment)) { continue }
        $walked = Join-Path $walked $segment
        if (-not (Test-Path -LiteralPath $walked)) { continue }
        $item = Get-Item -LiteralPath $walked -Force
        $isReparsePoint = ($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -eq [System.IO.FileAttributes]::ReparsePoint
        if ($item.LinkTarget -or $isReparsePoint) {
            throw (NewQualificationError -Code 'source_link_rejected' -Message "Source reference '$Reference' is redirected at '$segment'. Links, junctions, and other reparse points beneath the source root are not followed.")
        }
    }

    $candidate
}

function Copy-PackageToStaging {
    <#
    .SYNOPSIS
        Copies a resolved source into a unique staging directory.

    .DESCRIPTION
        Staging is per-run and per-package so that a partially completed run
        leaves nothing that a later run could mistake for verified content.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)] [ValidateNotNullOrEmpty()] [string] $SourcePath,
        [Parameter(Mandatory)] [ValidateNotNullOrEmpty()] [string] $StagingDirectory
    )

    if (-not (Test-Path -LiteralPath $SourcePath -PathType Leaf)) {
        throw (NewQualificationError -Code 'source_not_found' -Message "Source file not found: $SourcePath")
    }
    if (-not (Test-Path -LiteralPath $StagingDirectory -PathType Container)) {
        $null = New-Item -ItemType Directory -Path $StagingDirectory -Force
    }

    $destination = Join-Path $StagingDirectory ([System.IO.Path]::GetFileName($SourcePath))
    if ($PSCmdlet.ShouldProcess($destination, 'Stage package')) {
        Copy-Item -LiteralPath $SourcePath -Destination $destination -Force
    }
    $destination
}

function Test-PackageIntegrity {
    <#
    .SYNOPSIS
        Compares a file's SHA-256 against the expected value from the manifest.

    .OUTPUTS
        PSCustomObject with Matched, Expected, and Actual. Hash comparison is
        ordinal against lowercase, so a difference in case is never mistaken for
        a difference in content.
    #>
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param(
        [Parameter(Mandatory)] [ValidateNotNullOrEmpty()] [string] $Path,
        [Parameter(Mandatory)] [ValidatePattern('^[a-fA-F0-9]{64}$')] [string] $ExpectedSha256
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw (NewQualificationError -Code 'source_not_found' -Message "File not found for integrity check: $Path")
    }

    $actual = (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
    $expected = $ExpectedSha256.ToLowerInvariant()

    [PSCustomObject]@{
        Matched  = [string]::Equals($actual, $expected, [System.StringComparison]::Ordinal)
        Expected = $expected
        Actual   = $actual
    }
}

function Invoke-SourceQualification {
    <#
    .SYNOPSIS
        Qualifies every package in a manifest: resolve, stage, verify.

    .DESCRIPTION
        Produces a structured result per package and an aggregate outcome. Staging
        is removed in a finally block so a failure part-way through does not leave
        unverified content behind, while the original error still propagates.

    .PARAMETER Manifest
        A manifest object from Import-PackageManifest.

    .PARAMETER SourceRoot
        Directory that manifest source references are relative to.

    .PARAMETER StagingRoot
        Parent directory for per-run staging. A unique subdirectory is created.

    .PARAMETER KeepStaging
        Retain staged content. Intended for diagnosis, not for normal runs.

    .OUTPUTS
        An evidence envelope (ADR 5): resultSchemaVersion 2, resultKind
        source-qualification, and a payload validated against the closed
        definition for that kind.

        Outcome is 'passed' when every required package qualified, 'failed' when
        one did not, and 'incomplete' when staging could not be removed -- which
        is a property of the run rather than of any package.

        Package results carry a bounded reason code, never an exception message.
    #>
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param(
        [Parameter(Mandatory)] $Manifest,
        [Parameter(Mandatory)] [ValidateNotNullOrEmpty()] [string] $SourceRoot,
        [Parameter(Mandatory)] [ValidateNotNullOrEmpty()] [string] $StagingRoot,
        [Parameter()] [switch] $KeepStaging,

        # Supplied by the orchestrator when a run spans stages, so evidence from
        # qualification, transfer, and the guest correlates. Generated only when
        # this stage runs standalone.
        [Parameter()] [string] $RunId
    )

    # A missing source root is a run-level configuration error, not a property of
    # any package. Checking it here means the run reports "could not complete"
    # once, rather than reporting an identical failure against every package and
    # leaving a reader to infer the real cause.
    if (-not (Test-Path -LiteralPath $SourceRoot -PathType Container)) {
        throw "Source root not found: $SourceRoot"
    }

    $runId = if ([string]::IsNullOrWhiteSpace($RunId)) { Get-RunIdentifier } else { Assert-RunIdentifier -RunId $RunId }
    $stagingDirectory = Join-Path $StagingRoot "source-qualification-$runId"
    $results = [System.Collections.Generic.List[PSCustomObject]]::new()
    $startedUtc = [datetime]::UtcNow

    try {
        $null = New-Item -ItemType Directory -Path $stagingDirectory -Force

        foreach ($package in $Manifest.Packages) {
            $result = [ordered]@{
                id         = $package.id
                version    = $package.version
                order      = $package.order
                required   = $package.required
                outcome    = 'failed'
                reasonCode = $null
                expected   = $package.sha256
                actual     = $null
            }

            try {
                $resolved = Resolve-PackageSource -Reference $package.source -SourceRoot $SourceRoot
                $packageStaging = Join-Path $stagingDirectory $package.id
                $staged = Copy-PackageToStaging -SourcePath $resolved -StagingDirectory $packageStaging
                $integrity = Test-PackageIntegrity -Path $staged -ExpectedSha256 $package.sha256

                $result.actual = $integrity.Actual
                if ($integrity.Matched) {
                    $result.outcome = 'passed'
                }
                else {
                    $result.reasonCode = 'integrity_mismatch'
                }
            }
            catch {
                # Only the code reaches the result. Exception messages carry
                # absolute paths and other runtime-derived values, and evidence
                # is not a safe place for them.
                $code = $_.Exception.Data['ReasonCode']
                $result.reasonCode = if ($code) { $code } else { 'unexpected_error' }
                Write-Verbose "Package '$($package.id)' failed with $($result.reasonCode): $($_.Exception.Message)"
            }

            $results.Add([PSCustomObject]$result)
        }
    }
    finally {
        # Cleanup outcome is recorded, never swallowed. Staging that survives a
        # run holds content whose verification status a later reader cannot
        # determine, so a silent failure here is worse than a loud one.
        if ($KeepStaging) {
            $cleanupOutcome = 'retained'
        }
        elseif (-not (Test-Path -LiteralPath $stagingDirectory)) {
            $cleanupOutcome = 'removed'
        }
        else {
            try {
                Remove-Item -LiteralPath $stagingDirectory -Recurse -Force -ErrorAction Stop
                $cleanupOutcome = if (Test-Path -LiteralPath $stagingDirectory) { 'failed' } else { 'removed' }
            }
            catch {
                $cleanupOutcome = 'failed'
                Write-Verbose "Staging cleanup failed: $($_.Exception.Message)"
            }
        }
    }

    $failedRequired = @($results | Where-Object { $_.outcome -ne 'passed' -and $_.required })
    $failedOptional = @($results | Where-Object { $_.outcome -ne 'passed' -and -not $_.required })

    # A cleanup failure is not a package failure, so it does not become 'failed'.
    # It is an inability to complete the run cleanly, which the caller must be
    # able to distinguish. 'incomplete' says exactly that.
    $outcome = if ($cleanupOutcome -eq 'failed') { 'incomplete' }
               elseif ($failedRequired.Count -gt 0) { 'failed' }
               else { 'passed' }

    ConvertTo-EvidenceEnvelope -ResultKind 'source-qualification' -RunId $runId `
        -Outcome $outcome -StartedUtc $startedUtc `
        -ManifestSchemaVersion ([int] $Manifest.SchemaVersion) -Payload ([ordered]@{
            packageCount        = $results.Count
            passedCount         = @($results | Where-Object outcome -EQ 'passed').Count
            failedRequiredCount = $failedRequired.Count
            failedOptionalCount = $failedOptional.Count
            cleanupOutcome      = $cleanupOutcome
            packages            = $results.ToArray()
        })
}

Export-ModuleMember -Function Resolve-PackageSource, Copy-PackageToStaging, Test-PackageIntegrity, Invoke-SourceQualification
