<#
.SYNOPSIS
    Parsing and comparison of Intune install/uninstall/detection commands.
.DESCRIPTION
    The command configured in Intune must be reproducible locally. These
    helpers resolve a command's target file and normalise commands so the
    tested command can be compared against the production command.
#>

Set-StrictMode -Version Latest

# Arguments that force or permit an interactive UI. A SYSTEM-context install
# has no interactive desktop, so these hang the deployment.
$script:InteractiveArguments = @(
    @{ Pattern = '(?<![\w/-])/qf(?![\w])';       Reason = 'msiexec full UI' }
    @{ Pattern = '(?<![\w/-])/qr(?![\w])';       Reason = 'msiexec reduced UI' }
    @{ Pattern = '(?<![\w/-])/qb(?![\w])';       Reason = 'msiexec basic UI' }
    @{ Pattern = '(?<![\w/-])/interactive(?![\w])'; Reason = 'explicit interactive mode' }
    @{ Pattern = '(?<![\w/-])/prompt(?![\w])';   Reason = 'prompts for input' }
    @{ Pattern = '(?<![\w-])-Wait\s*$';          Reason = 'trailing -Wait with no process to wait on' }
    @{ Pattern = '(?<![\w/-])/passive(?![\w])';  Reason = 'displays a progress UI' }
    @{ Pattern = '(?<![\w-])-NoExit(?![\w])';    Reason = 'PowerShell will not terminate' }
    @{ Pattern = '(?<![\w/-])/showui(?![\w])';   Reason = 'displays installer UI' }
)

function ConvertFrom-CommandLine {
    <#
    .SYNOPSIS
        Splits a command line into an executable and argument tokens,
        honouring double-quoted segments.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$CommandLine)

    $tokens = [System.Collections.Generic.List[string]]::new()
    $current = [System.Text.StringBuilder]::new()
    $inQuotes = $false

    foreach ($char in $CommandLine.ToCharArray()) {
        if ($char -eq '"') {
            $inQuotes = -not $inQuotes
            continue
        }
        if ($char -match '\s' -and -not $inQuotes) {
            if ($current.Length -gt 0) {
                $tokens.Add($current.ToString())
                $current.Clear() | Out-Null
            }
            continue
        }
        $current.Append($char) | Out-Null
    }
    if ($current.Length -gt 0) { $tokens.Add($current.ToString()) }

    if ($tokens.Count -eq 0) {
        throw "Command line is empty"
    }

    [PSCustomObject]@{
        Executable = $tokens[0]
        Arguments  = if ($tokens.Count -gt 1) { $tokens[1..($tokens.Count - 1)] } else { @() }
        Raw        = $CommandLine
    }
}

function Resolve-CommandTarget {
    <#
    .SYNOPSIS
        Resolves the payload file a command will actually execute.
    .DESCRIPTION
        For a PowerShell wrapper this is the -File argument; for a direct
        installer invocation it is the executable itself. Returns the path
        resolved against the package root, plus whether it exists.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$CommandLine,
        [Parameter(Mandatory)][string]$PackagePath
    )

    $parsed = ConvertFrom-CommandLine -CommandLine $CommandLine
    $target = $null
    $kind   = 'Executable'

    # A PowerShell wrapper's real payload is the -File argument.
    for ($i = 0; $i -lt $parsed.Arguments.Count; $i++) {
        if ($parsed.Arguments[$i] -match '^-(File|f)$' -and ($i + 1) -lt $parsed.Arguments.Count) {
            $target = $parsed.Arguments[$i + 1]
            $kind   = 'Script'
            break
        }
    }

    # msiexec's payload is the /i or /x operand.
    if (-not $target) {
        for ($i = 0; $i -lt $parsed.Arguments.Count; $i++) {
            if ($parsed.Arguments[$i] -match '^/(i|x|package)$' -and ($i + 1) -lt $parsed.Arguments.Count) {
                $target = $parsed.Arguments[$i + 1]
                $kind   = 'MSI'
                break
            }
            if ($parsed.Arguments[$i] -match '^/(i|x)(.+\.msi)$') {
                $target = $Matches[2]
                $kind   = 'MSI'
                break
            }
        }
    }

    if (-not $target) {
        $target = $parsed.Executable
        $kind   = 'Executable'
    }

    $normalized = $target -replace '^\.[\\/]', ''
    $isSystemExecutable = $normalized -match '^[\w.]+\.(exe|com)$' -and
                          $normalized -notmatch '[\\/]' -and
                          $kind -eq 'Executable'

    $resolvedPath = if ($isSystemExecutable) {
        $normalized
    } else {
        Join-Path -Path $PackagePath -ChildPath $normalized
    }

    [PSCustomObject]@{
        CommandLine        = $CommandLine
        Executable         = $parsed.Executable
        Target             = $normalized
        TargetKind         = $kind
        ResolvedPath       = $resolvedPath
        IsSystemExecutable = $isSystemExecutable
        Exists             = if ($isSystemExecutable) { $true } else { Test-Path -LiteralPath $resolvedPath -PathType Leaf }
    }
}

function Find-InteractiveArgument {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$CommandLine)

    $findings = [System.Collections.Generic.List[PSCustomObject]]::new()

    foreach ($entry in $script:InteractiveArguments) {
        if ($CommandLine -match $entry.Pattern) {
            $findings.Add([PSCustomObject]@{
                Argument = $Matches[0]
                Reason   = $entry.Reason
            })
        }
    }

    $findings.ToArray()
}

function Find-DuplicateArgument {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$CommandLine)

    $parsed = ConvertFrom-CommandLine -CommandLine $CommandLine

    # Only switches can meaningfully duplicate; operands legitimately repeat.
    $switches = @($parsed.Arguments | Where-Object { $_ -match '^[-/]' })

    $switches |
        Group-Object -NoElement |
        Where-Object { $_.Count -gt 1 } |
        ForEach-Object {
            [PSCustomObject]@{
                Argument = $_.Name
                Count    = $_.Count
            }
        }
}

function Get-NormalizedCommand {
    <#
    .SYNOPSIS
        Normalises a command for equality comparison.
    .DESCRIPTION
        Collapses whitespace and casing so that only meaningful differences
        surface when comparing a tested command to a production command.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$CommandLine)

    ($CommandLine -replace '\s+', ' ').Trim().ToLowerInvariant()
}

function Compare-IntuneCommand {
    <#
    .SYNOPSIS
        Compares the validated command against the command destined for Intune.
    .DESCRIPTION
        Implements the Intune command sanity check: if the tested command and
        the production command differ, the package is not production ready.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$TestedCommand,
        [Parameter(Mandatory)][AllowEmptyString()][string]$IntuneCommand,
        [Parameter(Mandatory)][string]$CommandType
    )

    $matches = (Get-NormalizedCommand -CommandLine $TestedCommand) -eq
               (Get-NormalizedCommand -CommandLine $IntuneCommand)

    [PSCustomObject]@{
        CommandType   = $CommandType
        TestedCommand = $TestedCommand
        IntuneCommand = $IntuneCommand
        Matches       = $matches
        Message       = if ($matches) {
            "$CommandType command matches the validated command"
        } else {
            "WARNING: PRODUCTION CONFIGURATION DOES NOT MATCH VALIDATED CONFIGURATION ($CommandType)"
        }
    }
}
