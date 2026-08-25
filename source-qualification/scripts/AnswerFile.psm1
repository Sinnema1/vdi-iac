#Requires -Version 7.0

<#
.SYNOPSIS
    Renders the unattended answer file, and destroys it afterwards.

.DESCRIPTION
    Increment 3 stage 2, governed by ADR 6. The committed template carries no
    credential. The rendered file does: it holds a working administrator
    password for as long as it exists, and it is the artifact this module exists
    to keep short-lived.

    What this module guarantees:

    The secret never becomes a managed string. A .NET string cannot be zeroed on
    demand and lives until collection, so the value is marshalled from a
    SecureString into a char buffer, XML-escaped and encoded a run at a time
    straight into the output stream, and every buffer cleared in a finally
    block. Conversion and writing happen inside one function so no buffer
    crosses a pipeline boundary, where PowerShell may copy it somewhere this
    module cannot clear.

    The rendered file is never read back. Verifying substitution by rereading
    the finished file would construct exactly the string the rest of this design
    avoids, so the check runs before any secret is inserted: after non-secret
    substitution, the only placeholders still standing must be the declared
    secret ones, and each is consumed as it is written.

    The rendered file is removed on every exit path, and a failed removal is
    terminal. A run that did its work and left a live credential on disk has not
    succeeded. When the work also failed, the original failure is preserved and
    the cleanup outcome recorded alongside it.

    The temporary root is owned by this module. Callers do not choose where a
    rendered credential is written, so it cannot land in the repository or
    behind a redirected path.

    What this module does NOT guarantee:

    The scriptblock is a trusted component. It is handed the path to a readable
    file containing a working credential, because a Packer build needs to give
    that file to setup. Any code inside it can read, copy, or transmit the
    contents, and nothing here can prevent that. This module's boundary is that
    *it* does not return, log, or otherwise surface the value; what a caller
    does with the file it asked for is the caller's responsibility, and the
    scriptblock should be treated as part of the trusted build path.
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

    # uniqueItems compares whole objects, so ADMINISTRATOR_PASSWORD declared
    # twice with different flags satisfies the schema. The duplicate is the
    # bypass: the non-secret copy would take a caller-supplied plain value and
    # substitute it into the same position.
    $duplicates = @($declared | Group-Object | Where-Object Count -GT 1 | ForEach-Object { $_.Name })
    if ($duplicates) {
        throw (NewAnswerFileError -Code 'placeholder_duplicated' `
                -Message "The declaration names a placeholder more than once: $($duplicates -join ', ').")
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

    # Every plain-text credential position must name a placeholder declared
    # exactly once and marked secret. A position filled by a non-secret
    # placeholder would be substituted from ordinary values and never take the
    # protected write path.
    $secretNames = @($Declaration.placeholders | Where-Object { $_.secret } | ForEach-Object { $_.name })

    # <PlainText>true</PlainText> beside a value that is not a placeholder is the
    # shape a committed rendered file takes.
    #
    # [^<]* rather than a lazy any-character match. With (?s) a lazy match
    # starting at one element runs on until it finds the next PlainText element
    # anywhere in the file, so an unrelated <Value> pairs with a distant
    # <PlainText> and the captured text spans everything between them.
    foreach ($match in [regex]::Matches($Template, '<Value>(?<value>[^<]*)</Value>\s*<PlainText>true</PlainText>')) {
        $value = $match.Groups['value'].Value.Trim()
        $token = [regex]::Match($value, "\A$($script:PlaceholderPattern)\z")
        if (-not $token.Success) {
            throw (NewAnswerFileError -Code 'template_carries_credential' `
                    -Message 'A plain-text value in the template is not a placeholder. The committed template must never carry a credential.')
        }

        $name = $token.Groups['name'].Value
        $timesDeclared = @($Declaration.placeholders | Where-Object { $_.name -eq $name }).Count
        if ($name -notin $secretNames -or $timesDeclared -ne 1) {
            throw (NewAnswerFileError -Code 'credential_position_unprotected' `
                    -Message "The plain-text position {{$name}} must name a placeholder declared exactly once and marked secret; it is declared $timesDeclared time(s).")
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

# Windows Setup names the architecture differently from the canonical value the
# media reference carries. Mapped here rather than at a call site, so the two
# spellings cannot drift apart.
$script:SetupArchitecture = @{ 'x64' = 'amd64'; 'arm64' = 'arm64' }

function Get-AnswerFileValueSet {
    <#
    .SYNOPSIS
        Derives every non-secret placeholder value from the validated declaration.

    .DESCRIPTION
        Callers do not supply these. The declaration's image selection has
        already been checked against the qualified media, so deriving from it is
        what makes the rendered file agree with what was qualified; a
        caller-supplied index or language could disagree with both and nothing
        downstream would notice.

        A declared non-secret placeholder with no derivation here is an error
        rather than a blank. Adding one is a deliberate change with a test.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param([Parameter(Mandatory)] $Declaration)

    $selection = $Declaration.imageSelection
    $architecture = $script:SetupArchitecture[$selection.architecture]
    if (-not $architecture) {
        throw (NewAnswerFileError -Code 'architecture_unmapped' `
                -Message "No Windows Setup architecture token is mapped for '$($selection.architecture)'.")
    }

    @{
        IMAGE_INDEX            = [string]$selection.index
        UI_LANGUAGE            = $selection.language
        PROCESSOR_ARCHITECTURE = $architecture
    }
}

