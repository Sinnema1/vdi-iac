#Requires -Version 7.0

<#
.SYNOPSIS
    The semantic rules guest evidence must satisfy beyond its schema.

.DESCRIPTION
    One implementation, used everywhere a decision is made from guest evidence:
    the restart gate inside the guest and the orchestration verdict on the host.
    Two copies of these rules would drift, and the copy that drifted would be the
    one making the decision that mattered.

    Every rule here relates fields the schema constrains separately. A document
    can satisfy every field constraint and still describe two different runs, or
    claim a result its own package list contradicts, so schema validity is a
    precondition for calling these rules rather than a substitute for them.
#>

Set-StrictMode -Version 3.0

function ReadOptional {
    # terminalReasonCode is optional in the schema, and under StrictMode reading
    # an absent property throws rather than yielding null.
    param($Object, [string] $Name)
    if ($Object.PSObject.Properties.Name -contains $Name) { $Object.$Name } else { $null }
}

function Test-GuestEvidenceConsistency {
    <#
    .SYNOPSIS
        Returns a reason code when a document contradicts itself, or null.

    .PARAMETER RestartDecision
        Applies the rules that matter only when the caller is deciding whether to
        reboot. An installer that timed out and could not be terminated may still
        be running, and a reboot is the one action that must never meet it. That
        is not a contradiction in the document -- evidence reporting it is honest
        and the host is right to record it as a halt -- so the rule is scoped to
        the decision it protects rather than making an accurate report read as
        malformed.

    .OUTPUTS
        A bounded reason code, or null when every rule holds.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)] $Evidence,
        [Parameter()] [switch] $RestartDecision
    )

    $payload = $Evidence.payload
    $packages = @($payload.packages)
    $terminal = ReadOptional -Object $payload -Name 'terminalReasonCode'

    if ($RestartDecision) {
        # Checked before anything else and independently of the terminal reason.
        # A package can report that its process outlived termination while the
        # payload records some other terminal cause, or none at all, and the
        # danger is identical in all three cases.
        if (@($packages | Where-Object { (ReadOptional -Object $_ -Name 'reasonCode') -eq 'install_timeout_termination_failed' }).Count -gt 0) {
            return 'install_termination_unconfirmed'
        }
    }

    if ($Evidence.outcome -eq 'passed') {
        if ($payload.failedRequiredCount -ne 0) { return 'evidence_inconsistent' }
        if ($terminal) { return 'evidence_inconsistent' }
        # Stated separately from the rule below it. A passed result carrying a
        # failed *required* package is the case that would let a build proceed on
        # a missing prerequisite, and it should fail its own assertion rather
        # than only as a side effect of the broader one.
        if (@($packages | Where-Object { $_.outcome -ne 'passed' -and $_.required }).Count -gt 0) { return 'evidence_inconsistent' }
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

    # The execution witness. Unguarded: both fields are required by the envelope
    # schema the evidence has already been validated against, so a presence check
    # could only skip the comparison, never reach a document that omits them.
    if ($payload.installerAttemptCount -ne @($packages | Where-Object { $_.installerAttempted }).Count) {
        return 'evidence_inconsistent'
    }

    $null
}

function Test-GuestEvidencePairConsistency {
    <#
    .SYNOPSIS
        Returns a reason code when two phases do not describe the same run, or null.

    .DESCRIPTION
        Identity is id *and* version. Comparing identifiers alone would accept an
        install of one version validated against another, which is precisely the
        substitution a per-package hash cannot catch: both documents are
        internally consistent and only their relationship is wrong.

    .OUTPUTS
        A bounded reason code, or null when the two phases agree.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)] $InstallEvidence,
        [Parameter(Mandatory)] $ValidateEvidence
    )

    $identity = {
        param($Evidence)
        @(@($Evidence.payload.packages | ForEach-Object { "$($_.id)@$($_.version)" }) | Sort-Object) -join '|'
    }

    if ((& $identity $InstallEvidence) -ne (& $identity $ValidateEvidence)) { return 'evidence_inconsistent' }
    if ($InstallEvidence.manifestSchemaVersion -ne $ValidateEvidence.manifestSchemaVersion) { return 'evidence_inconsistent' }

    $null
}

Export-ModuleMember -Function Test-GuestEvidenceConsistency, Test-GuestEvidencePairConsistency
