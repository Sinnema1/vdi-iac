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
#>

Set-StrictMode -Version 3.0

Import-Module (Join-Path $PSScriptRoot 'RunIdentity.psm1')

$script:AttestationSchema = Join-Path $PSScriptRoot '..' '..' 'contracts' 'finalization-attestation-1.schema.json'

# The guest RPC key. Transient by design: the host clears it before launching the
# finalizer and again after reading it, so a value found here is one this run
# wrote and a clone cannot inherit a previous build's evidence.
$script:AttestationKey = 'guestinfo.vdiiac.finalization'

# Bounded. The channel is not a log, and a value that grows without limit is one
# nobody can reason about at the point it is read.
$script:MaximumAttestationBytes = 4096

function Get-FinalizationAttestationKey { $script:AttestationKey }
function Get-MaximumAttestationSize { $script:MaximumAttestationBytes }

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
    foreach ($step in @(
            @{ Name = 'residue-confirmed';    Operation = 'ConfirmResidueAbsent'; Reason = 'residue_present' }
            @{ Name = 'account-disabled';     Operation = 'DisableAccount';       Reason = 'account_not_disabled' }
            @{ Name = 'listener-removed';     Operation = 'RemoveListener';       Reason = 'listener_not_removed' }
            @{ Name = 'firewall-rule-removed'; Operation = 'RemoveFirewallRule';  Reason = 'firewall_rule_not_removed' }
            @{ Name = 'verified';             Operation = 'Verify';               Reason = 'verification_failed' })) {

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
        attestationSchemaVersion = 1
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
        & $Adapter['InvokeSysprep']
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
    if ($attestation.outcome -ne 'passed') { return 'finalization_failed' }
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
    -join ((1..32) | ForEach-Object { '{0:x}' -f (Get-Random -Minimum 0 -Maximum 16) })
}

Export-ModuleMember -Function Invoke-GuestFinalization, Test-FinalizationAttestation,
    Get-FinalizationNonce, Get-FinalizationAttestationKey, Get-MaximumAttestationSize
