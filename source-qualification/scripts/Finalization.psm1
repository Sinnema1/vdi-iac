#Requires -Version 7.0

<#
.SYNOPSIS
    The terminal transition: tear the build access down, attest, and shut down.

.DESCRIPTION
    Increment 3 stage 5 steps 5 to 7, governed by ADR 8. This runs detached, as
    SYSTEM, because it removes the WinRM listener Packer reached the guest
    through -- a provisioner doing this would kill its own channel part way.

    The order is the design. Residue is re-confirmed, the build account is
    disabled, the listener and firewall rule are removed, all of it is verified
    by re-reading, the attestation is published, and only then does Sysprep run.

    Sysprep is reachable **only** after every gate passes. A finalizer that fails
    publishes a failure and leaves the machine running, which the build observes
    as a shutdown that never came. That is the whole fail-closed property, and it
    is why the builder must not be allowed to shut the guest down helpfully on
    its behalf.

    Publication precedes shutdown because after the machine is down nothing can
    publish. Failure to publish is itself terminal: a generalized VM with no
    attestation is refused later, but only after it has already generalized
    itself.

    Every platform interaction goes through an injected adapter, so the ordering
    and the refusals are exercised on any machine, with no VMware Tools, no
    WinRM, and no Sysprep present.

    What counts as torn down is the whole of the build's access, not just the
    parts that are obviously credentials. Sysprep removes none of it: the
    finalizer's own scheduled task, the build workspace holding scripts,
    contracts, evidence, and its log, and the WinRM certificate with its private
    key would all survive into the image. A generalized image carrying the
    private key of a listener it used to run is an image that ships with the
    means to impersonate one.
#>

Set-StrictMode -Version 3.0

Import-Module (Join-Path $PSScriptRoot 'RunIdentity.psm1')

$script:AttestationSchema = Join-Path $PSScriptRoot '..' '..' 'contracts' 'finalization-attestation-2.schema.json'

# The guest RPC key. Transient by design: the host clears it before launching the
# finalizer and again after reading it, so a value found here is one this run
# wrote and a clone cannot inherit a previous build's evidence.
$script:AttestationKey = 'guestinfo.vdiiac.finalization'

# Bounded. The channel is not a log, and a value that grows without limit is one
# nobody can reason about at the point it is read.
$script:MaximumAttestationBytes = 4096

# The steps a passed finalization performed, in the order it performed them.
# Exactly this sequence: a missing step means something was not done, a
# duplicate means the record was assembled rather than observed, and a reordered
# one means the safety property the order carries did not hold. An additional
# step is a finalizer this gate was not written for.
$script:RequiredSteps = @(
    'residue-confirmed'
    'account-disabled'
    'listener-removed'
    'firewall-rule-removed'
    'certificate-removed'
    'task-unregistered'
    'workspace-removed'
    'verified'
)

function Get-FinalizationAttestationKey { $script:AttestationKey }
function Get-MaximumAttestationSize { $script:MaximumAttestationBytes }

function Test-VMwareToolsPrerequisite {
    <#
    .SYNOPSIS
        Confirms VMware Tools is present, running, and the expected version.

    .DESCRIPTION
        The attestation channel is Tools' guest RPC interface, so Tools is a
        prerequisite rather than incidental software that happens to be there. A
        fresh Windows installation carries none of it.

        Checked before the finalizer launches, not inside it. A finalizer that
        discovered the problem would have to refuse to shut down -- correct, but
        it would have already disabled the account and removed the listener,
        leaving a machine nobody can reach and nothing can finish.

        The version is compared because it is a recipe input: a different Tools
        version is a different image, with a different way of reporting on
        itself.

    .PARAMETER Adapter
        GetToolsVersion and GetToolsRunning, injected. The production
        implementation uses the supported Windows command path; nothing here
        depends on which, and no vendor binary is committed.

    .OUTPUTS
        Satisfied, plus a bounded reason when it is not.
    #>
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param(
        [Parameter(Mandatory)] [ValidateNotNullOrEmpty()] [string] $ExpectedVersion,
        [Parameter(Mandatory)] [hashtable] $Adapter
    )

    function Unsatisfied([string] $Code) { [PSCustomObject]@{ Satisfied = $false; ReasonCode = $Code; Observed = $null } }

    $observed = $null
    try { $observed = & $Adapter['GetToolsVersion'] }
    catch { return Unsatisfied 'tools_not_installed' }

    if ([string]::IsNullOrWhiteSpace([string]$observed)) { return Unsatisfied 'tools_not_installed' }

    $running = $false
    try { $running = [bool](& $Adapter['GetToolsRunning']) }
    catch { $running = $false }
    if (-not $running) {
        return [PSCustomObject]@{ Satisfied = $false; ReasonCode = 'tools_not_running'; Observed = [string]$observed }
    }

    if (-not [string]::Equals([string]$observed, $ExpectedVersion, [System.StringComparison]::Ordinal)) {
        # Exact. A version is a recipe input, so "close enough" would mean the
        # digest names a Tools build that is not the one installed.
        return [PSCustomObject]@{ Satisfied = $false; ReasonCode = 'tools_version_mismatch'; Observed = [string]$observed }
    }

    [PSCustomObject]@{ Satisfied = $true; ReasonCode = $null; Observed = [string]$observed }
}

