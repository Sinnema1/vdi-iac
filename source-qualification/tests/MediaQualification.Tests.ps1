#Requires -Version 7.0

BeforeAll {
    $script:RepoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    Import-Module (Join-Path $script:RepoRoot 'source-qualification' 'scripts' 'MediaQualification.psm1') -Force
    Import-Module (Join-Path $script:RepoRoot 'source-qualification' 'scripts' 'RunIdentity.psm1') -Force

    $script:ReferenceSchema = Join-Path $script:RepoRoot 'contracts' 'media-reference-1.schema.json'
    $script:RecordSchema = Join-Path $script:RepoRoot 'contracts' 'media-qualification-1.schema.json'

    function NewTempDir {
        $d = Join-Path ([System.IO.Path]::GetTempPath()) ([guid]::NewGuid().ToString())
        $null = New-Item -ItemType Directory -Path $d -Force
        $d
    }

    function NewMediaFile {
        # Stands in for installation media. Content is irrelevant; only its
        # digest is, and a few bytes hash exactly as a few gigabytes would.
        param([string] $Root, [string] $Name = 'windows.iso', [string] $Content = 'installation-media-content')
        $path = Join-Path $Root $Name
        Set-Content -LiteralPath $path -Value $Content -NoNewline -Encoding utf8
        [PSCustomObject]@{
            Path   = $path
            Name   = $Name
            Digest = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant()
            Length = (Get-Item -LiteralPath $path).Length
        }
    }

    function NewReference {
        param(
            [string] $Path, [string] $Digest, [string] $Locator = 'windows.iso',
            [string] $FileName = 'windows.iso', [string] $Algorithm = 'SHA256',
            [string] $Citation = 'https://vendor.example/downloads/checksums.txt',
            [string] $AuthorityKind = 'vendor-published',
            [int] $SizeBytes = 0, [string] $Edition = 'Windows Enterprise',
            [int] $Index = 1, [string] $Architecture = 'x64', [string] $Language = 'en-US',
            [string] $MediaId = 'windows-baseline'
        )
        $reference = [ordered]@{
            schemaVersion = 1
            mediaId       = $MediaId
            reference     = [ordered]@{ kind = 'file'; locator = $Locator; fileName = $FileName }
            integrity     = [ordered]@{
                algorithm = $Algorithm; digest = $Digest
                authority = [ordered]@{
                    kind = $AuthorityKind; citation = $Citation
                    retrievedUtc = '2026-01-01T00:00:00Z'
                }
            }
            image         = [ordered]@{ edition = $Edition; index = $Index }
            platform      = [ordered]@{ architecture = $Architecture; language = $Language }
        }
        if ($SizeBytes -gt 0) { $reference.reference.sizeBytes = $SizeBytes }
        $reference | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $Path -Encoding utf8
        $Path
    }
}

