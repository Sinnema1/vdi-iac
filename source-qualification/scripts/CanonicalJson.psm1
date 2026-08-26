#Requires -Version 7.0

<#
.SYNOPSIS
    Serializes a document to one byte sequence, the same way every time.

.DESCRIPTION
    A digest is only an identity if the same inputs always produce the same
    bytes. ConvertTo-Json does not promise that: property order follows
    insertion, escaping and spacing are free to change between releases, and
    numeric formatting follows the runtime. Any of those would make a recipe
    digest differ between two machines that agree about every input.

    So the representation is fixed here rather than inherited, per ADR 7:

      - UTF-8, no byte-order mark;
      - object keys sorted by ordinal code point, never by culture, because a
        culture-aware sort orders the same two keys differently in different
        locales;
      - arrays emitted in the order given. Sequence-bearing arrays are therefore
        preserved, and a caller wanting set semantics sorts before calling;
      - integers only, in shortest decimal form. Floating point is refused: two
        runtimes can print the same double differently, and a recipe has no
        field that needs one;
      - no whitespace between tokens;
      - absent values omitted by the caller, never encoded as null;
      - control characters refused outright, so no \u escape is ever emitted and
        there is no question of which case its hex digits take;
      - unpaired surrogates refused. The default UTF-8 encoder replaces every
        invalid code unit with U+FFFD, so two strings differing only in which
        lone surrogate they carry encode to identical bytes and digest the same.
        A collision in an identity mechanism is the one failure it cannot have.
        The explicit check is what prevents it, and it runs first so the error
        names the field; the strict encoder is a backstop that would raise if a
        value ever reached it another way. Because the check comes first, the
        encoder cannot be exercised independently -- it is defence in depth, not
        a separately tested control.
#>

Set-StrictMode -Version 3.0

function ConvertTo-CanonicalJson {
    <#
    .SYNOPSIS
        Returns the canonical JSON text for a document.

    .OUTPUTS
        A string. Get-CanonicalJsonBytes encodes it; the two are separate so a
        test can read what was serialized without decoding bytes.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)] [AllowNull()] $Node)

    $builder = [System.Text.StringBuilder]::new()
    WriteCanonicalNode -Node $Node -Builder $builder -Location 'document' -Depth 0
    $builder.ToString()
}

function Get-CanonicalJsonDigest {
    <#
    .SYNOPSIS
        Returns the SHA-256 of a document's canonical form, lowercase hex.

    .DESCRIPTION
        The encoding is part of the canonical form, so it is applied here rather
        than left to a caller. A byte-order mark would change the digest while
        changing nothing about the document, and PowerShell's default file
        encodings have differed by platform and release.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)] [AllowNull()] $Node)

    # Strict: throwOnInvalidBytes, so an unpaired surrogate that somehow reached
    # this point raises rather than being silently replaced with U+FFFD. The
    # serializer refuses them first with a message naming the field; this is the
    # backstop that makes a silent collision impossible rather than unlikely.
    $encoding = [System.Text.UTF8Encoding]::new($false, $true)
    $bytes = $encoding.GetBytes((ConvertTo-CanonicalJson -Node $Node))
    $sha256 = [System.Security.Cryptography.SHA256]::Create()
    try { [System.BitConverter]::ToString($sha256.ComputeHash($bytes)).Replace('-', '').ToLowerInvariant() }
    finally { $sha256.Dispose() }
}

