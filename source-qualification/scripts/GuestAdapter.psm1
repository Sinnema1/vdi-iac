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

    [PSCustomObject]@{
        Name = 'windows'

        # Returns ExitCode, TimedOut, and Terminated. Standard output and error
        # are read and discarded: relaying third-party output would launder it
        # into ours, and ADR 5 keeps it out of every artifact we produce.
        StartProcess = {
            param([string] $FilePath, [string[]] $ArgumentList, [int] $TimeoutSeconds)

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
            $confirmed = $process.WaitForExit($script:TerminationGraceSeconds * 1000)

            [PSCustomObject]@{ ExitCode = $null; TimedOut = $true; Terminated = $confirmed }
        }

        # Allowlisted roots only. A validation check never names an absolute path.
        ResolveRoot = {
            param([string] $Root)

            if (-not $IsWindows) {
                throw "Guest filesystem roots resolve on Windows only; this adapter is running on $([System.Environment]::OSVersion.Platform)."
            }
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
            Test-Path -LiteralPath $Path -PathType Leaf
        }

        # Returns $null when the file carries no version information, which the
        # caller reports as inconclusive rather than as a mismatch.
        GetFileVersion = {
            param([string] $Path, [string] $Field)

            $info = [System.Diagnostics.FileVersionInfo]::GetVersionInfo($Path)
            $value = if ($Field -eq 'product') { $info.ProductVersion } else { $info.FileVersion }
            if ([string]::IsNullOrWhiteSpace($value)) { $null } else { $value.Trim() }
        }

        TestService = {
            param([string] $Name)

            if (-not $IsWindows) {
                throw 'Service checks run on Windows only.'
            }
            $null -ne (Get-Service -Name $Name -ErrorAction SilentlyContinue)
        }
    }
}

Export-ModuleMember -Function Get-GuestAdapter
