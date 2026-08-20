#Requires -Version 7.0

<#
.SYNOPSIS
    Verifies, installs, and validates the packages a transfer bundle carries.

.DESCRIPTION
    The guest half of Increment 2. Every operating-system interaction goes
    through an injected adapter (ADR 2), so this module is exercised on any
    platform without installing software, creating services, or rebooting.

    Installation logic reports that a restart is required. It never triggers one:
    Packer owns the restart boundary, and an installer that reboots on its own
    takes that ownership away, which is why MSI 1641 is a failure here.
#>

Set-StrictMode -Version 3.0

foreach ($dependency in 'RunIdentity', 'SourceQualification', 'Evidence', 'GuestAdapter', 'TransferBundle') {
    Import-Module (Join-Path $PSScriptRoot "$dependency.psm1")
}

# Fixed by the platform, so the contract states them rather than letting a
# manifest redefine them. 1641 means the installer initiated a reboot outside
# Packer's control.
$script:MsiSuccess = 0
$script:MsiSuccessRestartRequired = 3010
$script:MsiRebootInitiated = 1641

function ResolveConfinedPath {
    <#
    .SYNOPSIS
        Joins a relative path beneath a root and refuses any redirection in it.

    .DESCRIPTION
        Module-internal. The same rule Increment 1 proved for source resolution,
        applied on the guest side to both payloads and validation targets.

        A lexical check is not sufficient. Normalizing catches dot-segment
        traversal but not symbolic links, junctions, or other reparse points, so
        a link placed inside a bundle or beneath a validation root would satisfy
        a prefix comparison while reaching an arbitrary file. Every existing
        component beneath the root is checked, and any redirection is refused
        rather than followed.

        Two independent signals: LinkTarget covers symbolic links and junctions,
        and the ReparsePoint attribute covers the wider family for which
        LinkTarget is empty.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)] [ValidateNotNullOrEmpty()] [string] $Root,
        [Parameter(Mandatory)] [ValidateNotNullOrEmpty()] [string] $RelativePath
    )

    if (-not (Test-Path -LiteralPath $Root -PathType Container)) {
        throw (NewGuestError -Code 'path_rejected' -Message "Root not found: $Root")
    }

    $rootItem = Get-Item -LiteralPath $Root -Force
    $rootTarget = if ($rootItem.LinkTarget) { $rootItem.ResolveLinkTarget($true) } else { $null }
    $rootFull = if ($rootTarget) { [System.IO.Path]::GetFullPath($rootTarget.FullName) }
                else { [System.IO.Path]::GetFullPath($rootItem.FullName) }

    # Joined segment by segment: Windows normalizes separators across a whole
    # path, so substituting them into the string and joining once does not agree
    # with a path built the same way elsewhere.
    $candidate = $rootFull
    foreach ($segment in $RelativePath.Split('/')) {
        if ($segment) { $candidate = Join-Path $candidate $segment }
    }
    $candidate = [System.IO.Path]::GetFullPath($candidate)

    $separator = [System.IO.Path]::DirectorySeparatorChar
    $prefix = $rootFull.TrimEnd($separator) + $separator
    if (-not $candidate.StartsWith($prefix, [System.StringComparison]::Ordinal)) {
        throw (NewGuestError -Code 'path_rejected' -Message "Path '$RelativePath' resolves outside its root.")
    }

    $walked = $rootFull.TrimEnd($separator)
    foreach ($segment in $candidate.Substring($prefix.Length).Split($separator)) {
        if (-not $segment) { continue }
        $walked = Join-Path $walked $segment
        if (-not (Test-Path -LiteralPath $walked)) { continue }
        $item = Get-Item -LiteralPath $walked -Force
        $isReparse = ($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -eq [System.IO.FileAttributes]::ReparsePoint
        if ($item.LinkTarget -or $isReparse) {
            throw (NewGuestError -Code 'path_rejected' -Message "Path '$RelativePath' is redirected at '$segment'.")
        }
    }

    $candidate
}

