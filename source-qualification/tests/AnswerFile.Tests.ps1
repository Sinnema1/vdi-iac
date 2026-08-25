#Requires -Version 7.0

BeforeAll {
    $script:RepoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    Import-Module (Join-Path $script:RepoRoot 'source-qualification' 'scripts' 'AnswerFile.psm1') -Force

    $script:Committed = Join-Path $script:RepoRoot 'packer' 'unattended' 'autounattend.template.json'

    # A distinctive value, so a leak into any string is unmistakable rather than
    # something a substring check might miss.
    $script:SecretText = 'Zq7-CanaryPassword-3nR'

    function NewTempDir {
        $d = Join-Path ([System.IO.Path]::GetTempPath()) ([guid]::NewGuid().ToString())
        $null = New-Item -ItemType Directory -Path $d -Force
        $d
    }

    function AsSecure {
        # Appended character by character rather than converted from plaintext.
        # The analyzer flags -AsPlainText wherever it appears, and it is right
        # to: a test that models secret handling should not open with the one
        # call the production path is forbidden to make.
        param([string] $Value)
        $secure = [securestring]::new()
        foreach ($character in $Value.ToCharArray()) { $secure.AppendChar($character) }
        $secure.MakeReadOnly()
        $secure
    }

    function NewTemplateSet {
        <#
            A minimal template and its declaration, written to a temporary
            directory so cases can vary either side independently.
        #>
        param(
            [string] $Root,
            [string] $Template = '<v>{{ADMINISTRATOR_PASSWORD}}</v><i>{{IMAGE_INDEX}}</i>',
            $Placeholders = $null
        )
        if (-not $Placeholders) {
            $Placeholders = @(
                @{ name = 'ADMINISTRATOR_PASSWORD'; secret = $true;  description = 'Build administrator password.' }
                @{ name = 'IMAGE_INDEX';            secret = $false; description = 'Image index within the media.' }
            )
        }
        Set-Content -LiteralPath (Join-Path $Root 'unattend.xml.template') -Value $Template -Encoding utf8 -NoNewline
        $declarationPath = Join-Path $Root 'unattend.template.json'
        @{
            schemaVersion  = 1
            templateFile   = 'unattend.xml.template'
            imageSelection = @{ edition = 'Windows Enterprise'; index = 1; architecture = 'x64'; language = 'en-US' }
            placeholders   = $Placeholders
        } | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $declarationPath -Encoding utf8
        $declarationPath
    }

    function DefaultSecrets { @{ ADMINISTRATOR_PASSWORD = (AsSecure $script:SecretText) } }
}

Describe 'the committed answer-file template' {

    It 'satisfies its declaration' {
        { Import-AnswerFileTemplate -Path $script:Committed } | Should -Not -Throw
    }

    It 'carries no credential' {
        # The way this breaks is someone rendering once and committing the
        # result, so every plain-text value must still be a placeholder.
        $template = Get-Content -LiteralPath (Join-Path $script:RepoRoot 'packer' 'unattended' 'autounattend.xml.template') -Raw
        $pairs = [regex]::Matches($template, '<Value>(?<v>[^<]*)</Value>\s*<PlainText>true</PlainText>')
        $pairs.Count | Should -BeGreaterThan 0 -Because 'the template must contain plain-text values to check'
        foreach ($match in $pairs) {
            $match.Groups['v'].Value.Trim() | Should -Match '^\{\{[A-Z][A-Z0-9_]*\}\}$'
        }
    }

    It 'declares the administrator password as secret' {
        $declaration = Import-AnswerFileTemplate -Path $script:Committed
        ($declaration.placeholders | Where-Object name -EQ 'ADMINISTRATOR_PASSWORD').secret | Should -BeTrue
    }
}

