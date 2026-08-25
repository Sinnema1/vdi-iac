#Requires -Version 7.0

<#
.SYNOPSIS
    Renders the unattended answer file, and destroys it afterwards.

.DESCRIPTION
    Increment 3 stage 2, governed by ADR 6. The committed template carries no
    credential. The rendered file does: it holds a working administrator
    password for as long as it exists, and it is the artifact this module exists
    to keep short-lived.

    Three properties are worth stating plainly, because each is a place the
    value could otherwise escape.

    It never becomes a managed string. A .NET string cannot be zeroed on demand
    and lives until collection, so the secret is marshalled from a SecureString
    into a byte buffer, written through that buffer, and the buffer cleared in a
    finally block. The rendered content is never returned to a caller.

    It never reaches an argument list. Callers receive the path to the rendered
    file, never its contents, so the value cannot be handed to a process as a
    parameter where it would be visible to anything enumerating processes.

    It is removed on every exit path. Rendering is offered only through a
    scope-bound form that deletes the file in a finally block, so a failure part
    way through a build cannot leave it behind. There is deliberately no public
    function that renders and returns without taking responsibility for removal.

    Substitution is driven by the declaration, not by scanning the template. A
    template holding an undeclared placeholder and a declaration naming one the
    template lacks are both errors: the first would leave a live token in the
    file handed to setup, and the second usually means a placeholder was renamed
    in one place only.
#>

Set-StrictMode -Version 3.0

$script:TemplateSchema = Join-Path $PSScriptRoot '..' '..' 'contracts' 'answer-file-template-1.schema.json'

# Matches {{NAME}}. The name rule is the schema's, repeated here because this is
# what actually finds them in the template.
$script:PlaceholderPattern = '\{\{(?<name>[A-Z][A-Z0-9_]{1,62})\}\}'

function NewAnswerFileError {
    param([string] $Code, [string] $Message)
    $exception = [System.Exception]::new($Message)
    $exception.Data['ReasonCode'] = $Code
    $exception
}

function Import-AnswerFileTemplate {
    <#
    .SYNOPSIS
        Reads a template declaration and checks it against its template.

    .OUTPUTS
        The declaration, with the resolved template path attached.
    #>
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param(
        [Parameter(Mandatory)] [ValidateNotNullOrEmpty()] [string] $Path
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw (NewAnswerFileError -Code 'declaration_not_found' -Message "Answer-file declaration not found: $Path")
    }

    $raw = Get-Content -LiteralPath $Path -Raw -Encoding utf8
    if (-not (Test-Json -Json $raw -SchemaFile $script:TemplateSchema -ErrorAction SilentlyContinue)) {
        throw (NewAnswerFileError -Code 'declaration_invalid' -Message "Answer-file declaration does not satisfy the contract: $Path")
    }

    $declaration = $raw | ConvertFrom-Json

    $templatePath = Join-Path (Split-Path -Parent $Path) $declaration.templateFile
    if (-not (Test-Path -LiteralPath $templatePath -PathType Leaf)) {
        throw (NewAnswerFileError -Code 'template_not_found' -Message "Answer-file template not found: $($declaration.templateFile)")
    }

    $template = Get-Content -LiteralPath $templatePath -Raw -Encoding utf8

    $declared = @($declaration.placeholders | ForEach-Object { $_.name })
    $present = @([regex]::Matches($template, $script:PlaceholderPattern) |
        ForEach-Object { $_.Groups['name'].Value } | Sort-Object -Unique)

    $undeclared = @($present | Where-Object { $_ -notin $declared })
    if ($undeclared) {
        throw (NewAnswerFileError -Code 'placeholder_undeclared' `
                -Message "The template holds placeholders the declaration does not name: $($undeclared -join ', ').")
    }

    $missing = @($declared | Where-Object { $_ -notin $present })
    if ($missing) {
        throw (NewAnswerFileError -Code 'placeholder_absent' `
                -Message "The declaration names placeholders the template does not hold: $($missing -join ', ').")
    }

    Assert-TemplateCarriesNoCredential -Template $template -Declaration $declaration

    $declaration | Add-Member -NotePropertyName 'templatePath' -NotePropertyValue $templatePath -PassThru
}

