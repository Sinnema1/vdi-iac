#Requires -Version 7.0

<#
.SYNOPSIS
    Decides a lab run's outcome from retrieved guest evidence.

.DESCRIPTION
    A module rather than a function inside the orchestrator script, so tests can
    import it without executing that script. Dot-sourcing a script with mandatory
    parameters prompts for input instead of running, which hangs a suite rather
    than failing it.

    Completeness is the point. An earlier version accepted any non-empty subset
    of phase files, so an install-only result could be reported as passed while
    validation evidence was simply missing -- a run that never validated anything
    reporting that everything validated.
#>

Set-StrictMode -Version 3.0

Import-Module (Join-Path $PSScriptRoot '..' '..' 'source-qualification' 'scripts' 'RunIdentity.psm1')
Import-Module (Join-Path $PSScriptRoot '..' '..' 'source-qualification' 'scripts' 'Evidence.psm1')

# A completed normal run produces exactly these, one each.
$script:ExpectedPhases = @{
    'install-guest-evidence.json'  = 'install'
    'validate-guest-evidence.json' = 'validate'
}

# Accepted by the harness on the two guest phases: packages failed for reasons
# the run is designed to report. Any other non-zero is a genuine failure of the
# harness itself and cannot be read as a conclusive result.
$script:LogicalFailureExitCode = 200

# The only terminal reasons that describe a deliberate pre-restart halt. Any
# other incomplete install leaves the missing validation phase unexplained, and
# accepting it would let an unrelated failure pass as a designed stop.
$script:PreRestartHaltReasons = @(
    'install_timeout_termination_failed',
    'descriptor_digest_mismatch',
    'descriptor_invalid',
    'run_id_mismatch',
    'adapter_unsupported'
)