Describe 'declaration and template agreement' {

    It 'refuses a template holding an undeclared placeholder' {
        # It would survive rendering and reach setup as literal text.
        $root = NewTempDir
        $path = NewTemplateSet -Root $root -Template '<v>{{ADMINISTRATOR_PASSWORD}}</v><i>{{IMAGE_INDEX}}</i><x>{{UNDECLARED}}</x>'
        { Import-AnswerFileTemplate -Path $path } | Should -Throw -ExpectedMessage '*does not name: UNDECLARED*'
    }

    It 'refuses a declaration naming a placeholder the template lacks' {
        # Usually a rename applied in one place only.
        $root = NewTempDir
        $path = NewTemplateSet -Root $root -Template '<v>{{ADMINISTRATOR_PASSWORD}}</v>' -Placeholders @(
            @{ name = 'ADMINISTRATOR_PASSWORD'; secret = $true;  description = 'Password.' }
            @{ name = 'IMAGE_INDEX';            secret = $false; description = 'Index.' })
        { Import-AnswerFileTemplate -Path $path } | Should -Throw -ExpectedMessage '*does not hold: IMAGE_INDEX*'
    }

    It 'refuses a template with a literal credential where a placeholder belongs' {
        $root = NewTempDir
        Set-Content -LiteralPath (Join-Path $root 'unattend.xml.template') `
            -Value '<Value>hunter2</Value><PlainText>true</PlainText>{{IMAGE_INDEX}}' -Encoding utf8 -NoNewline
        $path = Join-Path $root 'unattend.template.json'
        @{
            schemaVersion = 1; templateFile = 'unattend.xml.template'
            imageSelection = @{ edition = 'Windows Enterprise'; index = 1; architecture = 'x64'; language = 'en-US' }
            placeholders = @(@{ name = 'IMAGE_INDEX'; secret = $false; description = 'Index.' })
        } | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $path -Encoding utf8

        { Import-AnswerFileTemplate -Path $path } | Should -Throw -ExpectedMessage '*never carry a credential*'
    }
}

Describe 'rendering the answer file' {

    It 'substitutes every placeholder' {
        $root = NewTempDir
        $declaration = Import-AnswerFileTemplate -Path (NewTemplateSet -Root $root)

        $content = Invoke-WithRenderedAnswerFile -Declaration $declaration `
            -Secrets (DefaultSecrets) -ScriptBlock { param($p) Get-Content -LiteralPath $p -Raw }

        $content | Should -Be "<v>$($script:SecretText)</v><i>1</i>"
        $content | Should -Not -Match '\{\{'
    }

    It 'refuses a secret supplied as plain text' {
        # A [string] password has already been in managed memory and cannot be
        # cleared, so accepting one would make the rest of this pointless.
        $root = NewTempDir
        $declaration = Import-AnswerFileTemplate -Path (NewTemplateSet -Root $root)

        { Invoke-WithRenderedAnswerFile -Declaration $declaration `
            -Secrets @{ ADMINISTRATOR_PASSWORD = 'plain' } -ScriptBlock { param($p) $p } } |
            Should -Throw -ExpectedMessage '*must be supplied as a SecureString*'
    }

    It 'refuses a missing secret value' {
        $root = NewTempDir
        $declaration = Import-AnswerFileTemplate -Path (NewTemplateSet -Root $root)

        { Invoke-WithRenderedAnswerFile -Declaration $declaration `
            -Secrets @{} -ScriptBlock { param($p) $p } } |
            Should -Throw -ExpectedMessage '*No value supplied*'
    }

    It 'refuses a non-secret placeholder it cannot derive a value for' {
        # Non-secret values come from the validated declaration, never from the
        # caller, so an undeclared derivation is an error rather than a blank.
        # Failing closed here is what stops a caller supplying an index or
        # language that disagrees with the qualified media.
        $root = NewTempDir
        $path = NewTemplateSet -Root $root -Template '<v>{{ADMINISTRATOR_PASSWORD}}</v><i>{{IMAGE_INDEX}}</i><z>{{TIME_ZONE}}</z>' -Placeholders @(
            @{ name = 'ADMINISTRATOR_PASSWORD'; secret = $true;  description = 'Password.' }
            @{ name = 'IMAGE_INDEX';            secret = $false; description = 'Index.' }
            @{ name = 'TIME_ZONE';              secret = $false; description = 'Undeclared derivation.' })
        $declaration = Import-AnswerFileTemplate -Path $path

        { Invoke-WithRenderedAnswerFile -Declaration $declaration `
            -Secrets (DefaultSecrets) -ScriptBlock { param($p) $p } } |
            Should -Throw -ExpectedMessage '*No value is derived*'
    }

    It 'derives every non-secret value from the declaration' {
        $root = NewTempDir
        $declaration = Import-AnswerFileTemplate -Path (NewTemplateSet -Root $root)
        $values = Get-AnswerFileValueSet -Declaration $declaration

        $values['IMAGE_INDEX'] | Should -Be '1'
        $values['UI_LANGUAGE'] | Should -Be 'en-US'
        # Windows Setup spells the architecture differently from the canonical
        # value the media reference carries.
        $values['PROCESSOR_ARCHITECTURE'] | Should -Be 'amd64'
    }

    It 'maps arm64 to its own Setup token' {
        $root = NewTempDir
        $path = NewTemplateSet -Root $root
        $declaration = Import-AnswerFileTemplate -Path $path
        $declaration.imageSelection.architecture = 'arm64'

        (Get-AnswerFileValueSet -Declaration $declaration)['PROCESSOR_ARCHITECTURE'] | Should -Be 'arm64'
    }

    It 'refuses an architecture with no Setup mapping' {
        $root = NewTempDir
        $declaration = Import-AnswerFileTemplate -Path (NewTemplateSet -Root $root)
        $declaration.imageSelection.architecture = 'x86'

        { Get-AnswerFileValueSet -Declaration $declaration } |
            Should -Throw -ExpectedMessage '*No Windows Setup architecture token*'
    }

    It 'hands the scriptblock a path, never the content' {
        $root = NewTempDir
        $declaration = Import-AnswerFileTemplate -Path (NewTemplateSet -Root $root)

        $received = Invoke-WithRenderedAnswerFile -Declaration $declaration `
            -Secrets (DefaultSecrets) -ScriptBlock { param($p) $p }

        $received | Should -BeOfType [string]
        $received | Should -Not -Match ([regex]::Escape($script:SecretText))
    }

    It 'renders nothing under -WhatIf' {
        # A preview run that produced a live credential and then declined to
        # delete it would be worse than doing the work.
        $root = NewTempDir
        $declaration = Import-AnswerFileTemplate -Path (NewTemplateSet -Root $root)

        Invoke-WithRenderedAnswerFile -Declaration $declaration `
            -Secrets (DefaultSecrets) -ScriptBlock { param($p) $p } -WhatIf | Out-Null

        @(Get-ChildItem -Path $root -Filter 'autounattend-*.xml' -File) | Should -BeNullOrEmpty
    }
}

Describe 'the rendered file is short-lived' {

    It 'removes the rendered file after the scriptblock succeeds' {
        $root = NewTempDir
        $declaration = Import-AnswerFileTemplate -Path (NewTemplateSet -Root $root)

        $path = Invoke-WithRenderedAnswerFile -Declaration $declaration `
            -Secrets (DefaultSecrets) -ScriptBlock { param($p) $p }

        Test-Path -LiteralPath $path | Should -BeFalse
    }

    It 'removes the rendered file when the scriptblock throws' {
        # The path that matters. A build failing part way through must not leave
        # a working administrator password on the host.
        $root = NewTempDir
        $declaration = Import-AnswerFileTemplate -Path (NewTemplateSet -Root $root)

        { Invoke-WithRenderedAnswerFile -Declaration $declaration `
            -Secrets (DefaultSecrets) -ScriptBlock {
                param($p)
                if (-not (Test-Path -LiteralPath $p)) { throw 'the answer file was absent during the scriptblock' }
                throw 'build failed'
            } } | Should -Throw -ExpectedMessage 'build failed'

        @(Get-ChildItem -Path $root -Filter 'autounattend-*.xml' -File) | Should -BeNullOrEmpty
    }

    It 'refuses an unsubstituted placeholder before writing any secret' {
        # Checked against the template, not by rereading the finished file: a
        # reread would build the managed string the whole design avoids. The
        # consequence is that nothing is written at all, so there is no window
        # in which a partly rendered credential exists.
        $root = NewTempDir
        $declaration = Import-AnswerFileTemplate -Path (NewTemplateSet -Root $root)
        Set-Content -LiteralPath $declaration.templatePath `
            -Value '<v>{{ADMINISTRATOR_PASSWORD}}</v><i>{{IMAGE_INDEX}}</i><x>{{LEFTOVER}}</x>' -Encoding utf8 -NoNewline

        $before = @(Get-ChildItem -Path ([System.IO.Path]::GetTempPath()) -Filter 'vdi-iac-answerfile-*' -Directory).Count

        { Invoke-WithRenderedAnswerFile -Declaration $declaration `
            -Secrets (DefaultSecrets) -ScriptBlock { param($p) $p } } |
            Should -Throw -ExpectedMessage '*unsubstituted placeholder*LEFTOVER*'

        @(Get-ChildItem -Path ([System.IO.Path]::GetTempPath()) -Filter 'vdi-iac-answerfile-*' -Directory).Count |
            Should -Be $before
    }

    It 'removes its own working directory, wherever it chose to put it' {
        $root = NewTempDir
        $declaration = Import-AnswerFileTemplate -Path (NewTemplateSet -Root $root)

        $workRoot = Invoke-WithRenderedAnswerFile -Declaration $declaration `
            -Secrets (DefaultSecrets) -ScriptBlock { param($p) Split-Path -Parent $p }

        Test-Path -LiteralPath $workRoot | Should -BeFalse
    }

    It 'writes the rendered file somewhere the caller did not choose' {
        # The caller cannot name the location, so a rendered credential cannot
        # be steered into the repository or through a redirected path.
        $root = NewTempDir
        $declaration = Import-AnswerFileTemplate -Path (NewTemplateSet -Root $root)

        $path = Invoke-WithRenderedAnswerFile -Declaration $declaration `
            -Secrets (DefaultSecrets) -ScriptBlock { param($p) $p }

        $path | Should -Not -BeLike "$script:RepoRoot*"
        (Split-Path -Leaf (Split-Path -Parent $path)) | Should -BeLike 'vdi-iac-answerfile-*'
    }

    It 'reports rather than throws when removal is impossible' {
        # Called from a finally block: throwing there would replace whatever
        # failure is already being reported.
        Remove-RenderedAnswerFile -Path (Join-Path (NewTempDir) 'never-existed.xml') | Should -Be 'absent'
    }

    It 'restricts the rendered file to its owner' -Skip:($IsWindows) {
        $root = NewTempDir
        $declaration = Import-AnswerFileTemplate -Path (NewTemplateSet -Root $root)

        $mode = Invoke-WithRenderedAnswerFile -Declaration $declaration `
            -Secrets (DefaultSecrets) -ScriptBlock {
                param($p) [System.IO.File]::GetUnixFileMode($p)
            }

        # No group or other bits, checked individually so a failure names which.
        foreach ($forbidden in 'GroupRead', 'GroupWrite', 'OtherRead', 'OtherWrite') {
            $bit = [System.Enum]::Parse([System.IO.UnixFileMode], $forbidden)
            ($mode -band $bit) | Should -Be 0 -Because "$forbidden must not be set"
        }
    }

    It 'restricts the rendered file to its owner on Windows' -Skip:(-not $IsWindows) {
        # The Windows branch of the restriction runs on every rendering test,
        # but nothing asserted what it produced: the code executing is not the
        # same as the ACL being restrictive. Windows is the platform this
        # actually ships on, so the claim needs proving there most of all.
        $root = NewTempDir
        $declaration = Import-AnswerFileTemplate -Path (NewTemplateSet -Root $root)

        $acl = Invoke-WithRenderedAnswerFile -Declaration $declaration `
            -Secrets (DefaultSecrets) -ScriptBlock { param($p) Get-Acl -LiteralPath $p }

        # Inheritance off, or a permissive parent directory silently grants
        # access the explicit rules never mention.
        $acl.AreAccessRulesProtected | Should -BeTrue -Because 'inherited rules would bypass the explicit ones'

        $current = [System.Security.Principal.WindowsIdentity]::GetCurrent().User
        $identities = @($acl.Access | ForEach-Object { $_.IdentityReference.Translate([System.Security.Principal.SecurityIdentifier]) })
        $identities.Count | Should -Be 1 -Because 'only the build identity may read a rendered credential'
        $identities[0].Value | Should -Be $current.Value
    }

    It 'restricts the file before any content is written' {
        # Writing first and restricting afterwards leaves a window in which the
        # rendered credential is readable by anything else on the machine.
        $module = Get-Content -LiteralPath (Join-Path $script:RepoRoot 'source-qualification' 'scripts' 'AnswerFile.psm1') -Raw
        $create = $module.IndexOf('NewRestrictedFile -Path $renderedPath')
        $write = $module.IndexOf('WriteRenderedAnswerFile -Template')
        $create | Should -BeGreaterThan 0
        $create | Should -BeLessThan $write
    }
}

Describe 'the secret does not escape' {

    It 'keeps the secret out of the exception when the scriptblock fails' {
        $root = NewTempDir
        $declaration = Import-AnswerFileTemplate -Path (NewTemplateSet -Root $root)

        $caught = $null
        try {
            Invoke-WithRenderedAnswerFile -Declaration $declaration `
                -Secrets (DefaultSecrets) -ScriptBlock { param($p) throw "failed reading $p" }
        }
        catch { $caught = $_ }

        $caught | Should -Not -BeNullOrEmpty
        "$($caught.Exception.Message)$($caught.ScriptStackTrace)" |
            Should -Not -Match ([regex]::Escape($script:SecretText))
    }

    It 'keeps the secret out of every value the renderer returns' {
        $root = NewTempDir
        $declaration = Import-AnswerFileTemplate -Path (NewTemplateSet -Root $root)

        $returned = Invoke-WithRenderedAnswerFile -Declaration $declaration `
            -Secrets (DefaultSecrets) -ScriptBlock {
                param($p)
                if (Test-Path -LiteralPath $p) { 'done' } else { 'missing' }
            }

        $returned | Should -Be 'done'
        "$returned" | Should -Not -Match ([regex]::Escape($script:SecretText))
    }

    It 'keeps the secret out of verbose output' {
        $root = NewTempDir
        $declaration = Import-AnswerFileTemplate -Path (NewTemplateSet -Root $root)

        $verbose = $($null = Invoke-WithRenderedAnswerFile -Declaration $declaration `
            -Secrets (DefaultSecrets) -ScriptBlock { param($p) $p } -Verbose) 4>&1

        "$verbose" | Should -Not -Match ([regex]::Escape($script:SecretText))
    }
}

Describe 'the answer file must match the qualified media' {

    BeforeAll {
        function NewMediaRecord {
            param([string] $Edition = 'Windows Enterprise', [int] $Index = 1,
                  [string] $Architecture = 'x64', [string] $Language = 'en-US')
            [PSCustomObject]@{
                image    = [PSCustomObject]@{ edition = $Edition; index = $Index }
                platform = [PSCustomObject]@{ architecture = $Architecture; language = $Language }
            }
        }
    }

    It 'accepts an answer file selecting the qualified image' {
        $root = NewTempDir
        $declaration = Import-AnswerFileTemplate -Path (NewTemplateSet -Root $root)
        Assert-AnswerFileMatchesMedia -Declaration $declaration -MediaRecord (NewMediaRecord) |
            Should -BeNullOrEmpty
    }

    It 'refuses a mismatched <field>' -ForEach @(
        @{ field = 'index';        record = @{ Index = 4 } }
        @{ field = 'edition';      record = @{ Edition = 'Windows Pro' } }
        @{ field = 'architecture'; record = @{ Architecture = 'arm64' } }
        @{ field = 'language';     record = @{ Language = 'de-DE' } }
    ) {
        # Media qualification records intent without opening the media, so this
        # is the check that stops a build installing something other than what
        # was qualified while provenance names the qualified artifact.
        $root = NewTempDir
        $declaration = Import-AnswerFileTemplate -Path (NewTemplateSet -Root $root)

        $reason = Assert-AnswerFileMatchesMedia -Declaration $declaration -MediaRecord (NewMediaRecord @record)
        $reason | Should -Not -BeNullOrEmpty
        $reason | Should -Match $field
    }
}

Describe 'setup residue in the guest' {

    BeforeAll {
        function NewGuestWithResidue {
            <#
                A fixture standing in for a guest after installation, with the
                answer-file copies setup leaves behind.
            #>
            param([string[]] $Paths = @('Windows/Panther/unattend.xml', 'Windows/System32/Sysprep/unattend.xml'))
            $drive = NewTempDir
            foreach ($relative in $Paths) {
                $full = Join-Path $drive $relative
                $null = New-Item -ItemType Directory -Path (Split-Path -Parent $full) -Force
                Set-Content -LiteralPath $full -Value "<Value>$($script:SecretText)</Value>" -Encoding utf8 -NoNewline
            }
            $drive
        }
    }

    It 'finds the copies setup left behind' {
        # Removing the rendered file on the host is half the lifecycle. Setup
        # writes its own copies, and each retains the password in plain text.
        $drive = NewGuestWithResidue
        @(Get-SetupResidue -SystemDrive $drive).Count | Should -Be 2
    }

    It 'reports a clean guest as clean' {
        Get-SetupResidue -SystemDrive (NewTempDir) | Should -BeNullOrEmpty
    }

    It 'removes every copy, not just the first' {
        $drive = NewGuestWithResidue
        $outcome = Remove-SetupResidue -SystemDrive $drive

        $outcome.Clean | Should -BeTrue
        $outcome.Remaining | Should -BeNullOrEmpty
        @($outcome.Results | Where-Object Outcome -EQ 'removed').Count | Should -Be 2
    }

    It 'continues past a copy it cannot remove' {
        # Stopping at the first failure would leave later copies in place, and
        # every one of them holds the password.
        #
        # A real filesystem condition rather than a mock. A ParameterFilter runs
        # in the module's scope and cannot see this test's variables, so a
        # path-matching mock silently blocked every removal -- which looked
        # exactly like the code stopping early, the defect being tested for.
        $drive = NewGuestWithResidue
        $blocked = Join-Path $drive 'Windows/Panther/unattend.xml'
        $blockedParent = Split-Path -Parent $blocked
        $handle = $null
        $originalMode = $null

        if ($IsWindows) {
            # An exclusive handle prevents deletion on Windows.
            $handle = [System.IO.File]::Open($blocked, [System.IO.FileMode]::Open,
                [System.IO.FileAccess]::Read, [System.IO.FileShare]::None)
        }
        else {
            # Unlink needs write permission on the directory, not the file.
            $originalMode = [System.IO.File]::GetUnixFileMode($blockedParent)
            [System.IO.File]::SetUnixFileMode($blockedParent,
                [System.IO.UnixFileMode]::UserRead -bor [System.IO.UnixFileMode]::UserExecute)
        }

        try {
            $outcome = Remove-SetupResidue -SystemDrive $drive

            $outcome.Clean | Should -BeFalse
            @($outcome.Results | Where-Object Outcome -EQ 'failed').Count | Should -Be 1
            @($outcome.Results | Where-Object Outcome -EQ 'removed').Count | Should -Be 1
            $outcome.Remaining.Count | Should -Be 1
        }
        finally {
            if ($handle) { $handle.Dispose() }
            if ($originalMode) { [System.IO.File]::SetUnixFileMode($blockedParent, $originalMode) }
        }
    }

    It 'leaves no residue content readable after a clean sweep' {
        $drive = NewGuestWithResidue
        $null = Remove-SetupResidue -SystemDrive $drive

        $surviving = Get-ChildItem -Path $drive -Recurse -File |
            Where-Object { (Get-Content -LiteralPath $_.FullName -Raw) -match [regex]::Escape($script:SecretText) }
        $surviving | Should -BeNullOrEmpty
    }

    It 'removes nothing under -WhatIf, and says so' {
        $drive = NewGuestWithResidue
        $outcome = Remove-SetupResidue -SystemDrive $drive -WhatIf

        @($outcome.Results | Where-Object Outcome -EQ 'not-attempted').Count | Should -Be 2
        @(Get-SetupResidue -SystemDrive $drive).Count | Should -Be 2
    }
}

Describe 'XML safety of the secret' {

    It 'renders a password containing <label> to the exact intended value' -ForEach @(
        @{ label = 'an ampersand';        secret = 'pa&ss' }
        @{ label = 'a less-than sign';    secret = 'pa<ss' }
        @{ label = 'both, and a quote';   secret = 'a&b<c>d"e''f' }
        @{ label = 'only markup';         secret = '<&>' }
        @{ label = 'an entity lookalike'; secret = '&amp;' }
    ) {
        # An unescaped & or < produces a document that is either malformed or
        # parses to a different value than the one set on the account, and the
        # symptom is a login that does not work -- a long way from the cause.
        #
        # The escaped write happens a run at a time straight into the stream, so
        # proving it means parsing the result and comparing the decoded value.
        # A single root element: the default fixture is two siblings, which is
        # not a well-formed document and would fail this test for a reason that
        # has nothing to do with escaping.
        $root = NewTempDir
        $declaration = Import-AnswerFileTemplate -Path (NewTemplateSet -Root $root `
            -Template '<u><v>{{ADMINISTRATOR_PASSWORD}}</v><i>{{IMAGE_INDEX}}</i></u>')
        $secure = AsSecure $secret
        # Copied into a plainly named variable the scriptblock can see. Pester's
        # -ForEach variable is not reachable from inside the block.
        $expected = $secret

        $verdict = Invoke-WithRenderedAnswerFile -Declaration $declaration `
            -Secrets @{ ADMINISTRATOR_PASSWORD = $secure } -ScriptBlock {
                param($p)
                $xml = [xml](Get-Content -LiteralPath $p -Raw)
                [PSCustomObject]@{
                    Parsed  = $true
                    Decoded = ($xml.u.v -eq $expected)
                }
            }

        $verdict.Parsed | Should -BeTrue -Because 'the rendered document must be well-formed XML'
        $verdict.Decoded | Should -BeTrue -Because 'the parsed value must equal the password exactly'
    }

    It 'produces a well-formed document for the committed template' {
        # No temporary directory needed: the renderer owns where it writes.
        $declaration = Import-AnswerFileTemplate -Path $script:Committed

        $wellFormed = Invoke-WithRenderedAnswerFile -Declaration $declaration `
            -Secrets @{ ADMINISTRATOR_PASSWORD = (AsSecure 'p@ss&word<1>') } -ScriptBlock {
                param($p)
                try { $null = [xml](Get-Content -LiteralPath $p -Raw); $true } catch { $false }
            }

        $wellFormed | Should -BeTrue
    }
}

Describe 'the duplicate-declaration bypass' {

    It 'refuses a placeholder declared twice' {
        # uniqueItems compares whole objects, so the same name with different
        # flags satisfies the schema. The duplicate is the bypass: the
        # non-secret copy takes a plain value and fills the same position.
        $root = NewTempDir
        $path = NewTemplateSet -Root $root -Template '<v>{{ADMINISTRATOR_PASSWORD}}</v><i>{{IMAGE_INDEX}}</i>' -Placeholders @(
            @{ name = 'ADMINISTRATOR_PASSWORD'; secret = $true;  description = 'The protected declaration.' }
            @{ name = 'ADMINISTRATOR_PASSWORD'; secret = $false; description = 'The bypass.' }
            @{ name = 'IMAGE_INDEX';            secret = $false; description = 'Index.' })

        { Import-AnswerFileTemplate -Path $path } |
            Should -Throw -ExpectedMessage '*more than once: ADMINISTRATOR_PASSWORD*'
    }

    It 'refuses a declaration carrying a trailing control character' {
        # The schema patterns are ECMA-262 portable, so under .NET a trailing
        # newline satisfies a pattern ending in $. Assert-NoControlCharacter is
        # what closes that, and the answer-file path needs it as much as the
        # media path: a placeholder name with a newline appended would be
        # substituted under one spelling and matched under another.
        $root = NewTempDir
        $path = NewTemplateSet -Root $root
        $document = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json -AsHashtable
        $document.templateFile = "unattend.xml.template`n"
        $document | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $path -Encoding utf8

        { Import-AnswerFileTemplate -Path $path } |
            Should -Throw -ExpectedMessage '*control character 0x0A*'
    }

    It 'refuses a plain-text position filled by a non-secret placeholder' {
        # Schema-valid and internally consistent. What is wrong is that the
        # position holding a credential would be substituted from ordinary
        # values and never take the protected write path.
        $root = NewTempDir
        Set-Content -LiteralPath (Join-Path $root 'unattend.xml.template') `
            -Value '<Value>{{IMAGE_INDEX}}</Value><PlainText>true</PlainText>' -Encoding utf8 -NoNewline
        $path = Join-Path $root 'unattend.template.json'
        @{
            schemaVersion = 1; templateFile = 'unattend.xml.template'
            imageSelection = @{ edition = 'Windows Enterprise'; index = 1; architecture = 'x64'; language = 'en-US' }
            placeholders = @(@{ name = 'IMAGE_INDEX'; secret = $false; description = 'Not secret.' })
        } | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $path -Encoding utf8

        { Import-AnswerFileTemplate -Path $path } |
            Should -Throw -ExpectedMessage '*must name a placeholder declared exactly once and marked secret*'
    }
}

Describe 'a failed deletion is terminal' {

    BeforeAll {
        function BlockDeletion {
            # A real filesystem condition. On Unix unlink needs write permission
            # on the directory; on Windows an exclusive handle prevents removal.
            param([string] $Path)
            $parent = Split-Path -Parent $Path
            if ($IsWindows) {
                [PSCustomObject]@{
                    Handle = [System.IO.File]::Open($Path, [System.IO.FileMode]::Open,
                        [System.IO.FileAccess]::Read, [System.IO.FileShare]::None)
                    Parent = $parent; Mode = $null
                }
            }
            else {
                $mode = [System.IO.File]::GetUnixFileMode($parent)
                [System.IO.File]::SetUnixFileMode($parent,
                    [System.IO.UnixFileMode]::UserRead -bor [System.IO.UnixFileMode]::UserExecute)
                [PSCustomObject]@{ Handle = $null; Parent = $parent; Mode = $mode }
            }
        }

        function UnblockDeletion {
            param($Block)
            if ($Block.Handle) { $Block.Handle.Dispose() }
            if ($Block.Mode) { [System.IO.File]::SetUnixFileMode($Block.Parent, $Block.Mode) }
        }
    }

    It 'fails the run when the rendered file cannot be removed' {
        # The previous coverage exercised only the harmless 'absent' case, which
        # says nothing about what happens when a credential is genuinely stuck
        # on disk. Work that succeeded while leaving one there has not succeeded.
        $root = NewTempDir
        $declaration = Import-AnswerFileTemplate -Path (NewTemplateSet -Root $root)
        $script:Block = $null

        try {
            { Invoke-WithRenderedAnswerFile -Declaration $declaration `
                -Secrets (DefaultSecrets) -ScriptBlock {
                    param($p)
                    $script:Block = BlockDeletion -Path $p
                    'work completed'
                } } | Should -Throw -ExpectedMessage '*credential remains on disk*'
        }
        finally { if ($script:Block) { UnblockDeletion -Block $script:Block } }
    }

    It 'preserves the original failure when work and cleanup both fail' {
        # The caller needs the failure that started it. The cleanup outcome is
        # recorded beside it rather than replacing it, or the run reports a
        # deletion problem and hides why the build broke.
        $root = NewTempDir
        $declaration = Import-AnswerFileTemplate -Path (NewTemplateSet -Root $root)
        $script:Block = $null
        $caught = $null

        try {
            try {
                Invoke-WithRenderedAnswerFile -Declaration $declaration `
                    -Secrets (DefaultSecrets) -ScriptBlock {
                        param($p)
                        $script:Block = BlockDeletion -Path $p
                        throw 'the build failed first'
                    } -WarningAction SilentlyContinue
            }
            catch { $caught = $_ }
        }
        finally { if ($script:Block) { UnblockDeletion -Block $script:Block } }

        $caught.Exception.Message | Should -Be 'the build failed first'
        $caught.Exception.Data['CleanupOutcome'] | Should -Be 'failed'
    }
}