function NewGuestError {
    <#
    .SYNOPSIS
        Builds an exception carrying a bounded reason code.

    .NOTES
        Module-internal. The name omits a dash: it constructs a value rather than
        changing state.
    #>
    [CmdletBinding()]
    [OutputType([System.Exception])]
    param(
        [Parameter(Mandatory)] [ValidateSet('path_rejected','adapter_unsupported','integrity_mismatch','unexpected_error')] [string] $Code,
        [Parameter(Mandatory)] [string] $Message
    )
    $exception = [System.Exception]::new($Message)
    $exception.Data['ReasonCode'] = $Code
    $exception
}

function Remove-GuestBundle {
    <#
    .SYNOPSIS
        Removes one run's bundle from the guest staging root, and nothing else.

    .DESCRIPTION
        The target is derived, never accepted. An earlier version took a bundle
        path from the caller and removed it recursively, which meant any path a
        caller could name was a deletion target; reproduced against an unrelated
        temporary directory.

        The target is now the single child the host is known to have created:
        'bundle-<runId>' beneath the trusted staging root, with the run
        identifier validated as a canonical UUID before it reaches the path. The
        staging root itself is never the target, and neither is anything outside
        it.

        Nothing here reads the descriptor. Cleanup has to work after descriptor
        tampering, so what gets deleted cannot depend on a document an attacker
        may have rewritten.

        Ordering belongs to the host: evidence must be retrieved before the
        directory holding it is removed, and a phase running inside the guest
        cannot know whether that has happened. Stage 5 calls this after
        retrieval.

    .OUTPUTS
        removed, retained, failed, or not-attempted. Never a bare boolean: a
        caller has to tell "there was nothing to remove" from "it would not go".
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)] [ValidateNotNullOrEmpty()] [string] $StagingRoot,
        [Parameter(Mandatory)] [ValidateNotNullOrEmpty()] [string] $RunId,
        [Parameter()] [switch] $KeepBundle
    )

    $validatedRunId = Assert-RunIdentifier -RunId $RunId

    if (-not (Test-Path -LiteralPath $StagingRoot -PathType Container)) {
        throw (NewGuestError -Code 'path_rejected' -Message "Guest staging root not found: $StagingRoot")
    }

    $rootItem = Get-Item -LiteralPath $StagingRoot -Force
    $rootTarget = if ($rootItem.LinkTarget) { $rootItem.ResolveLinkTarget($true) } else { $null }
    $rootFull = if ($rootTarget) { [System.IO.Path]::GetFullPath($rootTarget.FullName) }
                else { [System.IO.Path]::GetFullPath($rootItem.FullName) }

    $target = [System.IO.Path]::GetFullPath((Join-Path $rootFull "bundle-$validatedRunId"))

    # Belt and braces. The name is derived from a validated UUID, so this cannot
    # fire; if it ever does, the derivation was bypassed and nothing is deleted.
    $separator = [System.IO.Path]::DirectorySeparatorChar
    $prefix = $rootFull.TrimEnd($separator) + $separator
    if (-not $target.StartsWith($prefix, [System.StringComparison]::Ordinal) -or $target -eq $rootFull) {
        throw (NewGuestError -Code 'path_rejected' -Message 'Derived cleanup target is not a child of the staging root.')
    }

    if ($KeepBundle) { return 'retained' }
    if (-not (Test-Path -LiteralPath $target)) { return 'removed' }

    # A redirected target would delete whatever it points at rather than the
    # bundle, so it is refused rather than followed.
    $targetItem = Get-Item -LiteralPath $target -Force
    $isReparse = ($targetItem.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -eq [System.IO.FileAttributes]::ReparsePoint
    if ($targetItem.LinkTarget -or $isReparse) {
        throw (NewGuestError -Code 'path_rejected' -Message 'Cleanup target is redirected; refusing to follow it.')
    }

    if (-not $PSCmdlet.ShouldProcess($target, 'Remove guest bundle')) { return 'not-attempted' }

    try {
        Remove-Item -LiteralPath $target -Recurse -Force -ErrorAction Stop
    }
    catch {
        Write-Verbose "Guest bundle cleanup failed: $($_.Exception.Message)"
        return 'failed'
    }

    if (Test-Path -LiteralPath $target) { 'failed' } else { 'removed' }
}

