#Requires -Version 7.0

BeforeAll {
    $script:RepoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    $scripts = Join-Path $script:RepoRoot 'source-qualification' 'scripts'
    foreach ($module in 'RunIdentity', 'GuestProvisioning', 'AnswerFile', 'PreGeneralization') {
        Import-Module (Join-Path $scripts "$module.psm1") -Force
    }
    $script:Schema = Join-Path $script:RepoRoot 'contracts' 'evidence-envelope-2.schema.json'

    function NewTempDir {
        $d = Join-Path ([System.IO.Path]::GetTempPath()) ([guid]::NewGuid().ToString())
        $null = New-Item -ItemType Directory -Path $d -Force
        $d
    }

    function WritePhase {
        param([string] $Path, [string] $RunId, [string] $Phase)
        @{
            resultSchemaVersion = 2; resultKind = 'guest-provisioning'
            runId = $RunId; manifestSchemaVersion = 2
            startedUtc = '2026-01-01T00:00:00.0000000Z'; completedUtc = '2026-01-01T00:00:01.0000000Z'
            outcome = 'passed'
            payload = @{
                phase = $Phase; restartRequired = $false
                packageCount = 1; passedCount = 1; failedRequiredCount = 0
                installerAttemptCount = 1; terminalReasonCode = $null
                cleanupOutcome = 'removed'
                packages = @(@{ id = 'example-agent'; version = '1.2.3'; order = 10; required = $true
                                outcome = 'passed'; reasonCode = $null
                                restartRequired = $false; installerAttempted = $true })
            }
        } | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $Path -Encoding utf8
    }

    function NewGate {
        param([string] $RunId, [switch] $Refusing)
        $dir = NewTempDir
        $installPath = Join-Path $dir 'install.json'
        $validatePath = Join-Path $dir 'validate.json'
        WritePhase -Path $installPath -RunId $RunId -Phase 'install'
        if (-not $Refusing) { WritePhase -Path $validatePath -RunId $RunId -Phase 'validate' }
        @{ InstallEvidencePath = $installPath; ValidateEvidencePath = $validatePath
           RunId = $RunId; SchemaPath = $script:Schema }
    }

    function NewMediaRecord {
        param([string] $Edition = 'Enterprise', [string] $Architecture = 'x64', [string] $Language = 'en-US')
        [PSCustomObject]@{
            image    = [PSCustomObject]@{ edition = $Edition; index = 1 }
            platform = [PSCustomObject]@{ architecture = $Architecture; language = $Language }
        }
    }

    function NewFacts {
        <#
            An injected fact provider. The production one refuses off Windows, so
            the entire check set is exercised against this instead.
        #>
        param(
            [string] $Edition = 'Enterprise', [string] $Architecture = '64-bit',
            [string] $Language = 'en-US', [bool] $PendingRestart = $false,
            [string[]] $ActiveInstallers = @(), [switch] $EditionThrows
        )
        # Captured into one state object first. The getters below close over
        # $state rather than over each parameter, so the parameters are read in
        # ordinary assignments -- which is also the only form static analysis can
        # see, since it does not look inside a closure.
        $state = @{
            Edition          = $Edition
            Architecture     = $Architecture
            Language         = $Language
            PendingRestart   = $PendingRestart
            ActiveInstallers = $ActiveInstallers
            EditionThrows    = [bool] $EditionThrows
        }

        @{
            GetEdition = {
                if ($state.EditionThrows) { throw 'registry unavailable' } else { $state.Edition }
            }.GetNewClosure()
            GetArchitecture = { $state.Architecture }.GetNewClosure()
            GetLanguage = { $state.Language }.GetNewClosure()
            GetPendingRestart = { $state.PendingRestart }.GetNewClosure()
            GetActiveInstallerProcesses = { $state.ActiveInstallers }.GetNewClosure()
        }
    }

    function Readiness {
        param($Gate, $Media, [string] $StagingRoot, [string] $RunId, $Facts)
        Test-PreGeneralizationReadiness -Gate $Gate -MediaRecord $Media `
            -StagingRoot $StagingRoot -RunId $RunId -FactProvider $Facts
    }
}

Describe 'the provisioning gate comes first' {

    It 'refuses pre-generalization checks when provisioning is not accounted for' {
        # Called rather than trusted. A caller who skipped the gate is exactly
        # the caller these steps exist to protect against.
        $runId = Get-RunIdentifier
        { Readiness -Gate (NewGate -RunId $runId -Refusing) -Media (NewMediaRecord) `
            -StagingRoot (NewTempDir) -RunId $runId -Facts (NewFacts) } |
            Should -Throw -ExpectedMessage '*Provisioning is not complete*'
    }

    It 'refuses residue removal when provisioning is not accounted for' {
        $runId = Get-RunIdentifier
        { Invoke-AnswerFileResidueRemoval -Gate (NewGate -RunId $runId -Refusing) -SystemDrive (NewTempDir) } |
            Should -Throw -ExpectedMessage '*Provisioning is not complete*'
    }

    It 'refuses a gate argument set that is incomplete' {
        { Invoke-AnswerFileResidueRemoval -Gate @{ RunId = (Get-RunIdentifier) } -SystemDrive (NewTempDir) } |
            Should -Throw -ExpectedMessage '*missing*'
    }
}

