#Requires -Version 7.0

BeforeAll {
    $script:RepoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    Import-Module (Join-Path $script:RepoRoot 'source-qualification' 'scripts' 'RunIdentity.psm1') -Force
    Import-Module (Join-Path $script:RepoRoot 'source-qualification' 'scripts' 'Finalization.psm1') -Force
    Import-Module (Join-Path $script:RepoRoot 'source-qualification' 'scripts' 'BuildEvidence.psm1') -Force
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
            RemoveCertificate    = { $true }
            UnregisterTask       = { $true }
            RemoveWorkspace      = { $true }
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
            [bool] $WriteWorks = $true,
            [bool] $WriteCorrupts = $false,
            # Per-file, so a case can reach conversion and fail only at the
            # final write. Failing every write stops the run at the attestation
            # persist instead, which is a different path entirely.
            [string[]] $FailWritesFor = @(),
            [string[]] $CorruptWritesFor = @(),
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
            HostEvidence = @{}; WriteWorks = $WriteWorks; WriteCorrupts = $WriteCorrupts
            FailWritesFor = $FailWritesFor; CorruptWritesFor = $CorruptWritesFor
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
            WriteHostEvidence = {
                param($Name, $Content)
                $state.Log.Add("Write:$Name")
                if (-not $state.WriteWorks -or $state.FailWritesFor -contains $Name) { return $false }
                # A writer that reports success without producing a readable
                # document is the case the read-back guards.
                $corrupt = $state.WriteCorrupts -or ($state.CorruptWritesFor -contains $Name)
                $state.HostEvidence[$Name] = if ($corrupt) { 'truncated' } else { $Content }
                $true
            }.GetNewClosure()
            ReadHostEvidence = {
                param($Name)
                $state.Log.Add("ReadHost:$Name")
                if ($state.HostEvidence.ContainsKey($Name)) { $state.HostEvidence[$Name] } else { $null }
            }.GetNewClosure()
            GetArtifactIdentity = {
                param($Machine)
                $state.Log.Add('Identity')
                $state.MachinesSeen.Add($Machine.Name)
                $state.Identity
            }.GetNewClosure()
        }
    }

    function CompletedPhases {
        @('media-qualification', 'answer-file', 'construction', 'provisioning',
          'pre-generalization', 'credential-residue', 'generalization', 'shutdown') |
            ForEach-Object { [PSCustomObject]@{ name = $_; outcome = 'passed' } }
    }

    function Seal {
        param($Platform, [string] $RunId, [string] $Nonce, [bool] $PackerSucceeded = $true, $Phases = $null)
        if ($null -eq $Phases) { $Phases = CompletedPhases }
        Invoke-CandidateSealing -RunId $RunId -Nonce $Nonce -CandidateName 'windows-candidate' `
            -PackerSucceeded $PackerSucceeded -CompletedPhases $Phases `
            -RecipeDigest ('a' * 64) -RecipeInputVersion 3 -ManifestSchemaVersion 2 `
            -MediaId 'windows-baseline' -StartedUtc '2026-01-01T00:00:00.0000000Z' `
            -Adapter $Platform -Confirm:$false
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
            -PackerSucceeded $true -CompletedPhases (CompletedPhases) `
            -RecipeDigest ('a' * 64) -RecipeInputVersion 3 -ManifestSchemaVersion 2 `
            -MediaId 'windows-baseline' -StartedUtc '2026-01-01T00:00:00.0000000Z' `
            -Adapter $platform -WhatIf

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

Describe 'the attestation is preserved before it is destroyed' {

    It 'writes the attestation to host evidence before clearing GuestInfo' {
        # Clearing destroys the only copy outside this process. An interruption
        # between the clear and a later write would leave the evidence nowhere,
        # and returning it in a result object is not preservation.
        $runId = Get-RunIdentifier; $nonce = Get-FinalizationNonce
        $platform = NewPlatform -Attestation (PassedAttestationJson -RunId $runId -Nonce $nonce)
        $null = Seal -Platform $platform -RunId $runId -Nonce $nonce

        $log = @($platform.State.Log)
        $log.IndexOf('Write:finalization-attestation.json') | Should -BeGreaterThan -1
        $log.IndexOf('Write:finalization-attestation.json') | Should -BeLessThan $log.IndexOf('Clear')
    }

    It 'confirms the persisted copy by reading it back' {
        $runId = Get-RunIdentifier; $nonce = Get-FinalizationNonce
        $platform = NewPlatform -Attestation (PassedAttestationJson -RunId $runId -Nonce $nonce)
        $null = Seal -Platform $platform -RunId $runId -Nonce $nonce

        $log = @($platform.State.Log)
        $log.IndexOf('ReadHost:finalization-attestation.json') | Should -BeLessThan $log.IndexOf('Clear')
        $platform.State.HostEvidence['finalization-attestation.json'] | Should -Not -BeNullOrEmpty
    }

    It 'leaves GuestInfo intact and never converts when persistence fails' {
        # The property that matters: a failed write must not cost the evidence.
        $runId = Get-RunIdentifier; $nonce = Get-FinalizationNonce
        $platform = NewPlatform -Attestation (PassedAttestationJson -RunId $runId -Nonce $nonce) -WriteWorks $false

        $result = Seal -Platform $platform -RunId $runId -Nonce $nonce
        $result.ReasonCode | Should -Be 'attestation_not_persisted'
        $result.BuildState | Should -Be 'pre-seal'
        @($platform.State.Log) | Should -Not -Contain 'Clear'
        @($platform.State.Log) | Should -Not -Contain 'Convert'
        $platform.State.Cleared | Should -BeFalse
        $platform.State.Converted | Should -BeFalse
    }

    It 'refuses when the persisted copy does not read back intact' {
        # A writer reporting success without producing a readable document.
        $runId = Get-RunIdentifier; $nonce = Get-FinalizationNonce
        $platform = NewPlatform -Attestation (PassedAttestationJson -RunId $runId -Nonce $nonce) -WriteCorrupts $true

        $result = Seal -Platform $platform -RunId $runId -Nonce $nonce
        $result.ReasonCode | Should -Be 'attestation_not_persisted'
        @($platform.State.Log) | Should -Not -Contain 'Clear'
        $platform.State.Converted | Should -BeFalse
    }
}

Describe 'provenance is emitted, validated, and written' {

    It 'emits a document the contract accepts' {
        $runId = Get-RunIdentifier; $nonce = Get-FinalizationNonce
        $platform = NewPlatform -Attestation (PassedAttestationJson -RunId $runId -Nonce $nonce)

        $result = Seal -Platform $platform -RunId $runId -Nonce $nonce
        $result.Provenance | Should -Not -BeNullOrEmpty
        Test-EvidenceEnvelopeDocument -Json $result.Provenance | Should -BeNullOrEmpty
    }

    It 'emits a document the candidate gate accepts' {
        # The same gate every downstream consumer uses, applied to the
        # serialized document rather than to the object this function held.
        $runId = Get-RunIdentifier; $nonce = Get-FinalizationNonce
        $platform = NewPlatform -Attestation (PassedAttestationJson -RunId $runId -Nonce $nonce)

        Test-SealedCandidate -Json (Seal -Platform $platform -RunId $runId -Nonce $nonce).Provenance |
            Should -BeTrue
    }

    It 'writes the provenance to host evidence' {
        $runId = Get-RunIdentifier; $nonce = Get-FinalizationNonce
        $platform = NewPlatform -Attestation (PassedAttestationJson -RunId $runId -Nonce $nonce)
        $null = Seal -Platform $platform -RunId $runId -Nonce $nonce

        $platform.State.HostEvidence['image-build-evidence.json'] | Should -Not -BeNullOrEmpty
    }

    It 'carries the full phase sequence a candidate requires' {
        $runId = Get-RunIdentifier; $nonce = Get-FinalizationNonce
        $platform = NewPlatform -Attestation (PassedAttestationJson -RunId $runId -Nonce $nonce)

        $document = (Seal -Platform $platform -RunId $runId -Nonce $nonce).Provenance | ConvertFrom-Json
        @($document.payload.phases | ForEach-Object { $_.name }) | Should -Be @(
            'media-qualification', 'answer-file', 'construction', 'provisioning',
            'pre-generalization', 'credential-residue', 'generalization',
            'shutdown', 'seal', 'provenance')
    }

    It 'refuses to report sealed when a build phase did not pass' {
        # The candidate gate decides, not this function's own bookkeeping.
        $runId = Get-RunIdentifier; $nonce = Get-FinalizationNonce
        $platform = NewPlatform -Attestation (PassedAttestationJson -RunId $runId -Nonce $nonce)
        $phases = @(CompletedPhases)
        $phases[4].outcome = 'failed'

        $result = Seal -Platform $platform -RunId $runId -Nonce $nonce -Phases $phases
        $result.BuildState | Should -Be 'seal-unconfirmed'
        $result.ReasonCode | Should -Be 'provenance_incomplete'
        $result.UnconfirmedArtifact | Should -Not -BeNullOrEmpty
    }

    It 'refuses a <field> the schema knows is malformed' -ForEach @(
        @{ field = 'managed object reference'; property = 'managedObjectReference'; value = 'NOT-A-MOREF!' }
        @{ field = 'instance UUID';            property = 'instanceUuid';           value = 'not-a-uuid' }
        @{ field = 'vCenter instance';         property = 'vCenterInstanceId';       value = '' }
    ) {
        # Checking that three fields are non-empty accepts a managed object
        # reference that is not one and a UUID that is not a UUID. The schema
        # knows the shapes.
        $runId = Get-RunIdentifier; $nonce = Get-FinalizationNonce
        $identity = NewIdentity
        $identity.$property = $value
        $platform = NewPlatform -Attestation (PassedAttestationJson -RunId $runId -Nonce $nonce) -Identity $identity

        $result = Seal -Platform $platform -RunId $runId -Nonce $nonce
        $result.BuildState | Should -Be 'seal-unconfirmed'
        $result.ArtifactIdentity | Should -BeNullOrEmpty
    }

    It 'recovers the identity into unconfirmedArtifact when provenance cannot be confirmed' {
        # Something exists and can be named, so it is named -- as what may
        # exist, never as an accepted candidate.
        $runId = Get-RunIdentifier; $nonce = Get-FinalizationNonce
        $identity = NewIdentity
        $identity.instanceUuid = 'not-a-uuid'
        $platform = NewPlatform -Attestation (PassedAttestationJson -RunId $runId -Nonce $nonce) -Identity $identity

        $result = Seal -Platform $platform -RunId $runId -Nonce $nonce
        $result.UnconfirmedArtifact.managedObjectReference | Should -Be 'vm-1234'
    }

    It 'refuses a manifest version the recipe path cannot process' {
        # Only the candidate gate checks this: the schema permits manifest
        # version 1 because other result kinds carry it, and the consistency
        # validator does not look. Without that call this document would be
        # emitted as a sealed candidate describing a contract the recipe path
        # cannot read.
        $runId = Get-RunIdentifier; $nonce = Get-FinalizationNonce
        $platform = NewPlatform -Attestation (PassedAttestationJson -RunId $runId -Nonce $nonce)

        $result = Invoke-CandidateSealing -RunId $runId -Nonce $nonce -CandidateName 'windows-candidate' `
            -PackerSucceeded $true -CompletedPhases (CompletedPhases) `
            -RecipeDigest ('a' * 64) -RecipeInputVersion 3 -ManifestSchemaVersion 1 `
            -MediaId 'windows-baseline' -StartedUtc '2026-01-01T00:00:00.0000000Z' `
            -Adapter $platform -Confirm:$false

        $result.BuildState | Should -Be 'seal-unconfirmed'
        $result.ReasonCode | Should -Be 'provenance_incomplete'
    }

    It 'refuses a recipe-input version this code does not implement' {
        # Same reasoning. A digest is only comparable within a version this code
        # implements, and nothing but the candidate gate enforces that here.
        $runId = Get-RunIdentifier; $nonce = Get-FinalizationNonce
        $platform = NewPlatform -Attestation (PassedAttestationJson -RunId $runId -Nonce $nonce)

        $result = Invoke-CandidateSealing -RunId $runId -Nonce $nonce -CandidateName 'windows-candidate' `
            -PackerSucceeded $true -CompletedPhases (CompletedPhases) `
            -RecipeDigest ('a' * 64) -RecipeInputVersion 2 -ManifestSchemaVersion 2 `
            -MediaId 'windows-baseline' -StartedUtc '2026-01-01T00:00:00.0000000Z' `
            -Adapter $platform -Confirm:$false

        $result.BuildState | Should -Be 'seal-unconfirmed'
        $result.ReasonCode | Should -Be 'provenance_incomplete'
    }

    It 'never reports sealed without an emitted, validated document' {
        $runId = Get-RunIdentifier; $nonce = Get-FinalizationNonce
        foreach ($platform in @(
                (NewPlatform -Attestation (PassedAttestationJson -RunId $runId -Nonce $nonce) -ConvertWorks $false)
                (NewPlatform -Attestation (PassedAttestationJson -RunId $runId -Nonce $nonce) -IdentityMissing)
                (NewPlatform -Attestation (PassedAttestationJson -RunId $runId -Nonce $nonce) -WriteWorks $false)
                (NewPlatform -Attestation ''))) {

            $result = Seal -Platform $platform -RunId $runId -Nonce $nonce
            if ($result.BuildState -eq 'sealed') {
                $result.Provenance | Should -Not -BeNullOrEmpty
                Test-SealedCandidate -Json $result.Provenance | Should -BeTrue
            }
            else {
                # A non-sealed result may carry a reconciliation record, which
                # is a different document: it must never satisfy the candidate
                # gate.
                if ($result.Provenance) {
                    Test-SealedCandidate -Json $result.Provenance | Should -BeFalse
                }
            }
        }
    }
}

Describe 'the final write is confirmed by retrieval' {

    It 'refuses to report sealed when the record does not read back' {
        # A sealed state claims a durable document exists. A writer reporting
        # success and leaving a truncated file would otherwise produce a
        # candidate whose evidence nobody can read.
        $runId = Get-RunIdentifier; $nonce = Get-FinalizationNonce
        $platform = NewPlatform -Attestation (PassedAttestationJson -RunId $runId -Nonce $nonce) `
            -CorruptWritesFor @('image-build-evidence.json')

        $result = Seal -Platform $platform -RunId $runId -Nonce $nonce
        $result.BuildState | Should -Not -Be 'sealed'
        $result.ReasonCode | Should -Be 'provenance_incomplete'
    }

    It 'judges the retrieved bytes rather than the ones it handed the writer' {
        $runId = Get-RunIdentifier; $nonce = Get-FinalizationNonce
        $platform = NewPlatform -Attestation (PassedAttestationJson -RunId $runId -Nonce $nonce)
        $result = Seal -Platform $platform -RunId $runId -Nonce $nonce

        $result.BuildState | Should -Be 'sealed'
        $result.Provenance | Should -Be $platform.State.HostEvidence['image-build-evidence.json']
        @($platform.State.Log) | Should -Contain 'ReadHost:image-build-evidence.json'
    }
}