function NewOwnedWorkRoot {
    <#
        A directory this module creates, names, and removes. Callers do not
        choose where a rendered credential is written: a caller-supplied path
        could place it inside the repository, on a shared volume, or behind a
        redirection that sends it somewhere else entirely.

        Created fresh under a GUID, so it cannot be a pre-existing redirection;
        the check below catches the case where something replaced it between
        creation and use.
    #>
    $root = Join-Path ([System.IO.Path]::GetTempPath()) ('vdi-iac-answerfile-' + [guid]::NewGuid().ToString('n'))
    $null = New-Item -ItemType Directory -Path $root -Force

    $item = Get-Item -LiteralPath $root -Force
    $isReparsePoint = ($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -eq [System.IO.FileAttributes]::ReparsePoint
    if ($item.LinkTarget -or $isReparsePoint) {
        Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
        throw (NewAnswerFileError -Code 'work_root_redirected' `
                -Message 'The rendering directory is a reparse point. Refusing to write a credential through a redirected path.')
    }

    RestrictPath -Path $root -Directory
    $root
}

function RestrictPath {
    <#
        Owner-only access. Applied to the directory before the file exists and
        to the file before any content reaches it: writing first and restricting
        afterwards leaves a window in which the rendered credential is readable
        by anything else on the machine.
    #>
    param([string] $Path, [switch] $Directory)

    if ($IsWindows) {
        # Inheritance removed, then a single entry for the identity running the
        # build. An inherited ACL is how a restricted parent still yields a
        # world-readable file.
        $acl = Get-Acl -LiteralPath $Path
        $acl.SetAccessRuleProtection($true, $false)
        foreach ($rule in @($acl.Access)) { $null = $acl.RemoveAccessRule($rule) }
        $identity = [System.Security.Principal.WindowsIdentity]::GetCurrent().User
        $inheritance = if ($Directory) { 'ContainerInherit, ObjectInherit' } else { 'None' }
        $acl.AddAccessRule([System.Security.AccessControl.FileSystemAccessRule]::new(
                $identity, 'FullControl', $inheritance, 'None', 'Allow'))
        Set-Acl -LiteralPath $Path -AclObject $acl
    }
    else {
        $mode = if ($Directory) {
            [System.IO.UnixFileMode]::UserRead -bor [System.IO.UnixFileMode]::UserWrite -bor [System.IO.UnixFileMode]::UserExecute
        }
        else {
            [System.IO.UnixFileMode]::UserRead -bor [System.IO.UnixFileMode]::UserWrite
        }
        [System.IO.File]::SetUnixFileMode($Path, $mode)
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

        Non-secret values are derived from the declaration, not accepted from
        the caller. Only the secrets are supplied, and only as SecureStrings.

        The scriptblock receives the path. It is a trusted component: the file it
        is given is readable and holds a working credential, and nothing here
        constrains what the scriptblock does with it.

    .PARAMETER Secrets
        SecureString values, by placeholder name.

    .OUTPUTS
        Whatever the scriptblock returns.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)] $Declaration,
        [Parameter(Mandatory)] [hashtable] $Secrets,
        [Parameter(Mandatory)] [scriptblock] $ScriptBlock
    )

    $values = Get-AnswerFileValueSet -Declaration $Declaration

    foreach ($placeholder in $Declaration.placeholders) {
        if ($placeholder.secret) {
            if (-not $Secrets.ContainsKey($placeholder.name)) {
                throw (NewAnswerFileError -Code 'value_missing' -Message "No value supplied for placeholder $($placeholder.name).")
            }
            if ($Secrets[$placeholder.name] -isnot [securestring]) {
                throw (NewAnswerFileError -Code 'secret_not_protected' `
                        -Message "The value for $($placeholder.name) is declared secret and must be supplied as a SecureString.")
            }
        }
        elseif (-not $values.ContainsKey($placeholder.name)) {
            throw (NewAnswerFileError -Code 'value_underivable' `
                    -Message "No value is derived for placeholder $($placeholder.name). Non-secret values come from the declaration, never from the caller.")
        }
    }

    $template = Get-Content -LiteralPath $Declaration.templatePath -Raw -Encoding utf8

    # Non-secret substitution happens in managed memory, which is fine: none of
    # these values is sensitive, and it is what leaves the secret tokens as the
    # only ones standing.
    foreach ($placeholder in @($Declaration.placeholders | Where-Object { -not $_.secret })) {
        $template = $template.Replace('{{' + $placeholder.name + '}}', [string]$values[$placeholder.name])
    }

    $secretPlaceholders = @($Declaration.placeholders | Where-Object { $_.secret })
    $secretNames = @($secretPlaceholders | ForEach-Object { $_.name })

    # Checked here, before a single secret byte is written, and never by reading
    # the finished file back: rereading it would build the managed string this
    # whole design exists to avoid. Anything still standing must be a declared
    # secret, and each of those is consumed as it is written.
    $standing = @([regex]::Matches($template, $script:PlaceholderPattern) |
        ForEach-Object { $_.Groups['name'].Value } | Sort-Object -Unique)
    $unsubstituted = @($standing | Where-Object { $_ -notin $secretNames })
    if ($unsubstituted) {
        throw (NewAnswerFileError -Code 'placeholder_unsubstituted' `
                -Message "The answer file would still hold unsubstituted placeholder(s): $($unsubstituted -join ', ').")
    }

    if (-not $PSCmdlet.ShouldProcess('the unattended answer file', 'Render')) { return }

    $workRoot = NewOwnedWorkRoot
    $renderedPath = Join-Path $workRoot 'autounattend.xml'
    $failure = $null
    $result = $null
    $cleanup = 'not-attempted'

    try {
        NewRestrictedFile -Path $renderedPath
        WriteRenderedAnswerFile -Template $template -Path $renderedPath `
            -SecretNames $secretNames -Secrets $Secrets
        $result = & $ScriptBlock $renderedPath
    }
    catch {
        $failure = $_
    }
    finally {
        # -WhatIf:$false deliberately. Removal of a rendered credential is not
        # subject to the caller's preview mode: if the file exists, it goes.
        $cleanup = Remove-RenderedAnswerFile -Path $renderedPath -WhatIf:$false -Confirm:$false
        Remove-Item -LiteralPath $workRoot -Recurse -Force -ErrorAction SilentlyContinue
    }

    if ($failure) {
        # The original failure is what the caller needs; the cleanup outcome is
        # recorded beside it rather than replacing it.
        $failure.Exception.Data['CleanupOutcome'] = $cleanup
        if ($cleanup -eq 'failed') {
            Write-Warning "The rendered answer file could not be removed: $renderedPath"
        }
        throw $failure
    }

    if ($cleanup -eq 'failed') {
        # Terminal. Work that succeeded while leaving a live credential on disk
        # has not succeeded, and returning the result would say it had.
        throw (NewAnswerFileError -Code 'rendered_file_retained' `
                -Message 'The rendered answer file could not be removed. A credential remains on disk, so this run is not successful.')
    }

    $result
}

