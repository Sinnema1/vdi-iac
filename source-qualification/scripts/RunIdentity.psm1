#Requires -Version 7.0

<#
.SYNOPSIS
    Validates run identifiers and reserves the directories they name.

.DESCRIPTION
    A run identifier correlates evidence across host qualification, transfer, and
    guest provisioning, so it is supplied by the orchestrator rather than
    invented per stage (ADR 5).

    It also names staging directories on both host and guest, and those
    directories are later removed recursively. That makes it a confinement
    concern rather than a formatting one: an arbitrary caller-supplied string is
    a path-traversal vector into a recursive delete. Validation happens before
    the value reaches any path.

    Syntax is not uniqueness. A well-formed identifier can still be one already
    used -- a retried run, a copy-pasted value, a caller with a fixed identifier
    in a script -- and reuse would point two runs at one directory. Directories
    are therefore reserved with create-or-fail rather than create-if-missing.
#>

Set-StrictMode -Version 3.0

# Canonical lowercase UUID. Uppercase is refused rather than normalized: a
# caller that produced the wrong form should hear about it, and two spellings of
# one identifier make evidence harder to correlate, not easier.
# \A and \z, not ^ and $. In .NET, $ also matches immediately before a trailing
# newline, so a pattern anchored with $ accepts "<uuid>\n" -- which would then be
# interpolated into a path. \z is the absolute end of the string.
$script:RunIdentifierPattern = '\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z'

function Get-RunIdentifier {
    <#
    .SYNOPSIS
        Returns a new canonical run identifier.

    .NOTES
        Named Get- rather than New-: it creates no resource and changes no state,
        and a state-changing verb would require ShouldProcess for a function that
        has nothing to confirm.

    .DESCRIPTION
        For a stage invoked standalone. When a run spans stages, the orchestrator
        generates one and passes it down.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param()

    [guid]::NewGuid().ToString().ToLowerInvariant()
}

function Assert-RunIdentifier {
    <#
    .SYNOPSIS
        Refuses anything that is not a canonical lowercase UUID.

    .OUTPUTS
        The identifier, so a caller can validate and assign in one step.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)] [AllowEmptyString()] [AllowNull()] [string] $RunId
    )

    if ([string]::IsNullOrWhiteSpace($RunId)) {
        throw 'Run identifier is empty. It must be a canonical lowercase UUID.'
    }
    if ($RunId -cnotmatch $script:RunIdentifierPattern) {
        # -cnotmatch, because a case-insensitive comparison would accept the
        # uppercase form this rejects on purpose.
        throw "Run identifier '$RunId' is not a canonical lowercase UUID."
    }
    $RunId
}

function New-RunDirectory {
    <#
    .SYNOPSIS
        Reserves the directory a run identifier names, or fails.

    .DESCRIPTION
        Creation is create-or-fail. An existing directory is never adopted: it
        belongs to another run, and this one would later delete it recursively.

    .PARAMETER Root
        Parent directory. Created if absent, since the parent is shared and its
        prior existence says nothing about this run.

    .PARAMETER RunId
        Validated before it reaches the path.

    .PARAMETER Prefix
        Distinguishes concurrent directories belonging to one run, for example a
        staging directory and a bundle directory.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)] [ValidateNotNullOrEmpty()] [string] $Root,
        [Parameter(Mandatory)] [ValidateNotNullOrEmpty()] [string] $RunId,
        [Parameter()] [ValidatePattern('^[a-z0-9-]{1,32}$')] [string] $Prefix = 'run'
    )

    $validated = Assert-RunIdentifier -RunId $RunId

    if (-not (Test-Path -LiteralPath $Root -PathType Container)) {
        $null = New-Item -ItemType Directory -Path $Root -Force
    }

    $path = Join-Path $Root "$Prefix-$validated"
    if (-not $PSCmdlet.ShouldProcess($path, 'Reserve run directory')) {
        return $path
    }

    try {
        # Deliberately without -Force: it would adopt an existing directory,
        # which is the collision this exists to detect.
        $null = New-Item -ItemType Directory -Path $path -ErrorAction Stop
    }
    catch {
        if (Test-Path -LiteralPath $path) {
            $exception = [System.Exception]::new("Run directory '$path' already exists. Refusing to reuse a run identifier.")
            $exception.Data['ReasonCode'] = 'run_id_collision'
            throw $exception
        }
        throw
    }

    $path
}

Export-ModuleMember -Function Get-RunIdentifier, Assert-RunIdentifier, New-RunDirectory