Describe 'the media reference contract' {

    It 'accepts a complete reference' {
        $root = NewTempDir
        $media = NewMediaFile -Root $root
        $path = NewReference -Path (Join-Path $root 'media.json') -Digest $media.Digest
        { Import-MediaReference -Path $path } | Should -Not -Throw
    }

    It 'rejects a reference missing <field>' -ForEach @(
        @{ field = 'mediaId' }, @{ field = 'reference' }, @{ field = 'integrity' }
        @{ field = 'image' },   @{ field = 'platform' },  @{ field = 'schemaVersion' }
    ) {
        $root = NewTempDir
        $media = NewMediaFile -Root $root
        $path = NewReference -Path (Join-Path $root 'media.json') -Digest $media.Digest
        $document = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json -AsHashtable
        $document.Remove($field)
        $document | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $path -Encoding utf8

        { Import-MediaReference -Path $path } | Should -Throw
    }

    It 'rejects an unknown property, so a typo is not silently ignored' {
        $root = NewTempDir
        $media = NewMediaFile -Root $root
        $path = NewReference -Path (Join-Path $root 'media.json') -Digest $media.Digest
        $document = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json -AsHashtable
        $document['editon'] = 'Windows Enterprise'
        $document | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $path -Encoding utf8

        { Import-MediaReference -Path $path } | Should -Throw
    }

    It 'rejects architecture <value>' -ForEach @(
        @{ value = 'x86' }, @{ value = 'amd64' }, @{ value = 'X64' }, @{ value = '' }
    ) {
        $root = NewTempDir
        $media = NewMediaFile -Root $root
        $path = NewReference -Path (Join-Path $root 'media.json') -Digest $media.Digest -Architecture $value
        { Import-MediaReference -Path $path } | Should -Throw
    }

    It 'rejects language <value>' -ForEach @(
        @{ value = 'english' }, @{ value = 'EN-US' }, @{ value = 'en_US' }, @{ value = '' }
    ) {
        $root = NewTempDir
        $media = NewMediaFile -Root $root
        $path = NewReference -Path (Join-Path $root 'media.json') -Digest $media.Digest -Language $value
        { Import-MediaReference -Path $path } | Should -Throw
    }

    It 'rejects image index <value>, which no media carries' -ForEach @(
        @{ value = 0 }, @{ value = -1 }, @{ value = 65 }
    ) {
        $root = NewTempDir
        $media = NewMediaFile -Root $root
        $path = NewReference -Path (Join-Path $root 'media.json') -Digest $media.Digest -Index $value
        { Import-MediaReference -Path $path } | Should -Throw
    }

    It 'rejects a digest whose length disagrees with its algorithm' {
        # Schema-valid in isolation: both patterns admit a 64-character digest.
        # Only the pairing is wrong, which no per-field constraint can see.
        $root = NewTempDir
        $media = NewMediaFile -Root $root
        $path = NewReference -Path (Join-Path $root 'media.json') -Digest $media.Digest -Algorithm 'SHA512'

        { Import-MediaReference -Path $path } | Should -Throw -ExpectedMessage '*512 digest is 128 characters*'
    }

    It 'rejects a non-hexadecimal digest' {
        $root = NewTempDir
        $path = NewReference -Path (Join-Path $root 'media.json') -Digest ('z' * 64)
        { Import-MediaReference -Path $path } | Should -Throw
    }

    It 'rejects an uppercase digest, so one spelling reaches the comparison' {
        $root = NewTempDir
        $media = NewMediaFile -Root $root
        $path = NewReference -Path (Join-Path $root 'media.json') -Digest $media.Digest.ToUpperInvariant()
        { Import-MediaReference -Path $path } | Should -Throw
    }
}

Describe 'the checksum authority' {

    It 'accepts an HTTPS citation' {
        $root = NewTempDir
        $media = NewMediaFile -Root $root
        $path = NewReference -Path (Join-Path $root 'media.json') -Digest $media.Digest `
            -Locator 'vendor/windows.iso' -Citation 'https://vendor.example/security/checksums'
        { Import-MediaReference -Path $path } | Should -Not -Throw
    }

    It 'rejects a citation that is a path rather than a reference: <value>' -ForEach @(
        @{ value = 'vendor/SHA256SUMS' }
        @{ value = './vendor/SHA256SUMS' }
        @{ value = 'SHA256SUMS' }
        @{ value = 'C:/media/SHA256SUMS' }
        @{ value = '../SHA256SUMS' }
    ) {
        # The structural rule replaces a path comparison that could be spelled
        # around -- './vendor/...' defeated it, and root-level media never
        # entered it at all. A filesystem path cannot be an HTTPS reference, so
        # the whole family is refused by shape rather than case by case.
        $root = NewTempDir
        $media = NewMediaFile -Root $root
        $path = NewReference -Path (Join-Path $root 'media.json') -Digest $media.Digest `
            -Locator 'vendor/windows.iso' -Citation $value
        { Import-MediaReference -Path $path } | Should -Throw
    }

    It 'rejects an insecure or malformed citation: <value>' -ForEach @(
        @{ value = 'http://vendor.example/checksums' }
        @{ value = 'https://vendor' }
        @{ value = 'https://' }
        @{ value = 'ftp://vendor.example/checksums' }
        @{ value = 'https://vendor.example/check sums' }
    ) {
        $root = NewTempDir
        $media = NewMediaFile -Root $root
        $path = NewReference -Path (Join-Path $root 'media.json') -Digest $media.Digest -Citation $value
        { Import-MediaReference -Path $path } | Should -Throw
    }

    It 'rejects any authority kind other than vendor-published: <value>' -ForEach @(
        @{ value = 'operator-attested' }, @{ value = 'trusted' }, @{ value = '' }
    ) {
        # operator-attested was removed. An operator recording a checksum they
        # read from a vendor page is citing that vendor page, and the citation
        # already says so; a second kind only offered a weaker option with no
        # distinguishable meaning.
        $root = NewTempDir
        $media = NewMediaFile -Root $root
        $path = NewReference -Path (Join-Path $root 'media.json') -Digest $media.Digest -AuthorityKind $value
        { Import-MediaReference -Path $path } | Should -Throw
    }
}

