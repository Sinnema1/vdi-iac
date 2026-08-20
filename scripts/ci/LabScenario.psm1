#Requires -Version 7.0

<#
.SYNOPSIS
    The three Level 3 lab scenarios ADR 3 requires, and the tampering they apply.

.DESCRIPTION
    A positive run proves the pieces connect. The two negative runs prove the
    controls refuse content, and they defeat different ones:

    Payload tampering alters a package after host verification and leaves the
    descriptor alone, so the per-package hash comparison catches it.

    Descriptor tampering rewrites the descriptor *and* the payload hashes to
    match, so every in-bundle check passes. Only the digest delivered out of band
    catches that, which is why a suite testing only the first case would report
    success while the interesting attack goes unexercised.

    The tampering functions are separated from the runner so they can be tested
    without a target: a scenario whose tampering silently did nothing would
    otherwise pass for the wrong reason.
#>

Set-StrictMode -Version 3.0

$script:Scenarios = @{
    'positive' = [PSCustomObject]@{
        Name              = 'positive'
        Description       = 'Every package verifies, installs, and validates.'
        Tamper            = 'none'
        ExpectedOutcome   = 'passed'
        ExpectInstalled   = $true
        ExpectedReasonCode = $null
    }
    'payload-tamper' = [PSCustomObject]@{
        Name              = 'payload-tamper'
        Description       = 'A payload is altered after host qualification. Guest verification refuses it before the installer runs.'
        Tamper            = 'payload'
        ExpectedOutcome   = 'failed'
        ExpectInstalled   = $false
        ExpectedReasonCode = 'integrity_mismatch'
    }
    'descriptor-tamper' = [PSCustomObject]@{
        Name              = 'descriptor-tamper'
        Description       = 'The descriptor and the payload hashes are rewritten together, so every in-bundle check passes. Only the out-of-band digest refuses it.'
        Tamper            = 'descriptor'
        ExpectedOutcome   = 'incomplete'
        ExpectInstalled   = $false
        ExpectedReasonCode = 'descriptor_digest_mismatch'
    }
}

function Get-LabScenario {
    <#
    .SYNOPSIS
        Returns one scenario definition, or every one of them.
    #>
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param(
        [Parameter()] [ValidateSet('positive','payload-tamper','descriptor-tamper')] [string] $Name
    )

    if ($Name) { return $script:Scenarios[$Name] }
    $script:Scenarios.Values | Sort-Object Name
}

function Set-LabBundleTampering {
    <#
    .SYNOPSIS
        Applies a scenario's tampering to an assembled bundle.

    .DESCRIPTION
        Applied after New-TransferBundle has verified everything, which is the
        point: it simulates content altered in transit, between the host proving
        a payload is what the manifest said and the guest receiving it.

    .OUTPUTS
        The digest a caller should present to the guest. For descriptor
        tampering this is deliberately the *original* digest -- the attacker
        cannot change what the orchestrator already delivered out of band, and
        that mismatch is the control being tested.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)] [ValidateNotNullOrEmpty()] [string] $BundlePath,
        [Parameter(Mandatory)] [ValidateNotNullOrEmpty()] [string] $OriginalDigest,
        [Parameter(Mandatory)] [ValidateSet('none','payload','descriptor')] [string] $Tamper
    )

    if ($Tamper -eq 'none') { return $OriginalDigest }
    if (-not $PSCmdlet.ShouldProcess($BundlePath, "Apply $Tamper tampering")) { return $OriginalDigest }

    $descriptorPath = Join-Path $BundlePath 'descriptor.json'
    $descriptor = Get-Content -LiteralPath $descriptorPath -Raw | ConvertFrom-Json

    $payloadPath = $BundlePath
    foreach ($segment in $descriptor.packages[0].payloadPath.Split('/')) {
        if ($segment) { $payloadPath = Join-Path $payloadPath $segment }
    }
    if (-not (Test-Path -LiteralPath $payloadPath -PathType Leaf)) {
        throw "Cannot tamper: the bundle has no payload at '$($descriptor.packages[0].payloadPath)'."
    }

    Add-Content -LiteralPath $payloadPath -Value 'tampered' -Encoding utf8

    if ($Tamper -eq 'payload') {
        # Descriptor untouched, so its recorded hash no longer matches the file.
        return $OriginalDigest
    }

    # Rewrite the descriptor so it describes the altered payload. Every in-bundle
    # check now passes, and only the out-of-band digest disagrees.
    $descriptor.packages[0].sha256 = (Get-FileHash -LiteralPath $payloadPath -Algorithm SHA256).Hash.ToLowerInvariant()
    $descriptor | ConvertTo-Json -Depth 16 | Set-Content -LiteralPath $descriptorPath -Encoding utf8

    $OriginalDigest
}