function Get-NormalizedInstallerResult {
    <#
    .SYNOPSIS
        Maps a raw process result to an outcome, a reason code, and a restart signal.

    .DESCRIPTION
        Pure: no filesystem, no process, no clock. Exit-code policy is the part
        most likely to be wrong in a way that only shows up on a real installer,
        so it is separated from everything that needs one.

    .PARAMETER Entry
        The descriptor entry, carrying installer kind, restart policy, and for
        EXE packages its declared exit codes.

    .PARAMETER RawResult
        ExitCode, TimedOut, and Terminated from the process adapter.

    .OUTPUTS
        Outcome (passed, failed, or incomplete), ReasonCode, RestartRequired.
    #>
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param(
        [Parameter(Mandatory)] $Entry,
        [Parameter(Mandatory)] $RawResult
    )

    $verdict = [ordered]@{ Outcome = 'failed'; ReasonCode = $null; RestartRequired = $false }

    if ($RawResult.TimedOut) {
        # A process that would not die may still be writing to the guest, so the
        # run cannot continue to the next package or to the restart. That is not
        # a package failure; nothing is known about the machine's state.
        if ($RawResult.Terminated) {
            $verdict.ReasonCode = 'install_timeout'
        }
        else {
            $verdict.Outcome = 'incomplete'
            $verdict.ReasonCode = 'install_timeout_termination_failed'
        }
        return [PSCustomObject] $verdict
    }

    $code = $RawResult.ExitCode

    if ($Entry.installer.kind -eq 'msi') {
        switch ($code) {
            $script:MsiSuccess {
                $verdict.Outcome = 'passed'
            }
            $script:MsiSuccessRestartRequired {
                $verdict.Outcome = 'passed'
                $verdict.RestartRequired = $true
            }
            $script:MsiRebootInitiated {
                $verdict.ReasonCode = 'installer_initiated_reboot'
            }
            default {
                $verdict.ReasonCode = 'installer_failed'
            }
        }
    }
    else {
        $success = @($Entry.installer.exitCodes.success)
        $restart = @()
        if ($Entry.installer.exitCodes.PSObject.Properties.Name -contains 'restartRequired') {
            $restart = @($Entry.installer.exitCodes.restartRequired)
        }

        if ($restart -contains $code) {
            $verdict.Outcome = 'passed'
            $verdict.RestartRequired = $true
        }
        elseif ($success -contains $code) {
            $verdict.Outcome = 'passed'
        }
        else {
            $verdict.ReasonCode = 'installer_failed'
        }
    }

    # A package that asked for a restart under a policy forbidding one is not
    # quietly downgraded to success: the contract said it must not need a reboot,
    # and it did.
    if ($verdict.RestartRequired -and $Entry.installer.restartPolicy -eq 'forbid') {
        $verdict.Outcome = 'failed'
        $verdict.ReasonCode = 'restart_forbidden'
        $verdict.RestartRequired = $false
    }

    [PSCustomObject] $verdict
}

function Get-InstallerInvocation {
    <#
    .SYNOPSIS
        Builds the file and token list for a package, without running anything.

    .DESCRIPTION
        Separated so the tokens can be asserted directly. For MSI the executor
        owns the command line entirely -- quiet, no-restart, and the log path --
        and a manifest contributes only allowlisted NAME=value properties, so it
        cannot pass a switch at all.
    #>
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param(
        [Parameter(Mandatory)] $Entry,
        [Parameter(Mandatory)] [ValidateNotNullOrEmpty()] [string] $PayloadPath,
        [Parameter(Mandatory)] [ValidateNotNullOrEmpty()] [string] $LogDirectory
    )

    if ($Entry.installer.kind -eq 'msi') {
        $tokens = [System.Collections.Generic.List[string]]::new()
        $tokens.Add('/i')
        $tokens.Add($PayloadPath)
        $tokens.Add('/qn')
        $tokens.Add('/norestart')
        $tokens.Add('/l*v')
        $tokens.Add((Join-Path $LogDirectory "$($Entry.id).log"))

        if ($Entry.installer.PSObject.Properties.Name -contains 'properties' -and $Entry.installer.properties) {
            foreach ($property in $Entry.installer.properties.PSObject.Properties) {
                $tokens.Add("$($property.Name)=$($property.Value)")
            }
        }

        return [PSCustomObject]@{ FilePath = 'msiexec.exe'; ArgumentList = $tokens.ToArray() }
    }

    $arguments = @()
    if ($Entry.installer.PSObject.Properties.Name -contains 'arguments' -and $Entry.installer.arguments) {
        $arguments = @($Entry.installer.arguments)
    }
    [PSCustomObject]@{ FilePath = $PayloadPath; ArgumentList = $arguments }
}

