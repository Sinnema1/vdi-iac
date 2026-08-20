#Requires -Version 7.0

<#
    Cross-cutting checks that span two contracts.

    A rule copied from one schema into another drifts silently: the copy keeps
    passing its own tests while the two documents disagree about what a value
    is. These assert the agreement itself, so a change to one contract that is
    not mirrored in the other fails here rather than in a later increment.
#>

BeforeAll {
    $script:RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..' '..')).Path
    $contracts = Join-Path $script:RepoRoot 'contracts'
    Import-Module (Join-Path $script:RepoRoot 'source-qualification' 'scripts' 'RunIdentity.psm1') -Force
    Import-Module (Join-Path $script:RepoRoot 'source-qualification' 'scripts' 'Evidence.psm1') -Force

    $script:ManifestSchema = Get-Content -LiteralPath (Join-Path $contracts 'package-manifest-2.schema.json') -Raw | ConvertFrom-Json
    $script:EvidenceSchema = Get-Content -LiteralPath (Join-Path $contracts 'evidence-envelope-2.schema.json') -Raw | ConvertFrom-Json
    $script:ManifestVersion = $script:ManifestSchema.definitions.package.properties.version

    function EvidenceVersionNode {
        param([string] $Definition)
        $script:EvidenceSchema.definitions.$Definition.properties.version
    }

    function GuestPayloadWithVersion {
        param([string] $Version)
        @{ phase = 'install'; restartRequired = $false; packageCount = 1; passedCount = 0
           failedRequiredCount = 0; cleanupOutcome = 'not-attempted'
           packages = @(@{ id = 'a'; version = $Version; order = 1; required = $false
                           outcome = 'failed'; reasonCode = 'installer_failed'; restartRequired = $false }) }
    }

    function QualificationPayloadWithVersion {
        param([string] $Version)
        @{ packageCount = 1; passedCount = 0; failedRequiredCount = 0; failedOptionalCount = 1
           cleanupOutcome = 'removed'
           packages = @(@{ id = 'a'; version = $Version; order = 1; required = $false
                           outcome = 'failed'; reasonCode = 'integrity_mismatch' }) }
    }

    function TryEnvelope {
        param([string] $Kind, [string] $Version)
        $payload = if ($Kind -eq 'guest-provisioning') { GuestPayloadWithVersion $Version } else { QualificationPayloadWithVersion $Version }
        try {
            $null = ConvertTo-EvidenceEnvelope -ResultKind $Kind -RunId (Get-RunIdentifier) -Outcome failed `
                -StartedUtc ([datetime]::UtcNow) -ManifestSchemaVersion 2 -Payload $payload
            'accepted'
        }
        catch { 'rejected' }
    }
}

Describe 'evidence and manifest agree on what a version is' {

    It 'copies the manifest version pattern into <definition>' -ForEach @(
        @{ definition = 'qualificationPackage' }, @{ definition = 'guestPackage' }
    ) {
        (EvidenceVersionNode $definition).pattern | Should -Be $script:ManifestVersion.pattern
    }

    It 'copies the manifest rejection pattern into <definition>' -ForEach @(
        @{ definition = 'qualificationPackage' }, @{ definition = 'guestPackage' }
    ) {
        # The half that was missed. The positive pattern was copied and the
        # companion rejection was not, so evidence would have accepted a version
        # a manifest could never declare.
        (EvidenceVersionNode $definition).not.pattern | Should -Be $script:ManifestVersion.not.pattern
    }

    It 'bounds <definition> version length as the manifest does' -ForEach @(
        @{ definition = 'qualificationPackage' }, @{ definition = 'guestPackage' }
    ) {
        (EvidenceVersionNode $definition).maxLength | Should -Be $script:ManifestVersion.maxLength
    }
}

Describe 'evidence refuses a version a manifest could not declare' {

    It 'refuses <version> in guest-provisioning evidence' -ForEach @(
        @{ version = 'latest' }, @{ version = 'LATEST' }, @{ version = 'newest' }
        @{ version = 'x' }, @{ version = '1.x' }, @{ version = '1.x.0' }
        @{ version = '1.*' }, @{ version = '>=1.0' }
    ) {
        TryEnvelope 'guest-provisioning' $version | Should -Be 'rejected'
    }

    It 'refuses <version> in source-qualification evidence' -ForEach @(
        @{ version = 'latest' }, @{ version = 'x' }, @{ version = '1.x' }, @{ version = '1.*' }
    ) {
        TryEnvelope 'source-qualification' $version | Should -Be 'rejected'
    }

    It 'still accepts <version>, which a manifest may declare' -ForEach @(
        @{ version = '1.2.3' }, @{ version = '1.0.0-rc.1' }, @{ version = '2026.08.1' }
        @{ version = '1.0.0-x64' }, @{ version = '10.0.19045' }
    ) {
        TryEnvelope 'guest-provisioning' $version | Should -Be 'accepted'
    }
}
