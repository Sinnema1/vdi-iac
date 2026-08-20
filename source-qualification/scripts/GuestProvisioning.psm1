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
        $record = [ordered]@{ Id = $check.id; Kind = $check.kind; Outcome = 'inconclusive'; ReasonCode = $null }

        try {
            switch ($check.kind) {
                'service-exists' {
                    $record.Outcome = if (& $Adapter.TestService $check.serviceName) { 'passed' } else { 'failed' }
                    if ($record.Outcome -eq 'failed') { $record.ReasonCode = 'service_absent' }
                }
                default {
                    $root = & $Adapter.ResolveRoot $check.root
                    if ([string]::IsNullOrWhiteSpace($root)) {
                        $record.ReasonCode = 'root_unavailable'
                        break
                    }
                    $path = Join-Path $root ($check.relativePath -replace '/', [System.IO.Path]::DirectorySeparatorChar)

                    if (-not (& $Adapter.TestFile $path)) {
                        $record.Outcome = 'failed'
                        $record.ReasonCode = 'file_absent'
                        break
                    }
                    if ($check.kind -eq 'file-exists') {
                        $record.Outcome = 'passed'
                        break
                    }

                    $observed = & $Adapter.GetFileVersion $path $check.versionField
                    if ([string]::IsNullOrWhiteSpace($observed)) {
                        $record.ReasonCode = 'version_unavailable'
                        break
                    }
                    if (TestVersionEquals -Expected $check.expectedVersion -Observed $observed) {
                        $record.Outcome = 'passed'
                    }
                    else {
                        $record.Outcome = 'failed'
                        $record.ReasonCode = 'version_mismatch'
                    }
                }
            }
        }
        catch {
            # An adapter that threw did not establish anything, so the check is
            # inconclusive rather than failed.
            $record.ReasonCode = 'check_error'
            Write-Verbose "Check '$($check.id)' could not complete: $($_.Exception.Message)"
        }

        $checks.Add([PSCustomObject] $record)
    }

    $outcome = if (@($checks | Where-Object Outcome -EQ 'failed').Count -gt 0) { 'failed' }
               elseif (@($checks | Where-Object Outcome -EQ 'inconclusive').Count -gt 0) { 'inconclusive' }
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
        [Parameter()] [ValidateSet('install','validate')] [string] $Phase = 'install',
        [Parameter()] $Adapter,
        [Parameter()] [ValidateNotNullOrEmpty()] [string] $LogDirectory
    )

    $startedUtc = [datetime]::UtcNow
    if (-not $Adapter) { $Adapter = Get-GuestAdapter }
    if (-not $LogDirectory) { $LogDirectory = Join-Path $BundlePath 'logs' }

    $descriptorPath = Join-Path $BundlePath 'descriptor.json'
    $descriptor = Test-TransferDescriptor -Path $descriptorPath -ExpectedSha256 $ExpectedDescriptorSha256

    if (-not (Test-Path -LiteralPath $LogDirectory -PathType Container)) {
        $null = New-Item -ItemType Directory -Path $LogDirectory -Force
    }

    $results = [System.Collections.Generic.List[PSCustomObject]]::new()
    $restartRequired = $false
    $terminal = $null

    foreach ($entry in $descriptor.packages) {
        $record = [ordered]@{
            Id = $entry.id; Version = $entry.version; Order = $entry.order
            Required = $entry.required; Outcome = 'failed'; ReasonCode = $null
            RestartRequired = $false; Validation = $null
        }

        try {
            $payloadPath = Join-Path $BundlePath ($entry.payloadPath -replace '/', [System.IO.Path]::DirectorySeparatorChar)

            if ($Phase -eq 'install') {
                # The same expected hash the host used, carried in the descriptor
                # and authenticated with it. Never recomputed as expected.
                $integrity = Test-PackageIntegrity -Path $payloadPath -ExpectedSha256 $entry.sha256
                if (-not $integrity.Matched) {
                    $record.ReasonCode = 'integrity_mismatch'
                    $results.Add([PSCustomObject] $record)
                    continue
                }

                $invocation = Get-InstallerInvocation -Entry $entry -PayloadPath $payloadPath -LogDirectory $LogDirectory
                $raw = & $Adapter.StartProcess $invocation.FilePath $invocation.ArgumentList $entry.installer.timeoutSeconds
                $verdict = Get-NormalizedInstallerResult -Entry $entry -RawResult $raw

                $record.Outcome = $verdict.Outcome
                $record.ReasonCode = $verdict.ReasonCode
                $record.RestartRequired = $verdict.RestartRequired
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
                $record.Validation = $validation.Checks
                $record.Outcome = if ($validation.Outcome -eq 'passed') { 'passed' } else { 'failed' }
                if ($validation.Outcome -ne 'passed') { $record.ReasonCode = "validation_$($validation.Outcome)" }
            }
        }
        catch {
            $code = $_.Exception.Data['ReasonCode']
            $record.ReasonCode = if ($code) { $code } else { 'unexpected_error' }
            Write-Verbose "Package '$($entry.id)' failed with $($record.ReasonCode): $($_.Exception.Message)"
        }

        $results.Add([PSCustomObject] $record)
    }

    $failedRequired = @($results | Where-Object { $_.Outcome -ne 'passed' -and $_.Required })
    $outcome = if ($terminal) { 'incomplete' }
               elseif ($failedRequired.Count -gt 0) { 'failed' }
               else { 'passed' }

    ConvertTo-EvidenceEnvelope -ResultKind 'guest-provisioning' -RunId $descriptor.runId `
        -Outcome $outcome -StartedUtc $startedUtc `
        -ManifestSchemaVersion ([int] $descriptor.manifestSchemaVersion) -Payload ([ordered]@{
            phase = $Phase
            restartRequired = $restartRequired
            packageCount = $results.Count
            passedCount = @($results | Where-Object Outcome -EQ 'passed').Count
            failedRequiredCount = $failedRequired.Count
            terminalReasonCode = $terminal
            packages = $results.ToArray()
        })
}

Export-ModuleMember -Function Get-NormalizedInstallerResult, Get-InstallerInvocation, Invoke-PackageValidation, Invoke-GuestProvisioning