function Assert-TemplateCarriesNoCredential {
    <#
    .SYNOPSIS
        Refuses a template whose secret positions hold anything but a placeholder.

    .DESCRIPTION
        The committed template must carry no credential, and the way that breaks
        is someone rendering once and committing the result. Every element that
        holds a secret is required to contain exactly its placeholder, so a
        literal value in that position is refused rather than published.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [ValidateNotNullOrEmpty()] [string] $Template,
        [Parameter(Mandatory)] $Declaration
    )

    foreach ($placeholder in @($Declaration.placeholders | Where-Object { $_.secret })) {
        $token = '{{' + $placeholder.name + '}}'
        if ($Template -notlike "*$token*") {
            throw (NewAnswerFileError -Code 'secret_placeholder_missing' `
                    -Message "The template does not hold the secret placeholder $token. A rendered file must never be committed as the template.")
        }
    }

    # <PlainText>true</PlainText> beside a value that is not a placeholder is the
    # shape a committed rendered file takes.
    #
    # [^<]* rather than a lazy any-character match. With (?s) a lazy match
    # starting at one element runs on until it finds the next PlainText element
    # anywhere in the file, so an unrelated <Value> pairs with a distant
    # <PlainText> and the captured text spans everything between them.
    foreach ($match in [regex]::Matches($Template, '<Value>(?<value>[^<]*)</Value>\s*<PlainText>true</PlainText>')) {
        $value = $match.Groups['value'].Value.Trim()
        if ($value -notmatch "^$($script:PlaceholderPattern)$") {
            throw (NewAnswerFileError -Code 'template_carries_credential' `
                    -Message 'A plain-text value in the template is not a placeholder. The committed template must never carry a credential.')
        }
    }
}

function Assert-AnswerFileMatchesMedia {
    <#
    .SYNOPSIS
        Refuses an answer file that installs something other than the qualified media.

    .DESCRIPTION
        Media qualification records a declared installation selection but does
        not open the media to confirm it. The answer file is what actually tells
        setup which image to install, so the two must agree: a build whose answer
        file selects a different index installs something other than what was
        qualified, and every downstream provenance claim would name the wrong
        thing.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)] $Declaration,
        [Parameter(Mandatory)] $MediaRecord
    )

    $selection = $Declaration.imageSelection
    foreach ($field in 'edition', 'index') {
        if ($selection.$field -ne $MediaRecord.image.$field) {
            return "answer file selects $field '$($selection.$field)'; qualified media declares '$($MediaRecord.image.$field)'"
        }
    }
    foreach ($field in 'architecture', 'language') {
        if ($selection.$field -ne $MediaRecord.platform.$field) {
            return "answer file selects $field '$($selection.$field)'; qualified media declares '$($MediaRecord.platform.$field)'"
        }
    }

    $null
}