Describe 'Invoke-MediaQualification' {

    It 'passes media whose digest matches, and records the observation' {
        $root = NewTempDir
        $media = NewMediaFile -Root $root
        $path = NewReference -Path (Join-Path $root 'media.json') -Digest $media.Digest

        $record = Invoke-MediaQualification -ReferencePath $path -MediaRoot $root
        $record.outcome | Should -Be 'passed'
        $record.reasonCode | Should -BeNullOrEmpty
        $record.integrity.observedDigest | Should -Be $media.Digest
        $record.integrity.expectedDigest | Should -Be $media.Digest
    }

    It 'carries the full identity a build needs into the record' {
        # The builder consumes this record. Anything it has to guess is a value
        # the build is not pinning.
        $root = NewTempDir
        $media = NewMediaFile -Root $root
        $path = NewReference -Path (Join-Path $root 'media.json') -Digest $media.Digest `
            -Edition 'Windows Enterprise' -Index 3 -Architecture 'x64' -Language 'en-GB'

        $record = Invoke-MediaQualification -ReferencePath $path -MediaRoot $root
        $record.image.edition | Should -Be 'Windows Enterprise'
        $record.image.index | Should -Be 3
        $record.platform.architecture | Should -Be 'x64'
        $record.platform.language | Should -Be 'en-GB'
        $record.integrity.algorithm | Should -Be 'SHA256'
        $record.integrity.authority.citation | Should -Not -BeNullOrEmpty
        $record.reference.fileName | Should -Be 'windows.iso'
    }

    It 'fails media whose content does not match the expected digest' {
        $root = NewTempDir
        $media = NewMediaFile -Root $root
        $path = NewReference -Path (Join-Path $root 'media.json') -Digest $media.Digest

        # Tampered after the expectation was established, which is the order
        # that makes the check meaningful.
        Set-Content -LiteralPath $media.Path -Value 'substituted-content' -NoNewline -Encoding utf8

        $record = Invoke-MediaQualification -ReferencePath $path -MediaRoot $root
        $record.outcome | Should -Be 'failed'
        $record.reasonCode | Should -Be 'integrity_mismatch'
        $record.integrity.observedDigest | Should -Not -Be $record.integrity.expectedDigest
    }

    It 'records a refusal rather than writing nothing' {
        # A build that finds no record cannot tell a refusal from a stage that
        # never ran, and the safe reading of an absent file is not obvious.
        $root = NewTempDir
        $media = NewMediaFile -Root $root
        $path = NewReference -Path (Join-Path $root 'media.json') -Digest $media.Digest
        Remove-Item -LiteralPath $media.Path -Force

        $record = Invoke-MediaQualification -ReferencePath $path -MediaRoot $root
        $record.outcome | Should -Be 'failed'
        $record.reasonCode | Should -Be 'media_not_found'
        $record.integrity.observedDigest | Should -BeNullOrEmpty
    }

    It 'fails media that resolves outside the media root' {
        $root = NewTempDir
        $outside = NewMediaFile -Root (NewTempDir) -Name 'windows.iso'
        $path = NewReference -Path (Join-Path $root 'media.json') -Digest $outside.Digest `
            -Locator '../elsewhere/windows.iso'

        (Invoke-MediaQualification -ReferencePath $path -MediaRoot $root).reasonCode |
            Should -Be 'media_outside_root'
    }

    It 'fails media whose resolved name disagrees with the reference' {
        $root = NewTempDir
        $media = NewMediaFile -Root $root -Name 'other.iso'
        $path = NewReference -Path (Join-Path $root 'media.json') -Digest $media.Digest `
            -Locator 'other.iso' -FileName 'windows.iso'

        (Invoke-MediaQualification -ReferencePath $path -MediaRoot $root).reasonCode |
            Should -Be 'media_name_mismatch'
    }

    It 'fails a size mismatch before it hashes the artifact' {
        $root = NewTempDir
        $media = NewMediaFile -Root $root
        $path = NewReference -Path (Join-Path $root 'media.json') -Digest $media.Digest `
            -SizeBytes ($media.Length + 4096)

        $record = Invoke-MediaQualification -ReferencePath $path -MediaRoot $root
        $record.reasonCode | Should -Be 'media_size_mismatch'
        $record.integrity.observedDigest | Should -BeNullOrEmpty -Because 'the artifact should not have been hashed'
    }

    It 'accepts a size that matches' {
        $root = NewTempDir
        $media = NewMediaFile -Root $root
        $path = NewReference -Path (Join-Path $root 'media.json') -Digest $media.Digest -SizeBytes $media.Length
        (Invoke-MediaQualification -ReferencePath $path -MediaRoot $root).outcome | Should -Be 'passed'
    }

    It 'refuses media reached through a symbolic link' -Skip:($IsWindows) {
        # Reparse points beneath the root are refused rather than followed: a
        # resolved target can be replaced between the check and the read.
        $root = NewTempDir
        $outside = NewMediaFile -Root (NewTempDir) -Name 'windows.iso'
        $null = New-Item -ItemType SymbolicLink -Path (Join-Path $root 'windows.iso') -Target $outside.Path
        $path = NewReference -Path (Join-Path $root 'media.json') -Digest $outside.Digest

        (Invoke-MediaQualification -ReferencePath $path -MediaRoot $root).reasonCode |
            Should -Be 'media_link_rejected'
    }

    It 'carries the supplied run identifier into the record' {
        $root = NewTempDir
        $media = NewMediaFile -Root $root
        $path = NewReference -Path (Join-Path $root 'media.json') -Digest $media.Digest
        $runId = Get-RunIdentifier

        (Invoke-MediaQualification -ReferencePath $path -MediaRoot $root -RunId $runId).runId | Should -Be $runId
    }

    It 'refuses a run identifier that is not a canonical UUID' {
        $root = NewTempDir
        $media = NewMediaFile -Root $root
        $path = NewReference -Path (Join-Path $root 'media.json') -Digest $media.Digest

        { Invoke-MediaQualification -ReferencePath $path -MediaRoot $root -RunId '../escape' } | Should -Throw
    }
}

