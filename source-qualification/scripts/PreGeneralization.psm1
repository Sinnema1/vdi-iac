#Requires -Version 7.0

<#
.SYNOPSIS
    The checks that must hold before a build VM becomes an image, and the
    residue removal that follows them.

.DESCRIPTION
    Increment 3 stage 5, steps 3 and 4. Everything here runs on a machine that is
    about to lose its identity, so it is the last point at which anything can be
    observed and the last point at which anything can be fixed.

    Checks are an allowlisted set, not supplied script. A design that accepted
    arbitrary PowerShell would make the set of things that must be true depend on
    whoever last edited a variable file, and a pre-generalization check that can
    be weakened per run is not a gate. Adding a check is a change to this module
    with a test.

    Every check is answered through an injected fact provider, so the whole set
    runs against fixtures on any platform. The production provider refuses to run
    anywhere but Windows.

    Both entry points require the provisioning gate first. They call it rather
    than accepting a claim that it passed, because a caller who forgot is exactly
    the caller these steps exist to protect against.
#>

Set-StrictMode -Version 3.0

Import-Module (Join-Path $PSScriptRoot 'RunIdentity.psm1')
Import-Module (Join-Path $PSScriptRoot 'GuestProvisioning.psm1')
Import-Module (Join-Path $PSScriptRoot 'AnswerFile.psm1')

# Process names that mean an installer is still working. Hard-coded rather than
# discovered: generalizing while one of these is running seals a half-applied
# installation, and the set of names that matter is a decision, not a search.
$script:InstallerProcessNames = @('msiexec', 'setup', 'msiexec.exe', 'setup.exe', 'TrustedInstaller')

# Windows names architectures differently from the media reference, and the two
# spellings share no text: "64-bit" against x64 has nothing in common to match
# on. An explicit map rather than a fuzzy comparison, so arm64 can never satisfy
# an x64 expectation by accident -- which a substring rule would eventually
# allow, since "ARM 64-bit" contains "64-bit".
$script:ArchitectureAliases = @{
    'x64'   = @('x64', 'amd64', '64bit', 'x8664')
    'arm64' = @('arm64', 'arm64bit')
}

