#Requires -Version 7.0

BeforeAll {
    $script:RepoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    Import-Module (Join-Path $script:RepoRoot 'source-qualification' 'scripts' 'RunIdentity.psm1') -Force
    Import-Module (Join-Path $script:RepoRoot 'source-qualification' 'scripts' 'Finalization.psm1') -Force

    function NewAdapter {
        <#
            Every platform interaction, injected. The finalizer's ordering and its
            refusals are exercised with no VMware Tools, no WinRM, and no Sysprep
            anywhere near the machine running the tests.
        #>
        param(
            [string] $FailAt,
            [bool] $PublishSucceeds = $true,
            [System.Collections.Generic.List[string]] $Log = $null
        )
        if ($null -eq $Log) { $Log = [System.Collections.Generic.List[string]]::new() }

        $state = @{ FailAt = $FailAt; PublishSucceeds = $PublishSucceeds; Log = $Log; Published = $null }

        # Each step gets its own closure rather than sharing a helper. A helper
        # invoked from inside a closure resolves its own free variables through
        # the caller's scope chain, which made every step read the wrong state
        # and fail at the first one whatever was asked for.
        $step = {
            param($State, [string] $Name)
            $State.Log.Add($Name)
            $State.FailAt -ne $Name
        }

        @{
            State                = $state
            ConfirmResidueAbsent = { & $step $state 'ConfirmResidueAbsent' }.GetNewClosure()
            DisableAccount       = { & $step $state 'DisableAccount' }.GetNewClosure()
            RemoveListener       = { & $step $state 'RemoveListener' }.GetNewClosure()
            RemoveFirewallRule   = { & $step $state 'RemoveFirewallRule' }.GetNewClosure()
            Verify               = { & $step $state 'Verify' }.GetNewClosure()
            PublishAttestation   = {
                param($Key, $Json)
                $state.Log.Add('PublishAttestation')
                $state.Published = $Json
                $state.PublishSucceeds
            }.GetNewClosure()
            InvokeSysprep        = { $state.Log.Add('InvokeSysprep') }.GetNewClosure()
        }
    }

    function Finalize {
        param($Adapter, [string] $RunId, [string] $Nonce)
        Invoke-GuestFinalization -RunId $RunId -Nonce $Nonce -Adapter $Adapter
    }
}