Describe 'pre-generalization checks' {

    It 'passes a machine that matches what was qualified' {
        $runId = Get-RunIdentifier
        $result = Readiness -Gate (NewGate -RunId $runId) -Media (NewMediaRecord) `
            -StagingRoot (NewTempDir) -RunId $runId -Facts (NewFacts)

        $result.Outcome | Should -Be 'passed'
        $result.ReasonCode | Should -BeNullOrEmpty
        $result.Phase | Should -Be 'pre-generalization'
        @($result.Checks | Where-Object outcome -NE 'passed') | Should -BeNullOrEmpty
    }

    It 'reconciles <field> against the qualified media intent' -ForEach @(
        @{ field = 'edition';      facts = @{ Edition = 'Professional' } }
        @{ field = 'architecture'; facts = @{ Architecture = 'ARM 64-bit' } }
        @{ field = 'language';     facts = @{ Language = 'de-DE' } }
    ) {
        # Media qualification never opened the media, so the declared edition,
        # architecture, and language were intent. This is where that intent is
        # finally reconciled against what actually installed.
        $runId = Get-RunIdentifier
        $result = Readiness -Gate (NewGate -RunId $runId) -Media (NewMediaRecord) `
            -StagingRoot (NewTempDir) -RunId $runId -Facts (NewFacts @facts)

        $result.Outcome | Should -Be 'failed'
        $result.ReasonCode | Should -Be 'pre_generalization_failed'
        ($result.Checks | Where-Object id -EQ $field).reasonCode | Should -Be 'identity_mismatch'
    }

    It 'accepts the forms Windows actually reports' {
        # Windows reports an edition identifier, not a media display name, and
        # "64-bit" rather than x64. A literal comparison would fail every real
        # build, so agreement is containment in either direction.
        $runId = Get-RunIdentifier
        $result = Readiness -Gate (NewGate -RunId $runId) `
            -Media (NewMediaRecord -Edition 'Windows Enterprise' -Architecture 'x64') `
            -StagingRoot (NewTempDir) -RunId $runId `
            -Facts (NewFacts -Edition 'Enterprise' -Architecture '64-bit')

        $result.Outcome | Should -Be 'passed'
    }

    It 'treats an unreadable fact as a failure, not a pass' {
        # An unanswerable question about a machine about to become an image is
        # not agreement.
        $runId = Get-RunIdentifier
        $result = Readiness -Gate (NewGate -RunId $runId) -Media (NewMediaRecord) `
            -StagingRoot (NewTempDir) -RunId $runId -Facts (NewFacts -EditionThrows)

        $result.Outcome | Should -Be 'failed'
        ($result.Checks | Where-Object id -EQ 'edition').outcome | Should -Be 'inconclusive'
    }

    It 'refuses a machine with a restart outstanding' {
        # The machine is not in the state anything observed, and generalizing
        # seals that half-applied state in.
        $runId = Get-RunIdentifier
        $result = Readiness -Gate (NewGate -RunId $runId) -Media (NewMediaRecord) `
            -StagingRoot (NewTempDir) -RunId $runId -Facts (NewFacts -PendingRestart $true)

        $result.Outcome | Should -Be 'failed'
        ($result.Checks | Where-Object id -EQ 'no-pending-restart').reasonCode | Should -Be 'restart_pending'
    }

    It 'refuses a machine with an installer still running' {
        $runId = Get-RunIdentifier
        $result = Readiness -Gate (NewGate -RunId $runId) -Media (NewMediaRecord) `
            -StagingRoot (NewTempDir) -RunId $runId -Facts (NewFacts -ActiveInstallers @('msiexec'))

        $result.Outcome | Should -Be 'failed'
        ($result.Checks | Where-Object id -EQ 'no-active-installer').reasonCode | Should -Be 'installer_active'
    }

    It 'refuses a machine still carrying the transfer bundle' {
        # Its packages are installer content, and an image that ships with them
        # ships with material nobody expected to distribute.
        $runId = Get-RunIdentifier
        $staging = NewTempDir
        $null = New-Item -ItemType Directory -Path (Join-Path $staging "bundle-$runId") -Force

        $result = Readiness -Gate (NewGate -RunId $runId) -Media (NewMediaRecord) `
            -StagingRoot $staging -RunId $runId -Facts (NewFacts)

        $result.Outcome | Should -Be 'failed'
        ($result.Checks | Where-Object id -EQ 'bundle-removed').reasonCode | Should -Be 'bundle_present'
    }

    It 'looks for the bundle this run created, not any bundle' {
        # A directory belonging to another run is not this run's to report on.
        $runId = Get-RunIdentifier
        $staging = NewTempDir
        $null = New-Item -ItemType Directory -Path (Join-Path $staging "bundle-$(Get-RunIdentifier)") -Force

        (Readiness -Gate (NewGate -RunId $runId) -Media (NewMediaRecord) `
            -StagingRoot $staging -RunId $runId -Facts (NewFacts)).Outcome | Should -Be 'passed'
    }

    It 'refuses a run identifier that is not a canonical UUID' {
        $runId = Get-RunIdentifier
        { Readiness -Gate (NewGate -RunId $runId) -Media (NewMediaRecord) `
            -StagingRoot (NewTempDir) -RunId '../escape' -Facts (NewFacts) } | Should -Throw
    }

    It 'reduces to the shape the image-build contract accepts' {
        $runId = Get-RunIdentifier
        $phase = ConvertTo-ImageBuildPhase -PhaseResult (Readiness -Gate (NewGate -RunId $runId) `
            -Media (NewMediaRecord) -StagingRoot (NewTempDir) -RunId $runId -Facts (NewFacts))

        @($phase.Keys | Sort-Object) | Should -Be @('name', 'outcome', 'reasonCode')
        $phase['name'] | Should -Be 'pre-generalization'
        $phase['outcome'] | Should -Be 'passed'
    }
}

