#Requires -Version 5.1

<#
    Psd1.ps1

    Reading and writing the .psd1 configuration.

    Reading has to work on Windows PowerShell 5.1, which is what Intune's
    Management Extension runs. Import-PowerShellDataFile evaluates a .psd1
    through ScriptBlockAst.SafeGetValue(); PowerShell 7 added script-block
    support to that evaluator and 5.1 has none, so a configuration containing a
    script-block literal fails to load there - and because the failure is in the
    loader it takes the whole file with it, not just the section that used one.

    Import-Psd1 therefore falls back to reading the file's syntax tree when the
    native loader refuses it. The fallback parses; it never executes, so a
    configuration cannot run code merely by being loaded.

    No Set-StrictMode: dot-sourcing applies it to the caller's scope, which
    would make a legitimately absent optional key throw in the scripts that
    consume this.
#>

function Get-ScriptBlockBody {
    <#
        Returns the source inside a script block, without its braces.

        Braces are stripped through the syntax tree rather than by trimming
        characters, because trimming is wrong: '{@{Type=1}}' loses both closing
        braces and yields unbalanced source.

        Import-PowerShellDataFile returns a script block that WRAPS the one
        written in the file, so its body is the literal text '{ ... }' and
        invoking it yields another script block rather than running the code.
        Nested wrappers are unwrapped first for that reason.
    #>
    param([Parameter(Mandatory)]$ScriptBlockAst)

    $current = $ScriptBlockAst
    while ($true) {
        if ($current -isnot [System.Management.Automation.Language.ScriptBlockAst]) { break }
        if (-not $current.EndBlock) { break }

        $statements = @($current.EndBlock.Statements)
        if ($statements.Count -ne 1) { break }
        if ($statements[0] -isnot [System.Management.Automation.Language.PipelineAst]) { break }

        $elements = @($statements[0].PipelineElements)
        if ($elements.Count -ne 1) { break }
        if ($elements[0] -isnot [System.Management.Automation.Language.CommandExpressionAst]) { break }

        $expression = $elements[0].Expression
        if ($expression -isnot [System.Management.Automation.Language.ScriptBlockExpressionAst]) { break }
        $current = $expression.ScriptBlock
    }

    if ($current -is [System.Management.Automation.Language.ScriptBlockAst] -and $current.EndBlock) {
        return [string]$current.EndBlock.Extent.Text
    }
    return ''
}