Describe 'the qualification record contract' {

    BeforeAll {
        function NewRecord {
            param([string] $Root)
            $media = NewMediaFile -Root $Root
            $path = NewReference -Path (Join-Path $Root 'media.json') -Digest $media.Digest
            Invoke-MediaQualification -ReferencePath $path -MediaRoot $Root
        }
    }

    It 'writes a passed record that satisfies its own contract' {
        $root = NewTempDir
        $record = NewRecord -Root $root
        $out = Join-Path $root 'qualification.json'
        Save-MediaQualificationRecord -Record $record -Path $out | Out-Null

        Test-Json -Json (Get-Content -LiteralPath $out -Raw) -SchemaFile $script:RecordSchema -ErrorAction SilentlyContinue |
            Should -BeTrue
    }

    It 'writes a failed record that satisfies its own contract' {
        $root = NewTempDir
        # The file has to exist so the run reaches the digest comparison; its
        # own digest is irrelevant, because the reference declares another.
        NewMediaFile -Root $root | Out-Null
        $path = NewReference -Path (Join-Path $root 'media.json') -Digest ('b' * 64)
        $record = Invoke-MediaQualification -ReferencePath $path -MediaRoot $root
        $out = Join-Path $root 'qualification.json'
        Save-MediaQualificationRecord -Record $record -Path $out | Out-Null

        Test-Json -Json (Get-Content -LiteralPath $out -Raw) -SchemaFile $script:RecordSchema -ErrorAction SilentlyContinue |
            Should -BeTrue
    }

    It 'refuses to write a passed record carrying a reason code' {
        # Not a schema rule, deliberately: Test-Json does not enforce draft-07
        # if/then, so a conditional written there would validate this document.
        $root = NewTempDir
        $record = NewRecord -Root $root
        $record.reasonCode = 'integrity_mismatch'

        { Save-MediaQualificationRecord -Record $record -Path (Join-Path $root 'q.json') } |
            Should -Throw -ExpectedMessage '*carries a reason code*'
    }

    It 'refuses to write a passed record that never observed a digest' {
        $root = NewTempDir
        $record = NewRecord -Root $root
        $record.integrity.observedDigest = $null

        { Save-MediaQualificationRecord -Record $record -Path (Join-Path $root 'q.json') } |
            Should -Throw -ExpectedMessage '*no observed digest*'
    }

    It 'refuses to write a passed record whose digests disagree' {
        $root = NewTempDir
        $record = NewRecord -Root $root
        $record.integrity.observedDigest = 'c' * 64

        { Save-MediaQualificationRecord -Record $record -Path (Join-Path $root 'q.json') } |
            Should -Throw -ExpectedMessage '*digests that do not match*'
    }

    It 'refuses a record whose algorithm and expected digest disagree' {
        # The record is as capable of carrying a contradictory pair as the
        # reference is, and it is the document the builder consumes.
        $root = NewTempDir
        $record = NewRecord -Root $root
        $record.integrity.algorithm = 'SHA512'

        { Save-MediaQualificationRecord -Record $record -Path (Join-Path $root 'q.json') } |
            Should -Throw -ExpectedMessage '*SHA512 expected digest is 128 characters*'
    }

    It 'refuses a record whose observed digest is the wrong length for its algorithm' {
        $root = NewTempDir
        $record = NewRecord -Root $root
        $record.integrity.observedDigest = 'd' * 96

        { Save-MediaQualificationRecord -Record $record -Path (Join-Path $root 'q.json') } |
            Should -Throw -ExpectedMessage '*observed digest*'
    }

    It 'refuses to write a failed record with no reason code' {
        $root = NewTempDir
        $record = NewRecord -Root $root
        $record.outcome = 'failed'
        $record.reasonCode = $null

        { Save-MediaQualificationRecord -Record $record -Path (Join-Path $root 'q.json') } |
            Should -Throw -ExpectedMessage '*no reason code*'
    }

    It 'does not write a file when the record is refused' {
        $root = NewTempDir
        $record = NewRecord -Root $root
        $record.reasonCode = 'integrity_mismatch'
        $out = Join-Path $root 'q.json'

        { Save-MediaQualificationRecord -Record $record -Path $out } | Should -Throw
        Test-Path -LiteralPath $out | Should -BeFalse
    }
}

