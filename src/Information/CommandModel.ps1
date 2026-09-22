<#
.SYNOPSIS
    Commands as structure, not as opaque strings.
.DESCRIPTION
    A command stored as one string has to be re-parsed by everything that
    touches it, and every re-parse is a chance to lose a quote or double an
    argument. Commands are held as an executable plus an argument list, and the
    string Intune receives is rendered from that structure once, at the end.
#>

Set-StrictMode -Version Latest

function New-StructuredCommand {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Executable,
        [string[]]$Arguments = @(),
        [string]$WorkingDirectory = '',
        [ValidateSet('System', 'User')][string]$Context = 'System',
        [hashtable]$Environment = @{}
    )

    [PSCustomObject]@{
        Executable       = $Executable
        Arguments        = @($Arguments)
        WorkingDirectory = $WorkingDirectory
        Context          = $Context
        Environment      = $Environment
    }
}

function ConvertTo-CommandString {
    <#
    .SYNOPSIS
        Renders a structured command as the exact string to run.
    .DESCRIPTION
        An argument is quoted only when it contains whitespace and is not
        already quoted. Quoting an argument that carries its own quotes is how
        paths end up double-wrapped and silently wrong.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][PSCustomObject]$Command)

    $parts = [System.Collections.Generic.List[string]]::new()
    $parts.Add((Format-CommandToken -Token $Command.Executable))

    foreach ($argument in @($Command.Arguments)) {
        if ($null -eq $argument) { continue }
        $parts.Add((Format-CommandToken -Token $argument))
    }

    $parts -join ' '
}

function Format-CommandToken {
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Token)

    if ([string]::IsNullOrEmpty($Token)) { return '""' }
    if ($Token.StartsWith('"') -and $Token.EndsWith('"') -and $Token.Length -gt 1) { return $Token }
    if ($Token -match '\s') { return '"' + $Token + '"' }

    $Token
}

function New-PowerShellScriptCommand {
    <#
    .SYNOPSIS
        The canonical way to invoke a packaged script under Intune.
    .DESCRIPTION
        -NonInteractive matters as much as -NoProfile: Intune runs with no
        desktop, and a script that stops for input hangs until the deployment
        times out.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ScriptName,
        [string[]]$ScriptArguments = @()
    )

    $relative = if ($ScriptName.StartsWith('.\') -or $ScriptName.StartsWith('.//')) {
        $ScriptName
    } else {
        ".\$ScriptName"
    }

    # The path is not pre-quoted. Quoting is left to the renderer, which adds
    # quotes only when the value contains whitespace. Quotes around a path that
    # does not need them survive into every layer that later re-parses the
    # command, and cmd.exe in particular strips the outermost pair of a /c
    # string, which turns a correctly quoted argument into an unbalanced one.
    $arguments = @(
        '-NoProfile'
        '-ExecutionPolicy', 'Bypass'
        '-NonInteractive'
        '-File', $relative
    ) + $ScriptArguments

    New-StructuredCommand -Executable 'powershell.exe' -Arguments $arguments
}

function New-MsiInstallCommand {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$InstallerFileName,
        [string[]]$AdditionalArguments = @(),
        [string]$LogPath = ''
    )

    $arguments = @('/i', "`"$InstallerFileName`"", '/qn', '/norestart') + $AdditionalArguments
    if ($LogPath) { $arguments += @('/l*v', "`"$LogPath`"") }

    New-StructuredCommand -Executable 'msiexec.exe' -Arguments $arguments
}

function New-MsiUninstallCommand {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$ProductCode)

    New-StructuredCommand -Executable 'msiexec.exe' -Arguments @('/x', $ProductCode, '/qn', '/norestart')
}

function ConvertFrom-CommandString {
    <#
    .SYNOPSIS
        Recovers structure from a command string, for values that arrive from a
        previous build or from a user who pasted one in.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowEmptyString()][string]$CommandLine)

    if ([string]::IsNullOrWhiteSpace($CommandLine)) {
        return New-StructuredCommand -Executable ''
    }

    $tokens = [System.Collections.Generic.List[string]]::new()
    $current = [System.Text.StringBuilder]::new()
    $inQuotes = $false

    foreach ($char in $CommandLine.ToCharArray()) {
        if ($char -eq '"') {
            $inQuotes = -not $inQuotes
            [void]$current.Append($char)
            continue
        }

        if ($char -eq ' ' -and -not $inQuotes) {
            if ($current.Length -gt 0) {
                $tokens.Add($current.ToString())
                [void]$current.Clear()
            }
            continue
        }

        [void]$current.Append($char)
    }

    if ($current.Length -gt 0) { $tokens.Add($current.ToString()) }
    if ($tokens.Count -eq 0) { return New-StructuredCommand -Executable '' }

    $executable = $tokens[0].Trim('"')
    $arguments  = if ($tokens.Count -gt 1) { $tokens[1..($tokens.Count - 1)] } else { @() }

    New-StructuredCommand -Executable $executable -Arguments $arguments
}

function Test-StructuredCommand {
    <#
    .SYNOPSIS
        Checks a command for the mistakes that survive review and fail in
        production: repeated switches, interactive flags, and a -File argument
        that points nowhere.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][PSCustomObject]$Command,
        [string]$ContentDirectory = ''
    )

    $problems = [System.Collections.Generic.List[string]]::new()

    if ([string]::IsNullOrWhiteSpace($Command.Executable)) {
        $problems.Add('Command has no executable')
    }

    $switches = @(
        foreach ($argument in @($Command.Arguments)) {
            if ($argument -match '^[-/]') { $argument.ToLowerInvariant() }
        }
    )

    $duplicates = @($switches | Group-Object | Where-Object { $_.Count -gt 1 })
    foreach ($duplicate in $duplicates) {
        $problems.Add("Duplicate argument: $($duplicate.Name)")
    }

    $interactive = @('/qb', '/qr', '/qf', '/qn+', '/passive', '/interactive', '-noexit', '/promptrestart')
    foreach ($argument in @($Command.Arguments)) {
        if ($argument.ToLowerInvariant() -in $interactive) {
            $problems.Add("Argument requires a desktop session Intune will not have: $argument")
        }
    }

    if ($Command.Executable -match 'powershell' -and '-NonInteractive' -notin @($Command.Arguments)) {
        $problems.Add('PowerShell command is missing -NonInteractive')
    }

    if ($ContentDirectory) {
        $arguments = @($Command.Arguments)
        for ($index = 0; $index -lt $arguments.Count - 1; $index++) {
            if ($arguments[$index] -ne '-File') { continue }

            $scriptPath = $arguments[$index + 1].Trim('"')
            $resolved = Join-Path $ContentDirectory ($scriptPath -replace '^\.\\', '')
            if (-not (Test-Path -LiteralPath $resolved)) {
                $problems.Add("Command targets a script that is not in the package: $scriptPath")
            }
        }
    }

    [PSCustomObject]@{
        IsValid  = $problems.Count -eq 0
        Problems = $problems.ToArray()
    }
}