function Get-LabScenarioObservation {
    <#
    .SYNOPSIS
        Reads what actually happened, from schema-validated guest evidence.

    .DESCRIPTION
        A scenario asserted only on its overall outcome passes for the wrong
        reason: 'incomplete' is reachable through missing evidence or a failed
        cleanup, neither of which is the control under test. The bounded reason
        code and the installer attempt count come from the evidence itself.

    .OUTPUTS
        ReasonCode and InstallerAttemptCount. Both null or zero when no guest
        evidence was retrieved, which a caller must treat as a failed scenario
        rather than a satisfied expectation.
    #>
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param(
        [Parameter(Mandatory)] [ValidateNotNullOrEmpty()] [string] $EvidenceDirectory,
        [Parameter(Mandatory)] [ValidateNotNullOrEmpty()] [string] $RunId
    )

    $schema = Join-Path $PSScriptRoot '..' '..' 'contracts' 'evidence-envelope-2.schema.json'
    $reasonCode = $null
    $attempts = 0

    foreach ($name in 'install-guest-evidence.json', 'validate-guest-evidence.json') {
        $path = Join-Path $EvidenceDirectory $name
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { continue }

        $raw = Get-Content -LiteralPath $path -Raw -Encoding utf8
        if (-not (Test-Json -Json $raw -SchemaFile $schema -ErrorAction SilentlyContinue)) { continue }

        $evidence = $raw | ConvertFrom-Json
        if ($evidence.runId -cne $RunId) { continue }
        if ($evidence.resultKind -ne 'guest-provisioning') { continue }

        if ($evidence.payload.PSObject.Properties.Name -contains 'installerAttemptCount') {
            $attempts += [int] $evidence.payload.installerAttemptCount
        }

        # The first bounded reason found, package-level before phase-level: a
        # package refusal names the control that fired.
        if (-not $reasonCode) {
            $failed = @($evidence.payload.packages | Where-Object { $_.reasonCode }) | Select-Object -First 1
            if ($failed) { $reasonCode = $failed.reasonCode }
            elseif ($evidence.payload.terminalReasonCode) { $reasonCode = $evidence.payload.terminalReasonCode }
        }
    }

    [PSCustomObject]@{ ReasonCode = $reasonCode; InstallerAttemptCount = $attempts }
}

function Get-LabScenarioVerdict {
    <#
    .SYNOPSIS
        Decides whether a scenario ended as it was defined to.

    .DESCRIPTION
        The production decision, used by the runner and by its tests. A test-only
        copy of this logic proves the copy works: the runner could diverge from it
        silently, which is the class of defect these scenarios exist to catch.

    .OUTPUTS
        Passed, plus the specific failures when it did not.
    #>
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param(
        [Parameter(Mandatory)] $Definition,
        [Parameter(Mandatory)] [ValidateNotNullOrEmpty()] [string] $Outcome,
        [Parameter()] [AllowNull()] [string] $ObservedReasonCode,
        [Parameter(Mandatory)] [int] $InstallerAttemptCount,
        [Parameter(Mandatory)] [ValidateNotNullOrEmpty()] [string] $HostCleanupOutcome,
        [Parameter(Mandatory)] [ValidateNotNullOrEmpty()] [string] $GuestCleanupOutcome
    )

    $failures = [System.Collections.Generic.List[string]]::new()

    if ($Outcome -ne $Definition.ExpectedOutcome) {
        $failures.Add("outcome was '$Outcome', expected '$($Definition.ExpectedOutcome)'")
    }

    # An outcome alone cannot carry a negative scenario: 'incomplete' is reachable
    # through missing evidence or a failed cleanup, neither of which is the
    # control under test.
    if ($Definition.ExpectedReasonCode -and $ObservedReasonCode -ne $Definition.ExpectedReasonCode) {
        $failures.Add("reason code was '$ObservedReasonCode', expected '$($Definition.ExpectedReasonCode)'")
    }

    # A count from evidence, not an inference from output: an installer that
    # started and then failed has still started.
    $installerRan = $InstallerAttemptCount -gt 0
    if ($installerRan -ne $Definition.ExpectInstalled) {
        $failures.Add("installer attempts were $InstallerAttemptCount, expected installed: $($Definition.ExpectInstalled)")
    }

    # These scenarios run against a healthy communicator, so cleanup succeeding is
    # part of what they assert.
    if ($HostCleanupOutcome -ne 'removed') { $failures.Add("host cleanup was '$HostCleanupOutcome', expected 'removed'") }
    if ($GuestCleanupOutcome -ne 'removed') { $failures.Add("guest cleanup was '$GuestCleanupOutcome', expected 'removed'") }

    [PSCustomObject]@{ Passed = ($failures.Count -eq 0); Failures = @($failures) }
}

Export-ModuleMember -Function Get-LabScenario, Set-LabBundleTampering, Get-LabScenarioObservation, Get-LabScenarioVerdict
