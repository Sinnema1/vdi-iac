#Requires -Version 7.0

BeforeAll {
    $script:RepoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    Import-Module (Join-Path $script:RepoRoot 'source-qualification' 'scripts' 'RunIdentity.psm1') -Force
    Import-Module (Join-Path $script:RepoRoot 'source-qualification' 'scripts' 'Finalization.psm1') -Force
    Import-Module (Join-Path $script:RepoRoot 'scripts' 'ci' 'Sealing.psm1') -Force

    function PassedAttestationJson {
        <#
            A real attestation, produced by the real finalizer against injected
            steps, rather than a document written to match the reader.
        #>
        param([string] $RunId, [string] $Nonce)
        $captured = @{ Json = $null; Key = $null }
        $adapter = @{
            ConfirmResidueAbsent = { $true }
            DisableAccount       = { $true }
            RemoveListener       = { $true }
            RemoveFirewallRule   = { $true }
            Verify               = { $true }
            PublishAttestation   = { param($Key, $Json) $captured.Key = $Key; $captured.Json = $Json; $true }.GetNewClosure()
            InvokeSysprep        = { $true }
        }
        $null = Invoke-GuestFinalization -RunId $RunId -Nonce $Nonce -Adapter $adapter
        $captured.Json
    }

    function NewIdentity {
        # SYNTHETIC. Invented to exercise the contract; no vSphere instance
        # produced any of it, and it is never evidence that one did.
        param([string] $Reference = 'vm-1234')
        [PSCustomObject]@{
            vCenterInstanceId      = 'vcenter-instance-a'
            managedObjectReference = $Reference
            instanceUuid           = '3f2504e0-4f89-41d3-9a0c-0305e82c3301'
            recordedName           = 'windows-candidate'
        }
    }

    function NewPlatform {
        param(
            [string] $Attestation,
            [string] $PowerState = 'poweredOff',
            [bool] $Resolves = $true,
            [bool] $ClearWorks = $true,
            [bool] $ConvertWorks = $true,
            $Identity = $null,
            [switch] $IdentityMissing
        )
        if ($null -eq $Identity -and -not $IdentityMissing) { $Identity = NewIdentity }

        # Every argument the coordinator passes is recorded rather than ignored.
        # An adapter that accepted a machine and a key and discarded both would
        # let the coordinator read the wrong key, or act on a machine it never
        # resolved, with nothing here noticing.
        $state = @{
            Attestation = $Attestation; PowerState = $PowerState; Resolves = $Resolves
            ClearWorks = $ClearWorks; ConvertWorks = $ConvertWorks
            Identity = $Identity; Converted = $false; Cleared = $false
            Log = [System.Collections.Generic.List[string]]::new()
            ResolvedRun = $null; ReadKeys = [System.Collections.Generic.List[string]]::new()
            ClearedKeys = [System.Collections.Generic.List[string]]::new()
            MachinesSeen = [System.Collections.Generic.List[string]]::new()
        }

        @{
            State = $state
            ResolveVirtualMachine = {
                param($Run, $Name)
                $state.Log.Add('Resolve')
                $state.ResolvedRun = $Run
                if ($state.Resolves) { [PSCustomObject]@{ Name = $Name; Run = $Run } } else { $null }
            }.GetNewClosure()
            GetPowerState = {
                param($Machine)
                $state.Log.Add('PowerState')
                $state.MachinesSeen.Add($Machine.Name)
                $state.PowerState
            }.GetNewClosure()
            ReadGuestInfo = {
                param($Machine, $Key)
                $state.Log.Add('Read')
                $state.MachinesSeen.Add($Machine.Name)
                $state.ReadKeys.Add($Key)
                if ($state.Cleared) { '' } else { $state.Attestation }
            }.GetNewClosure()
            ClearGuestInfo = {
                param($Machine, $Key)
                $state.Log.Add('Clear')
                $state.MachinesSeen.Add($Machine.Name)
                $state.ClearedKeys.Add($Key)
                if (-not $state.ClearWorks) { throw 'clear failed' }
                $state.Cleared = $true
                $true
            }.GetNewClosure()
            ConvertToTemplate = {
                param($Machine)
                $state.Log.Add('Convert')
                $state.MachinesSeen.Add($Machine.Name)
                if (-not $state.ConvertWorks) { throw 'convert failed' }
                $state.Converted = $true
                $true
            }.GetNewClosure()
            GetArtifactIdentity = {
                param($Machine)
                $state.Log.Add('Identity')
                $state.MachinesSeen.Add($Machine.Name)
                $state.Identity
            }.GetNewClosure()
        }
    }

    function Seal {
        param($Platform, [string] $RunId, [string] $Nonce, [bool] $PackerSucceeded = $true)
        Invoke-CandidateSealing -RunId $RunId -Nonce $Nonce -CandidateName 'windows-candidate' `
            -PackerSucceeded $PackerSucceeded -Adapter $Platform -Confirm:$false
    }
}

Describe 'sealing a finalized candidate' {

    It 'seals a powered-off machine whose attestation checks out' {
        $runId = Get-RunIdentifier; $nonce = Get-FinalizationNonce
        $platform = NewPlatform -Attestation (PassedAttestationJson -RunId $runId -Nonce $nonce)

        $result = Seal -Platform $platform -RunId $runId -Nonce $nonce
        $result.BuildState | Should -Be 'sealed'
        $result.Outcome | Should -Be 'passed'
        $result.ArtifactIdentity.managedObjectReference | Should -Be 'vm-1234'
        $result.UnconfirmedArtifact | Should -BeNullOrEmpty
    }

    It 'clears the attestation before it converts' {
        # A template inheriting a previous build's attestation hands every clone
        # evidence about a machine it is not.
        $runId = Get-RunIdentifier; $nonce = Get-FinalizationNonce
        $platform = NewPlatform -Attestation (PassedAttestationJson -RunId $runId -Nonce $nonce)
        $null = Seal -Platform $platform -RunId $runId -Nonce $nonce

        $log = @($platform.State.Log)
        $log.IndexOf('Clear') | Should -BeLessThan $log.IndexOf('Convert')
    }

    It 'reads and clears the key the finalizer published to' {
        # The right document under the wrong key is indistinguishable from
        # nothing published, and clearing a different key leaves the real one in
        # place for a clone to inherit.
        $runId = Get-RunIdentifier; $nonce = Get-FinalizationNonce
        $platform = NewPlatform -Attestation (PassedAttestationJson -RunId $runId -Nonce $nonce)
        $null = Seal -Platform $platform -RunId $runId -Nonce $nonce

        @($platform.State.ReadKeys) | Should -Not -BeNullOrEmpty
        foreach ($key in $platform.State.ReadKeys) { $key | Should -Be (Get-FinalizationAttestationKey) }
        foreach ($key in $platform.State.ClearedKeys) { $key | Should -Be (Get-FinalizationAttestationKey) }
    }

    It 'resolves by run identity and acts only on what it resolved' {
        # A name is mutable and reusable. Acting on a machine other than the one
        # resolved is how one build's artifact acquires another's provenance.
        $runId = Get-RunIdentifier; $nonce = Get-FinalizationNonce
        $platform = NewPlatform -Attestation (PassedAttestationJson -RunId $runId -Nonce $nonce)
        $null = Seal -Platform $platform -RunId $runId -Nonce $nonce

        $platform.State.ResolvedRun | Should -Be $runId
        ($platform.State.MachinesSeen | Sort-Object -Unique) | Should -Be @('windows-candidate')
    }

    It 'verifies the clear by re-reading rather than trusting it' {
        $runId = Get-RunIdentifier; $nonce = Get-FinalizationNonce
        $platform = NewPlatform -Attestation (PassedAttestationJson -RunId $runId -Nonce $nonce)
        $null = Seal -Platform $platform -RunId $runId -Nonce $nonce

        # Read twice: once for the attestation, once to confirm it is gone.
        @($platform.State.Log | Where-Object { $_ -eq 'Read' }).Count | Should -BeGreaterOrEqual 2
    }
}

Describe 'nothing is sealed before it is certain' {

    It 'refuses when Packer did not succeed' {
        # A failed build produced a machine in whatever state it failed in, and
        # sealing makes that permanent.
        $runId = Get-RunIdentifier; $nonce = Get-FinalizationNonce
        $platform = NewPlatform -Attestation (PassedAttestationJson -RunId $runId -Nonce $nonce)

        $result = Seal -Platform $platform -RunId $runId -Nonce $nonce -PackerSucceeded $false
        $result.ReasonCode | Should -Be 'construction_failed'
        @($platform.State.Log) | Should -Not -Contain 'Convert'
    }

    It 'refuses when the machine cannot be resolved by run identity' {
        # A name is mutable and reusable, so sealing whatever answers to it is
        # how one build's artifact acquires another build's provenance.
        $runId = Get-RunIdentifier; $nonce = Get-FinalizationNonce
        $platform = NewPlatform -Attestation (PassedAttestationJson -RunId $runId -Nonce $nonce) -Resolves $false

        (Seal -Platform $platform -RunId $runId -Nonce $nonce).ReasonCode | Should -Be 'vm_not_resolved'
    }

    It 'refuses a machine that is still <state>' -ForEach @(
        @{ state = 'poweredOn' }, @{ state = 'suspended' }, @{ state = 'unknown' }
    ) {
        # Observed through the platform. A guest command that says it will shut
        # down is not a shutdown that happened.
        $runId = Get-RunIdentifier; $nonce = Get-FinalizationNonce
        $platform = NewPlatform -Attestation (PassedAttestationJson -RunId $runId -Nonce $nonce) -PowerState $state

        $result = Seal -Platform $platform -RunId $runId -Nonce $nonce
        $result.ReasonCode | Should -Be 'vm_not_powered_off'
        @($platform.State.Log) | Should -Not -Contain 'Convert'
    }

    It 'refuses <case>' -ForEach @(
        @{ case = 'a missing attestation';   reason = 'attestation_missing' }
        @{ case = 'a malformed attestation'; reason = 'attestation_malformed' }
    ) {
        $runId = Get-RunIdentifier; $nonce = Get-FinalizationNonce
        $value = if ($case -like '*missing*') { '' } else { '{ not json' }
        $platform = NewPlatform -Attestation $value

        (Seal -Platform $platform -RunId $runId -Nonce $nonce).ReasonCode | Should -Be $reason
    }

    It 'refuses an attestation from a previous build' {
        $nonce = Get-FinalizationNonce
        $stale = PassedAttestationJson -RunId (Get-RunIdentifier) -Nonce $nonce
        $runId = Get-RunIdentifier
        $platform = NewPlatform -Attestation $stale

        (Seal -Platform $platform -RunId $runId -Nonce $nonce).ReasonCode | Should -Be 'attestation_run_id_mismatch'
    }

    It 'refuses an attestation this run did not write' {
        $runId = Get-RunIdentifier
        $platform = NewPlatform -Attestation (PassedAttestationJson -RunId $runId -Nonce (Get-FinalizationNonce))

        (Seal -Platform $platform -RunId $runId -Nonce (Get-FinalizationNonce)).ReasonCode |
            Should -Be 'attestation_nonce_mismatch'
    }

    It 'blocks conversion when the attestation cannot be cleared' {
        # The artifact is not made immutable while it still carries evidence
        # that would outlive the machine it describes.
        $runId = Get-RunIdentifier; $nonce = Get-FinalizationNonce
        $platform = NewPlatform -Attestation (PassedAttestationJson -RunId $runId -Nonce $nonce) -ClearWorks $false

        $result = Seal -Platform $platform -RunId $runId -Nonce $nonce
        $result.ReasonCode | Should -Be 'attestation_not_cleared'
        $result.BuildState | Should -Be 'pre-seal'
        @($platform.State.Log) | Should -Not -Contain 'Convert'
        $platform.State.Converted | Should -BeFalse
    }

    It 'reports nothing attempted under -WhatIf, and converts nothing' {
        $runId = Get-RunIdentifier; $nonce = Get-FinalizationNonce
        $platform = NewPlatform -Attestation (PassedAttestationJson -RunId $runId -Nonce $nonce)

        $result = Invoke-CandidateSealing -RunId $runId -Nonce $nonce -CandidateName 'windows-candidate' `
            -PackerSucceeded $true -Adapter $platform -WhatIf

        $result.ReasonCode | Should -Be 'not_attempted'
        $platform.State.Converted | Should -BeFalse
    }
}