Describe 'uncertainty after conversion is written down' {

    BeforeAll {
        function UnconfirmedRecord {
            param($Platform)
            $Platform.State.HostEvidence['seal-unconfirmed-evidence.json']
        }
    }

    It 'writes a reconciliation record when <case>' -ForEach @(
        @{ case = 'conversion threw';            make = { NewPlatform -Attestation $args[0] -ConvertWorks $false } }
        @{ case = 'the identity is unreadable';  make = { NewPlatform -Attestation $args[0] -IdentityMissing } }
        @{ case = 'the final write fails';       make = { NewPlatform -Attestation $args[0] -CorruptWritesFor @('image-build-evidence.json') } }
    ) {
        # Something may exist on the platform, and a record nobody wrote is an
        # artifact nobody will find.
        $runId = Get-RunIdentifier; $nonce = Get-FinalizationNonce
        $platform = & $make (PassedAttestationJson -RunId $runId -Nonce $nonce)

        $result = Seal -Platform $platform -RunId $runId -Nonce $nonce
        $result.BuildState | Should -Be 'seal-unconfirmed'
        UnconfirmedRecord -Platform $platform | Should -Not -BeNullOrEmpty
    }

    It 'writes a record the contract accepts' {
        $runId = Get-RunIdentifier; $nonce = Get-FinalizationNonce
        $platform = NewPlatform -Attestation (PassedAttestationJson -RunId $runId -Nonce $nonce) -ConvertWorks $false
        $null = Seal -Platform $platform -RunId $runId -Nonce $nonce

        $record = UnconfirmedRecord -Platform $platform
        Test-EvidenceEnvelopeDocument -Json $record | Should -BeNullOrEmpty
        Test-ImageBuildResult -Evidence ($record | ConvertFrom-Json) | Should -BeNullOrEmpty
        Test-SealedCandidate -Json $record | Should -BeFalse
    }

    It 'carries a recovered identity that satisfies its contract' {
        $runId = Get-RunIdentifier; $nonce = Get-FinalizationNonce
        $platform = NewPlatform -Attestation (PassedAttestationJson -RunId $runId -Nonce $nonce) -ConvertWorks $false
        $null = Seal -Platform $platform -RunId $runId -Nonce $nonce

        $document = UnconfirmedRecord -Platform $platform | ConvertFrom-Json
        $document.payload.unconfirmedArtifact.managedObjectReference | Should -Be 'vm-1234'
        $document.payload.PSObject.Properties.Name | Should -Not -Contain 'artifactIdentity'
    }

    It 'omits a recovered identity that does not' {
        # A malformed identity would make the whole record unreadable, losing
        # the reconciliation entirely in order to describe something that
        # cannot be looked up anyway.
        $runId = Get-RunIdentifier; $nonce = Get-FinalizationNonce
        $identity = NewIdentity
        $identity.instanceUuid = 'not-a-uuid'
        $platform = NewPlatform -Attestation (PassedAttestationJson -RunId $runId -Nonce $nonce) -Identity $identity
        $null = Seal -Platform $platform -RunId $runId -Nonce $nonce

        $record = UnconfirmedRecord -Platform $platform
        Test-EvidenceEnvelopeDocument -Json $record | Should -BeNullOrEmpty
        ($record | ConvertFrom-Json).payload.PSObject.Properties.Name | Should -Not -Contain 'unconfirmedArtifact'
    }

    It 'reports that nothing was persisted when the sink is unavailable' {
        # Code whose evidence sink is unavailable cannot claim durable evidence.
        # The entry point turns this into a failing process status.
        $runId = Get-RunIdentifier; $nonce = Get-FinalizationNonce
        $platform = NewPlatform -Attestation (PassedAttestationJson -RunId $runId -Nonce $nonce) `
            -ConvertWorks $false -FailWritesFor @('seal-unconfirmed-evidence.json')

        $result = Seal -Platform $platform -RunId $runId -Nonce $nonce
        $result.EvidencePersisted | Should -BeFalse
        $result.Provenance | Should -BeNullOrEmpty
    }

    It 'reports evidence persisted on the successful path' {
        $runId = Get-RunIdentifier; $nonce = Get-FinalizationNonce
        $platform = NewPlatform -Attestation (PassedAttestationJson -RunId $runId -Nonce $nonce)
        (Seal -Platform $platform -RunId $runId -Nonce $nonce).EvidencePersisted | Should -BeTrue
    }
}

Describe 'a refusal before the seal is recorded too' {

    It 'writes a pre-seal record when <case>' -ForEach @(
        @{ case = 'the build failed';        seal = { Seal -Platform $args[0] -RunId $args[1] -Nonce $args[2] -PackerSucceeded $false } }
        @{ case = 'the machine is still on'; seal = { Seal -Platform $args[0] -RunId $args[1] -Nonce $args[2] } }
    ) {
        # A pre-seal refusal is still a result someone has to act on. Reporting
        # persistence without writing anything was a claim about a document that
        # did not exist.
        $runId = Get-RunIdentifier; $nonce = Get-FinalizationNonce
        $attestation = PassedAttestationJson -RunId $runId -Nonce $nonce
        $platform = if ($case -like '*still on*') {
            NewPlatform -Attestation $attestation -PowerState 'poweredOn'
        }
        else { NewPlatform -Attestation $attestation }

        $result = & $seal $platform $runId $nonce
        $result.BuildState | Should -Be 'pre-seal'
        $result.EvidencePersisted | Should -BeTrue
        $platform.State.HostEvidence['pre-seal-evidence.json'] | Should -Not -BeNullOrEmpty
    }

    It 'writes a pre-seal record the contract accepts' {
        $runId = Get-RunIdentifier; $nonce = Get-FinalizationNonce
        $platform = NewPlatform -Attestation (PassedAttestationJson -RunId $runId -Nonce $nonce) -PowerState 'poweredOn'
        $null = Seal -Platform $platform -RunId $runId -Nonce $nonce

        $record = $platform.State.HostEvidence['pre-seal-evidence.json']
        Test-EvidenceEnvelopeDocument -Json $record | Should -BeNullOrEmpty
        Test-ImageBuildResult -Evidence ($record | ConvertFrom-Json) | Should -BeNullOrEmpty
        Test-SealedCandidate -Json $record | Should -BeFalse
        ($record | ConvertFrom-Json).payload.buildState | Should -Be 'pre-seal'
    }

    It 'reports no persistence when the pre-seal record cannot be written' {
        $runId = Get-RunIdentifier; $nonce = Get-FinalizationNonce
        $platform = NewPlatform -Attestation (PassedAttestationJson -RunId $runId -Nonce $nonce) `
            -PowerState 'poweredOn' -FailWritesFor @('pre-seal-evidence.json')

        $result = Seal -Platform $platform -RunId $runId -Nonce $nonce
        $result.EvidencePersisted | Should -BeFalse
        $result.Provenance | Should -BeNullOrEmpty
    }

    It 'records nothing under -WhatIf, and says so' {
        # Nothing was attempted, so nothing is written down as though it had
        # been.
        $runId = Get-RunIdentifier; $nonce = Get-FinalizationNonce
        $platform = NewPlatform -Attestation (PassedAttestationJson -RunId $runId -Nonce $nonce)

        $result = Invoke-CandidateSealing -RunId $runId -Nonce $nonce -CandidateName 'windows-candidate' `
            -PackerSucceeded $true -CompletedPhases (CompletedPhases) `
            -RecipeDigest ('a' * 64) -RecipeInputVersion 3 -ManifestSchemaVersion 2 `
            -MediaId 'windows-baseline' -StartedUtc '2026-01-01T00:00:00.0000000Z' `
            -Adapter $platform -WhatIf

        $result.EvidencePersisted | Should -BeFalse
        $platform.State.HostEvidence.ContainsKey('pre-seal-evidence.json') | Should -BeFalse
    }
}