function NewRestrictedFile {
    param([string] $Path)

    $stream = [System.IO.File]::Open($Path, [System.IO.FileMode]::CreateNew,
        [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)
    $stream.Dispose()
    RestrictPath -Path $Path
}

function WriteRenderedAnswerFile {
    <#
        Writes the file as bytes. Conversion, XML escaping, and writing all
        happen here: handing a byte buffer back through the pipeline would let
        PowerShell copy it somewhere this module cannot clear, so the
        SecureString is opened and closed inside this one scope.
    #>
    param(
        [string] $Template, [string] $Path,
        [string[]] $SecretNames, [hashtable] $Secrets
    )

    $encoding = [System.Text.UTF8Encoding]::new($false)
    $stream = [System.IO.File]::Open($Path, [System.IO.FileMode]::Open,
        [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)
    try {
        $tokens = @($SecretNames | ForEach-Object { [regex]::Escape('{{' + $_ + '}}') })
        foreach ($piece in [regex]::Split($Template, '(' + ($tokens -join '|') + ')')) {
            if (-not $piece) { continue }
            $match = [regex]::Match($piece, "\A$($script:PlaceholderPattern)\z")
            if ($match.Success -and $match.Groups['name'].Value -in $SecretNames) {
                WriteEscapedSecret -Secure $Secrets[$match.Groups['name'].Value] -Stream $stream -Encoding $encoding
            }
            else {
                $bytes = $encoding.GetBytes($piece)
                $stream.Write($bytes, 0, $bytes.Length)
            }
        }
    }
    finally { $stream.Dispose() }
}

function WriteEscapedSecret {
    <#
        XML-escapes and writes the secret without ever building a managed string
        from it.

        A password containing & or < would otherwise produce a document that is
        either malformed or parses to a different value than the one set on the
        account -- and the failure would appear as a login that does not work,
        far from its cause.

        Escaped characters are all non-surrogate, so encoding the runs between
        them cannot split a surrogate pair.
    #>
    param([securestring] $Secure, [System.IO.Stream] $Stream, $Encoding)

    $entities = @{
        ([char]'&') = '&amp;'; ([char]'<') = '&lt;'; ([char]'>') = '&gt;'
        ([char]'"') = '&quot;'; ([char]"'") = '&apos;'
    }

    $pointer = [System.IntPtr]::Zero
    $chars = $null
    try {
        $pointer = [System.Runtime.InteropServices.Marshal]::SecureStringToGlobalAllocUnicode($Secure)
        $chars = [char[]]::new($Secure.Length)
        [System.Runtime.InteropServices.Marshal]::Copy($pointer, $chars, 0, $chars.Length)

        $runStart = 0
        for ($i = 0; $i -lt $chars.Length; $i++) {
            $entity = $entities[$chars[$i]]
            if (-not $entity) { continue }
            WriteCharRun -Chars $chars -Start $runStart -Count ($i - $runStart) -Stream $Stream -Encoding $Encoding
            $entityBytes = $Encoding.GetBytes($entity)
            $Stream.Write($entityBytes, 0, $entityBytes.Length)
            $runStart = $i + 1
        }
        WriteCharRun -Chars $chars -Start $runStart -Count ($chars.Length - $runStart) -Stream $Stream -Encoding $Encoding
    }
    finally {
        if ($chars) { [array]::Clear($chars, 0, $chars.Length) }
        if ($pointer -ne [System.IntPtr]::Zero) {
            [System.Runtime.InteropServices.Marshal]::ZeroFreeGlobalAllocUnicode($pointer)
        }
    }
}

function WriteCharRun {
    param([char[]] $Chars, [int] $Start, [int] $Count, [System.IO.Stream] $Stream, $Encoding)

    if ($Count -le 0) { return }
    $bytes = $Encoding.GetBytes($Chars, $Start, $Count)
    try { $Stream.Write($bytes, 0, $bytes.Length) }
    finally { [array]::Clear($bytes, 0, $bytes.Length) }
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
    # Setup caches a copy here before %WINDIR%\Panther exists, and it survives
    # if installation is interrupted. Listed first because it is the one most
    # easily forgotten.
    '$Windows.~BT/Sources/Panther/unattend.xml'
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
    Get-AnswerFileValueSet, Invoke-WithRenderedAnswerFile, Remove-RenderedAnswerFile,
    Get-SetupResidue, Remove-SetupResidue