Describe 'the terminal transition' {

    It 'performs every step, publishes, then shuts down' {
        $adapter = NewAdapter
        $result = Finalize -Adapter $adapter -RunId (Get-RunIdentifier) -Nonce (Get-FinalizationNonce)

        $result.Outcome | Should -Be 'passed'
        $result.SysprepInvoked | Should -BeTrue
        @($adapter.State.Log) | Should -Be @(
            'ConfirmResidueAbsent', 'DisableAccount', 'RemoveListener',
            'RemoveFirewallRule', 'Verify', 'PublishAttestation', 'InvokeSysprep')
    }

    It 'publishes before it shuts down' {
        # After the machine is down nothing can publish.
        $adapter = NewAdapter
        $null = Finalize -Adapter $adapter -RunId (Get-RunIdentifier) -Nonce (Get-FinalizationNonce)

        $log = @($adapter.State.Log)
        $log.IndexOf('PublishAttestation') | Should -BeLessThan $log.IndexOf('InvokeSysprep')
    }

    It 'removes the listener before the firewall rule, and the account before both' {
        # A removed account with a listener still up is harmless. The reverse
        # leaves a reachable listener and a live account, which is the state this
        # exists to prevent.
        $adapter = NewAdapter
        $null = Finalize -Adapter $adapter -RunId (Get-RunIdentifier) -Nonce (Get-FinalizationNonce)

        $log = @($adapter.State.Log)
        $log.IndexOf('DisableAccount') | Should -BeLessThan $log.IndexOf('RemoveListener')
        $log.IndexOf('RemoveListener') | Should -BeLessThan $log.IndexOf('RemoveFirewallRule')
    }

    It 'does not invoke Sysprep when <step> fails' -ForEach @(
        @{ step = 'ConfirmResidueAbsent' }, @{ step = 'DisableAccount' }
        @{ step = 'RemoveListener' },       @{ step = 'RemoveFirewallRule' }
        @{ step = 'Verify' }
    ) {
        # The whole fail-closed property. A failed finalizer leaves the machine
        # running, which the build observes as a shutdown that never came.
        # Asserting only that it published a failure would be a different claim.
        $adapter = NewAdapter -FailAt $step
        $result = Finalize -Adapter $adapter -RunId (Get-RunIdentifier) -Nonce (Get-FinalizationNonce)

        $result.SysprepInvoked | Should -BeFalse
        @($adapter.State.Log) | Should -Not -Contain 'InvokeSysprep'
        $result.Outcome | Should -Be 'failed'
    }

    It 'skips the steps after a failure rather than attempting them' {
        # A later step succeeding would make the record read as though the
        # sequence had held.
        $adapter = NewAdapter -FailAt 'DisableAccount'
        $result = Finalize -Adapter $adapter -RunId (Get-RunIdentifier) -Nonce (Get-FinalizationNonce)

        @($adapter.State.Log) | Should -Not -Contain 'RemoveListener'
        @($result.Attestation.steps | Where-Object name -EQ 'listener-removed').outcome | Should -Be 'skipped'
    }

    It 'still publishes a failure before stopping' {
        # The machine stays up, and the reason it stayed up is readable.
        $adapter = NewAdapter -FailAt 'Verify'
        $result = Finalize -Adapter $adapter -RunId (Get-RunIdentifier) -Nonce (Get-FinalizationNonce)

        $adapter.State.Published | Should -Not -BeNullOrEmpty
        $result.ReasonCode | Should -Be 'verification_failed'
    }

    It 'refuses to shut down when it cannot publish' {
        # Shutting down here produces a generalized VM with no attestation:
        # refused later, but only after it has destroyed its own identity.
        $adapter = NewAdapter -PublishSucceeds $false

        { Finalize -Adapter $adapter -RunId (Get-RunIdentifier) -Nonce (Get-FinalizationNonce) } |
            Should -Throw -ExpectedMessage '*Refusing to shut down without it*'
        @($adapter.State.Log) | Should -Not -Contain 'InvokeSysprep'
    }

    It 'treats a throwing step as a failed one' {
        $adapter = NewAdapter
        $adapter['DisableAccount'] = { throw 'access denied' }
        $result = Finalize -Adapter $adapter -RunId (Get-RunIdentifier) -Nonce (Get-FinalizationNonce)

        $result.SysprepInvoked | Should -BeFalse
        $result.ReasonCode | Should -Be 'account_not_disabled'
    }

    It 'refuses a nonce that is not the expected shape' {
        { Finalize -Adapter (NewAdapter) -RunId (Get-RunIdentifier) -Nonce 'short' } | Should -Throw
    }
}

Describe 'the attestation is bounded and boring' {

    It 'satisfies its contract' {
        $adapter = NewAdapter
        $null = Finalize -Adapter $adapter -RunId (Get-RunIdentifier) -Nonce (Get-FinalizationNonce)

        Test-Json -Json $adapter.State.Published `
            -SchemaFile (Join-Path $script:RepoRoot 'contracts' 'finalization-attestation-1.schema.json') `
            -ErrorAction SilentlyContinue | Should -BeTrue
    }

    It 'stays well inside the bounded size' {
        $adapter = NewAdapter -FailAt 'Verify'
        $null = Finalize -Adapter $adapter -RunId (Get-RunIdentifier) -Nonce (Get-FinalizationNonce)

        [System.Text.Encoding]::UTF8.GetByteCount($adapter.State.Published) |
            Should -BeLessThan (Get-MaximumAttestationSize)
    }

    It 'carries no path, argument, or exception text' {
        # A free-text message quotes whatever it failed on, which is how paths,
        # arguments, and credentials escape a document meant to be a summary.
        $adapter = NewAdapter
        $adapter['Verify'] = { throw "cannot read C:/vdi-iac-build/secret.xml with password Zq7-Canary" }
        $null = Finalize -Adapter $adapter -RunId (Get-RunIdentifier) -Nonce (Get-FinalizationNonce)

        $adapter.State.Published | Should -Not -Match 'vdi-iac-build'
        $adapter.State.Published | Should -Not -Match 'Zq7-Canary'
        $adapter.State.Published | Should -Not -Match 'cannot read'
    }

    It 'names a transient key, so a clone cannot inherit it' {
        Get-FinalizationAttestationKey | Should -Be 'guestinfo.vdiiac.finalization'
    }
}