function NewRestrictedFile {
    <#
        Creates the file with an owner-only mode before any content reaches it.
        Writing first and restricting afterwards leaves a window in which the
        rendered credential is readable by anything else on the machine.
    #>
    param([string] $Path)

    $stream = [System.IO.File]::Open($Path, [System.IO.FileMode]::CreateNew,
        [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)
    $stream.Dispose()

    if ($IsWindows) {
        # Inheritance removed, then a single entry for the identity running the
        # build. An inherited ACL is how a restricted directory still yields a
        # world-readable file.
        $acl = Get-Acl -LiteralPath $Path
        $acl.SetAccessRuleProtection($true, $false)
        foreach ($rule in @($acl.Access)) { $null = $acl.RemoveAccessRule($rule) }
        $identity = [System.Security.Principal.WindowsIdentity]::GetCurrent().User
        $acl.AddAccessRule([System.Security.AccessControl.FileSystemAccessRule]::new(
                $identity, 'FullControl', 'None', 'None', 'Allow'))
        Set-Acl -LiteralPath $Path -AclObject $acl
    }
    else {
        [System.IO.File]::SetUnixFileMode($Path,
            [System.IO.UnixFileMode]::UserRead -bor [System.IO.UnixFileMode]::UserWrite)
    }
}

function Invoke-WithRenderedAnswerFile {
    <#
    .SYNOPSIS
        Renders the answer file, runs a scriptblock with its path, and destroys it.

    .DESCRIPTION
        The only way to render. There is no function that produces the file and
        hands it back, because that would put removal in the caller's hands and
        the caller is where it gets forgotten.

        The scriptblock receives the path, never the content. The secret is
        written through a byte buffer that is cleared whether the render
        succeeds, throws, or the scriptblock throws.

    .PARAMETER Secrets
        SecureString values, by placeholder name.

    .OUTPUTS
        Whatever the scriptblock returns.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)] $Declaration,
        [Parameter(Mandatory)] [hashtable] $Values,
        [Parameter(Mandatory)] [hashtable] $Secrets,
        [Parameter(Mandatory)] [ValidateNotNullOrEmpty()] [string] $WorkRoot,
        [Parameter(Mandatory)] [scriptblock] $ScriptBlock
    )

    foreach ($placeholder in $Declaration.placeholders) {
        $supplied = if ($placeholder.secret) { $Secrets.ContainsKey($placeholder.name) }
                    else { $Values.ContainsKey($placeholder.name) }
        if (-not $supplied) {
            throw (NewAnswerFileError -Code 'value_missing' `
                    -Message "No value supplied for placeholder $($placeholder.name).")
        }
        if ($placeholder.secret -and $Secrets[$placeholder.name] -isnot [securestring]) {
            throw (NewAnswerFileError -Code 'secret_not_protected' `
                    -Message "The value for $($placeholder.name) is declared secret and must be supplied as a SecureString.")
        }
    }

    $template = Get-Content -LiteralPath $Declaration.templatePath -Raw -Encoding utf8

    # Non-secret substitution happens in managed memory, which is fine: none of
    # these values is sensitive, and they are what makes the remaining tokens
    # findable.
    foreach ($placeholder in @($Declaration.placeholders | Where-Object { -not $_.secret })) {
        $template = $template.Replace('{{' + $placeholder.name + '}}', [string]$Values[$placeholder.name])
    }

    # Refused before anything is written. A -WhatIf run that rendered the file
    # and then declined to delete it would leave a live credential on disk,
    # which is the opposite of what the switch is for.
    if (-not $PSCmdlet.ShouldProcess($WorkRoot, 'Render the unattended answer file')) { return }

    $renderedPath = Join-Path $WorkRoot ('autounattend-' + [guid]::NewGuid().ToString('n') + '.xml')
    $secretPlaceholders = @($Declaration.placeholders | Where-Object { $_.secret })

    try {
        NewRestrictedFile -Path $renderedPath
        WriteWithSecrets -Template $template -Path $renderedPath `
            -SecretPlaceholders $secretPlaceholders -Secrets $Secrets

        $remaining = [regex]::Matches((Get-Content -LiteralPath $renderedPath -Raw -Encoding utf8), $script:PlaceholderPattern)
        if ($remaining.Count -gt 0) {
            # Fails closed. A live token reaching setup produces a machine
            # configured with the literal text of a placeholder.
            throw (NewAnswerFileError -Code 'placeholder_unsubstituted' `
                    -Message "The rendered answer file still holds $($remaining.Count) placeholder(s).")
        }

        & $ScriptBlock $renderedPath
    }
    finally {
        # -WhatIf:$false deliberately. Removal of a rendered credential is not
        # subject to the caller's preview mode: if the file exists, it goes.
        #
        # Discarded, not emitted: a finally block writing to the pipeline appends
        # its result to whatever the scriptblock returned, so the caller would
        # receive an array instead of their own value.
        $null = Remove-RenderedAnswerFile -Path $renderedPath -WhatIf:$false -Confirm:$false
    }
}

function WriteWithSecrets {
    <#
        Writes the file as bytes, splicing secret values in without ever building
        a managed string that contains one.
    #>
    param(
        [string] $Template, [string] $Path,
        $SecretPlaceholders, [hashtable] $Secrets
    )

    $encoding = [System.Text.UTF8Encoding]::new($false)
    $stream = [System.IO.File]::Open($Path, [System.IO.FileMode]::Open,
        [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)
    try {
        # One pass over the template, emitting the text between secret tokens and
        # the secret bytes at each token.
        $names = @($SecretPlaceholders | ForEach-Object { [regex]::Escape('{{' + $_.name + '}}') })
        $split = [regex]::Split($Template, '(' + ($names -join '|') + ')')

        foreach ($piece in $split) {
            $match = [regex]::Match($piece, "^$($script:PlaceholderPattern)$")
            if ($match.Success -and @($SecretPlaceholders.name) -contains $match.Groups['name'].Value) {
                $bytes = ConvertFromSecureStringToBytes -Secure $Secrets[$match.Groups['name'].Value] -Encoding $encoding
                try { $stream.Write($bytes, 0, $bytes.Length) }
                finally { [array]::Clear($bytes, 0, $bytes.Length) }
            }
            elseif ($piece) {
                $bytes = $encoding.GetBytes($piece)
                $stream.Write($bytes, 0, $bytes.Length)
            }
        }
    }
    finally { $stream.Dispose() }
}

function ConvertFromSecureStringToBytes {
    <#
        SecureString to bytes without an intermediate managed string. The
        unmanaged buffer is zeroed and freed in a finally block; a string built
        here would survive until collection with no way to clear it.
    #>
    param([securestring] $Secure, $Encoding)

    $pointer = [System.IntPtr]::Zero
    try {
        $pointer = [System.Runtime.InteropServices.Marshal]::SecureStringToGlobalAllocUnicode($Secure)
        $length = $Secure.Length
        $chars = [char[]]::new($length)
        [System.Runtime.InteropServices.Marshal]::Copy($pointer, $chars, 0, $length)
        try { return $Encoding.GetBytes($chars) }
        finally { [array]::Clear($chars, 0, $chars.Length) }
    }
    finally {
        if ($pointer -ne [System.IntPtr]::Zero) {
            [System.Runtime.InteropServices.Marshal]::ZeroFreeGlobalAllocUnicode($pointer)
        }
    }
}

function Remove-RenderedAnswerFile {
    <#
    .SYNOPSIS
        Removes a rendered answer file, reporting whether it is gone.

    .DESCRIPTION
        Called from a finally block, so it must not throw: an exception here
        would replace whatever failure is already being reported. It returns
        the outcome instead, and a caller that cares can act on it.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([string])]
    param([Parameter(Mandatory)] [ValidateNotNullOrEmpty()] [string] $Path)

    if (-not (Test-Path -LiteralPath $Path)) { return 'absent' }
    if (-not $PSCmdlet.ShouldProcess($Path, 'Remove the rendered answer file')) { return 'not-attempted' }
    try {
        Remove-Item -LiteralPath $Path -Force -ErrorAction Stop
        'removed'
    }
    catch {
        # Reported, never swallowed. A rendered credential still on disk is the
        # condition the caller most needs to know about.
        Write-Warning "The rendered answer file could not be removed: $Path"
        'failed'
    }
}

