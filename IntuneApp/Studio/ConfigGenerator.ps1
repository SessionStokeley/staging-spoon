#Requires -Version 5.1
<#
    ConfigGenerator.ps1

    Serializes a configuration model into a valid PowerShell data file (.psd1).

    The .psd1 is the contract between the interactive wizard and the packaging
    engine. Everything downstream derives from it, so this serializer must emit
    literals that Import-PowerShellDataFile can always read back.

    Headless: no UI dependencies. Dot-source and call ConvertTo-Psd1String.
#>

Set-StrictMode -Version Latest

function ConvertTo-Psd1Literal {
    <#
        Converts a single value to its PowerShell literal representation.
        Strings are single-quoted (no subexpression evaluation on read-back).
    #>
    param($Value)

    if ($null -eq $Value) { return '$null' }

    if ($Value -is [bool]) { return $(if ($Value) { '$true' } else { '$false' }) }

    if ($Value -is [int] -or $Value -is [long] -or $Value -is [int16] -or
        $Value -is [byte] -or $Value -is [uint32] -or $Value -is [uint64]) {
        return $Value.ToString([System.Globalization.CultureInfo]::InvariantCulture)
    }

    if ($Value -is [double] -or $Value -is [decimal] -or $Value -is [single]) {
        return $Value.ToString([System.Globalization.CultureInfo]::InvariantCulture)
    }

    if ($Value -is [scriptblock]) {
        # Script blocks are only legal in a .psd1 when the caller opts out of
        # restricted parsing. Emit as-is; the validator flags the implication.
        return "{$($Value.ToString())}"
    }

    # Everything else serializes as a single-quoted string.
    $text = [string]$Value
    return "'" + $text.Replace("'", "''") + "'"
}

function Test-Psd1IsEnumerable {
    param($Value)
    if ($null -eq $Value) { return $false }
    if ($Value -is [string]) { return $false }
    if ($Value -is [System.Collections.IDictionary]) { return $false }
    return ($Value -is [System.Collections.IEnumerable])
}

function ConvertTo-Psd1String {
    <#
        .SYNOPSIS
        Renders a hashtable / ordered dictionary as .psd1 source text.

        .PARAMETER InputObject
        The model to serialize. Hashtables, ordered dictionaries, arrays and
        scalars are supported.

        .PARAMETER Comments
        Optional map of dotted key paths to comment text, e.g.
        @{ 'Installer.Arguments' = 'Silent switches for this installer' }
        Comments are emitted on the line above the key.

        .PARAMETER IndentLevel
        Current nesting depth. Callers normally leave this at 0.

        .PARAMETER Path
        Current dotted path, used to look up comments. Internal.
    #>
    param(
        # AllowNull is required: a $null member must serialize as '$null'
        # rather than being rejected by parameter binding.
        [AllowNull()]
        $InputObject,

        [hashtable]$Comments = @{},

        [int]$IndentLevel = 0,

        [string]$Path = ''
    )

    $pad = ' ' * (4 * $IndentLevel)
    $padInner = ' ' * (4 * ($IndentLevel + 1))

    # --- Dictionary ---
    if ($InputObject -is [System.Collections.IDictionary]) {
        if ($InputObject.Count -eq 0) { return '@{}' }

        $sb = [System.Text.StringBuilder]::new()
        [void]$sb.AppendLine('@{')

        # Align the '=' for readability within this block.
        $keys = @($InputObject.Keys)
        $maxKeyLength = ($keys | ForEach-Object { ([string]$_).Length } | Measure-Object -Maximum).Maximum
        if (-not $maxKeyLength) { $maxKeyLength = 0 }

        foreach ($key in $keys) {
            $keyText = [string]$key
            $childPath = if ($Path) { "$Path.$keyText" } else { $keyText }

            if ($Comments.ContainsKey($childPath)) {
                foreach ($line in ($Comments[$childPath] -split "`n")) {
                    [void]$sb.AppendLine("$padInner# $($line.TrimEnd())")
                }
            }

            $value = $InputObject[$key]
            $rendered = ConvertTo-Psd1String -InputObject $value `
                -Comments $Comments -IndentLevel ($IndentLevel + 1) -Path $childPath

            $paddedKey = $keyText.PadRight($maxKeyLength)
            [void]$sb.AppendLine("$padInner$paddedKey = $rendered")
        }

        [void]$sb.Append("$pad}")
        return $sb.ToString()
    }

    # --- Array ---
    if (Test-Psd1IsEnumerable $InputObject) {
        $items = @($InputObject)
        if ($items.Count -eq 0) { return '@()' }

        # Arrays of scalars stay on one line when they are short enough.
        $allScalar = -not ($items | Where-Object {
            ($_ -is [System.Collections.IDictionary]) -or (Test-Psd1IsEnumerable $_)
        })

        if ($allScalar) {
            $rendered = $items | ForEach-Object { ConvertTo-Psd1Literal $_ }
            $oneLine = '@(' + ($rendered -join ', ') + ')'
            if ($oneLine.Length -le 70) { return $oneLine }
        }

        $sb = [System.Text.StringBuilder]::new()
        [void]$sb.AppendLine('@(')
        foreach ($item in $items) {
            $rendered = ConvertTo-Psd1String -InputObject $item `
                -Comments $Comments -IndentLevel ($IndentLevel + 1) -Path $Path
            [void]$sb.AppendLine("$padInner$rendered")
        }
        [void]$sb.Append("$pad)")
        return $sb.ToString()
    }

    # --- Scalar ---
    return ConvertTo-Psd1Literal $InputObject
}