Describe 'the committed media reference example' {

    It 'satisfies the reference contract' {
        # An example that does not validate is worse than none: it is the shape
        # people copy, and it would fail only once someone tried to build.
        $example = Join-Path $script:RepoRoot 'packer' 'media' 'windows-baseline.media.json.example'
        Test-Path -LiteralPath $example | Should -BeTrue
        Test-Json -Json (Get-Content -LiteralPath $example -Raw) -SchemaFile $script:ReferenceSchema -ErrorAction SilentlyContinue |
            Should -BeTrue
    }

    It 'carries an obviously unusable digest rather than a plausible one' {
        # A placeholder that looks real is one that gets shipped by accident.
        $example = Join-Path $script:RepoRoot 'packer' 'media' 'windows-baseline.media.json.example'
        (Get-Content -LiteralPath $example -Raw | ConvertFrom-Json).integrity.digest |
            Should -Be ('0' * 64)
    }

    It 'is an example only, never a live reference, at any depth' {
        # This repository is a reference implementation and carries the
        # synthetic example only. A live reference names a real artifact and its
        # digest, and belongs in the repository that operates a build.
        #
        # Searched recursively: a top-level search would miss
        # packer/media/windows/live.media.json, and the directory is not
        # required to stay flat.
        Get-ChildItem -Path (Join-Path $script:RepoRoot 'packer' 'media') -Filter '*.media.json' -File -Recurse |
            Should -BeNullOrEmpty
    }
}

