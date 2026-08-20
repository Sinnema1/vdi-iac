#Requires -Version 7.0

<#
.SYNOPSIS
    The operating-system boundaries guest provisioning touches, as one injectable set.

.DESCRIPTION
    Implements the Level 1 requirement in ADR 2. Execution, filesystem, and
    service access are reached only through this adapter, so tests substitute
    fakes and never install software, create services, or reboot a runner.

    Making the boundary explicit is the larger benefit. Every place the guest
    phase touches the operating system is named here rather than scattered
    through the implementation, so what a fake has to stand in for is legible.

    The default adapter is real and Windows-only. On any other platform its
    members throw rather than degrade, because a check that quietly returns
    'not found' on Linux would report a package as failed for the wrong reason.
#>

Set-StrictMode -Version 3.0

# Terminating a process that ignores the request is not a detail: an installer
# still writing to the guest must never meet a reboot, so the wait is bounded
# and its failure is reported rather than assumed away.
$script:TerminationGraceSeconds = 30
$script:MinimumPowerShellVersion = [version]'7.4.0'

function AssertGuestPlatform {
    <#
    .SYNOPSIS
        Refuses to run the production adapter anywhere it cannot mean what it says.

    .DESCRIPTION
        Module-internal. Called when the adapter is acquired and again in every
        member, so an unsupported runtime stops the run before any descriptor is
        read, any directory created, or any package attempted.

        The PowerShell floor is a version, not a major: ProcessStartInfo
        .ArgumentList needs a modern runtime, and a major-only check accepts
        releases that no longer receive fixes.
    #>
    [CmdletBinding()]
    param()

    if (-not $IsWindows) {
        $exception = [System.Exception]::new('The production guest adapter runs on Windows only. Tests inject a fake adapter instead.')
        $exception.Data['ReasonCode'] = 'adapter_unsupported'
        throw $exception
    }
    if ($PSVersionTable.PSVersion -lt $script:MinimumPowerShellVersion) {
        $exception = [System.Exception]::new("The production guest adapter needs PowerShell $script:MinimumPowerShellVersion or later; this host has $($PSVersionTable.PSVersion).")
        $exception.Data['ReasonCode'] = 'adapter_unsupported'
        throw $exception
    }
}

function Get-GuestAdapter {
    <#
    .SYNOPSIS
        Returns the real adapter set.

    .OUTPUTS
        An object whose members are script blocks. Tests build the same shape
        with fakes; nothing else in the guest phase talks to the operating
        system directly.
    #>
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param()

    # Guarded at acquisition, not only inside each member. A guard that first
    # fires inside the package loop is caught there and recorded as a package
    # outcome, so an unsupported runtime could be reported against an optional
    # package while the run as a whole returned passed. An unsupported runtime is
    # a property of the run.
    AssertGuestPlatform

    [PSCustomObject]@{
        Name = 'windows'

        # Returns ExitCode, TimedOut, and Terminated. Standard output and error
        # are read and discarded: relaying third-party output would launder it
        # into ours, and ADR 5 keeps it out of every artifact we produce.
        StartProcess = {
            param([string] $FilePath, [string[]] $ArgumentList, [int] $TimeoutSeconds)

            AssertGuestPlatform

            $info = [System.Diagnostics.ProcessStartInfo]::new()
            $info.FileName = $FilePath
            $info.UseShellExecute = $false
            $info.RedirectStandardOutput = $true
            $info.RedirectStandardError = $true
            $info.CreateNoWindow = $true
            # Each token added individually. Joining them into a string and
            # letting the child re-split loses spaces and quoting; measured in
            # ADR 2.
            foreach ($token in $ArgumentList) { $info.ArgumentList.Add($token) }

            $process = [System.Diagnostics.Process]::Start($info)
            $null = $process.StandardOutput.ReadToEndAsync()
            $null = $process.StandardError.ReadToEndAsync()

            if ($process.WaitForExit($TimeoutSeconds * 1000)) {
                return [PSCustomObject]@{ ExitCode = $process.ExitCode; TimedOut = $false; Terminated = $true }
            }

            # Kill the tree, not just the parent. Installers spawn children, and
            # killing only the parent leaves the machine being modified by a
            # process nothing is waiting for.
            try { $process.Kill($true) } catch { Write-Verbose "Kill failed: $($_.Exception.Message)" }
            $null = $process.WaitForExit($script:TerminationGraceSeconds * 1000)

            # Terminated stays false. WaitForExit reports on the process this
            # object represents, and .NET does not extend that to descendants
            # killed as part of the tree, so a parent that exited says nothing
            # about whether a child is still writing to the guest.
            #
            # Reporting an unconfirmed kill as confirmed would turn an
            # 'incomplete' run -- nothing known about the machine -- into a plain
            # package failure. Until a mechanism actually enumerates the tree,
            # this adapter refuses to claim it.
            [PSCustomObject]@{ ExitCode = $null; TimedOut = $true; Terminated = $false }
        }

        # Allowlisted roots only. A validation check never names an absolute path.
        ResolveRoot = {
            param([string] $Root)

            AssertGuestPlatform
            switch ($Root) {
                'programFiles'    { $env:ProgramFiles }
                'programFilesX86' { ${env:ProgramFiles(x86)} }
                'programData'     { $env:ProgramData }
                'windows'         { $env:SystemRoot }
                'system32'        { Join-Path $env:SystemRoot 'System32' }
                default           { throw "Unknown validation root '$Root'." }
            }
        }

        TestFile = {
            param([string] $Path)
            AssertGuestPlatform
            Test-Path -LiteralPath $Path -PathType Leaf
        }

        # Returns $null when the file carries no version information, which the
        # caller reports as inconclusive rather than as a mismatch.
        GetFileVersion = {
            param([string] $Path, [string] $Field)

            AssertGuestPlatform
            $info = [System.Diagnostics.FileVersionInfo]::GetVersionInfo($Path)
            $value = if ($Field -eq 'product') { $info.ProductVersion } else { $info.FileVersion }
            if ([string]::IsNullOrWhiteSpace($value)) { $null } else { $value.Trim() }
        }

        TestService = {
            param([string] $Name)

            AssertGuestPlatform
            $null -ne (Get-Service -Name $Name -ErrorAction SilentlyContinue)
        }
    }
}

Export-ModuleMember -Function Get-GuestAdapter