function Get-SystemFactProvider {
    <#
    .SYNOPSIS
        The production fact provider. Windows only.

    .DESCRIPTION
        Refuses on any other platform rather than returning something plausible.
        A provider that guessed would let the whole check set pass on a machine
        it was never designed to inspect.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param()

    if (-not $IsWindows) {
        throw 'The system fact provider runs only on Windows. Tests inject a provider instead.'
    }

    @{
        GetEdition = {
            (Get-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' -Name 'EditionID').EditionID
        }
        GetArchitecture = {
            # The OS architecture, not the process's. A 32-bit host process on a
            # 64-bit system would otherwise report the wrong answer.
            (Get-CimInstance -ClassName Win32_OperatingSystem).OSArchitecture
        }
        GetLanguage = {
            (Get-WinSystemLocale).Name
        }
        GetPendingRestart = {
            # Any one of these means a restart is outstanding. Checking a single
            # location reports "no restart pending" on a machine that has one.
            $keys = @(
                'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending'
                'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired'
                'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\PendingFileRenameOperations'
            )
            [bool](@($keys | Where-Object { Test-Path -LiteralPath $_ }).Count)
        }
        GetActiveInstallerProcesses = {
            @(Get-Process -ErrorAction SilentlyContinue |
                Where-Object { $_.ProcessName -in $script:InstallerProcessNames } |
                ForEach-Object { $_.ProcessName })
        }
    }
}

function AssertProvisioningGate {
    <#
        Called rather than trusted. A caller who skipped the gate is exactly the
        caller these steps exist to protect against.
    #>
    param([hashtable] $Gate)

    foreach ($key in 'InstallEvidencePath', 'ValidateEvidencePath', 'RunId', 'SchemaPath') {
        if (-not $Gate.ContainsKey($key)) { throw "The provisioning gate arguments are missing '$key'." }
    }

    $decision = Test-ProvisioningComplete -InstallEvidencePath $Gate.InstallEvidencePath `
        -ValidateEvidencePath $Gate.ValidateEvidencePath -RunId $Gate.RunId -SchemaPath $Gate.SchemaPath

    if (-not $decision.Authorized) {
        throw "Provisioning is not complete: $($decision.ReasonCode). Nothing may run against a machine whose provisioning cannot be accounted for."
    }
}

function NewCheck {
    param([string] $Id, [string] $Outcome, [string] $ReasonCode, [string] $Detail)
    [PSCustomObject]@{ id = $Id; outcome = $Outcome; reasonCode = $ReasonCode; detail = $Detail }
}

function Test-PreGeneralizationReadiness {
    <#
    .SYNOPSIS
        Runs the allowlisted checks that must hold before generalization.

    .DESCRIPTION
        Four things are established, each as its own check so a failure names
        itself rather than reporting that something was wrong:

        the installed Windows matches the media that was qualified; no restart is
        outstanding; no installer is still running; and the transfer bundle is
        gone.

        A check that cannot observe its fact reports inconclusive, and
        inconclusive fails the phase. An unanswerable question about a machine
        about to become an image is not a pass.

    .PARAMETER MediaRecord
        The qualification record, carrying the declared edition, architecture,
        and language. Media qualification never opened the media, so this is
        where the declared intent is finally reconciled against what installed.

    .OUTPUTS
        A bounded phase result: the phase name, its outcome, a reason code from
        the image-build contract, and the individual checks.
    #>
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param(
        [Parameter(Mandatory)] [hashtable] $Gate,
        [Parameter(Mandatory)] $MediaRecord,
        [Parameter(Mandatory)] [ValidateNotNullOrEmpty()] [string] $StagingRoot,
        [Parameter(Mandatory)] [ValidateNotNullOrEmpty()] [string] $RunId,
        [Parameter(Mandatory)] [hashtable] $FactProvider
    )

    AssertProvisioningGate -Gate $Gate
    $validatedRunId = Assert-RunIdentifier -RunId $RunId

    $checks = [System.Collections.Generic.List[PSCustomObject]]::new()

    # 1. Windows identity against the declared media intent.
    foreach ($comparison in @(
            @{ Id = 'edition';      Getter = 'GetEdition';      Expected = $MediaRecord.image.edition }
            @{ Id = 'architecture'; Getter = 'GetArchitecture'; Expected = $MediaRecord.platform.architecture }
            @{ Id = 'language';     Getter = 'GetLanguage';     Expected = $MediaRecord.platform.language })) {

        $observed = $null
        try { $observed = & $FactProvider[$comparison.Getter] }
        catch { $observed = $null }

        if ([string]::IsNullOrWhiteSpace([string]$observed)) {
            # Reported, not assumed. A fact that could not be read is not a fact
            # that matched.
            $checks.Add((NewCheck -Id $comparison.Id -Outcome 'inconclusive' `
                        -ReasonCode 'identity_unobservable' -Detail 'the value could not be read'))
            continue
        }

        # Architecture is mapped; the others are compared by containment.
        # Windows reports an edition identifier where the reference carries a
        # display name, so a literal comparison would fail every real build --
        # but architecture shares no text between the two spellings at all, and
        # a substring rule there would eventually let arm64 satisfy x64.
        $agrees = if ($comparison.Id -eq 'architecture') {
            ArchitectureAgrees -Observed ([string]$observed) -Expected ([string]$comparison.Expected)
        }
        else {
            IdentityAgrees -Observed ([string]$observed) -Expected ([string]$comparison.Expected)
        }

        if ($agrees) {
            $checks.Add((NewCheck -Id $comparison.Id -Outcome 'passed' -ReasonCode $null -Detail ([string]$observed)))
        }
        else {
            $checks.Add((NewCheck -Id $comparison.Id -Outcome 'failed' -ReasonCode 'identity_mismatch' `
                        -Detail "observed '$observed', declared '$($comparison.Expected)'"))
        }
    }

    # 2. No restart outstanding. One still pending means the machine is not in
    #    the state anything observed, and generalizing seals that in.
    $checks.Add((RunPredicateCheck -Id 'no-pending-restart' -Provider $FactProvider -Getter 'GetPendingRestart' `
                -FailWhen $true -ReasonCode 'restart_pending'))

    # 3. No installer still running.
    try {
        $active = @(& $FactProvider['GetActiveInstallerProcesses'])
        if ($active.Count -gt 0) {
            $checks.Add((NewCheck -Id 'no-active-installer' -Outcome 'failed' -ReasonCode 'installer_active' `
                        -Detail ($active -join ', ')))
        }
        else {
            $checks.Add((NewCheck -Id 'no-active-installer' -Outcome 'passed' -ReasonCode $null -Detail 'none'))
        }
    }
    catch {
        $checks.Add((NewCheck -Id 'no-active-installer' -Outcome 'inconclusive' `
                    -ReasonCode 'process_state_unobservable' -Detail 'the process list could not be read'))
    }

    # 4. The transfer bundle is gone. Its packages are installer content, and an
    #    image that ships with them ships with material nobody expected to
    #    distribute.
    $bundlePath = Join-Path $StagingRoot "bundle-$validatedRunId"
    if (Test-Path -LiteralPath $bundlePath) {
        $checks.Add((NewCheck -Id 'bundle-removed' -Outcome 'failed' -ReasonCode 'bundle_present' -Detail $bundlePath))
    }
    else {
        $checks.Add((NewCheck -Id 'bundle-removed' -Outcome 'passed' -ReasonCode $null -Detail 'absent'))
    }

    NewPhaseResult -Phase 'pre-generalization' -Checks $checks -ReasonCode 'pre_generalization_failed'
}

function ArchitectureAgrees {
    param([string] $Observed, [string] $Expected)

    $normalized = ($Observed -replace '[^A-Za-z0-9]', '').ToLowerInvariant()
    $expectedKey = ($Expected -replace '[^A-Za-z0-9]', '').ToLowerInvariant()

    if (-not $script:ArchitectureAliases.ContainsKey($expectedKey)) { return $false }
    $normalized -in $script:ArchitectureAliases[$expectedKey]
}

function IdentityAgrees {
    param([string] $Observed, [string] $Expected)

    $normalize = { param([string] $Value) ($Value -replace '[^A-Za-z0-9]', '').ToLowerInvariant() }
    $left = & $normalize $Observed
    $right = & $normalize $Expected
    if (-not $left -or -not $right) { return $false }
    $left.Contains($right) -or $right.Contains($left)
}

function RunPredicateCheck {
    param([string] $Id, [hashtable] $Provider, [string] $Getter, [bool] $FailWhen, [string] $ReasonCode)

    try { $observed = [bool](& $Provider[$Getter]) }
    catch {
        return NewCheck -Id $Id -Outcome 'inconclusive' -ReasonCode 'state_unobservable' `
            -Detail 'the value could not be read'
    }

    if ($observed -eq $FailWhen) { NewCheck -Id $Id -Outcome 'failed' -ReasonCode $ReasonCode -Detail 'observed' }
    else { NewCheck -Id $Id -Outcome 'passed' -ReasonCode $null -Detail 'clear' }
}

function NewPhaseResult {
    param([string] $Phase, $Checks, [string] $ReasonCode)

    $checkList = @($Checks)
    # Inconclusive counts as failure. An unanswerable question about a machine
    # about to become an image is not a pass.
    $failed = @($checkList | Where-Object { $_.outcome -ne 'passed' })

    [PSCustomObject]@{
        Phase      = $Phase
        Outcome    = $(if ($failed.Count -gt 0) { 'failed' } else { 'passed' })
        ReasonCode = $(if ($failed.Count -gt 0) { $ReasonCode } else { $null })
        Checks     = $checkList
    }
}

function Invoke-AnswerFileResidueRemoval {
    <#
    .SYNOPSIS
        Removes the answer-file copies setup left, and confirms they are gone.

    .DESCRIPTION
        Idempotent: a second run against a clean machine passes, because the
        result is about the machine's state rather than about what this
        invocation happened to delete. That matters because a retried build step
        must not fail for having nothing left to do.

        Fails closed when absence cannot be confirmed. A removal that reported
        success without re-reading the filesystem would let a locked file ship
        inside the image with the administrator password in it.

        Only the known locations are touched. A search-and-destroy sweep across
        the disk would eventually delete something it did not understand.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([PSCustomObject])]
    param(
        [Parameter(Mandatory)] [hashtable] $Gate,
        [Parameter(Mandatory)] [ValidateNotNullOrEmpty()] [string] $SystemDrive
    )

    AssertProvisioningGate -Gate $Gate

    $checks = [System.Collections.Generic.List[PSCustomObject]]::new()

    if (-not $PSCmdlet.ShouldProcess($SystemDrive, 'Remove answer-file residue')) {
        $checks.Add((NewCheck -Id 'residue-removed' -Outcome 'inconclusive' -ReasonCode 'not_attempted' `
                    -Detail 'preview mode'))
        return NewPhaseResult -Phase 'credential-residue' -Checks $checks -ReasonCode 'credential_residue_present'
    }

    $outcome = Remove-SetupResidue -SystemDrive $SystemDrive -Confirm:$false

    # The sweep's per-path outcomes are recorded as detail, not as verdicts. The
    # phase answers one question -- is there residue on this machine now -- and
    # a removal that failed while the file turned out to be gone anyway leaves a
    # clean machine, which is what matters. Making these independently fail the
    # phase would also make the re-read below redundant, and a check that cannot
    # decide anything is one nobody maintains.
    foreach ($result in $outcome.Results) {
        if ($result.Outcome -eq 'failed') {
            $checks.Add((NewCheck -Id "removal:$($result.Path)" -Outcome 'passed' `
                        -ReasonCode $null -Detail "removal reported failed for $($result.Path)"))
        }
    }

    # Re-read rather than trusting the sweep's own report. This is the check the
    # phase turns on: a removal reporting success without re-reading would let a
    # locked file ship inside the image with the administrator password in it.
    $remaining = @(Get-SetupResidue -SystemDrive $SystemDrive)
    if ($remaining.Count -gt 0) {
        $checks.Add((NewCheck -Id 'residue-absent' -Outcome 'failed' -ReasonCode 'residue_present' `
                    -Detail ($remaining -join ', ')))
    }
    else {
        $checks.Add((NewCheck -Id 'residue-absent' -Outcome 'passed' -ReasonCode $null -Detail 'confirmed absent'))
    }

    NewPhaseResult -Phase 'credential-residue' -Checks $checks -ReasonCode 'credential_residue_present'
}

function ConvertTo-ImageBuildPhase {
    <#
    .SYNOPSIS
        Reduces a phase result to the shape the image-build contract accepts.

    .DESCRIPTION
        The envelope's payload is closed, so the individual checks do not travel
        in it. They are the operator's diagnostic; the phase entry is the
        record. Reducing here rather than at each call site means the two cannot
        disagree about what the phase concluded.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param([Parameter(Mandatory)] $PhaseResult)

    @{
        name       = $PhaseResult.Phase
        outcome    = $PhaseResult.Outcome
        reasonCode = $PhaseResult.ReasonCode
    }
}

Export-ModuleMember -Function Get-SystemFactProvider, Test-PreGeneralizationReadiness,
    Invoke-AnswerFileResidueRemoval, ConvertTo-ImageBuildPhase