function Get-LabEvidenceOutcome {
    <#
    .SYNOPSIS
        Reads retrieved guest evidence and decides the run's outcome.

    .DESCRIPTION
        Refuses to conclude anything from incomplete input. Missing, duplicated,
        malformed, misattributed, or wrong-kind evidence all yield 'incomplete',
        because a run that cannot be described is not a run that passed.

    .PARAMETER EvidenceDirectory
        Where the harness downloaded guest evidence.

    .PARAMETER RunId
        The identifier this run was driven with. Evidence carrying a different one
        belongs to another run and is refused rather than counted.

    .PARAMETER PackerExitCode
        What packer returned. A non-zero code leaves the run incomplete unless it
        is conclusively the accepted logical-result path.

    .PARAMETER RequireValidatePhase
        Set when the run was expected to reach validation. A halted run stops
        before the restart on purpose, and its missing validate evidence is the
        designed behavior rather than a gap.
    #>
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param(
        [Parameter(Mandatory)] [ValidateNotNullOrEmpty()] [string] $EvidenceDirectory,
        [Parameter(Mandatory)] [ValidateNotNullOrEmpty()] [string] $RunId,
        [Parameter()] [AllowNull()] [System.Nullable[int]] $PackerExitCode,
        [Parameter()] [bool] $RequireValidatePhase = $true
    )

    $expectedRunId = Assert-RunIdentifier -RunId $RunId
    $phases = [System.Collections.Generic.List[PSCustomObject]]::new()
    $documents = @{}

    # An install-only record is permitted only when the install evidence itself
    # says the run stopped deliberately. Deriving that from a console message
    # would let any output containing the right words suppress a missing phase.
    $installOnly = -not $RequireValidatePhase
    $expectedNames = if ($installOnly) { @('install-guest-evidence.json') } else { $script:ExpectedPhases.Keys }

    foreach ($name in $expectedNames) {
        $found = @(Get-ChildItem -Path $EvidenceDirectory -Filter $name -File -ErrorAction SilentlyContinue)

        if ($found.Count -eq 0) {
            return NewVerdict -Outcome 'incomplete' -Reason 'evidence_missing' -Phases $phases -PackerExitCode $PackerExitCode
        }
        if ($found.Count -gt 1) {
            return NewVerdict -Outcome 'incomplete' -Reason 'evidence_duplicate' -Phases $phases -PackerExitCode $PackerExitCode
        }

        try {
            $raw = Get-Content -LiteralPath $found[0].FullName -Raw -Encoding utf8
            $parsed = $raw | ConvertFrom-Json
        }
        catch {
            return NewVerdict -Outcome 'incomplete' -Reason 'evidence_malformed' -Phases $phases -PackerExitCode $PackerExitCode
        }

        $schema = Join-Path $PSScriptRoot '..' '..' 'contracts' 'evidence-envelope-2.schema.json'
        if (-not (Test-Json -Json $raw -SchemaFile $schema -ErrorAction SilentlyContinue)) {
            return NewVerdict -Outcome 'incomplete' -Reason 'evidence_malformed' -Phases $phases -PackerExitCode $PackerExitCode
        }
        if ($parsed.resultKind -ne 'guest-provisioning') {
            return NewVerdict -Outcome 'incomplete' -Reason 'evidence_wrong_kind' -Phases $phases -PackerExitCode $PackerExitCode
        }
        if (-not [string]::Equals($parsed.runId, $expectedRunId, [System.StringComparison]::Ordinal)) {
            return NewVerdict -Outcome 'incomplete' -Reason 'evidence_run_id_mismatch' -Phases $phases -PackerExitCode $PackerExitCode
        }
        if ($parsed.payload.phase -ne $script:ExpectedPhases[$name]) {
            return NewVerdict -Outcome 'incomplete' -Reason 'phase_missing' -Phases $phases -PackerExitCode $PackerExitCode
        }

        # Schema validity is not consistency. A document can satisfy every field
        # constraint and still contradict itself -- outcome 'passed' beside a
        # non-zero failure count, or a terminal reason on a run that passed --
        # and accepting it means reporting a pass the evidence does not support.
        $inconsistency = TestEvidenceConsistency -Evidence $parsed
        if ($inconsistency) {
            return NewVerdict -Outcome 'incomplete' -Reason $inconsistency -Phases $phases -PackerExitCode $PackerExitCode
        }

        $phases.Add([PSCustomObject]@{
            phase               = $parsed.payload.phase
            outcome             = $parsed.outcome
            failedRequiredCount = $parsed.payload.failedRequiredCount
        })

        $documents[$parsed.payload.phase] = $parsed
    }

    if ($installOnly) {
        $install = $phases | Where-Object phase -EQ 'install' | Select-Object -First 1
        $installDocument = $documents['install']
        $installTerminal = if ($installDocument -and ($installDocument.payload.PSObject.Properties.Name -contains 'terminalReasonCode')) {
            $installDocument.payload.terminalReasonCode
        } else { $null }

        # A missing validation phase is excused only by a terminal reason that
        # describes a deliberate pre-restart stop. Absent, or present but naming
        # some other failure, the missing phase is unexplained rather than by
        # design -- and $null is not in the allowlist, so both cases refuse here.
        if ($installTerminal -notin $script:PreRestartHaltReasons) {
            return NewVerdict -Outcome 'incomplete' -Reason 'phase_missing' -Phases $phases -PackerExitCode $PackerExitCode
        }

        if (-not $install -or $install.outcome -ne 'incomplete') {
            # The run claimed to have halted, but its install evidence does not
            # describe a halt. One of the two is wrong, so nothing is concluded.
            return NewVerdict -Outcome 'incomplete' -Reason 'phase_missing' -Phases $phases -PackerExitCode $PackerExitCode
        }
        if ($null -eq $PackerExitCode -or $PackerExitCode -eq 0) {
            # A pre-restart halt fails the build. A zero exit contradicts it.
            return NewVerdict -Outcome 'incomplete' -Reason 'packer_failed' -Phases $phases -PackerExitCode $PackerExitCode
        }
        return NewVerdict -Outcome 'incomplete' -Reason 'phase_missing' -Phases $phases -PackerExitCode $PackerExitCode
    }

    # The two phases must describe the same run. Different package identities or a
    # different manifest version means one of them belongs somewhere else, and a
    # pass assembled from two unrelated records is not a pass.
    $installPackages = @($documents['install'].payload.packages | ForEach-Object { $_.id }) | Sort-Object
    $validatePackages = @($documents['validate'].payload.packages | ForEach-Object { $_.id }) | Sort-Object
    if (($installPackages -join '|') -ne ($validatePackages -join '|')) {
        return NewVerdict -Outcome 'incomplete' -Reason 'evidence_inconsistent' -Phases $phases -PackerExitCode $PackerExitCode
    }
    if ($documents['install'].manifestSchemaVersion -ne $documents['validate'].manifestSchemaVersion) {
        return NewVerdict -Outcome 'incomplete' -Reason 'evidence_inconsistent' -Phases $phases -PackerExitCode $PackerExitCode
    }

    $outcome = if (@($phases | Where-Object outcome -EQ 'incomplete').Count -gt 0) { 'incomplete' }
               elseif (@($phases | Where-Object outcome -NE 'passed').Count -gt 0) { 'failed' }
               else { 'passed' }

    # A non-zero packer exit is only conclusive when it is the accepted
    # logical-result path. Anything else means the harness itself failed, and the
    # evidence describes a run that did not finish the way it was driven.
    if ($null -ne $PackerExitCode -and $PackerExitCode -ne 0) {
        if ($PackerExitCode -ne $script:LogicalFailureExitCode -or $outcome -eq 'passed') {
            return NewVerdict -Outcome 'incomplete' -Reason 'packer_failed' -Phases $phases -PackerExitCode $PackerExitCode
        }
    }

    $reason = if ($outcome -eq 'passed') { $null } else { $null }
    NewVerdict -Outcome $outcome -Reason $reason -Phases $phases -PackerExitCode $PackerExitCode
}