Describe 'ambiguity after conversion is never a candidate' {

    It 'reports an unconfirmed artifact when conversion fails' {
        # Something may exist. Recording what may exist lets it be reconciled or
        # removed; naming it a candidate would publish it as accepted.
        $runId = Get-RunIdentifier; $nonce = Get-FinalizationNonce
        $platform = NewPlatform -Attestation (PassedAttestationJson -RunId $runId -Nonce $nonce) -ConvertWorks $false

        $result = Seal -Platform $platform -RunId $runId -Nonce $nonce
        $result.BuildState | Should -Be 'seal-unconfirmed'
        $result.Outcome | Should -Be 'incomplete'
        $result.ReasonCode | Should -Be 'seal_failed'
        $result.ArtifactIdentity | Should -BeNullOrEmpty
        $result.UnconfirmedArtifact | Should -Not -BeNullOrEmpty
    }

    It 'reports an unconfirmed artifact when the identity cannot be read' {
        # An artifact nothing can refer to is not one anything downstream can
        # use, whatever the conversion reported.
        $runId = Get-RunIdentifier; $nonce = Get-FinalizationNonce
        $platform = NewPlatform -Attestation (PassedAttestationJson -RunId $runId -Nonce $nonce) -IdentityMissing

        $result = Seal -Platform $platform -RunId $runId -Nonce $nonce
        $result.BuildState | Should -Be 'seal-unconfirmed'
        $result.ReasonCode | Should -Be 'seal_unconfirmed'
        $result.ArtifactIdentity | Should -BeNullOrEmpty
    }

    It 'reports an unconfirmed artifact when the identity is incomplete' {
        # A managed object reference is unique only within its instance, so an
        # identity missing any part of that scope names nothing durably.
        $runId = Get-RunIdentifier; $nonce = Get-FinalizationNonce
        $partial = NewIdentity
        $partial.instanceUuid = ''
        $platform = NewPlatform -Attestation (PassedAttestationJson -RunId $runId -Nonce $nonce) -Identity $partial

        $result = Seal -Platform $platform -RunId $runId -Nonce $nonce
        $result.BuildState | Should -Be 'seal-unconfirmed'
        $result.ArtifactIdentity | Should -BeNullOrEmpty
        $result.UnconfirmedArtifact | Should -Not -BeNullOrEmpty
    }

    It 'never reports a sealed state without a complete identity' {
        # The property that matters across every path above.
        $runId = Get-RunIdentifier; $nonce = Get-FinalizationNonce
        foreach ($platform in @(
                (NewPlatform -Attestation (PassedAttestationJson -RunId $runId -Nonce $nonce) -ConvertWorks $false)
                (NewPlatform -Attestation (PassedAttestationJson -RunId $runId -Nonce $nonce) -IdentityMissing)
                (NewPlatform -Attestation ''))) {

            $result = Seal -Platform $platform -RunId $runId -Nonce $nonce
            if ($result.BuildState -eq 'sealed') {
                $result.ArtifactIdentity | Should -Not -BeNullOrEmpty
            }
            else {
                $result.ArtifactIdentity | Should -BeNullOrEmpty
            }
        }
    }
}