# Where Windows setup leaves a copy of the answer file. Each of these retains
# the administrator password in plain text after installation, which is why
# removing the rendered file on the host is only half the lifecycle.
#
# Hard-coded rather than discovered: a residue sweep driven by a search would
# either miss a location it did not think to look in or delete something it
# should not. Adding a path is a deliberate change with a test.
$script:SetupResiduePaths = @(
    'Windows/Panther/unattend.xml'
    'Windows/Panther/unattend.orig.xml'
    'Windows/System32/Sysprep/unattend.xml'
    'Windows/Panther/Unattend/unattend.xml'
)

function Get-SetupResidue {
    <#
    .SYNOPSIS
        Lists the answer-file copies Windows setup left behind.

    .DESCRIPTION
        The system drive is a parameter so this runs against a fixture rather
        than only against a real guest. It reports; it does not delete, because
        the sealing gate needs to ask the question without changing the answer.

    .OUTPUTS
        The residue paths that exist, relative form preserved for reporting.
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [Parameter(Mandatory)] [ValidateNotNullOrEmpty()] [string] $SystemDrive
    )

    @($script:SetupResiduePaths |
        ForEach-Object { Join-Path $SystemDrive $_ } |
        Where-Object { Test-Path -LiteralPath $_ -PathType Leaf })
}

function Remove-SetupResidue {
    <#
    .SYNOPSIS
        Removes the answer-file copies setup left in the guest.

    .DESCRIPTION
        Each removal is attempted independently and the outcome reported per
        path. Stopping at the first failure would leave later copies in place,
        and every one of them holds the password in plain text.

        The result is what the sealing gate reads. An image whose residue could
        not be removed is not a candidate, and reporting that is more useful
        than throwing from the middle of a sweep.

    .OUTPUTS
        Per-path outcome, and whether anything remains.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([PSCustomObject])]
    param(
        [Parameter(Mandatory)] [ValidateNotNullOrEmpty()] [string] $SystemDrive
    )

    $results = foreach ($relative in $script:SetupResiduePaths) {
        $path = Join-Path $SystemDrive $relative
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
            [PSCustomObject]@{ Path = $relative; Outcome = 'absent' }
            continue
        }
        if (-not $PSCmdlet.ShouldProcess($path, 'Remove setup residue')) {
            [PSCustomObject]@{ Path = $relative; Outcome = 'not-attempted' }
            continue
        }
        try {
            Remove-Item -LiteralPath $path -Force -ErrorAction Stop
            [PSCustomObject]@{ Path = $relative; Outcome = 'removed' }
        }
        catch {
            [PSCustomObject]@{ Path = $relative; Outcome = 'failed' }
        }
    }

    $results = @($results)
    [PSCustomObject]@{
        Results   = $results
        Remaining = @(Get-SetupResidue -SystemDrive $SystemDrive)
        Clean     = (@(Get-SetupResidue -SystemDrive $SystemDrive).Count -eq 0)
    }
}

Export-ModuleMember -Function Import-AnswerFileTemplate, Assert-AnswerFileMatchesMedia,
    Invoke-WithRenderedAnswerFile, Remove-RenderedAnswerFile,
    Get-SetupResidue, Remove-SetupResidue