Describe 'answer-file residue removal' {

    BeforeAll {
        function NewGuestDrive {
            param([string[]] $Residue = @('Windows/Panther/unattend.xml', 'Windows/System32/Sysprep/unattend.xml'))
            $drive = NewTempDir
            foreach ($relative in $Residue) {
                $full = Join-Path $drive $relative
                $null = New-Item -ItemType Directory -Path (Split-Path -Parent $full) -Force
                Set-Content -LiteralPath $full -Value '<Value>canary</Value>' -NoNewline
            }
            $drive
        }

        function PlantWitnesses {
            <#
                Files the sweep must not touch, in the directories it works in
                and beside them. Without these a sweep that deleted everything
                under Windows would pass every other assertion here.
            #>
            param([string] $Drive)
            $witnesses = @(
                'Windows/Panther/setupact.log'
                'Windows/Panther/unattend-notes.txt'
                'Windows/System32/Sysprep/Sysprep.exe'
                'Windows/System32/drivers/etc/hosts'
                'Users/Public/Desktop/readme.txt'
                'ProgramData/keep.txt'
            )
            foreach ($relative in $witnesses) {
                $full = Join-Path $Drive $relative
                $null = New-Item -ItemType Directory -Path (Split-Path -Parent $full) -Force
                Set-Content -LiteralPath $full -Value "witness:$relative" -NoNewline
            }
            $witnesses
        }
    }

    It 'removes the residue and confirms it is gone' {
        $runId = Get-RunIdentifier
        $drive = NewGuestDrive
        $result = Invoke-AnswerFileResidueRemoval -Gate (NewGate -RunId $runId) -SystemDrive $drive

        $result.Phase | Should -Be 'credential-residue'
        $result.Outcome | Should -Be 'passed'
        ($result.Checks | Where-Object id -EQ 'residue-absent').outcome | Should -Be 'passed'
    }

    It 'confirms absence by re-reading, not by trusting the sweep' {
        # A removal reporting success without re-reading would let a locked file
        # ship inside the image with the administrator password in it.
        $runId = Get-RunIdentifier
        $drive = NewGuestDrive
        $null = Invoke-AnswerFileResidueRemoval -Gate (NewGate -RunId $runId) -SystemDrive $drive

        Get-ChildItem -Path $drive -Recurse -File |
            Where-Object { (Get-Content -LiteralPath $_.FullName -Raw) -match 'canary' } |
            Should -BeNullOrEmpty
    }

    It 'touches nothing else, in the same directories or beside them' {
        $runId = Get-RunIdentifier
        $drive = NewGuestDrive
        $witnesses = PlantWitnesses -Drive $drive

        $null = Invoke-AnswerFileResidueRemoval -Gate (NewGate -RunId $runId) -SystemDrive $drive

        foreach ($relative in $witnesses) {
            $full = Join-Path $drive $relative
            Test-Path -LiteralPath $full | Should -BeTrue -Because "$relative must survive"
            (Get-Content -LiteralPath $full -Raw) | Should -Be "witness:$relative"
        }
    }

    It 'is idempotent' {
        # A retried build step must not fail for having nothing left to do: the
        # result is about the machine's state, not about what this invocation
        # deleted.
        $runId = Get-RunIdentifier
        $drive = NewGuestDrive
        $gate = NewGate -RunId $runId

        (Invoke-AnswerFileResidueRemoval -Gate $gate -SystemDrive $drive).Outcome | Should -Be 'passed'
        (Invoke-AnswerFileResidueRemoval -Gate $gate -SystemDrive $drive).Outcome | Should -Be 'passed'
    }

    It 'passes on a machine that never had residue' {
        $runId = Get-RunIdentifier
        (Invoke-AnswerFileResidueRemoval -Gate (NewGate -RunId $runId) -SystemDrive (NewTempDir)).Outcome |
            Should -Be 'passed'
    }

    It 'fails closed when a copy cannot be removed' {
        # The case the confirmation exists for.
        $runId = Get-RunIdentifier
        $drive = NewGuestDrive
        $blocked = Join-Path $drive 'Windows/Panther/unattend.xml'
        $parent = Split-Path -Parent $blocked
        $handle = $null; $mode = $null

        if ($IsWindows) {
            $handle = [System.IO.File]::Open($blocked, [System.IO.FileMode]::Open,
                [System.IO.FileAccess]::Read, [System.IO.FileShare]::None)
        }
        else {
            $mode = [System.IO.File]::GetUnixFileMode($parent)
            [System.IO.File]::SetUnixFileMode($parent,
                [System.IO.UnixFileMode]::UserRead -bor [System.IO.UnixFileMode]::UserExecute)
        }

        try {
            $result = Invoke-AnswerFileResidueRemoval -Gate (NewGate -RunId $runId) -SystemDrive $drive
            $result.Outcome | Should -Be 'failed'
            $result.ReasonCode | Should -Be 'credential_residue_present'
        }
        finally {
            if ($handle) { $handle.Dispose() }
            if ($mode) { [System.IO.File]::SetUnixFileMode($parent, $mode) }
        }
    }

    It 'removes nothing under -WhatIf, and does not report success' {
        $runId = Get-RunIdentifier
        $drive = NewGuestDrive
        $result = Invoke-AnswerFileResidueRemoval -Gate (NewGate -RunId $runId) -SystemDrive $drive -WhatIf

        $result.Outcome | Should -Be 'failed'
        Test-Path -LiteralPath (Join-Path $drive 'Windows/Panther/unattend.xml') | Should -BeTrue
    }
}