function Invoke-PackageValidation {
    <#
    .SYNOPSIS
        Runs a package's validation checks through the adapter.

    .DESCRIPTION
        All-of semantics: any failed check makes the package failed; otherwise
        any inconclusive check makes it inconclusive; only all-passed is passed.

        A check that cannot establish a result is inconclusive, never passed. For
        a required package both failed and inconclusive fail the build, so the
        distinction is about what the evidence says rather than what happens.
    #>
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param(
        [Parameter(Mandatory)] $Entry,
        [Parameter(Mandatory)] $Adapter
    )

    $checks = [System.Collections.Generic.List[PSCustomObject]]::new()

    foreach ($check in $Entry.validation) {
        $record = [ordered]@{ id = $check.id; kind = $check.kind; outcome = 'inconclusive'; reasonCode = $null }

        try {
            switch ($check.kind) {
                'service-exists' {
                    $record.outcome = if (& $Adapter.TestService $check.serviceName) { 'passed' } else { 'failed' }
                    if ($record.outcome -eq 'failed') { $record.reasonCode = 'service_absent' }
                }
                default {
                    $root = & $Adapter.ResolveRoot $check.root
                    if ([string]::IsNullOrWhiteSpace($root)) {
                        $record.reasonCode = 'root_unavailable'
                        break
                    }

                    # Confined and reparse-checked before the file is touched. A
                    # link beneath a validation root would otherwise let a check
                    # report on a file outside it.
                    try {
                        $path = ResolveConfinedPath -Root $root -RelativePath $check.relativePath
                    }
                    catch {
                        $record.outcome = 'failed'
                        $record.reasonCode = 'path_rejected'
                        break
                    }

                    if (-not (& $Adapter.TestFile $path)) {
                        $record.outcome = 'failed'
                        $record.reasonCode = 'file_absent'
                        break
                    }
                    if ($check.kind -eq 'file-exists') {
                        $record.outcome = 'passed'
                        break
                    }

                    $observed = & $Adapter.GetFileVersion $path $check.versionField
                    if ([string]::IsNullOrWhiteSpace($observed)) {
                        $record.reasonCode = 'version_unavailable'
                        break
                    }
                    if (TestVersionEquals -Expected $check.expectedVersion -Observed $observed) {
                        $record.outcome = 'passed'
                    }
                    else {
                        $record.outcome = 'failed'
                        $record.reasonCode = 'version_mismatch'
                    }
                }
            }
        }
        catch {
            # An adapter that threw did not establish anything, so the check is
            # inconclusive rather than failed.
            $record.reasonCode = 'check_error'
            Write-Verbose "Check '$($check.id)' could not complete: $($_.Exception.Message)"
        }

        $checks.Add([PSCustomObject] $record)
    }

    $outcome = if (@($checks | Where-Object outcome -EQ 'failed').Count -gt 0) { 'failed' }
               elseif (@($checks | Where-Object outcome -EQ 'inconclusive').Count -gt 0) { 'inconclusive' }
               else { 'passed' }

    [PSCustomObject]@{ Outcome = $outcome; Checks = $checks.ToArray() }
}

