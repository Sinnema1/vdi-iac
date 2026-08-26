#Requires -Version 7.0

BeforeAll {
    $script:RepoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    Import-Module (Join-Path $script:RepoRoot 'source-qualification' 'scripts' 'BuildEvidence.psm1') -Force

    $script:Contracts = Join-Path $script:RepoRoot 'contracts'
    $script:V2 = Join-Path $script:Contracts 'evidence-envelope-2.schema.json'
    $script:V3 = Join-Path $script:Contracts 'evidence-envelope-3.schema.json'

    # The ordered obligations a sealed candidate must have met. Kept here as
    # data so a case can drop, duplicate, or reorder one deliberately.
    $script:RequiredPhases = @(
        'media-qualification', 'answer-file', 'construction', 'provisioning',
        'pre-generalization', 'credential-residue', 'generalization',
        'shutdown', 'seal', 'provenance')

    function CompleteSealPhases {
        @(foreach ($name in $script:RequiredPhases) {
            [ordered]@{ name = $name; outcome = 'passed'; reasonCode = $null }
        })
    }

    function NewArtifact {
        <#
            A SYNTHETIC identity. Every value here is invented to exercise the
            contract, and none of it came from a vSphere instance: no lab build
            has run. It must never be quoted as evidence that one has.
        #>
        param([string] $Reference = 'vm-1234')
        [ordered]@{
            vCenterInstanceId      = 'vcenter-instance-a'
            managedObjectReference = $Reference
            instanceUuid           = '3f2504e0-4f89-41d3-9a0c-0305e82c3301'
            recordedName           = 'candidate-image'
        }
    }

    function NewBuildEvidence {
        <#
            A build result in whichever state a case needs. Self-consistent by
            construction, so a case fails for the rule it is about rather than
            for an unrelated contradiction.
        #>
        param(
            [string] $BuildState = 'sealed',
            [string] $Outcome = 'passed',
            $ArtifactIdentity = $null,
            $UnconfirmedArtifact = $null,
            [string] $TerminalReason,
            $Phases = $null
        )

        if ($null -eq $Phases) { $Phases = CompleteSealPhases }

        $payload = [ordered]@{
            buildState         = $BuildState
            recipeInputVersion = 1
            recipeDigest       = 'a' * 64
            mediaId            = 'windows-baseline'
            phases             = @($Phases)
        }
        if ($ArtifactIdentity) { $payload.artifactIdentity = $ArtifactIdentity }
        if ($UnconfirmedArtifact) { $payload.unconfirmedArtifact = $UnconfirmedArtifact }
        if ($TerminalReason) { $payload.terminalReasonCode = $TerminalReason }

        [ordered]@{
            resultSchemaVersion   = 3
            resultKind            = 'image-build'
            runId                 = '3f2504e0-4f89-41d3-9a0c-0305e82c3301'
            manifestSchemaVersion = 2
            startedUtc            = '2026-01-01T00:00:00.0000000Z'
            completedUtc          = '2026-01-01T01:00:00.0000000Z'
            outcome               = $Outcome
            payload               = $payload
        }
    }

    function AsObject { param($Table) $Table | ConvertTo-Json -Depth 20 | ConvertFrom-Json }
    function AsJson { param($Table) $Table | ConvertTo-Json -Depth 20 }
}

Describe 'version 2 is left alone' {

    It 'matches its recorded digest byte for byte' {
        # A published contract version is never edited in place. Adding version 3
        # must not have touched it, and a digest is the only assertion that
        # proves a whitespace or ordering change did not slip in.
        (Get-FileHash -LiteralPath $script:V2 -Algorithm SHA256).Hash.ToLowerInvariant() |
            Should -Be 'ca4867d8dbbd900f8695440c84af440d7e03d7b02ee71a1bc9c2b15c6fe410e6'
    }

    It 'still knows nothing about the image-build kind' {
        (Get-Content -LiteralPath $script:V2 -Raw | ConvertFrom-Json).properties.resultKind.enum |
            Should -Not -Contain 'image-build'
    }

    It 'still validates a version 2 document' {
        # The compatibility promise, exercised rather than asserted in prose.
        $document = [ordered]@{
            resultSchemaVersion = 2; resultKind = 'guest-provisioning'
            runId = '3f2504e0-4f89-41d3-9a0c-0305e82c3301'; manifestSchemaVersion = 2
            startedUtc = '2026-01-01T00:00:00.0000000Z'; completedUtc = '2026-01-01T00:00:01.0000000Z'
            outcome = 'passed'
            payload = [ordered]@{
                phase = 'install'; restartRequired = $false
                packageCount = 1; passedCount = 1; failedRequiredCount = 0
                installerAttemptCount = 1; cleanupOutcome = 'removed'
                packages = @([ordered]@{
                    id = 'a'; version = '1.0.0'; order = 1; required = $true
                    outcome = 'passed'; reasonCode = $null
                    restartRequired = $false; installerAttempted = $true })
            }
        }
        Test-EvidenceEnvelopeDocument -Json (AsJson $document) | Should -BeNullOrEmpty
    }
}