Describe 'reading the attestation from outside the guest' {

    BeforeAll {
        function PublishedAttestation {
            param([string] $RunId, [string] $Nonce, [string] $FailAt)
            $adapter = NewAdapter -FailAt $FailAt
            $null = Finalize -Adapter $adapter -RunId $RunId -Nonce $Nonce
            $adapter.State.Published
        }
    }

    It 'accepts an attestation from this run carrying this nonce' {
        $runId = Get-RunIdentifier; $nonce = Get-FinalizationNonce
        Test-FinalizationAttestation -Json (PublishedAttestation -RunId $runId -Nonce $nonce) `
            -RunId $runId -Nonce $nonce | Should -BeNullOrEmpty
    }

    It 'refuses a missing attestation' {
        # Missing is unverified, not probably-fine.
        Test-FinalizationAttestation -Json '' -RunId (Get-RunIdentifier) -Nonce (Get-FinalizationNonce) |
            Should -Be 'attestation_missing'
    }

    It 'refuses a malformed attestation' {
        Test-FinalizationAttestation -Json '{ not json' -RunId (Get-RunIdentifier) -Nonce (Get-FinalizationNonce) |
            Should -Be 'attestation_malformed'
    }

    It 'refuses an oversized value' {
        $oversized = '{"padding":"' + ('a' * (Get-MaximumAttestationSize)) + '"}'
        Test-FinalizationAttestation -Json $oversized -RunId (Get-RunIdentifier) -Nonce (Get-FinalizationNonce) |
            Should -Be 'attestation_oversized'
    }

    It 'refuses a stale attestation from a previous run' {
        $nonce = Get-FinalizationNonce
        $published = PublishedAttestation -RunId (Get-RunIdentifier) -Nonce $nonce

        Test-FinalizationAttestation -Json $published -RunId (Get-RunIdentifier) -Nonce $nonce |
            Should -Be 'attestation_run_id_mismatch'
    }

    It 'refuses an attestation this run did not write' {
        # The key is cleared before the finalizer launches, so a value carrying
        # another nonce is one left behind rather than one produced here.
        $runId = Get-RunIdentifier
        $published = PublishedAttestation -RunId $runId -Nonce (Get-FinalizationNonce)

        Test-FinalizationAttestation -Json $published -RunId $runId -Nonce (Get-FinalizationNonce) |
            Should -Be 'attestation_nonce_mismatch'
    }

    It 'refuses an attestation reporting failure' {
        $runId = Get-RunIdentifier; $nonce = Get-FinalizationNonce
        Test-FinalizationAttestation -Json (PublishedAttestation -RunId $runId -Nonce $nonce -FailAt 'Verify') `
            -RunId $runId -Nonce $nonce | Should -Be 'finalization_failed'
    }

    It 'refuses a passed attestation carrying a step that did not pass' {
        # Contradictory: the summary claims success while the sequence it
        # summarises did not hold.
        $runId = Get-RunIdentifier; $nonce = Get-FinalizationNonce
        $document = PublishedAttestation -RunId $runId -Nonce $nonce | ConvertFrom-Json
        $document.steps[2].outcome = 'skipped'

        Test-FinalizationAttestation -Json ($document | ConvertTo-Json -Depth 8 -Compress) `
            -RunId $runId -Nonce $nonce | Should -Be 'finalization_step_did_not_pass'
    }
}