Describe 'the production fact provider' {

    It 'refuses to run off Windows' -Skip:($IsWindows) {
        # A provider that guessed would let the whole check set pass on a machine
        # it was never designed to inspect.
        { Get-SystemFactProvider } | Should -Throw -ExpectedMessage '*only on Windows*'
    }

    It 'answers every fact the checks ask for' -Skip:(-not $IsWindows) {
        $provider = Get-SystemFactProvider
        foreach ($fact in 'GetEdition', 'GetArchitecture', 'GetLanguage', 'GetPendingRestart', 'GetActiveInstallerProcesses') {
            $provider.ContainsKey($fact) | Should -BeTrue -Because "$fact is asked for by a check"
        }
    }
}

Describe 'architecture agreement is mapped, not guessed' {

    It 'accepts <observed> as <expected>' -ForEach @(
        @{ observed = '64-bit';     expected = 'x64' }
        @{ observed = 'x64';        expected = 'x64' }
        @{ observed = 'AMD64';      expected = 'x64' }
        @{ observed = 'ARM 64-bit'; expected = 'arm64' }
        @{ observed = 'ARM64';      expected = 'arm64' }
    ) {
        $runId = Get-RunIdentifier
        $result = Readiness -Gate (NewGate -RunId $runId) -Media (NewMediaRecord -Architecture $expected) `
            -StagingRoot (NewTempDir) -RunId $runId -Facts (NewFacts -Architecture $observed)

        ($result.Checks | Where-Object id -EQ 'architecture').outcome | Should -Be 'passed'
    }

    It 'refuses <observed> as <expected>' -ForEach @(
        @{ observed = 'ARM 64-bit'; expected = 'x64' }
        @{ observed = '64-bit';     expected = 'arm64' }
        @{ observed = '32-bit';     expected = 'x64' }
        @{ observed = 'x86';        expected = 'x64' }
    ) {
        # A substring rule would eventually accept the first of these, since
        # "ARM 64-bit" contains "64-bit". Sealing an arm64 image under an x64
        # identity is not a mistake anything downstream could detect.
        $runId = Get-RunIdentifier
        $result = Readiness -Gate (NewGate -RunId $runId) -Media (NewMediaRecord -Architecture $expected) `
            -StagingRoot (NewTempDir) -RunId $runId -Facts (NewFacts -Architecture $observed)

        ($result.Checks | Where-Object id -EQ 'architecture').reasonCode | Should -Be 'identity_mismatch'
    }

    It 'refuses an architecture nobody mapped' {
        # An unmapped expectation cannot be satisfied by anything, rather than
        # being satisfied by everything.
        $runId = Get-RunIdentifier
        $result = Readiness -Gate (NewGate -RunId $runId) -Media (NewMediaRecord -Architecture 'ia64') `
            -StagingRoot (NewTempDir) -RunId $runId -Facts (NewFacts -Architecture 'ia64')

        ($result.Checks | Where-Object id -EQ 'architecture').outcome | Should -Be 'failed'
    }
}