Describe 'the version dispatcher' {

    It 'validates a version 2 document against version 2, not the newest' {
        # Validating everything against the newest schema would accept a version
        # 2 document carrying version 3 fields.
        $document = [ordered]@{
            resultSchemaVersion = 2; resultKind = 'image-build'
            runId = '3f2504e0-4f89-41d3-9a0c-0305e82c3301'; manifestSchemaVersion = 2
            startedUtc = '2026-01-01T00:00:00.0000000Z'; completedUtc = '2026-01-01T01:00:00.0000000Z'
            outcome = 'passed'; payload = [ordered]@{ buildState = 'sealed' }
        }
        Test-EvidenceEnvelopeDocument -Json (AsJson $document) | Should -Be 'evidence_malformed'
    }

    It 'refuses version <version> rather than falling back to the newest' -ForEach @(
        @{ version = 1 }, @{ version = 4 }, @{ version = 99 }
    ) {
        $document = NewBuildEvidence -ArtifactIdentity (NewArtifact)
        $document.resultSchemaVersion = $version
        Test-EvidenceEnvelopeDocument -Json (AsJson $document) | Should -Be 'evidence_unsupported_version'
    }

    It 'accepts a well-formed version 3 build result' {
        Test-EvidenceEnvelopeDocument -Json (AsJson (NewBuildEvidence -ArtifactIdentity (NewArtifact))) |
            Should -BeNullOrEmpty
    }

    It 'refuses a trailing control character the pattern admits' {
        # ECMA-portable patterns end in $, which under .NET matches before a
        # final newline. The semantic check is what closes it.
        $document = NewBuildEvidence -ArtifactIdentity (NewArtifact)
        $document.payload.mediaId = "windows-baseline`n"
        Test-EvidenceEnvelopeDocument -Json (AsJson $document) | Should -Be 'evidence_malformed'
    }
}