function TestEvidenceConsistency {
    <#
    .SYNOPSIS
        Returns a reason code when a document contradicts itself, or null.

    .DESCRIPTION
        Module-internal. Every rule here relates two fields the schema constrains
        separately, so none of them can be expressed as a per-field constraint.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)] $Evidence)

    $payload = $Evidence.payload
    $packages = @($payload.packages)

    # terminalReasonCode is optional in the schema, and under StrictMode reading
    # an absent property throws rather than yielding null.
    $terminal = if ($payload.PSObject.Properties.Name -contains 'terminalReasonCode') { $payload.terminalReasonCode } else { $null }

    if ($Evidence.outcome -eq 'passed') {
        if ($payload.failedRequiredCount -ne 0) { return 'evidence_inconsistent' }
        if ($terminal) { return 'evidence_inconsistent' }
        if (@($packages | Where-Object { $_.outcome -ne 'passed' }).Count -gt 0) { return 'evidence_inconsistent' }
        if ($payload.passedCount -ne $payload.packageCount) { return 'evidence_inconsistent' }
    }

    if ($Evidence.outcome -eq 'failed') {
        $failedRequired = @($packages | Where-Object { $_.outcome -ne 'passed' -and $_.required }).Count
        if ($payload.failedRequiredCount -ne $failedRequired) { return 'evidence_inconsistent' }
        if ($failedRequired -eq 0 -and -not $terminal) { return 'evidence_inconsistent' }
    }

    if ($packages.Count -ne $payload.packageCount) { return 'evidence_inconsistent' }
    if ($payload.passedCount -gt $payload.packageCount) { return 'evidence_inconsistent' }
    if (@($packages | Where-Object { $_.outcome -eq 'passed' }).Count -ne $payload.passedCount) { return 'evidence_inconsistent' }

    $null
}

function NewVerdict {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $Outcome,
        [Parameter()] [AllowNull()] [string] $Reason,
        [Parameter(Mandatory)] $Phases,
        [Parameter()] [AllowNull()] [System.Nullable[int]] $PackerExitCode
    )
    [PSCustomObject]@{
        Outcome        = $Outcome
        Reason         = $Reason
        Phases         = @($Phases)
        PackerExitCode = $PackerExitCode
    }
}

