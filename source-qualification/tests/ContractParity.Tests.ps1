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
           failedRequiredCount = 0; installerAttemptCount = 0; cleanupOutcome = 'not-attempted'
           packages = @(@{ id = 'a'; version = $Version; order = 1; required = $false
                           outcome = 'failed'; reasonCode = 'installer_failed'
                           restartRequired = $false; installerAttempted = $false }) }
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

Describe 'committed schema identifiers' {

    BeforeAll {
        $script:ContractsDir = Join-Path (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) 'contracts'
        $script:SchemaFiles = @(Get-ChildItem -Path $script:ContractsDir -Filter '*.schema.json' -File -Recurse)
    }

    It 'finds schemas to check' {
        # Without this the rules below pass vacuously if the directory moves.
        $script:SchemaFiles.Count | Should -BeGreaterThan 3
    }

    It 'uses the example namespace for every schema identifier' {
        # A schema $id is published content. An identifier naming a real host or
        # account carries an affiliation into a document that is copied,
        # embedded, and quoted far from this repository.
        #
        # The boundary scanner does not catch this: the value is a
        # well-formed URL and matches no structural rule. It is a contract rule,
        # so it is enforced by the contract tests instead.
        $offenders = foreach ($file in $script:SchemaFiles) {
            $id = (Get-Content -LiteralPath $file.FullName -Raw | ConvertFrom-Json).'$id'
            if ($id -notmatch '^https://example\.invalid/schemas/[a-z0-9][a-z0-9-]*\.json$') {
                "$($file.Name): $id"
            }
        }
        $offenders | Should -BeNullOrEmpty
    }

    It 'gives every schema a distinct identifier' {
        $ids = foreach ($file in $script:SchemaFiles) {
            (Get-Content -LiteralPath $file.FullName -Raw | ConvertFrom-Json).'$id'
        }
        ($ids | Sort-Object -Unique).Count | Should -Be $script:SchemaFiles.Count
    }

    It 'names each schema identifier after its file' {
        # A copied schema whose $id still names the file it came from is the way
        # two contracts end up claiming one identity.
        #
        # One documented exception. package-manifest.schema.json was published
        # before the versioned file-naming convention existed, so its file
        # carries no version and its identifier does. The file is frozen
        # byte-for-byte by ADR 1 and cannot be renamed or edited to agree, so
        # the exception is recorded here rather than the rule being dropped.
        $frozen = @{ 'package-manifest.schema.json' = 'https://example.invalid/schemas/package-manifest-1.json' }

        foreach ($file in $script:SchemaFiles) {
            $id = (Get-Content -LiteralPath $file.FullName -Raw | ConvertFrom-Json).'$id'
            $expected = if ($frozen.ContainsKey($file.Name)) { $frozen[$file.Name] }
                        else { 'https://example.invalid/schemas/' + ($file.Name -replace '\.schema\.json$', '.json') }
            $id | Should -Be $expected -Because "$($file.Name) should identify itself"
        }
    }
}

Describe 'schema pattern portability' {

    BeforeAll {
        $script:AllPatterns = foreach ($file in @(Get-ChildItem -Path (Join-Path (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) 'contracts') -Filter '*.schema.json' -File -Recurse)) {
            $raw = Get-Content -LiteralPath $file.FullName -Raw
            foreach ($match in [regex]::Matches($raw, '"pattern"\s*:\s*"(?<p>(\\.|[^"\\])*)"')) {
                [PSCustomObject]@{ File = $file.Name; Pattern = $match.Groups['p'].Value }
            }
        }
    }

    It 'finds patterns to check' {
        @($script:AllPatterns).Count | Should -BeGreaterThan 10
    }

    It 'uses no anchor ECMA-262 does not define' {
        # JSON Schema draft-07 specifies ECMA-262 regular expressions. \A and \z
        # are .NET constructs; a JavaScript engine reads \Ax\z as a literal A, an
        # x, and a literal z, so a schema using them validates here and demands
        # nonsense everywhere else -- silently, and in the permissive direction.
        #
        # The trailing-newline gap those anchors were reached for is closed
        # semantically instead, by Assert-NoControlCharacter.
        $offenders = @($script:AllPatterns | Where-Object { $_.Pattern -match '\\A|\\z|\\Z' } |
            ForEach-Object { "$($_.File): $($_.Pattern)" })
        $offenders | Should -BeNullOrEmpty
    }

    It 'compiles every pattern under ECMA-262 semantics' {
        # A pattern that only .NET accepts is one no other validator can apply.
        $node = Get-Command node -ErrorAction SilentlyContinue
        if (-not $node) { Set-ItResult -Skipped -Because 'node is not installed'; return }

        $script = @'
let bad = [];
for (const line of require('fs').readFileSync(process.argv[1], 'utf8').split('\n')) {
  if (!line.trim()) continue;
  const sep = line.indexOf('\t');
  try { new RegExp(line.slice(sep + 1)); } catch (e) { bad.push(line.slice(0, sep) + ': ' + e.message); }
}
console.log(bad.join('\n'));
'@
        $listing = Join-Path ([System.IO.Path]::GetTempPath()) ([guid]::NewGuid().ToString() + '.txt')
        $scriptPath = Join-Path ([System.IO.Path]::GetTempPath()) ([guid]::NewGuid().ToString() + '.js')
        # The captured text is the JSON string literal, so its escapes are
        # decoded before ECMA sees them, exactly as a validator would.
        ($script:AllPatterns | ForEach-Object {
            $_.File + "`t" + ($_.Pattern -replace '\\\\', '\' -replace '\\"', '"')
        }) -join "`n" | Set-Content -LiteralPath $listing -Encoding utf8
        $script | Set-Content -LiteralPath $scriptPath -Encoding utf8

        (& node $scriptPath $listing) -join "`n" | Should -BeNullOrEmpty
    }
}
