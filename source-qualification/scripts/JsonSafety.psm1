#Requires -Version 7.0

<#
.SYNOPSIS
    The checks a JSON Schema pattern cannot portably make.

.DESCRIPTION
    JSON Schema draft-07 specifies ECMA-262 regular expressions. Under those
    semantics an unanchored-multiline `$` matches only at the end of input, so
    `^...$` already refuses a trailing newline -- but .NET, which is what
    validates schemas here, also matches `$` immediately before a trailing
    newline. A 64-character hex digest followed by a newline therefore satisfies
    a pattern that reads as though it could not.

    \A and \z fix that under .NET and break everywhere else: ECMA-262 does not
    define them, and a JavaScript engine reads `\Ax\z` as a literal A, an x, and
    a literal z. A schema written that way validates here and demands nonsense
    from every other validator, which is worse than the gap it closes because it
    fails silently and in the permissive direction.

    So the patterns stay ECMA-portable and the gap is closed semantically, here,
    for every document this repository validates.
#>

Set-StrictMode -Version 3.0

function Assert-NoControlCharacter {
    <#
    .SYNOPSIS
        Refuses a control character anywhere in a document's string values.

    .DESCRIPTION
        Descent is bounded by type rather than by probing for properties:
        probing whether a node has properties descends into primitives whose own
        properties are of the same type, which recurses without end. Depth is
        bounded as well, so a hostile document cannot exhaust the stack.

    .PARAMETER Location
        Where the value sits, used to name the offending field rather than
        reporting only that something somewhere was wrong.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [AllowNull()] $Node,
        [Parameter()] [string] $Location = 'document',
        [Parameter()] [string] $Subject = 'Document',
        [Parameter()] [int] $Depth = 0
    )

    if ($Depth -gt 32) { throw "$Subject nests deeper than expected at $Location." }
    if ($null -eq $Node) { return }

    if ($Node -is [string]) {
        foreach ($character in $Node.ToCharArray()) {
            if ([char]::IsControl($character)) {
                $code = '0x{0:X2}' -f [int] $character
                throw "$Subject value at $Location contains control character $code."
            }
        }
        return
    }

    if ($Node -is [System.Collections.IDictionary]) {
        foreach ($key in $Node.Keys) {
            Assert-NoControlCharacter -Node $Node[$key] -Location "$Location.$key" -Subject $Subject -Depth ($Depth + 1)
        }
        return
    }

    if ($Node -is [System.Collections.IList]) {
        for ($i = 0; $i -lt $Node.Count; $i++) {
            Assert-NoControlCharacter -Node $Node[$i] -Location "$Location[$i]" -Subject $Subject -Depth ($Depth + 1)
        }
        return
    }

    if ($Node -is [System.Management.Automation.PSCustomObject]) {
        foreach ($property in $Node.PSObject.Properties) {
            Assert-NoControlCharacter -Node $property.Value -Location "$Location.$($property.Name)" -Subject $Subject -Depth ($Depth + 1)
        }
    }

    # Numbers and booleans carry no text.
}

Export-ModuleMember -Function Assert-NoControlCharacter