function Invoke-GuestFinalization {
    <#
    .SYNOPSIS
        Performs the terminal transition, and shuts down only if it fully worked.

    .PARAMETER Adapter
        Platform operations, injected: ConfirmResidueAbsent, DisableAccount,
        RemoveListener, RemoveFirewallRule, Verify, PublishAttestation, and
        InvokeSysprep.

    .OUTPUTS
        The attestation that was published, and whether Sysprep was invoked.
    #>
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param(
        [Parameter(Mandatory)] [ValidateNotNullOrEmpty()] [string] $RunId,
        [Parameter(Mandatory)] [ValidatePattern('^[0-9a-f]{32}$')] [string] $Nonce,
        [Parameter(Mandatory)] [hashtable] $Adapter
    )

    $validatedRunId = Assert-RunIdentifier -RunId $RunId
    $steps = [System.Collections.Generic.List[PSCustomObject]]::new()
    $reason = $null

    # Ordered, and each one gated on the last. Disabling the account before the
    # listener is removed leaves a window with a listener and no way in, which is
    # harmless; the reverse leaves a reachable listener and a live account, which
    # is the state this exists to prevent.
    # The workspace is removed second to last, because the steps before it read
    # from it -- the residue module lives there. The verification that follows
    # reads nothing from disk, which is what makes that ordering possible.
    foreach ($step in @(
            @{ Name = 'residue-confirmed';     Operation = 'ConfirmResidueAbsent'; Reason = 'residue_present' }
            @{ Name = 'account-disabled';      Operation = 'DisableAccount';       Reason = 'account_not_disabled' }
            @{ Name = 'listener-removed';      Operation = 'RemoveListener';       Reason = 'listener_not_removed' }
            @{ Name = 'firewall-rule-removed'; Operation = 'RemoveFirewallRule';   Reason = 'firewall_rule_not_removed' }
            @{ Name = 'certificate-removed';   Operation = 'RemoveCertificate';    Reason = 'certificate_not_removed' }
            @{ Name = 'task-unregistered';     Operation = 'UnregisterTask';       Reason = 'task_not_unregistered' }
            @{ Name = 'workspace-removed';     Operation = 'RemoveWorkspace';      Reason = 'workspace_not_removed' }
            @{ Name = 'verified';              Operation = 'Verify';               Reason = 'verification_failed' })) {

        if ($reason) {
            # Everything after a failure is skipped rather than attempted. A
            # later step succeeding would make the record read as though the
            # sequence had held.
            $steps.Add([PSCustomObject]@{ name = $step.Name; outcome = 'skipped' })
            continue
        }

        $succeeded = $false
        try { $succeeded = [bool](& $Adapter[$step.Operation]) }
        catch { $succeeded = $false }

        if ($succeeded) { $steps.Add([PSCustomObject]@{ name = $step.Name; outcome = 'passed' }) }
        else {
            $steps.Add([PSCustomObject]@{ name = $step.Name; outcome = 'failed' })
            $reason = $step.Reason
        }
    }

    $attestation = [ordered]@{
        attestationSchemaVersion = 2
        runId                    = $validatedRunId
        nonce                    = $Nonce
        completedUtc             = [datetime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ss.fffffffZ')
        outcome                  = $(if ($reason) { 'failed' } else { 'passed' })
        reasonCode               = $reason
        steps                    = @($steps)
    }

    $json = $attestation | ConvertTo-Json -Depth 8 -Compress
    if (-not (Test-Json -Json $json -SchemaFile $script:AttestationSchema -ErrorAction SilentlyContinue)) {
        throw 'The finalization attestation does not satisfy its own contract. Refusing to publish or shut down.'
    }
    if ([System.Text.Encoding]::UTF8.GetByteCount($json) -gt $script:MaximumAttestationBytes) {
        throw 'The finalization attestation exceeds the bounded size. Refusing to publish or shut down.'
    }

    $published = $false
    try { $published = [bool](& $Adapter['PublishAttestation'] $script:AttestationKey $json) }
    catch { $published = $false }

    if (-not $published) {
        # Terminal, and deliberately before Sysprep. Shutting down here would
        # produce a generalized VM with no attestation: refused later, but only
        # after the machine had already destroyed its own identity.
        throw 'The finalization attestation could not be published. Refusing to shut down without it.'
    }

    $sysprepInvoked = $false
    if (-not $reason) {
        # The adapter confirms or throws. An implementation that returned
        # nothing -- or false -- while doing nothing would otherwise be recorded
        # as a shutdown that happened, which is the one thing this result must
        # never claim falsely.
        $confirmed = & $Adapter['InvokeSysprep']
        if (-not $confirmed) {
            throw 'The Sysprep adapter did not confirm it ran. Refusing to report a shutdown that may not have happened.'
        }
        $sysprepInvoked = $true
    }

    [PSCustomObject]@{
        Attestation    = $attestation
        Json           = $json
        SysprepInvoked = $sysprepInvoked
        Outcome        = $attestation.outcome
        ReasonCode     = $reason
    }
}

function Test-FinalizationAttestation {
    <#
    .SYNOPSIS
        Returns a reason the attestation is unusable, or null.

    .DESCRIPTION
        Read from outside the guest, so every failure mode is a refusal rather
        than a question to ask the machine. Missing is unverified, not
        probably-fine; a value from another run is stale; a value carrying the
        wrong nonce is one this run did not write.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)] [AllowNull()] [AllowEmptyString()] [string] $Json,
        [Parameter(Mandatory)] [ValidateNotNullOrEmpty()] [string] $RunId,
        [Parameter(Mandatory)] [ValidateNotNullOrEmpty()] [string] $Nonce
    )

    if ([string]::IsNullOrWhiteSpace($Json)) { return 'attestation_missing' }
    if ([System.Text.Encoding]::UTF8.GetByteCount($Json) -gt $script:MaximumAttestationBytes) {
        return 'attestation_oversized'
    }
    if (-not (Test-Json -Json $Json -SchemaFile $script:AttestationSchema -ErrorAction SilentlyContinue)) {
        return 'attestation_malformed'
    }

    try { $attestation = $Json | ConvertFrom-Json } catch { return 'attestation_malformed' }

    if (-not [string]::Equals($attestation.runId, $RunId, [System.StringComparison]::Ordinal)) {
        return 'attestation_run_id_mismatch'
    }
    if (-not [string]::Equals($attestation.nonce, $Nonce, [System.StringComparison]::Ordinal)) {
        return 'attestation_nonce_mismatch'
    }
    # Semantic consistency the schema cannot express: outcome and reason code
    # have to agree with each other and with the steps.
    $reason = if ($attestation.PSObject.Properties.Name -contains 'reasonCode') { $attestation.reasonCode } else { $null }

    if ($attestation.outcome -eq 'passed' -and $reason) { return 'attestation_inconsistent' }
    if ($attestation.outcome -eq 'failed' -and -not $reason) { return 'attestation_inconsistent' }

    if ($attestation.outcome -ne 'passed') { return 'finalization_failed' }

    # Exactly the required sequence. Comparing sets or counting passes would
    # accept a record with a step missing, one listed twice, or the teardown
    # performed in an order whose safety property does not hold.
    $observed = @($attestation.steps | ForEach-Object { $_.name })
    if ($observed.Count -ne $script:RequiredSteps.Count) { return 'finalization_step_sequence_wrong' }
    for ($i = 0; $i -lt $script:RequiredSteps.Count; $i++) {
        if ($observed[$i] -ne $script:RequiredSteps[$i]) { return 'finalization_step_sequence_wrong' }
    }

    if (@($attestation.steps | Where-Object { $_.outcome -ne 'passed' }).Count -gt 0) {
        return 'finalization_step_did_not_pass'
    }

    $null
}

function Get-FinalizationNonce {
    <#
        Host-generated, per run. The key is cleared before the finalizer launches,
        so a value carrying this nonce is one this run wrote rather than one a
        previous build left behind on a reused machine.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param()

    # Cryptographic, not Get-Random. The nonce is what distinguishes an
    # attestation this run wrote from one left behind on a reused machine, so a
    # predictable value would let a stale document be accepted by a later build
    # that happened to draw the same sequence.
    $bytes = [byte[]]::new(16)
    [System.Security.Cryptography.RandomNumberGenerator]::Fill($bytes)
    ([System.BitConverter]::ToString($bytes) -replace '-', '').ToLowerInvariant()
}

Export-ModuleMember -Function Test-VMwareToolsPrerequisite, Invoke-GuestFinalization, Test-FinalizationAttestation,
    Get-FinalizationNonce, Get-FinalizationAttestationKey, Get-MaximumAttestationSize