Describe 'media contract parity' {

    BeforeAll {
        $script:Reference = Get-Content -LiteralPath $script:ReferenceSchema -Raw | ConvertFrom-Json
        $script:Record = Get-Content -LiteralPath $script:RecordSchema -Raw | ConvertFrom-Json
    }

    It 'uses one digest pattern in both contracts' {
        # The record repeats the reference's shapes rather than referring across
        # files, because Test-Json does not resolve external references. Repeated
        # shapes drift, so the drift is what gets asserted.
        $script:Record.properties.integrity.properties.expectedDigest.pattern |
            Should -Be $script:Reference.properties.integrity.properties.digest.pattern
        $script:Record.properties.integrity.properties.observedDigest.oneOf[1].pattern |
            Should -Be $script:Reference.properties.integrity.properties.digest.pattern
    }

    It 'permits the same algorithms in both contracts' {
        ($script:Record.properties.integrity.properties.algorithm.enum -join ',') |
            Should -Be ($script:Reference.properties.integrity.properties.algorithm.enum -join ',')
    }

    It 'constrains <section> identically in both contracts' -ForEach @(
        @{ section = 'image' }, @{ section = 'platform' }
    ) {
        # Constraints, not prose. The reference documents each field for a human
        # writing one; the record is machine-consumed. What must not diverge is
        # what each will accept.
        function StripDescriptions {
            param($Node)
            if ($Node -is [System.Management.Automation.PSCustomObject]) {
                $copy = [ordered]@{}
                foreach ($property in $Node.PSObject.Properties) {
                    if ($property.Name -eq 'description') { continue }
                    $copy[$property.Name] = StripDescriptions -Node $property.Value
                }
                return [PSCustomObject]$copy
            }
            $Node
        }

        (StripDescriptions -Node $script:Record.properties.$section | ConvertTo-Json -Depth 12) |
            Should -Be (StripDescriptions -Node $script:Reference.properties.$section | ConvertTo-Json -Depth 12)
    }

    It 'requires the same authority fields in both contracts' {
        $recordAuthority = $script:Record.properties.integrity.properties.authority
        $referenceAuthority = $script:Reference.properties.integrity.properties.authority
        ($recordAuthority.required -join ',') | Should -Be ($referenceAuthority.required -join ',')
        ($recordAuthority.properties.kind.enum -join ',') | Should -Be ($referenceAuthority.properties.kind.enum -join ',')
    }

    It 'permits the same reference kinds in both contracts' {
        ($script:Record.properties.reference.properties.kind.enum -join ',') |
            Should -Be ($script:Reference.properties.reference.properties.kind.enum -join ',')
    }
}