function ConvertFrom-Psd1Ast {
    <#
        Converts a .psd1 expression tree into plain data, matching what
        Import-PowerShellDataFile produces: Hashtable, Object[], String, Int32,
        Boolean, $null. A script-block literal becomes its source text.
    #>
    param([Parameter(Mandatory)][System.Management.Automation.Language.Ast]$Ast)

    $node = $Ast

    while ($node -is [System.Management.Automation.Language.ConvertExpressionAst] -or
           $node -is [System.Management.Automation.Language.ParenExpressionAst]) {
        if ($node -is [System.Management.Automation.Language.ConvertExpressionAst]) { $node = $node.Child }
        else { $node = $node.Pipeline }
    }

    if ($node -is [System.Management.Automation.Language.PipelineAst]) {
        $elements = @($node.PipelineElements)
        if ($elements.Count -ne 1) {
            throw "Unsupported expression at line $($node.Extent.StartLineNumber): $($node.Extent.Text)"
        }
        $node = $elements[0].Expression
    }
    if ($node -is [System.Management.Automation.Language.CommandExpressionAst]) { $node = $node.Expression }

    if ($node -is [System.Management.Automation.Language.ScriptBlockExpressionAst]) {
        return Get-ScriptBlockBody -ScriptBlockAst $node.ScriptBlock
    }

    if ($node -is [System.Management.Automation.Language.HashtableAst]) {
        $result = @{}
        foreach ($pair in $node.KeyValuePairs) {
            $key = ConvertFrom-Psd1Ast -Ast $pair.Item1
            $result[[string]$key] = ConvertFrom-Psd1Ast -Ast $pair.Item2
        }
        return $result
    }

    if ($node -is [System.Management.Automation.Language.ArrayLiteralAst]) {
        $items = @()
        foreach ($element in $node.Elements) { $items += , (ConvertFrom-Psd1Ast -Ast $element) }
        return , $items
    }

    if ($node -is [System.Management.Automation.Language.ArrayExpressionAst]) {
        $items = @()
        foreach ($statement in $node.SubExpression.Statements) {
            $value = ConvertFrom-Psd1Ast -Ast $statement
            if ($null -ne $value -and $value -isnot [string] -and
                $value -is [System.Collections.IEnumerable] -and
                $value -isnot [System.Collections.IDictionary]) {
                foreach ($inner in $value) { $items += , $inner }
            }
            else { $items += , $value }
        }
        return , $items
    }

    if ($node -is [System.Management.Automation.Language.StringConstantExpressionAst]) { return $node.Value }
    if ($node -is [System.Management.Automation.Language.ConstantExpressionAst]) { return $node.Value }

    if ($node -is [System.Management.Automation.Language.VariableExpressionAst]) {
        $name = [string]$node.VariablePath.UserPath
        if ($name -eq 'true')  { return $true }
        if ($name -eq 'false') { return $false }
        if ($name -eq 'null')  { return $null }
        throw "A configuration may not reference `$$name (line $($node.Extent.StartLineNumber))."
    }

    if ($node -is [System.Management.Automation.Language.UnaryExpressionAst]) {
        $operand = ConvertFrom-Psd1Ast -Ast $node.Child
        if ($node.TokenKind -eq [System.Management.Automation.Language.TokenKind]::Minus) { return -$operand }
        if ($node.TokenKind -eq [System.Management.Automation.Language.TokenKind]::Plus)  { return $operand }
    }

    throw "Unsupported expression at line $($node.Extent.StartLineNumber): $($node.Extent.Text)"
}

function Import-Psd1 {
    <#
        .SYNOPSIS
        Loads a .psd1 on any PowerShell version.

        .PARAMETER Strict
        Skip the native loader and always read the syntax tree. This is how the
        test suite exercises the 5.1 path from PowerShell 7, whose native
        loader is too permissive to reproduce the failure.
    #>
    param(
        [Parameter(Mandatory)][string]$Path,
        [switch]$Strict
    )

    if (-not (Test-Path -LiteralPath $Path)) { throw "Configuration file not found: $Path" }

    $nativeError = ''
    if (-not $Strict) {
        try { return Import-PowerShellDataFile -LiteralPath $Path -ErrorAction Stop }
        catch { $nativeError = $_.Exception.Message }
    }

    $tokens = $null
    $parseErrors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$tokens, [ref]$parseErrors)

    if ($parseErrors -and @($parseErrors).Count -gt 0) {
        $first = @($parseErrors)[0]
        throw "Configuration does not parse: $($first.Message) (line $($first.Extent.StartLineNumber))"
    }

    $hashtable = $ast.Find({
        param($n) $n -is [System.Management.Automation.Language.HashtableAst]
    }, $false)

    if (-not $hashtable) { throw "Configuration contains no hashtable: $Path" }

    try { return ConvertFrom-Psd1Ast -Ast $hashtable }
    catch {
        if ($nativeError) {
            throw "Could not load the configuration. PowerShell reported: $nativeError. Reading it directly also failed: $($_.Exception.Message)"
        }
        throw
    }
}

function ConvertTo-Psd1Literal {
    <#
        A single value as .psd1 source. Strings are single-quoted, so nothing
        is evaluated when the file is read back.
    #>
    param($Value)

    if ($null -eq $Value) { return '$null' }
    if ($Value -is [bool]) { if ($Value) { return '$true' } else { return '$false' } }

    if ($Value -is [int] -or $Value -is [long] -or $Value -is [int16] -or
        $Value -is [byte] -or $Value -is [uint32] -or $Value -is [uint64] -or
        $Value -is [double] -or $Value -is [decimal] -or $Value -is [single]) {
        return $Value.ToString([System.Globalization.CultureInfo]::InvariantCulture)
    }

    return "'" + ([string]$Value).Replace("'", "''") + "'"
}