function New-Psd1Header {
    param(
        [string]$ApplicationName = 'Application',
        [string]$GeneratedBy = 'Intune Packaging Studio - Interactive Configuration Generator'
    )

    $stamp = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
    return @"
<#
    $ApplicationName - Intune Win32 package configuration

    Generated by : $GeneratedBy
    Generated on : $stamp

    This file is the source of truth for the package. Install.ps1,
    Uninstall.ps1 and Detection.ps1 all read their behavior from here.
    Edit this file directly, or re-open it in the Studio.
#>

"@
}

function Export-ConfigurationFile {
    <#
        .SYNOPSIS
        Writes a configuration model to disk as a .psd1 file.

        .PARAMETER Model
        The configuration model (ordered dictionary).

        .PARAMETER Path
        Destination .psd1 path.

        .PARAMETER NoHeader
        Omit the generated comment header.

        .PARAMETER PassThru
        Return the generated text instead of only the path.
    #>
    param(
        [Parameter(Mandatory)]
        $Model,

        [Parameter(Mandatory)]
        [string]$Path,

        [hashtable]$Comments = @{},

        [switch]$NoHeader,

        [switch]$PassThru
    )

    $appName = 'Application'
    if ($Model -is [System.Collections.IDictionary] -and $Model.Contains('ApplicationName')) {
        $appName = [string]$Model['ApplicationName']
    }

    $body = ConvertTo-Psd1String -InputObject $Model -Comments $Comments
    $text = if ($NoHeader) { $body } else { (New-Psd1Header -ApplicationName $appName) + $body }
    $text = $text + [Environment]::NewLine

    $dir = Split-Path -Parent $Path
    if ($dir -and -not (Test-Path $dir)) {
        New-Item -Path $dir -ItemType Directory -Force | Out-Null
    }

    # UTF-8 without BOM keeps Import-PowerShellDataFile and Git diffs happy.
    $encoding = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($Path, $text, $encoding)

    if ($PassThru) { return $text }
    return $Path
}

function Show-Psd1Content {
    <#
        .SYNOPSIS
        Prints .psd1 source with light syntax colouring and line numbers.

        .DESCRIPTION
        The technician must be able to read the exact file that will drive the
        package, not a prettified summary of it. This renders the real content.
    #>
    param(
        [Parameter(Mandatory, ParameterSetName = 'Path')][string]$Path,
        [Parameter(Mandatory, ParameterSetName = 'Text')][string]$Text,
        [switch]$NoLineNumbers
    )

    if ($PSCmdlet.ParameterSetName -eq 'Path') {
        if (-not (Test-Path -LiteralPath $Path)) {
            Write-Host "File not found: $Path" -ForegroundColor Red
            return
        }
        $Text = Get-Content -LiteralPath $Path -Raw
    }

    $lineNumber = 0
    foreach ($line in ($Text -split "`r?`n")) {
        $lineNumber++
        $prefix = if ($NoLineNumbers) { '' } else { '{0,4} | ' -f $lineNumber }

        $trimmed = $line.TrimStart()

        # Comments and block-comment bodies.
        if ($trimmed.StartsWith('#') -or $trimmed.StartsWith('<#') -or
            $trimmed.StartsWith('#>') -or $trimmed -eq '#>') {
            Write-Host "$prefix$line" -ForegroundColor DarkGreen
            continue
        }

        # key = value, the common case: colour the key and the value differently.
        if ($line -match '^(\s*)([A-Za-z_][A-Za-z0-9_]*)(\s*)(=)(\s*)(.*)$') {
            $indent = $Matches[1]; $key = $Matches[2]
            $gap = $Matches[3]; $spacer = $Matches[5]; $value = $Matches[6]

            Write-Host $prefix -NoNewline
            Write-Host "$indent$key" -NoNewline -ForegroundColor Cyan
            Write-Host "$gap=$spacer" -NoNewline -ForegroundColor Gray

            $valueColor =
                if ($value -match "^'")                      { 'Yellow' }
                elseif ($value -match '^\$(true|false|null)') { 'Magenta' }
                elseif ($value -match '^-?\d')               { 'Magenta' }
                elseif ($value -match '^@[({]')              { 'White' }
                else                                          { 'Gray' }

            Write-Host $value -ForegroundColor $valueColor
            continue
        }

        # Structural lines.
        if ($trimmed -match '^[@({\[]|^[)}\]]') {
            Write-Host "$prefix$line" -ForegroundColor White
            continue
        }

        Write-Host "$prefix$line" -ForegroundColor Gray
    }
}

function Test-Psd1Syntax {
    <#
        .SYNOPSIS
        Parses .psd1 text and reports syntax errors without executing it.
    #>
    param(
        [Parameter(Mandatory, ParameterSetName = 'Text')]
        [AllowEmptyString()]
        [string]$Text,

        [Parameter(Mandatory, ParameterSetName = 'Path')]
        [string]$Path
    )

    if ($PSCmdlet.ParameterSetName -eq 'Path') {
        if (-not (Test-Path $Path)) {
            return [pscustomobject]@{ Valid = $false; Errors = @("File not found: $Path") }
        }
        $Text = Get-Content -LiteralPath $Path -Raw
    }

    $tokens = $null
    $parseErrors = $null
    try {
        [System.Management.Automation.Language.Parser]::ParseInput(
            $Text, [ref]$tokens, [ref]$parseErrors) | Out-Null
    }
    catch {
        return [pscustomobject]@{ Valid = $false; Errors = @($_.Exception.Message) }
    }

    if ($parseErrors -and $parseErrors.Count -gt 0) {
        $messages = $parseErrors | ForEach-Object {
            "Line $($_.Extent.StartLineNumber): $($_.Message)"
        }
        return [pscustomobject]@{ Valid = $false; Errors = @($messages) }
    }

    return [pscustomobject]@{ Valid = $true; Errors = @() }
}