function WriteCanonicalNode {
    param(
        [AllowNull()] $Node,
        [System.Text.StringBuilder] $Builder,
        [string] $Location,
        [int] $Depth
    )

    if ($Depth -gt 32) { throw "Canonical document nests deeper than expected at $Location." }

    if ($null -eq $Node) {
        # Never encoded. An omitted field and a field explicitly set to null
        # would otherwise be two spellings of the same absence, digesting
        # differently.
        throw "Canonical form has no null: omit the value instead -- $Location."
    }

    if ($Node -is [string])  { WriteCanonicalString -Value $Node -Builder $Builder -Location $Location; return }
    if ($Node -is [bool])    { $null = $Builder.Append($(if ($Node) { 'true' } else { 'false' })); return }

    if ($Node -is [double] -or $Node -is [single] -or $Node -is [decimal]) {
        throw "Canonical form refuses floating point at $Location. Two runtimes may print the same value differently."
    }

    if ($Node -is [byte] -or $Node -is [int16] -or $Node -is [int32] -or $Node -is [int64] -or
        $Node -is [uint16] -or $Node -is [uint32] -or $Node -is [uint64]) {
        $null = $Builder.Append($Node.ToString([System.Globalization.CultureInfo]::InvariantCulture))
        return
    }

    if ($Node -is [System.Collections.IDictionary]) {
        $null = $Builder.Append('{')
        $first = $true
        # StringComparer::Ordinal, not Sort-Object -CaseSensitive. The latter is
        # a culture-aware case-sensitive sort: it orders 'a' before 'B', while
        # ordinal orders 'B' first because 0x42 precedes 0x61. Culture-aware
        # ordering can differ between locales, which is precisely what a
        # canonical form must not depend on.
        $keys = [string[]] @($Node.Keys)
        [System.Array]::Sort($keys, [System.StringComparer]::Ordinal)
        foreach ($key in $keys) {
            if (-not $first) { $null = $Builder.Append(',') }
            $first = $false
            WriteCanonicalString -Value ([string]$key) -Builder $Builder -Location "$Location key"
            $null = $Builder.Append(':')
            WriteCanonicalNode -Node $Node[$key] -Builder $Builder -Location "$Location.$key" -Depth ($Depth + 1)
        }
        $null = $Builder.Append('}')
        return
    }

    if ($Node -is [System.Collections.IList]) {
        $null = $Builder.Append('[')
        for ($i = 0; $i -lt $Node.Count; $i++) {
            if ($i -gt 0) { $null = $Builder.Append(',') }
            # Order preserved: an array that carries a sequence must survive
            # serialization unchanged, and a caller wanting a set sorts first.
            WriteCanonicalNode -Node $Node[$i] -Builder $Builder -Location "$Location[$i]" -Depth ($Depth + 1)
        }
        $null = $Builder.Append(']')
        return
    }

    if ($Node -is [System.Management.Automation.PSCustomObject]) {
        $map = [ordered]@{}
        foreach ($property in $Node.PSObject.Properties) { $map[$property.Name] = $property.Value }
        WriteCanonicalNode -Node $map -Builder $Builder -Location $Location -Depth $Depth
        return
    }

    throw "Canonical form has no representation for $($Node.GetType().FullName) at $Location."
}

function WriteCanonicalString {
    param([string] $Value, [System.Text.StringBuilder] $Builder, [string] $Location)

    $null = $Builder.Append('"')
    $characters = $Value.ToCharArray()
    for ($i = 0; $i -lt $characters.Length; $i++) {
        $character = $characters[$i]

        # Surrogate pairs are checked before anything else. A lone surrogate is
        # not a character: the default encoder turns every one of them into the
        # same replacement, so two distinct values would produce one digest.
        if ([char]::IsHighSurrogate($character)) {
            if ($i + 1 -ge $characters.Length -or -not [char]::IsLowSurrogate($characters[$i + 1])) {
                throw "Canonical form refuses an unpaired high surrogate at $Location."
            }
            $null = $Builder.Append($character)
            $null = $Builder.Append($characters[$i + 1])
            $i++
            continue
        }
        if ([char]::IsLowSurrogate($character)) {
            throw "Canonical form refuses an unpaired low surrogate at $Location."
        }

        if ([char]::IsControl($character)) {
            # Refused rather than escaped. Escaping would work, but it would
            # introduce choices -- which escape form, and which case its hex
            # digits take -- and a canonical form cannot have choices. No recipe
            # field needs a control character.
            $code = '0x{0:X2}' -f [int] $character
            throw "Canonical form refuses control character $code at $Location."
        }
        switch ($character) {
            '"'     { $null = $Builder.Append('\"') }
            '\'     { $null = $Builder.Append('\\') }
            default { $null = $Builder.Append($character) }
        }
    }
    $null = $Builder.Append('"')
}

Export-ModuleMember -Function ConvertTo-CanonicalJson, Get-CanonicalJsonDigest
