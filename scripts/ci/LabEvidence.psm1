#Requires -Version 7.0

<#
.SYNOPSIS
    Decides a lab run's outcome from retrieved guest evidence.

.DESCRIPTION
    A module rather than a function inside the orchestrator script, so tests can
    import it without executing that script. Dot-sourcing a script with mandatory
    parameters prompts for input instead of running, which hangs a suite rather
    than failing it.
#>

Set-StrictMode -Version 3.0

function Get-LabEvidenceOutcome {
    <#
    .SYNOPSIS
        Reads retrieved guest evidence and decides the run's outcome.

    .DESCRIPTION
        Separated from the Packer invocation so it can be tested without a
        target. Missing evidence is 'incomplete', not 'passed': a phase that left
        no evidence proved nothing.
    #>
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param(
        [Parameter(Mandatory)] [ValidateNotNullOrEmpty()] [string] $EvidenceDirectory
    )

    $documents = @(Get-ChildItem -Path $EvidenceDirectory -Filter '*guest-evidence.json' -File -ErrorAction SilentlyContinue)
    if ($documents.Count -eq 0) {
        return [PSCustomObject]@{ Outcome = 'incomplete'; Reason = 'no guest evidence was retrieved'; Phases = @() }
    }

    $phases = foreach ($document in $documents) {
        $parsed = Get-Content -LiteralPath $document.FullName -Raw | ConvertFrom-Json
        [PSCustomObject]@{
            File    = $document.Name
            Phase   = $parsed.payload.phase
            Outcome = $parsed.outcome
            Failed  = $parsed.payload.failedRequiredCount
        }
    }

    $outcome = if (@($phases | Where-Object Outcome -EQ 'incomplete').Count -gt 0) { 'incomplete' }
               elseif (@($phases | Where-Object Outcome -NE 'passed').Count -gt 0) { 'failed' }
               else { 'passed' }

    [PSCustomObject]@{
        Outcome = $outcome
        Reason  = if ($outcome -eq 'passed') { $null } else { 'a phase did not pass' }
        Phases  = @($phases)
    }
}

Export-ModuleMember -Function Get-LabEvidenceOutcome
