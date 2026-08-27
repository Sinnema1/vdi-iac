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
            [bool] $SysprepConfirms = $true,
            [System.Collections.Generic.List[string]] $Log = $null
        )
        if ($null -eq $Log) { $Log = [System.Collections.Generic.List[string]]::new() }

        $state = @{ FailAt = $FailAt; PublishSucceeds = $PublishSucceeds; Log = $Log
                    Published = $null; PublishedKey = $null; SysprepConfirms = $SysprepConfirms }

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
                # The key is recorded as well as the value: publishing the right
                # document under the wrong key is indistinguishable from not
                # publishing at all, and the sealing phase reads one key.
                $state.PublishedKey = $Key
                $state.Published = $Json
                $state.PublishSucceeds
            }.GetNewClosure()
            InvokeSysprep        = { $state.Log.Add('InvokeSysprep'); $state.SysprepConfirms }.GetNewClosure()
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

    It 'publishes under the key the sealing phase reads' {
        # The right document under the wrong key is indistinguishable from
        # nothing published at all, and the sealing phase reads exactly one key.
        $adapter = NewAdapter
        $null = Finalize -Adapter $adapter -RunId (Get-RunIdentifier) -Nonce (Get-FinalizationNonce)

        $adapter.State.PublishedKey | Should -Be (Get-FinalizationAttestationKey)
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

Describe 'the step sequence is exact' {

    BeforeAll {
        function PassedAttestation {
            param([string] $RunId, [string] $Nonce)
            $adapter = NewAdapter
            $null = Finalize -Adapter $adapter -RunId $RunId -Nonce $Nonce
            $adapter.State.Published | ConvertFrom-Json
        }

        function Judge {
            param($Document, [string] $RunId, [string] $Nonce)
            Test-FinalizationAttestation -Json ($Document | ConvertTo-Json -Depth 8 -Compress) `
                -RunId $RunId -Nonce $Nonce
        }
    }

    It 'accepts exactly the required sequence' {
        $runId = Get-RunIdentifier; $nonce = Get-FinalizationNonce
        Judge -Document (PassedAttestation -RunId $runId -Nonce $nonce) -RunId $runId -Nonce $nonce |
            Should -BeNullOrEmpty
    }

    It 'refuses a sequence with <case>' -ForEach @(
        @{ case = 'a step missing';    action = 'remove' }
        @{ case = 'a step duplicated'; action = 'duplicate' }
        @{ case = 'steps reordered';   action = 'reorder' }
        @{ case = 'an extra step';     action = 'extra' }
    ) {
        # Counting passes or comparing sets accepts every one of these. A
        # missing step means something was not done; a duplicate means the
        # record was assembled rather than observed; a reordering means the
        # safety property the order carries did not hold.
        $runId = Get-RunIdentifier; $nonce = Get-FinalizationNonce
        $document = PassedAttestation -RunId $runId -Nonce $nonce
        $steps = @($document.steps)

        $document.steps = switch ($action) {
            'remove'    { @($steps[0], $steps[1], $steps[3], $steps[4]) }
            'duplicate' { @($steps[0], $steps[1], $steps[1], $steps[2], $steps[3], $steps[4]) }
            'reorder'   { @($steps[0], $steps[2], $steps[1], $steps[3], $steps[4]) }
            'extra'     { @($steps) + @([PSCustomObject]@{ name = 'verified'; outcome = 'passed' }) }
        }

        Judge -Document $document -RunId $runId -Nonce $nonce | Should -Be 'finalization_step_sequence_wrong'
    }

    It 'refuses a passed outcome carrying a reason code' {
        # The summary contradicts itself, and the reason is the more specific of
        # the two claims.
        $runId = Get-RunIdentifier; $nonce = Get-FinalizationNonce
        $document = PassedAttestation -RunId $runId -Nonce $nonce
        $document.reasonCode = 'verification_failed'

        Judge -Document $document -RunId $runId -Nonce $nonce | Should -Be 'attestation_inconsistent'
    }

    It 'refuses a failed outcome carrying no reason code' {
        # A failure that will not say why is not a bounded result.
        $runId = Get-RunIdentifier; $nonce = Get-FinalizationNonce
        $document = PassedAttestation -RunId $runId -Nonce $nonce
        $document.outcome = 'failed'
        $document.reasonCode = $null

        Judge -Document $document -RunId $runId -Nonce $nonce | Should -Be 'attestation_inconsistent'
    }
}

Describe 'the Sysprep adapter must confirm' {

    It 'refuses to report a shutdown the adapter did not confirm' {
        # An adapter returning nothing while doing nothing would otherwise be
        # recorded as a shutdown that happened, which is the one claim this
        # result must never make falsely.
        $adapter = NewAdapter -SysprepConfirms $false

        { Finalize -Adapter $adapter -RunId (Get-RunIdentifier) -Nonce (Get-FinalizationNonce) } |
            Should -Throw -ExpectedMessage '*did not confirm it ran*'
    }

    It 'reports a shutdown only when the adapter confirmed one' {
        $adapter = NewAdapter
        (Finalize -Adapter $adapter -RunId (Get-RunIdentifier) -Nonce (Get-FinalizationNonce)).SysprepInvoked |
            Should -BeTrue
    }
}

Describe 'the finalization nonce' {

    It 'is 32 lowercase hexadecimal characters' {
        Get-FinalizationNonce | Should -Match '^[0-9a-f]{32}$'
    }

    It 'does not repeat across draws' {
        # A predictable nonce lets a stale attestation be accepted by a later
        # build that happened to draw the same value.
        $draws = 1..64 | ForEach-Object { Get-FinalizationNonce }
        ($draws | Sort-Object -Unique).Count | Should -Be 64
    }

    It 'comes from a cryptographic generator' {
        # Read with comments stripped. The module explains why Get-Random is not
        # used, and a naive search finds that explanation and reports the
        # opposite of the truth.
        $module = Get-Content -LiteralPath (Join-Path $script:RepoRoot 'source-qualification' 'scripts' 'Finalization.psm1')
        $code = ($module | Where-Object { $_.TrimStart() -notlike '#*' }) -join "`n"

        $code | Should -Match 'RandomNumberGenerator'
        $code | Should -Not -Match 'Get-Random'
    }
}

Describe 'VMware Tools is a prerequisite, not an assumption' {

    BeforeAll {
        function NewToolsAdapter {
            param([string] $Version = '12.5.0', [bool] $Running = $true, [switch] $Throws)
            $state = @{ Version = $Version; Running = $Running; Throws = [bool] $Throws }
            @{
                GetToolsVersion = {
                    if ($state.Throws) { throw 'the RPC tool was not found' } else { $state.Version }
                }.GetNewClosure()
                GetToolsRunning = { $state.Running }.GetNewClosure()
            }
        }
    }

    It 'is satisfied by the expected version, running' {
        $result = Test-VMwareToolsPrerequisite -ExpectedVersion '12.5.0' -Adapter (NewToolsAdapter)
        $result.Satisfied | Should -BeTrue
        $result.Observed | Should -Be '12.5.0'
    }

    It 'refuses a machine with no Tools at all' {
        # A fresh Windows installation carries none of it, and the attestation
        # channel is its RPC interface.
        (Test-VMwareToolsPrerequisite -ExpectedVersion '12.5.0' -Adapter (NewToolsAdapter -Throws)).ReasonCode |
            Should -Be 'tools_not_installed'
    }

    It 'refuses an empty version' {
        (Test-VMwareToolsPrerequisite -ExpectedVersion '12.5.0' -Adapter (NewToolsAdapter -Version '')).ReasonCode |
            Should -Be 'tools_not_installed'
    }

    It 'refuses Tools that is installed but not running' {
        (Test-VMwareToolsPrerequisite -ExpectedVersion '12.5.0' -Adapter (NewToolsAdapter -Running $false)).ReasonCode |
            Should -Be 'tools_not_running'
    }

    It 'refuses a version other than the one the recipe names' {
        # The version is a recipe input, so "close enough" would mean the digest
        # names a Tools build that is not the one installed.
        $result = Test-VMwareToolsPrerequisite -ExpectedVersion '12.5.0' -Adapter (NewToolsAdapter -Version '12.4.9')
        $result.ReasonCode | Should -Be 'tools_version_mismatch'
        $result.Observed | Should -Be '12.4.9'
    }

    It 'compares exactly, not by prefix' {
        (Test-VMwareToolsPrerequisite -ExpectedVersion '12.5.0' -Adapter (NewToolsAdapter -Version '12.5.01')).Satisfied |
            Should -BeFalse
    }

    It 'commits no vendor binary to reach the tool' {
        # The production adapter invokes the supported Windows command path by
        # name from wherever Tools installs it.
        Get-ChildItem -Path $script:RepoRoot -Recurse -File -Include '*.exe', '*.dll', '*.msi' -ErrorAction SilentlyContinue |
            Where-Object { $_.FullName -notmatch '[\\/]\.git[\\/]' } |
            Should -BeNullOrEmpty
    }
}
