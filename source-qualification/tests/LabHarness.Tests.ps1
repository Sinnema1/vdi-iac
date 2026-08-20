#Requires -Version 7.0

<#
    The lab harness, checked as far as it can be without a disposable target.

    These prove the configuration is complete and correctly ordered, that it
    refuses to run without the safeguards, and that the evidence evaluator
    behaves. They do not prove transfer, execution, restart, or validation
    against a real guest: that is Level 3, and it needs a machine this suite does
    not have. The harness's maturity is 'implementation complete; lab validation
    pending' until such a run happens.
#>

# Evaluated at discovery. Pester resolves -Skip while discovering tests, before
# BeforeAll runs, so a probe placed there leaves every packer case silently
# skipped -- which is how the first run of this file reported three skips on a
# machine that had packer installed.
$script:PackerAvailable = $null -ne (Get-Command packer -ErrorAction SilentlyContinue)

BeforeAll {
    $script:RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..' '..')).Path
    $script:HarnessDir = Join-Path $script:RepoRoot 'packer' 'harness'
    $script:HarnessFile = Join-Path $script:HarnessDir 'lab-null.pkr.hcl'
    $script:Harness = Get-Content -LiteralPath $script:HarnessFile -Raw

    # Imported, not dot-sourced. The orchestrator has mandatory parameters, and
    # dot-sourcing it would prompt for them rather than run.
    Import-Module (Join-Path $script:RepoRoot 'scripts' 'ci' 'LabEvidence.psm1') -Force

    # LabEvidence imports RunIdentity into its own scope, not the caller's, so the
    # tests import what they use rather than relying on a transitive import.
    Import-Module (Join-Path $script:RepoRoot 'source-qualification' 'scripts' 'RunIdentity.psm1') -Force

    function ToHclPath {
        <#
            HCL reads a backslash as an escape introducer, so a Windows path
            written into a var file produces "Invalid escape sequence" -- the
            temp path on a Windows runner contains \Users and \AppData.
            Windows accepts forward slashes, which the harness itself uses
            throughout for the same reason.
        #>
        param([string] $Path)
        $Path -replace '\\', '/'
    }

    function NewTempDir {
        $d = Join-Path ([System.IO.Path]::GetTempPath()) ([guid]::NewGuid().ToString())
        $null = New-Item -ItemType Directory -Path $d -Force
        $d
    }

    function WriteEvidence {
        param(
            [string] $Directory, [string] $Phase, [string] $Outcome, [int] $FailedRequired = 0,
            [string] $RunId = '3f2504e0-4f89-41d3-9a0c-0305e82c3301',
            [string] $Kind = 'guest-provisioning', [string] $DeclaredPhase
        )
        if (-not $DeclaredPhase) { $DeclaredPhase = $Phase }
        $document = @{
            resultSchemaVersion = 2; resultKind = $Kind
            runId = $RunId; manifestSchemaVersion = 2
            startedUtc = '2026-01-01T00:00:00.0000000Z'; completedUtc = '2026-01-01T00:00:01.0000000Z'
            outcome = $Outcome
            payload = @{ phase = $DeclaredPhase; restartRequired = $false; packageCount = 1
                         passedCount = 0; failedRequiredCount = $FailedRequired
                         cleanupOutcome = 'not-attempted'; packages = @() }
        }
        $document | ConvertTo-Json -Depth 12 |
            Set-Content -LiteralPath (Join-Path $Directory "$Phase-guest-evidence.json") -Encoding utf8
    }

    # Provisioner blocks in declaration order, which is execution order.
    function ProvisionerOrder {
        [regex]::Matches($script:Harness, '(?m)^\s{2}(error-cleanup-provisioner|provisioner)\s+"(?<type>[a-z-]+)"') |
            ForEach-Object { $_.Groups['type'].Value }
    }
}