Describe 'artifact identity appears exactly when a build sealed' {

    It 'accepts a sealed result carrying an artifact identity' {
        $document = NewBuildEvidence -ArtifactIdentity (NewArtifact)
        Test-ImageBuildResult -Evidence (AsObject $document) | Should -BeNullOrEmpty
        Test-SealedCandidate -Json (AsJson $document) | Should -BeTrue
    }

    It 'refuses a sealed result with no artifact identity' {
        # A sealed record naming no artifact describes nothing a consumer can act on.
        $document = NewBuildEvidence
        Test-ImageBuildResult -Evidence (AsObject $document) | Should -Be 'sealed_without_artifact_identity'
        Test-SealedCandidate -Json (AsJson $document) | Should -BeFalse
    }

    It 'refuses a <state> result carrying an artifact identity' -ForEach @(
        @{ state = 'pre-seal';         outcome = 'incomplete'; reason = 'pre_seal_carrying_artifact_identity' }
        @{ state = 'seal-unconfirmed'; outcome = 'incomplete'; reason = 'unconfirmed_seal_carrying_artifact_identity' }
    ) {
        # Presence of artifactIdentity is what makes a record an accepted
        # candidate, so no state short of a confirmed seal may carry one.
        $document = NewBuildEvidence -BuildState $state -Outcome $outcome `
            -ArtifactIdentity (NewArtifact) -TerminalReason 'seal_unconfirmed'
        Test-ImageBuildResult -Evidence (AsObject $document) | Should -Be $reason
        Test-SealedCandidate -Json (AsJson $document) | Should -BeFalse
    }

    It 'refuses a failed result carrying an artifact identity' {
        $document = NewBuildEvidence -BuildState 'seal-unconfirmed' -Outcome 'failed' `
            -ArtifactIdentity (NewArtifact) -TerminalReason 'seal_failed'
        Test-ImageBuildResult -Evidence (AsObject $document) | Should -Not -BeNullOrEmpty
        Test-SealedCandidate -Json (AsJson $document) | Should -BeFalse
    }

    It 'refuses a sealed result whose outcome is not passed' {
        $evidence = AsObject (NewBuildEvidence -Outcome 'incomplete' `
            -ArtifactIdentity (NewArtifact) -TerminalReason 'provenance_incomplete')
        Test-ImageBuildResult -Evidence $evidence | Should -Be 'sealed_without_passed_outcome'
    }

    It 'refuses a sealed result whose seal phase did not pass' {
        $phases = CompleteSealPhases
        $phases[8].outcome = 'failed'
        $phases[8].reasonCode = 'seal_failed'
        $evidence = AsObject (NewBuildEvidence -ArtifactIdentity (NewArtifact) -Phases $phases)
        Test-ImageBuildResult -Evidence $evidence | Should -Be 'sealed_with_failed_phase'
    }

    It 'refuses a seal event standing in for a build' {
        # The defect this gate exists for: one passed seal phase was accepted as
        # a candidate, so every other obligation could simply be absent.
        $document = NewBuildEvidence -ArtifactIdentity (NewArtifact) -Phases @(
            [ordered]@{ name = 'seal'; outcome = 'passed'; reasonCode = $null })
        Test-ImageBuildResult -Evidence (AsObject $document) | Should -Be 'sealed_without_every_required_phase'
        Test-SealedCandidate -Json (AsJson $document) | Should -BeFalse
    }

    It 'refuses a sealed result missing the <phase> obligation' -ForEach @(
        @{ phase = 'media-qualification' }, @{ phase = 'answer-file' }
        @{ phase = 'provisioning' },        @{ phase = 'pre-generalization' }
        @{ phase = 'credential-residue' },  @{ phase = 'generalization' }
        @{ phase = 'shutdown' },            @{ phase = 'provenance' }
    ) {
        # One case per obligation. Each of these changes whether the image is
        # usable or safe, so none may be omitted from a candidate.
        $phases = @(CompleteSealPhases | Where-Object { $_.name -ne $phase })
        $document = NewBuildEvidence -ArtifactIdentity (NewArtifact) -Phases $phases
        Test-ImageBuildResult -Evidence (AsObject $document) | Should -Be 'sealed_without_every_required_phase'
        Test-SealedCandidate -Json (AsJson $document) | Should -BeFalse
    }

    It 'refuses a sealed result whose phases are out of order' {
        # Order carries meaning: residue removal after generalization seals the
        # credential in, and provenance before sealing cannot name the artifact.
        $phases = CompleteSealPhases
        $swap = $phases[5]; $phases[5] = $phases[6]; $phases[6] = $swap
        $document = NewBuildEvidence -ArtifactIdentity (NewArtifact) -Phases $phases
        Test-ImageBuildResult -Evidence (AsObject $document) | Should -Be 'sealed_with_phases_out_of_order'
    }

    It 'refuses a sealed result with a duplicated phase' {
        $phases = @(CompleteSealPhases) + @([ordered]@{ name = 'seal'; outcome = 'passed'; reasonCode = $null })
        $document = NewBuildEvidence -ArtifactIdentity (NewArtifact) -Phases $phases
        Test-ImageBuildResult -Evidence (AsObject $document) | Should -Be 'sealed_without_every_required_phase'
    }

    It 'refuses a skipped obligation as though it had passed' {
        $phases = CompleteSealPhases
        $phases[4].outcome = 'skipped'
        $document = NewBuildEvidence -ArtifactIdentity (NewArtifact) -Phases $phases
        Test-ImageBuildResult -Evidence (AsObject $document) | Should -Be 'sealed_with_a_phase_that_did_not_pass'
    }

    It 'refuses a passed phase that names a failure' {
        # A phase claiming both is contradictory, and the reason is the more
        # specific of the two claims.
        $phases = CompleteSealPhases
        $phases[8].reasonCode = 'seal_failed'
        $document = NewBuildEvidence -ArtifactIdentity (NewArtifact) -Phases $phases
        Test-ImageBuildResult -Evidence (AsObject $document) | Should -Be 'sealed_with_a_phase_reporting_a_failure'
        Test-SealedCandidate -Json (AsJson $document) | Should -BeFalse
    }

    It 'refuses a pre-seal result reporting success' {
        # A build that never sealed produced no candidate, so it must not report
        # the outcome a consumer reads as one.
        $evidence = AsObject (NewBuildEvidence -BuildState 'pre-seal' -Outcome 'passed')
        Test-ImageBuildResult -Evidence $evidence | Should -Be 'pre_seal_reporting_passed'
    }
}

Describe 'an artifact left by a failed evidence emission' {

    It 'stays representable as incomplete, under a different field' {
        # The case this state exists for: sealing may have created an artifact
        # and the run could not confirm it. Recording what may exist lets it be
        # reconciled or removed; recording it as artifactIdentity would publish
        # it as an accepted candidate.
        $evidence = AsObject (NewBuildEvidence -BuildState 'seal-unconfirmed' -Outcome 'incomplete' `
            -UnconfirmedArtifact (NewArtifact) -TerminalReason 'seal_unconfirmed' -Phases @(
                [ordered]@{ name = 'construction'; outcome = 'passed';     reasonCode = $null }
                [ordered]@{ name = 'seal';         outcome = 'incomplete'; reasonCode = 'seal_unconfirmed' }))

        Test-EvidenceEnvelopeDocument -Json (AsJson (NewBuildEvidence -BuildState 'seal-unconfirmed' `
            -Outcome 'incomplete' -UnconfirmedArtifact (NewArtifact) -TerminalReason 'seal_unconfirmed')) |
            Should -BeNullOrEmpty
        Test-ImageBuildResult -Evidence $evidence | Should -BeNullOrEmpty
    }

    It 'is never an accepted sealed candidate' {
        $document = NewBuildEvidence -BuildState 'seal-unconfirmed' -Outcome 'incomplete' `
            -UnconfirmedArtifact (NewArtifact) -TerminalReason 'seal_unconfirmed'
        Test-SealedCandidate -Json (AsJson $document) | Should -BeFalse
    }

    It 'refuses every non-sealed state as a candidate' -ForEach @(
        @{ state = 'pre-seal';         outcome = 'incomplete' }
        @{ state = 'pre-seal';         outcome = 'failed' }
        @{ state = 'seal-unconfirmed'; outcome = 'incomplete' }
    ) {
        # Two gates refuse each of these -- the outcome and the consistency
        # check -- so no single one of them is individually necessary. The
        # question this answers is the one downstream acts on, so it is asserted
        # across the states rather than through whichever rule fires first.
        $document = NewBuildEvidence -BuildState $state -Outcome $outcome -TerminalReason 'seal_unconfirmed'
        Test-SealedCandidate -Json (AsJson $document) | Should -BeFalse
    }

    It 'refuses a sealed result that also records an unconfirmed artifact' {
        # Both fields present is a contradiction, and a reader taking the first
        # one it finds would resolve it the wrong way half the time.
        $evidence = AsObject (NewBuildEvidence -ArtifactIdentity (NewArtifact) `
            -UnconfirmedArtifact (NewArtifact -Reference 'vm-9999'))
        Test-ImageBuildResult -Evidence $evidence | Should -Be 'sealed_with_unconfirmed_artifact'
    }

    It 'requires a terminal reason on an unsuccessful result' {
        $evidence = AsObject (NewBuildEvidence -BuildState 'seal-unconfirmed' -Outcome 'incomplete')
        Test-ImageBuildResult -Evidence $evidence | Should -Be 'unsuccessful_result_without_terminal_reason'
    }
}

Describe 'artifact identity is scoped, not a bare reference' {

    It 'requires <field>' -ForEach @(
        @{ field = 'vCenterInstanceId' }, @{ field = 'managedObjectReference' }, @{ field = 'instanceUuid' }
    ) {
        # A managed object reference is unique only within one vCenter, and a
        # name is mutable. None of the three alone identifies an artifact.
        $document = NewBuildEvidence -ArtifactIdentity (NewArtifact)
        $document.payload.artifactIdentity.Remove($field)
        Test-EvidenceEnvelopeDocument -Json (AsJson $document) | Should -Be 'evidence_malformed'
    }

    It 'treats the recorded name as optional metadata' {
        $document = NewBuildEvidence -ArtifactIdentity (NewArtifact)
        $document.payload.artifactIdentity.Remove('recordedName')
        Test-EvidenceEnvelopeDocument -Json (AsJson $document) | Should -BeNullOrEmpty
    }
}

Describe 'envelope parity between versions 2 and 3' {

    BeforeAll {
        $script:SchemaV2 = Get-Content -LiteralPath $script:V2 -Raw | ConvertFrom-Json
        $script:SchemaV3 = Get-Content -LiteralPath $script:V3 -Raw | ConvertFrom-Json
    }

    It 'requires the same envelope fields' {
        ($script:SchemaV3.required -join ',') | Should -Be ($script:SchemaV2.required -join ',')
    }

    It 'copies the <field> rule unchanged' -ForEach @(
        @{ field = 'runId' }, @{ field = 'startedUtc' }, @{ field = 'completedUtc' }
        @{ field = 'outcome' }, @{ field = 'manifestSchemaVersion' }, @{ field = 'toolVersion' }
    ) {
        # Version 3 repeats these rather than referring across files, because
        # Test-Json does not resolve external references. Repeated shapes drift,
        # so the drift is what gets asserted.
        ($script:SchemaV3.properties.$field | ConvertTo-Json -Depth 12) |
            Should -Be ($script:SchemaV2.properties.$field | ConvertTo-Json -Depth 12)
    }

    It 'carries every version 2 result kind forward' {
        foreach ($kind in $script:SchemaV2.properties.resultKind.enum) {
            $script:SchemaV3.properties.resultKind.enum | Should -Contain $kind
        }
    }

    It 'carries every version 2 payload definition forward unchanged' {
        foreach ($name in $script:SchemaV2.definitions.PSObject.Properties.Name) {
            ($script:SchemaV3.definitions.$name | ConvertTo-Json -Depth 20) |
                Should -Be ($script:SchemaV2.definitions.$name | ConvertTo-Json -Depth 20) -Because "$name must not drift"
        }
    }

    It 'carries the kind-to-payload binding forward for every version 2 kind' {
        # The parity assertions above compared properties and definitions and
        # both passed while this was missing entirely -- and without it the
        # payload is validated by nothing at all. Copying a schema is not
        # copying its structure.
        $v2Branches = @($script:SchemaV2.oneOf | ForEach-Object { $_.properties.resultKind.enum[0] })
        $v3Branches = @($script:SchemaV3.oneOf | ForEach-Object { $_.properties.resultKind.enum[0] })

        $v3Branches | Should -Not -BeNullOrEmpty
        foreach ($kind in $v2Branches) { $v3Branches | Should -Contain $kind }
        $v3Branches | Should -Contain 'image-build'
    }

    It 'binds each version 2 kind to the same payload definition' {
        foreach ($branch in $script:SchemaV2.oneOf) {
            $kind = $branch.properties.resultKind.enum[0]
            $expected = $branch.properties.payload.'$ref'
            $actual = ($script:SchemaV3.oneOf | Where-Object { $_.properties.resultKind.enum[0] -eq $kind }).properties.payload.'$ref'
            $actual | Should -Be $expected -Because "$kind must resolve to the same payload"
        }
    }

    It 'enforces the payload a kind selects' {
        # The binding proven behaviourally, not only structurally: a guest
        # payload under the build kind must be refused.
        $document = NewBuildEvidence -ArtifactIdentity (NewArtifact)
        $document.payload = [ordered]@{ phase = 'install' }
        Test-EvidenceEnvelopeDocument -Json (AsJson $document) | Should -Be 'evidence_malformed'
    }

    It 'declares its own version, not version 2' {
        $script:SchemaV3.properties.resultSchemaVersion.enum | Should -Be @(3)
    }
}

Describe 'the candidate gate establishes schema validity itself' {

    It 'refuses a record whose artifact identity is malformed' {
        # This returned true while Test-EvidenceEnvelopeDocument returned
        # evidence_malformed for the same document. A gate that depends on the
        # caller having remembered a separate validation step is not a gate.
        $document = NewBuildEvidence -ArtifactIdentity ([ordered]@{
            vCenterInstanceId      = 'vc-a'
            managedObjectReference = 'NOT-A-MOREF!'
            instanceUuid           = 'not-a-uuid'
        })

        Test-EvidenceEnvelopeDocument -Json (AsJson $document) | Should -Be 'evidence_malformed'
        Test-SealedCandidate -Json (AsJson $document) | Should -BeFalse
    }

    It 'refuses a record declaring an unsupported envelope version' {
        $document = NewBuildEvidence -ArtifactIdentity (NewArtifact)
        $document.resultSchemaVersion = 99
        Test-SealedCandidate -Json (AsJson $document) | Should -BeFalse
    }

    It 'refuses a record declaring an unsupported recipe-input version' {
        # A digest is only comparable within a version this code implements.
        # Version 64 satisfies the schema's range and means nothing here.
        $document = NewBuildEvidence -ArtifactIdentity (NewArtifact)
        $document.payload.recipeInputVersion = 64

        Test-EvidenceEnvelopeDocument -Json (AsJson $document) | Should -BeNullOrEmpty
        Test-SealedCandidate -Json (AsJson $document) | Should -BeFalse
    }

    It 'refuses a document that is not JSON at all' {
        Test-SealedCandidate -Json '{ not json' | Should -BeFalse
    }

    It 'refuses a document with no declared envelope version' {
        # Reading an absent property throws under StrictMode, so this must
        # produce a bounded reason rather than an exception.
        $document = NewBuildEvidence -ArtifactIdentity (NewArtifact)
        $document.Remove('resultSchemaVersion')

        Test-EvidenceEnvelopeDocument -Json (AsJson $document) | Should -Be 'evidence_malformed'
        Test-SealedCandidate -Json (AsJson $document) | Should -BeFalse
    }

    It 'accepts the complete, valid candidate' {
        # The positive case, so the refusals above are not passing for want of a
        # document that could ever succeed.
        Test-SealedCandidate -Json (AsJson (NewBuildEvidence -ArtifactIdentity (NewArtifact))) | Should -BeTrue
    }
}

Describe 'version 2 keeps its own acceptance rules' {

    It 'does not apply the version 3 control-character rule to a version 2 document' {
        # Applying it to version 2 would change what a published contract
        # accepts -- a behavioural change to a stable version, made silently as
        # a side effect of adding version 3. Version 2's own semantic checks
        # live with its own readers.
        $document = [ordered]@{
            resultSchemaVersion = 2; resultKind = 'source-qualification'
            runId = '3f2504e0-4f89-41d3-9a0c-0305e82c3301'; manifestSchemaVersion = 2
            startedUtc = '2026-01-01T00:00:00.0000000Z'; completedUtc = '2026-01-01T00:00:01.0000000Z'
            outcome = 'passed'
            payload = [ordered]@{
                packageCount = 1; passedCount = 1; failedRequiredCount = 0; failedOptionalCount = 0
                cleanupOutcome = 'removed'
                packages = @([ordered]@{
                    # A trailing newline. Version 2's pattern ends in $, which
                    # under .NET matches before one, so this document has always
                    # been accepted by version 2 and must stay accepted.
                    id = "a`n"; version = '1.0.0'; order = 1; required = $true
                    outcome = 'passed'; reasonCode = $null })
            }
        }

        Test-EvidenceEnvelopeDocument -Json (AsJson $document) | Should -BeNullOrEmpty
    }

    It 'still applies the rule to a version 3 document' {
        # The other half: scoping the rule to version 3 must not have disabled
        # it. Without this, dropping the version check entirely goes unnoticed.
        $document = NewBuildEvidence -ArtifactIdentity (NewArtifact)
        $document.payload.mediaId = "windows-baseline`n"
        Test-EvidenceEnvelopeDocument -Json (AsJson $document) | Should -Be 'evidence_malformed'
    }
}