Describe 'persistence is never reported from the writer alone' {

    It 'refuses to report a persisted <record> that does not read back' -ForEach @(
        @{ record = 'pre-seal record';        name = 'pre-seal-evidence.json';        state = 'poweredOn'; convert = $true }
        @{ record = 'reconciliation record';  name = 'seal-unconfirmed-evidence.json'; state = 'poweredOff'; convert = $false }
    ) {
        # A writer returning success while leaving nothing readable would
        # produce a result claiming a durable document that does not exist.
        $runId = Get-RunIdentifier; $nonce = Get-FinalizationNonce
        $platform = NewPlatform -Attestation (PassedAttestationJson -RunId $runId -Nonce $nonce) `
            -PowerState $state -ConvertWorks $convert -CorruptWritesFor @($name)

        $result = Seal -Platform $platform -RunId $runId -Nonce $nonce
        $result.EvidencePersisted | Should -BeFalse
        $result.Provenance | Should -BeNullOrEmpty
    }
}

Describe 'phase outcomes are read, not asserted' {

    BeforeAll {
        $script:PhaseSchema = Join-Path $script:RepoRoot 'contracts' 'evidence-envelope-2.schema.json'

        function NewEvidenceRoot {
            param([string] $RunId, [hashtable] $Override = @{})
            $root = Join-Path ([System.IO.Path]::GetTempPath()) ([guid]::NewGuid().ToString())
            $null = New-Item -ItemType Directory -Path $root -Force

            $guest = @{
                resultSchemaVersion = 2; resultKind = 'guest-provisioning'
                runId = $RunId; manifestSchemaVersion = 2
                startedUtc = '2026-01-01T00:00:00.0000000Z'; completedUtc = '2026-01-01T00:00:01.0000000Z'
                outcome = 'passed'
                payload = @{
                    phase = 'validate'; restartRequired = $false
                    packageCount = 1; passedCount = 1; failedRequiredCount = 0
                    installerAttemptCount = 1; cleanupOutcome = 'removed'
                    packages = @(@{ id = 'a'; version = '1.0.0'; order = 1; required = $true
                                    outcome = 'passed'; reasonCode = $null
                                    restartRequired = $false; installerAttempted = $true })
                }
            }
            $guest | ConvertTo-Json -Depth 12 |
                Set-Content -LiteralPath (Join-Path $root 'validate-guest-evidence.json') -Encoding utf8

            foreach ($phase in 'pre-generalization', 'credential-residue') {
                @{ name = $phase; outcome = 'passed'; reasonCode = $null } | ConvertTo-Json |
                    Set-Content -LiteralPath (Join-Path $root "$phase-guest-evidence.json") -Encoding utf8
            }

            foreach ($key in $Override.Keys) {
                $path = Join-Path $root $key
                if ($null -eq $Override[$key]) { Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue }
                else { $Override[$key] | Set-Content -LiteralPath $path -Encoding utf8 }
            }
            $root
        }

        function Phases {
            param([string] $Root, [string] $RunId)
            Read-BuildPhaseEvidence -EvidenceRoot $Root -RunId $RunId -SchemaPath $script:PhaseSchema
        }
    }

    It 'reports every contract phase, in order' {
        $runId = Get-RunIdentifier
        @(Phases -Root (NewEvidenceRoot -RunId $runId) -RunId $runId | ForEach-Object { $_.name }) |
            Should -Be @('media-qualification', 'answer-file', 'construction', 'provisioning',
                         'pre-generalization', 'credential-residue', 'generalization', 'shutdown')
    }

    It 'passes when every downloaded document reports success' {
        $runId = Get-RunIdentifier
        @(Phases -Root (NewEvidenceRoot -RunId $runId) -RunId $runId | Where-Object outcome -NE 'passed') |
            Should -BeNullOrEmpty
    }

    It 'fails a phase whose evidence is missing' {
        # A hard-coded list of passed phases asserted the thing the seal was
        # supposed to establish. An absent document is not a pass.
        $runId = Get-RunIdentifier
        $root = NewEvidenceRoot -RunId $runId -Override @{ 'pre-generalization-guest-evidence.json' = $null }

        (Phases -Root $root -RunId $runId | Where-Object name -EQ 'pre-generalization').outcome |
            Should -Be 'failed'
    }

    It 'fails a phase whose evidence is malformed' {
        $runId = Get-RunIdentifier
        $root = NewEvidenceRoot -RunId $runId -Override @{ 'validate-guest-evidence.json' = '{ not json' }

        (Phases -Root $root -RunId $runId | Where-Object name -EQ 'provisioning').outcome | Should -Be 'failed'
    }

    It 'fails a phase whose evidence belongs to another run' {
        # It would attach one execution's provisioning to another's image.
        $runId = Get-RunIdentifier
        $root = NewEvidenceRoot -RunId (Get-RunIdentifier)

        (Phases -Root $root -RunId $runId | Where-Object name -EQ 'provisioning').outcome | Should -Be 'failed'
    }

    It 'fails a phase whose evidence reports failure' {
        $runId = Get-RunIdentifier
        $root = NewEvidenceRoot -RunId $runId -Override @{
            'credential-residue-guest-evidence.json' =
                (@{ name = 'credential-residue'; outcome = 'failed'; reasonCode = 'residue_present' } | ConvertTo-Json)
        }

        (Phases -Root $root -RunId $runId | Where-Object name -EQ 'credential-residue').outcome |
            Should -Be 'failed'
    }

    It 'a failed phase stops the seal' {
        # The end of the chain: unread evidence becomes a failed phase, and the
        # candidate gate refuses the document that carries it.
        $runId = Get-RunIdentifier; $nonce = Get-FinalizationNonce
        $root = NewEvidenceRoot -RunId $runId -Override @{ 'pre-generalization-guest-evidence.json' = $null }
        $phases = Phases -Root $root -RunId $runId

        $platform = NewPlatform -Attestation (PassedAttestationJson -RunId $runId -Nonce $nonce)
        $result = Seal -Platform $platform -RunId $runId -Nonce $nonce -Phases $phases

        $result.BuildState | Should -Not -Be 'sealed'
    }
}