function TestVersionEquals {
    <#
    .SYNOPSIS
        Compares four numeric components, absent ones read as zero.

    .DESCRIPTION
        Module-internal. So 7.0.1024 equals 7.0.1024.0. Ordering is not
        supported: a build pins an exact version, so "at least" has no meaning.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)] [string] $Expected,
        [Parameter(Mandatory)] [string] $Observed
    )

    $normalize = {
        param([string] $Value)
        $parts = @($Value.Trim().Split('.'))
        $numbers = @()
        for ($i = 0; $i -lt 4; $i++) {
            $component = 0
            if ($i -lt $parts.Count -and -not [int]::TryParse($parts[$i], [ref] $component)) { return $null }
            $numbers += $component
        }
        , $numbers
    }

    $left = & $normalize $Expected
    $right = & $normalize $Observed
    if ($null -eq $left -or $null -eq $right) { return $false }

    for ($i = 0; $i -lt 4; $i++) {
        if ($left[$i] -ne $right[$i]) { return $false }
    }
    $true
}

function Invoke-GuestProvisioning {
    <#
    .SYNOPSIS
        Verifies, installs, and validates every package a bundle carries.

    .DESCRIPTION
        Authenticates the descriptor against a digest delivered out of band
        before parsing it, re-verifies each payload against the hash the
        descriptor carries, installs through the adapter, and reports whether a
        restart is required.

        Post-install validation is deliberately not run here. Packer restarts the
        guest once after the batch, and a check run before a pending reboot
        observes a state the machine will not be in afterwards. Validation is a
        separate invocation on the far side of that boundary.

    .PARAMETER BundlePath
        The uploaded bundle root.

    .PARAMETER ExpectedDescriptorSha256
        Delivered out of band, not read from the bundle. A descriptor and its
        payload hashes can be rewritten together so that every in-bundle check
        passes; only a digest that did not travel with the bundle catches that.

    .PARAMETER RunId
        The run identifier the orchestrator delivered out of band, alongside the
        descriptor digest. It is compared against the identifier inside the
        authenticated descriptor, so a bundle that authenticates correctly but
        belongs to a different run -- a replay of an earlier upload, or a
        directory left behind by a previous pass -- is refused rather than
        installed.

    .PARAMETER Phase
        'install' runs verification and installation. 'validate' runs the
        post-restart checks against the same descriptor.

    .OUTPUTS
        An evidence envelope. Package results carry bounded reason codes; no
        argument, property value, path, or exception text reaches evidence.
    #>
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param(
        [Parameter(Mandatory)] [ValidateNotNullOrEmpty()] [string] $BundlePath,
        [Parameter(Mandatory)] [ValidateNotNullOrEmpty()] [string] $ExpectedDescriptorSha256,
        [Parameter(Mandatory)] [ValidateNotNullOrEmpty()] [string] $RunId,
        [Parameter()] [ValidateSet('install','validate')] [string] $Phase = 'install',
        [Parameter()] $Adapter,
        [Parameter()] [ValidateNotNullOrEmpty()] [string] $LogDirectory
    )

    $startedUtc = [datetime]::UtcNow
    $expectedRunId = Assert-RunIdentifier -RunId $RunId
    if (-not $Adapter) { $Adapter = Get-GuestAdapter }
    if (-not $LogDirectory) { $LogDirectory = Join-Path $BundlePath 'logs' }

    $descriptorPath = Join-Path $BundlePath 'descriptor.json'
    $descriptor = Test-TransferDescriptor -Path $descriptorPath -ExpectedSha256 $ExpectedDescriptorSha256

    # The digest proves the descriptor is one we produced. It does not prove it
    # is the one for *this* run: an earlier bundle, or a directory left behind by
    # a previous pass, authenticates perfectly well against its own digest.
    # Comparing against the identifier delivered out of band closes that.
    if (-not [string]::Equals($descriptor.runId, $expectedRunId, [System.StringComparison]::Ordinal)) {
        $exception = [System.Exception]::new('The descriptor belongs to a different run than the one this phase was given.')
        $exception.Data['ReasonCode'] = 'run_id_mismatch'
        throw $exception
    }

    if (-not (Test-Path -LiteralPath $LogDirectory -PathType Container)) {
        $null = New-Item -ItemType Directory -Path $LogDirectory -Force
    }

    $results = [System.Collections.Generic.List[PSCustomObject]]::new()
    $restartRequired = $false
    $terminal = $null

    foreach ($entry in $descriptor.packages) {
        $record = [ordered]@{
            id = $entry.id; version = $entry.version; order = $entry.order
            required = $entry.required; outcome = 'failed'; reasonCode = $null
            restartRequired = $false; installerAttempted = $false; validation = $null
        }

        try {
            # Confined and reparse-checked before the payload is hashed or run. A
            # link inside an uploaded bundle would otherwise let a verified hash
            # stand in for a file somewhere else entirely.
            $payloadPath = ResolveConfinedPath -Root $BundlePath -RelativePath $entry.payloadPath

            if ($Phase -eq 'install') {
                # The same expected hash the host used, carried in the descriptor
                # and authenticated with it. Never recomputed as expected.
                $integrity = Test-PackageIntegrity -Path $payloadPath -ExpectedSha256 $entry.sha256
                if (-not $integrity.Matched) {
                    $record.reasonCode = 'integrity_mismatch'
                    $results.Add([PSCustomObject] $record)
                    continue
                }

                $invocation = Get-InstallerInvocation -Entry $entry -PayloadPath $payloadPath -LogDirectory $LogDirectory
                $raw = & $Adapter.StartProcess $invocation.FilePath $invocation.ArgumentList $entry.installer.timeoutSeconds
                # Recorded before the outcome is known: an installer that
                # started and then failed still started, and a control that
                # claims to refuse before execution has to be measured against
                # that rather than against the result.
                $record.installerAttempted = $true

                $verdict = Get-NormalizedInstallerResult -Entry $entry -RawResult $raw

                $record.outcome = $verdict.Outcome
                $record.reasonCode = $verdict.ReasonCode
                $record.restartRequired = $verdict.RestartRequired
                if ($verdict.RestartRequired) { $restartRequired = $true }

                if ($verdict.Outcome -eq 'incomplete') {
                    # A process that would not die may still be writing. Stop the
                    # batch rather than letting a reboot meet it.
                    $terminal = $verdict.ReasonCode
                    $results.Add([PSCustomObject] $record)
                    break
                }
            }
            else {
                $validation = Invoke-PackageValidation -Entry $entry -Adapter $Adapter
                $record.validation = $validation.Checks
                $record.outcome = if ($validation.Outcome -eq 'passed') { 'passed' } else { 'failed' }
                if ($validation.Outcome -ne 'passed') { $record.reasonCode = "validation_$($validation.Outcome)" }
            }
        }
        catch {
            $code = $_.Exception.Data['ReasonCode']
            $record.reasonCode = if ($code) { $code } else { 'unexpected_error' }
            Write-Verbose "Package '$($entry.id)' failed with $($record.reasonCode): $($_.Exception.Message)"
        }

        $results.Add([PSCustomObject] $record)
    }

    $failedRequired = @($results | Where-Object { $_.outcome -ne 'passed' -and $_.required })
    $outcome = if ($terminal) { 'incomplete' }
               elseif ($failedRequired.Count -gt 0) { 'failed' }
               else { 'passed' }

    ConvertTo-EvidenceEnvelope -ResultKind 'guest-provisioning' -RunId $expectedRunId `
        -Outcome $outcome -StartedUtc $startedUtc `
        -ManifestSchemaVersion ([int] $descriptor.manifestSchemaVersion) -Payload ([ordered]@{
            phase = $Phase
            restartRequired = $restartRequired
            packageCount = $results.Count
            passedCount = @($results | Where-Object outcome -EQ 'passed').Count
            installerAttemptCount = @($results | Where-Object installerAttempted).Count
            failedRequiredCount = $failedRequired.Count
            terminalReasonCode = $terminal
            # Ordering belongs to the host: evidence must be retrieved before the
            # directory holding it is removed, and this phase cannot know whether
            # that has happened. Stage 5 calls Remove-GuestBundle and records what
            # it returns.
            cleanupOutcome = 'not-attempted'
            packages = $results.ToArray()
        })
}

Export-ModuleMember -Function Get-NormalizedInstallerResult, Get-InstallerInvocation, Invoke-PackageValidation, Invoke-GuestProvisioning, Remove-GuestBundle