Describe 'harness configuration is complete' {

    It 'is formatted as packer fmt would write it' -Skip:(-not $script:PackerAvailable) {
        & packer fmt -check -recursive $script:HarnessDir | Out-Null
        $LASTEXITCODE | Should -Be 0
    }

    It 'passes a full validate, not only a syntax check' -Skip:(-not $script:PackerAvailable) {
        # A syntax check would accept a file provisioner whose source does not
        # exist. Full validate resolves them, which is why the directories below
        # are real.
        $work = NewTempDir
        $bundle = Join-Path $work 'bundle'; $evidence = Join-Path $work 'evidence'
        $null = New-Item -ItemType Directory -Path $bundle, $evidence -Force
        $varFile = Join-Path $work 'vars.pkrvars.hcl'
        @"
guest_host                      = "windows-lab-target.example"
guest_username                  = "labuser"
guest_password                  = "placeholder"
acknowledge_destructive_lab_run = true
lab_marker_path                 = "C:/vdi-iac-lab/lab-marker.txt"
lab_marker_nonce                = "placeholder-nonce"
run_id                          = "3f2504e0-4f89-41d3-9a0c-0305e82c3301"
bundle_path                     = "$(ToHclPath $bundle)"
descriptor_sha256               = "$('a' * 64)"
evidence_output_dir             = "$(ToHclPath $evidence)"
tools_source_dir                = "$(ToHclPath (Join-Path $script:RepoRoot 'source-qualification' 'scripts'))"
guest_scripts_dir               = "$(ToHclPath (Join-Path $script:RepoRoot 'packer' 'scripts' 'guest'))"
"@ | Set-Content -LiteralPath $varFile -Encoding utf8

        # Quoted: an unquoted -var-file=$varFile is passed through literally,
        # and packer reports it cannot guess the format of a file named '$varFile'.
        $output = (& packer validate "-var-file=$varFile" $script:HarnessDir 2>&1) -join "`n"
        $LASTEXITCODE | Should -Be 0 -Because "packer said: $output"
    }

    It 'refuses to validate when the target and its safeguards are unset' -Skip:(-not $script:PackerAvailable) {
        # No usable defaults: an unset target must be an error rather than a
        # fallback to whatever happens to be reachable.
        & packer validate $script:HarnessDir 2>&1 | Out-Null
        $LASTEXITCODE | Should -Not -Be 0
    }

    It 'pins the Packer core version' {
        $script:Harness | Should -Match 'required_version\s*=\s*"1\.15\.4"'
    }

    It 'declares no default for <variable>' -ForEach @(
        @{ variable = 'guest_host' }, @{ variable = 'guest_username' }, @{ variable = 'guest_password' }
        @{ variable = 'acknowledge_destructive_lab_run' }, @{ variable = 'lab_marker_nonce' }
        @{ variable = 'descriptor_sha256' }
    ) {
        $block = [regex]::Match($script:Harness, "variable\s+`"$variable`"\s*\{(?<body>[^}]*)\}").Groups['body'].Value
        $block | Should -Not -Match 'default\s*='
    }

    It 'marks the credential and the nonce sensitive' {
        foreach ($variable in 'guest_password', 'lab_marker_nonce') {
            $block = [regex]::Match($script:Harness, "variable\s+`"$variable`"\s*\{(?<body>[^}]*)\}").Groups['body'].Value
            $block | Should -Match 'sensitive\s*=\s*true'
        }
    }
}

