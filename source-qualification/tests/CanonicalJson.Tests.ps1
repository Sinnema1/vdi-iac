#Requires -Version 7.0

BeforeAll {
    $script:RepoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    Import-Module (Join-Path $script:RepoRoot 'source-qualification' 'scripts' 'CanonicalJson.psm1') -Force
}

Describe 'canonical serialization' {

    It 'orders object keys the same way regardless of insertion order' {
        # The rule the whole digest rests on. A serializer following insertion
        # order gives two machines that agree about every input two different
        # identities.
        $a = [ordered]@{ zebra = 1; apple = 2; Mango = 3 }
        $b = [ordered]@{ Mango = 3; zebra = 1; apple = 2 }
        (ConvertTo-CanonicalJson -Node $a) | Should -Be (ConvertTo-CanonicalJson -Node $b)
    }

    It 'orders keys by ordinal code point, not by culture' {
        # A culture-aware sort places these differently in different locales, so
        # the digest would depend on the machine's regional settings.
        ConvertTo-CanonicalJson -Node ([ordered]@{ a = 1; B = 2 }) | Should -Be '{"B":2,"a":1}'
    }

    It 'preserves array order' {
        # Sequence-bearing arrays must survive. Package order is semantic, and
        # sorting it away is the most natural mistake to make here.
        ConvertTo-CanonicalJson -Node @(3, 1, 2) | Should -Be '[3,1,2]'
        (ConvertTo-CanonicalJson -Node @(1, 2, 3)) | Should -Not -Be (ConvertTo-CanonicalJson -Node @(3, 2, 1))
    }

    It 'emits no whitespace between tokens' {
        ConvertTo-CanonicalJson -Node ([ordered]@{ a = @(1, 2); b = [ordered]@{ c = $true } }) |
            Should -Be '{"a":[1,2],"b":{"c":true}}'
    }

    It 'emits integers in shortest decimal form' {
        ConvertTo-CanonicalJson -Node ([ordered]@{ n = 0; m = 10; k = -3; big = 4294967296 }) |
            Should -Be '{"big":4294967296,"k":-3,"m":10,"n":0}'
    }

    It 'distinguishes a number from its string spelling' {
        (ConvertTo-CanonicalJson -Node ([ordered]@{ v = 1 })) |
            Should -Not -Be (ConvertTo-CanonicalJson -Node ([ordered]@{ v = '1' }))
    }

    It 'refuses floating point' {
        # Two runtimes can print the same double differently, so a digest over
        # one would not be reproducible.
        { ConvertTo-CanonicalJson -Node ([ordered]@{ v = 1.5 }) } |
            Should -Throw -ExpectedMessage '*refuses floating point*'
    }

    It 'refuses null rather than encoding it' {
        # An omitted field and an explicit null would otherwise be two spellings
        # of one absence, digesting differently.
        { ConvertTo-CanonicalJson -Node ([ordered]@{ v = $null }) } |
            Should -Throw -ExpectedMessage '*omit the value instead*'
    }

    It 'distinguishes an omitted value from an empty one' {
        (ConvertTo-CanonicalJson -Node ([ordered]@{ a = 1 })) |
            Should -Not -Be (ConvertTo-CanonicalJson -Node ([ordered]@{ a = 1; b = '' }))
    }

    It 'refuses a control character in a string' {
        { ConvertTo-CanonicalJson -Node ([ordered]@{ v = "line`n" }) } |
            Should -Throw -ExpectedMessage '*refuses control character 0x0A*'
    }

    It 'escapes only what JSON requires' {
        ConvertTo-CanonicalJson -Node ([ordered]@{ v = 'a"b\c' }) | Should -Be '{"v":"a\"b\\c"}'
    }

    It 'emits non-ASCII text directly rather than escaping it' {
        # UTF-8 is the canonical encoding, so an escape would be a second
        # spelling of the same character.
        ConvertTo-CanonicalJson -Node ([ordered]@{ v = ('caf' + [char]0xE9) }) | Should -Be "{`"v`":caf$([char]0xE9)`"}".Replace(':caf', ':"caf')
    }

    It 'serializes a hashtable and an object with the same properties identically' {
        $object = [PSCustomObject]@{ b = 2; a = 1 }
        (ConvertTo-CanonicalJson -Node $object) | Should -Be (ConvertTo-CanonicalJson -Node ([ordered]@{ a = 1; b = 2 }))
    }

    It 'refuses a type it has no representation for' {
        { ConvertTo-CanonicalJson -Node ([ordered]@{ v = (Get-Date) }) } |
            Should -Throw -ExpectedMessage '*no representation for*'
    }

    It 'refuses a document nested beyond the depth bound' {
        $node = [ordered]@{ v = 'leaf' }
        foreach ($i in 1..40) { $node = [ordered]@{ v = $node } }
        { ConvertTo-CanonicalJson -Node $node } | Should -Throw -ExpectedMessage '*nests deeper than expected*'
    }
}

Describe 'canonical digest' {

    It 'is stable across insertion order' {
        (Get-CanonicalJsonDigest -Node ([ordered]@{ b = 1; a = 2 })) |
            Should -Be (Get-CanonicalJsonDigest -Node ([ordered]@{ a = 2; b = 1 }))
    }

    It 'is lowercase hexadecimal of the expected length' {
        Get-CanonicalJsonDigest -Node ([ordered]@{ a = 1 }) | Should -Match '^[0-9a-f]{64}$'
    }

    It 'matches an independently computed SHA-256 of the canonical bytes' {
        # Guards against the digest being taken over something other than what
        # ConvertTo-CanonicalJson produced.
        $node = [ordered]@{ b = 1; a = 'x' }
        $text = ConvertTo-CanonicalJson -Node $node
        $bytes = [System.Text.UTF8Encoding]::new($false).GetBytes($text)
        $stream = [System.IO.MemoryStream]::new($bytes)
        try { $expected = (Get-FileHash -InputStream $stream -Algorithm SHA256).Hash.ToLowerInvariant() }
        finally { $stream.Dispose() }

        Get-CanonicalJsonDigest -Node $node | Should -Be $expected
    }

    It 'changes when any value changes' {
        (Get-CanonicalJsonDigest -Node ([ordered]@{ a = 1 })) |
            Should -Not -Be (Get-CanonicalJsonDigest -Node ([ordered]@{ a = 2 }))
    }
}