function ConvertTo-Psd1Text {
    <#
        .SYNOPSIS
        Renders a hashtable as readable .psd1 source.

        .PARAMETER Comments
        Map of dotted key paths to comment text, emitted above the key.
    #>
    param(
        [AllowNull()]$InputObject,
        [hashtable]$Comments = @{},
        [int]$IndentLevel = 0,
        [string]$Path = ''
    )

    $pad = ' ' * (4 * $IndentLevel)
    $padInner = ' ' * (4 * ($IndentLevel + 1))

    if ($InputObject -is [System.Collections.IDictionary]) {
        if ($InputObject.Count -eq 0) { return '@{}' }

        $builder = [System.Text.StringBuilder]::new()
        [void]$builder.AppendLine('@{')

        $keys = @($InputObject.Keys)
        $widest = 0
        foreach ($key in $keys) { if (([string]$key).Length -gt $widest) { $widest = ([string]$key).Length } }

        foreach ($key in $keys) {
            $keyText = [string]$key
            $childPath = if ($Path) { "$Path.$keyText" } else { $keyText }

            if ($Comments.ContainsKey($childPath)) {
                foreach ($line in ($Comments[$childPath] -split "`n")) {
                    [void]$builder.AppendLine("$padInner# $($line.TrimEnd())")
                }
            }

            $rendered = ConvertTo-Psd1Text -InputObject $InputObject[$key] -Comments $Comments `
                -IndentLevel ($IndentLevel + 1) -Path $childPath
            [void]$builder.AppendLine("$padInner$($keyText.PadRight($widest)) = $rendered")
        }

        [void]$builder.Append("$pad}")
        return $builder.ToString()
    }

    $isList = ($null -ne $InputObject) -and ($InputObject -isnot [string]) -and
              ($InputObject -is [System.Collections.IEnumerable])

    if ($isList) {
        $items = @($InputObject)
        if ($items.Count -eq 0) { return '@()' }

        $allScalar = $true
        foreach ($item in $items) {
            if ($item -is [System.Collections.IDictionary]) { $allScalar = $false; break }
        }

        if ($allScalar) {
            $rendered = @()
            foreach ($item in $items) { $rendered += ConvertTo-Psd1Literal $item }
            return '@(' + ($rendered -join ', ') + ')'
        }

        $builder = [System.Text.StringBuilder]::new()
        [void]$builder.AppendLine('@(')
        foreach ($item in $items) {
            $rendered = ConvertTo-Psd1Text -InputObject $item -Comments $Comments `
                -IndentLevel ($IndentLevel + 1) -Path $Path
            [void]$builder.AppendLine("$padInner$rendered")
        }
        [void]$builder.Append("$pad)")
        return $builder.ToString()
    }

    return ConvertTo-Psd1Literal $InputObject
}

function Test-Psd1Syntax {
    <#
        Reports whether a file parses, and whether it loads on 5.1 without the
        syntax-tree fallback. A $false LoadsOn51 is not a failure - it means
        the file needs the fallback, which Import-Psd1 applies automatically.
    #>
    param([Parameter(Mandatory)][string]$Path)

    $tokens = $null
    $parseErrors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$tokens, [ref]$parseErrors)

    $errors = @()
    foreach ($e in @($parseErrors)) {
        $errors += "Line $($e.Extent.StartLineNumber): $($e.Message)"
    }
    if ($errors.Count -gt 0) {
        return @{ Valid = $false; LoadsOn51 = $false; Errors = $errors }
    }

    $unsafe = @($ast.FindAll({
        param($n)
        $n -is [System.Management.Automation.Language.ScriptBlockExpressionAst] -or
        $n -is [System.Management.Automation.Language.SubExpressionAst]
    }, $true))

    $reasons = @()
    foreach ($node in $unsafe) {
        $reasons += "Line $($node.Extent.StartLineNumber): Windows PowerShell 5.1 cannot load this from a .psd1."
    }

    return @{ Valid = $true; LoadsOn51 = ($reasons.Count -eq 0); Errors = $reasons }
}