Describe 'harness ordering' {

    It 'runs the read-only preflight before anything else' {
        # The marker check asks the target to prove it is the intended machine.
        # Anything before it would mutate a machine that has not identified
        # itself.
        (ProvisionerOrder)[0] | Should -Be 'powershell'
        $preflightIndex = $script:Harness.IndexOf('VDIIAC_MARKER_NONCE')
        $preflightIndex | Should -BeGreaterThan 0
        $preflightIndex | Should -BeLessThan $script:Harness.IndexOf('New-Item -ItemType Directory')
    }

    It 'uploads only after staging exists, and installs only after uploading' {
        $order = ProvisionerOrder
        $firstFile = [array]::IndexOf($order, 'file')
        $firstFile | Should -BeGreaterThan 0
        $script:Harness.IndexOf('Invoke-GuestPhase.ps1') | Should -BeGreaterThan $script:Harness.IndexOf('destination')
    }

    It 'validates the run identifier in HCL, before it reaches a path' {
        $block = [regex]::Match($script:Harness, 'variable\s+"run_id"\s*\{(?<body>[\s\S]*?)\n\}').Groups['body'].Value
        $block | Should -Match 'validation\s*\{'
        $block | Should -Match '\[0-9a-f\]\{8\}'
    }

    It 'refuses a non-canonical run identifier' -Skip:(-not $script:PackerAvailable) {
        $work = NewTempDir
        $varFile = Join-Path $work 'vars.pkrvars.hcl'
        'run_id = "NOT-A-UUID"' | Set-Content -LiteralPath $varFile -Encoding utf8
        $output = (& packer validate "-var-file=$varFile" $script:HarnessDir 2>&1) -join "`n"
        $output | Should -Match 'canonical lowercase UUID'
    }

    It 'asserts the guest runtime during the read-only preflight' {
        # Before anything is uploaded or executed, not when the first phase
        # discovers it.
        $preflight = $script:Harness.IndexOf('VDIIAC_MARKER_NONCE')
        $versionCheck = $script:Harness.IndexOf("[version]'7.4.0'")
        $versionCheck | Should -BeGreaterThan 0
        $versionCheck | Should -BeGreaterThan $preflight
        $versionCheck | Should -BeLessThan $script:Harness.IndexOf('New-Item -ItemType Directory')
    }

    It 'reserves the run directory rather than adopting one' {
        # -Force would take over a directory another run owns, and this one
        # removes its run directory recursively at the end.
        $script:Harness | Should -Match 'Refusing to reuse a run identifier'
        $script:Harness | Should -Match "New-Item -ItemType Directory -Path '\`$\{local\.run_root\}' \| Out-Null"
    }

    It 'writes the ownership sentinel only after the directory is reserved' {
        $reserve = $script:Harness.IndexOf('Refusing to reuse a run identifier')
        $sentinel = $script:Harness.IndexOf("Set-Content -LiteralPath '`${local.sentinel_path}'")
        $sentinel | Should -BeGreaterThan $reserve
    }

    It 'gates both cleanup paths on the ownership sentinel' {
        # Without this the error path can run after a failed preflight -- a target
        # that never identified itself -- and delete something it does not own.
        ([regex]::Matches($script:Harness, "Test-Path -LiteralPath '\`$\{local\.sentinel_path\}'")).Count |
            Should -BeGreaterOrEqual 2
    }

    It 'retrieves install evidence before the restart gate' {
        # A failing provisioner stops the ones after it, so evidence collected
        # later than the gate would never be collected at all.
        $installDownload = $script:Harness.IndexOf("install-`${local.evidence_name}`"`n    destination")
        if ($installDownload -lt 0) { $installDownload = $script:Harness.IndexOf('direction   = "download"') }
        $gate = $script:Harness.IndexOf('Refusing to restart a guest')
        $installDownload | Should -BeGreaterThan 0
        $installDownload | Should -BeLessThan $gate
    }

    It 'stops before the restart when the install did not complete' {
        $gate = $script:Harness.IndexOf('Refusing to restart a guest')
        $restart = $script:Harness.IndexOf('windows-restart')
        $gate | Should -BeGreaterThan 0
        $gate | Should -BeLessThan $restart
    }

    It 'restarts between installing and validating' {
        $order = ProvisionerOrder
        $restart = [array]::IndexOf($order, 'windows-restart')
        $restart | Should -BeGreaterThan 0

        $installIndex = $script:Harness.IndexOf("-Phase install")
        $validateIndex = $script:Harness.IndexOf("-Phase validate")
        $restartIndex = $script:Harness.IndexOf('windows-restart')

        $installIndex | Should -BeLessThan $restartIndex
        $restartIndex | Should -BeLessThan $validateIndex
    }

    It 'retrieves evidence before removing guest staging' {
        # Cleanup can fail, and evidence collected afterwards may be gone.
        $download = $script:Harness.IndexOf('direction   = "download"')
        $cleanup = $script:Harness.IndexOf('Remove-GuestBundle')
        $download | Should -BeGreaterThan 0
        $download | Should -BeLessThan $cleanup
    }

    It 'declares an error-cleanup provisioner last' {
        (ProvisionerOrder)[-1] | Should -Be 'powershell'
        $script:Harness | Should -Match 'error-cleanup-provisioner'
    }

    It 'accepts the logical-failure code only on the guest phases' {
        # Scoped deliberately. Applied broadly it would let a transport failure
        # pass for a completed run.
        ([regex]::Matches($script:Harness, 'valid_exit_codes\s*=\s*\[0, 200\]')).Count | Should -Be 2
    }

    It 'requests pwsh rather than Windows PowerShell for every PowerShell step' {
        $powershellBlocks = ([regex]::Matches($script:Harness, '(?m)^\s*(?:error-cleanup-)?provisioner\s+"powershell"')).Count
        $powershellBlocks | Should -BeGreaterThan 0
        ([regex]::Matches($script:Harness, 'use_pwsh\s*=\s*true')).Count | Should -Be $powershellBlocks
    }

    It 'delivers the descriptor digest through the environment, not the bundle' {
        $script:Harness | Should -Match 'VDIIAC_DESCRIPTOR_SHA256=\$\{var\.descriptor_sha256\}'
    }

    It 'derives guest cleanup from the host-controlled staging root' {
        # The Stage 5 invariant: never read or derived from the uploaded
        # descriptor, because cleanup has to work after descriptor tampering.
        $script:Harness | Should -Match "Remove-GuestBundle -StagingRoot '\`$\{local\.run_root\}' -RunId '\`$\{var\.run_id\}'"
    }
}

Describe 'the orchestrator invokes Packer correctly' {

    It 'passes -on-error=run-cleanup-provisioner' {
        # Declaring an error-cleanup-provisioner is not enough: under the default
        # -on-error=cleanup it never runs.
        $orchestrator = Get-Content -LiteralPath (Join-Path $script:RepoRoot 'scripts' 'ci' 'Invoke-LabRun.ps1') -Raw
        $orchestrator | Should -Match "'-on-error=run-cleanup-provisioner'"
    }
}

Describe 'Get-LabEvidenceOutcome' {

    BeforeAll {
        function WriteBoth {
            param([string] $Directory, [string] $RunId, [string] $InstallOutcome = 'passed', [string] $ValidateOutcome = 'passed')
            WriteEvidence -Directory $Directory -Phase 'install' -Outcome $InstallOutcome -RunId $RunId
            WriteEvidence -Directory $Directory -Phase 'validate' -Outcome $ValidateOutcome -RunId $RunId
        }
    }

    It 'reports passed only when both phases are present and passed' {
        $dir = NewTempDir; $runId = Get-RunIdentifier
        WriteBoth -Directory $dir -RunId $runId
        (Get-LabEvidenceOutcome -EvidenceDirectory $dir -RunId $runId -PackerExitCode 0).Outcome | Should -Be 'passed'
    }

    It 'refuses to conclude anything from an install-only result' {
        # The defect this replaced: any non-empty subset counted, so a run that
        # never validated anything could report that everything validated.
        $dir = NewTempDir; $runId = Get-RunIdentifier
        WriteEvidence -Directory $dir -Phase 'install' -Outcome 'passed' -RunId $runId

        $verdict = Get-LabEvidenceOutcome -EvidenceDirectory $dir -RunId $runId -PackerExitCode 0
        $verdict.Outcome | Should -Be 'incomplete'
        $verdict.Reason | Should -Be 'evidence_missing'
    }

    It 'reports incomplete when no evidence was retrieved' {
        $runId = Get-RunIdentifier
        (Get-LabEvidenceOutcome -EvidenceDirectory (NewTempDir) -RunId $runId -PackerExitCode 0).Reason |
            Should -Be 'evidence_missing'
    }

    It 'reports failed when a phase failed' {
        $dir = NewTempDir; $runId = Get-RunIdentifier
        WriteBoth -Directory $dir -RunId $runId -ValidateOutcome 'failed'
        (Get-LabEvidenceOutcome -EvidenceDirectory $dir -RunId $runId -PackerExitCode 200).Outcome | Should -Be 'failed'
    }

    It 'reports incomplete when a phase was incomplete, even beside a pass' {
        $dir = NewTempDir; $runId = Get-RunIdentifier
        WriteBoth -Directory $dir -RunId $runId -InstallOutcome 'incomplete'
        (Get-LabEvidenceOutcome -EvidenceDirectory $dir -RunId $runId -PackerExitCode 200).Outcome | Should -Be 'incomplete'
    }

    It 'refuses evidence belonging to another run' {
        $dir = NewTempDir; $runId = Get-RunIdentifier
        WriteBoth -Directory $dir -RunId (Get-RunIdentifier)
        (Get-LabEvidenceOutcome -EvidenceDirectory $dir -RunId $runId -PackerExitCode 0).Reason |
            Should -Be 'evidence_run_id_mismatch'
    }

    It 'refuses malformed evidence' {
        $dir = NewTempDir; $runId = Get-RunIdentifier
        WriteEvidence -Directory $dir -Phase 'validate' -Outcome 'passed' -RunId $runId
        '{ not json' | Set-Content -LiteralPath (Join-Path $dir 'install-guest-evidence.json') -Encoding utf8
        (Get-LabEvidenceOutcome -EvidenceDirectory $dir -RunId $runId -PackerExitCode 0).Reason |
            Should -Be 'evidence_malformed'
    }

    It 'refuses evidence of the wrong kind' {
        $dir = NewTempDir; $runId = Get-RunIdentifier
        WriteEvidence -Directory $dir -Phase 'validate' -Outcome 'passed' -RunId $runId
        WriteEvidence -Directory $dir -Phase 'install' -Outcome 'passed' -RunId $runId -Kind 'source-qualification'
        (Get-LabEvidenceOutcome -EvidenceDirectory $dir -RunId $runId -PackerExitCode 0).Reason |
            Should -BeIn @('evidence_wrong_kind', 'evidence_malformed')
    }

    It 'refuses a phase whose evidence describes a different phase' {
        $dir = NewTempDir; $runId = Get-RunIdentifier
        WriteEvidence -Directory $dir -Phase 'validate' -Outcome 'passed' -RunId $runId
        WriteEvidence -Directory $dir -Phase 'install' -Outcome 'passed' -RunId $runId -DeclaredPhase 'validate'
        (Get-LabEvidenceOutcome -EvidenceDirectory $dir -RunId $runId -PackerExitCode 0).Reason |
            Should -Be 'phase_missing'
    }

    It 'treats an unexpected packer exit code as inconclusive' {
        # Only the accepted logical-result code is conclusive. Anything else means
        # the harness itself failed, whatever the evidence happens to say.
        $dir = NewTempDir; $runId = Get-RunIdentifier
        WriteBoth -Directory $dir -RunId $runId -ValidateOutcome 'failed'
        (Get-LabEvidenceOutcome -EvidenceDirectory $dir -RunId $runId -PackerExitCode 1).Reason |
            Should -Be 'packer_failed'
    }

    It 'treats a non-zero exit beside a clean pass as inconclusive' {
        $dir = NewTempDir; $runId = Get-RunIdentifier
        WriteBoth -Directory $dir -RunId $runId
        (Get-LabEvidenceOutcome -EvidenceDirectory $dir -RunId $runId -PackerExitCode 200).Reason |
            Should -Be 'packer_failed'
    }

    It 'accepts an install-only record when the run halted before the restart' {
        # A halted run stops deliberately, so its missing validate evidence is
        # designed behavior rather than a gap.
        $dir = NewTempDir; $runId = Get-RunIdentifier
        WriteEvidence -Directory $dir -Phase 'install' -Outcome 'incomplete' -RunId $runId
        $verdict = Get-LabEvidenceOutcome -EvidenceDirectory $dir -RunId $runId -PackerExitCode 200 -RequireValidatePhase $false
        $verdict.Outcome | Should -Be 'incomplete'
        $verdict.Reason | Should -Not -Be 'evidence_missing'
    }
}

Describe 'Get-LabOrchestrationEvidence' {

    BeforeAll {
        function PassingVerdict {
            [PSCustomObject]@{
                Outcome = 'passed'; Reason = $null; PackerExitCode = 0
                Phases = @([PSCustomObject]@{ phase = 'install'; outcome = 'passed'; failedRequiredCount = 0 },
                           [PSCustomObject]@{ phase = 'validate'; outcome = 'passed'; failedRequiredCount = 0 })
            }
        }
    }

    It 'records both cleanup outcomes in schema-valid evidence' {
        # Cleanup used to be console output only, and host cleanup errors were
        # suppressed entirely. An outcome nobody records is one nobody can audit.
        $evidence = Get-LabOrchestrationEvidence -RunId (Get-RunIdentifier) -Verdict (PassingVerdict) `
            -HostCleanupOutcome 'removed' -GuestCleanupOutcome 'removed' -StartedUtc ([datetime]::UtcNow)

        $evidence.resultKind | Should -Be 'build-orchestration'
        $evidence.resultSchemaVersion | Should -Be 2
        $evidence.payload.hostCleanupOutcome | Should -Be 'removed'
        $evidence.payload.guestCleanupOutcome | Should -Be 'removed'
        $evidence.payload.phases.Count | Should -Be 2
    }

    It 'reports incomplete when <side> cleanup failed, whatever the phases said' -ForEach @(
        # Not named $host: that is an automatic variable holding the PowerShell
        # host object, and shadowing it breaks the case rather than the code.
        @{ side = 'host';  hostOutcome = 'failed'; guestOutcome = 'removed' }
        @{ side = 'guest'; hostOutcome = 'removed'; guestOutcome = 'failed' }
    ) {
        $evidence = Get-LabOrchestrationEvidence -RunId (Get-RunIdentifier) -Verdict (PassingVerdict) `
            -HostCleanupOutcome $hostOutcome -GuestCleanupOutcome $guestOutcome -StartedUtc ([datetime]::UtcNow)

        $evidence.outcome | Should -Be 'incomplete'
        $evidence.payload.terminalReasonCode | Should -Be 'cleanup_failed'
    }

    It 'records that cleanup was never attempted, rather than implying it succeeded' {
        $evidence = Get-LabOrchestrationEvidence -RunId (Get-RunIdentifier) -Verdict (PassingVerdict) `
            -HostCleanupOutcome 'not-attempted' -GuestCleanupOutcome 'not-attempted' -StartedUtc ([datetime]::UtcNow)
        $evidence.payload.guestCleanupOutcome | Should -Be 'not-attempted'
    }
}
