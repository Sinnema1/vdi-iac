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

    $expectedNames = if ($RequireValidatePhase) { $script:ExpectedPhases.Keys } else { @('install-guest-evidence.json') }

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

        $phases.Add([PSCustomObject]@{
            phase               = $parsed.payload.phase
            outcome             = $parsed.outcome
            failedRequiredCount = $parsed.payload.failedRequiredCount
        })
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

    $outcome = if ($HostCleanupOutcome -eq 'failed' -or $GuestCleanupOutcome -eq 'failed') { 'incomplete' }
               else { $Verdict.Outcome }

    $terminal = if ($HostCleanupOutcome -eq 'failed' -or $GuestCleanupOutcome -eq 'failed') { 'cleanup_failed' }
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

Export-ModuleMember -Function Get-LabEvidenceOutcome, Get-LabOrchestrationEvidence