function Get-LabOrchestrationEvidence {
    <#
    .SYNOPSIS
        Returns what the host observed, including both cleanup attempts.

    .NOTES
        Named Get- rather than New-: it builds a value and writes nothing, and a
        state-changing verb would require ShouldProcess for a function with
        nothing to confirm.

    .DESCRIPTION
        Cleanup was console output only, and host cleanup errors were suppressed
        entirely. An outcome nobody records is one nobody can audit, and the guest
        phase cannot record it: it does not know whether its evidence was
        retrieved before the directory holding it was removed.
    #>
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param(
        [Parameter(Mandatory)] [ValidateNotNullOrEmpty()] [string] $RunId,
        [Parameter(Mandatory)] $Verdict,
        [Parameter(Mandatory)] [ValidateSet('removed','retained','failed','not-attempted')] [string] $HostCleanupOutcome,
        [Parameter(Mandatory)] [ValidateSet('removed','retained','failed','not-attempted')] [string] $GuestCleanupOutcome,
        [Parameter(Mandatory)] [datetime] $StartedUtc
    )

    # 'not-attempted' is not success. A run that passed every phase but never
    # cleaned up has left content behind on a machine, and reporting that as a
    # clean pass is exactly the overstatement the outcome vocabulary exists to
    # prevent. Only 'removed', or 'retained' when the caller asked for it,
    # allows a pass to stand.
    $cleanupSettled = ($HostCleanupOutcome -in @('removed', 'retained')) -and
                      ($GuestCleanupOutcome -in @('removed', 'retained'))

    # A completed verdict of either kind requires settled cleanup. A run that
    # failed cleanly and a run that failed and abandoned content on a machine are
    # not the same result, and only one of them is fully accounted for.
    $completed = $Verdict.Outcome -in @('passed', 'failed')

    $outcome = if ($HostCleanupOutcome -eq 'failed' -or $GuestCleanupOutcome -eq 'failed') { 'incomplete' }
               elseif ($completed -and -not $cleanupSettled) { 'incomplete' }
               else { $Verdict.Outcome }

    $terminal = if ($HostCleanupOutcome -eq 'failed' -or $GuestCleanupOutcome -eq 'failed') { 'cleanup_failed' }
                elseif ($completed -and -not $cleanupSettled) { 'cleanup_failed' }
                else { $Verdict.Reason }

    ConvertTo-EvidenceEnvelope -ResultKind 'build-orchestration' -RunId $RunId `
        -Outcome $outcome -StartedUtc $StartedUtc -ManifestSchemaVersion 2 -Payload ([ordered]@{
            packerExitCode      = $Verdict.PackerExitCode
            phases              = @($Verdict.Phases)
            hostCleanupOutcome  = $HostCleanupOutcome
            guestCleanupOutcome = $GuestCleanupOutcome
            terminalReasonCode  = $terminal
        })
}

function Get-GuestCleanupOutcome {
    <#
    .SYNOPSIS
        Reads the harness's own cleanup report out of the build output.

    .DESCRIPTION
        The guest step reports what it did; a run that never reached it has not
        attempted cleanup, and saying otherwise would claim a machine was tidied
        when it was not.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)] [AllowEmptyCollection()] [string[]] $PackerOutput)

    $text = $PackerOutput -join "`n"
    if ($text -match 'guest cleanup: run directory removed') { return 'removed' }
    if ($text -match 'error cleanup: staging removed') { return 'removed' }
    if ($text -match 'still present') { return 'failed' }
    'not-attempted'
}

function Invoke-PackerBuild {
    <#
    .SYNOPSIS
        Runs packer, returning its output and exit code without throwing.

    .DESCRIPTION
        A native command's stderr becomes a terminating error under
        ErrorActionPreference 'Stop', which ends the caller before the exit code
        is read -- so a failing build could skip cleanup and evidence entirely.
        The preference is lowered for the call alone and restored afterwards.

    .OUTPUTS
        ExitCode and Output. Never throws for a non-zero build.
    #>
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param(
        [Parameter(Mandatory)] [string[]] $Arguments,
        [Parameter()] [string] $Executable = 'packer'
    )

    $previous = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        $output = & $Executable @Arguments 2>&1
        $exitCode = $LASTEXITCODE
    }
    catch {
        # The command could not be started at all, which is distinct from a
        # build that ran and failed.
        return [PSCustomObject]@{ ExitCode = $null; Output = @("$($_.Exception.Message)") }
    }
    finally {
        $ErrorActionPreference = $previous
    }

    [PSCustomObject]@{ ExitCode = $exitCode; Output = @($output | ForEach-Object { "$_" }) }
}

Export-ModuleMember -Function Get-LabEvidenceOutcome, Get-LabOrchestrationEvidence, Get-GuestCleanupOutcome, Invoke-PackerBuild
