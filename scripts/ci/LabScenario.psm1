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

Export-ModuleMember -Function Get-LabScenario, Set-LabBundleTampering
