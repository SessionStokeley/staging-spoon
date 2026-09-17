#Requires -Version 5.1

<#
    ConfigLoader.ps1

    Loads Configuration.psd1 in a way that works identically on Windows
    PowerShell 5.1 and PowerShell 7, and resolves Custom detection into an
    executable script block.

    Why this exists
    ---------------
    Import-PowerShellDataFile evaluates a .psd1 through
    ScriptBlockAst.SafeGetValue(). PowerShell 7 added script-block support to
    that evaluator; Windows PowerShell 5.1 did not have it, and rejects a
    script-block literal outright. A configuration containing

        Detection = @{ Type = 'Custom'; ScriptBlock = { ... } }

    therefore fails to load on 5.1 - and because the failure is in the loader,
    it takes the *whole* configuration with it, not just custom detection.
    Intune's Management Extension runs 5.1, which is precisely where it breaks.

    Two changes address that:

      1. The canonical way to express custom detection is now a string
         (Detection.Script) or a path to a .ps1 (Detection.ScriptFile). Both
         are ordinary .psd1 literals that 5.1 reads without complaint.

      2. Configurations that still use the script-block form keep working.
         When the native loader refuses a file, Import-PackageConfiguration
         re-reads it from the syntax tree and converts each script-block
         literal to its source text. Nothing that used to work stops working.

    On trust
    --------
    Resolve-DetectionScript compiles configuration text into a script block.
    That is not a new trust boundary: Configuration.psd1 ships inside the same
    .intunewin as Install.ps1 and is authored by the same person. Anyone who
    can change the configuration can already change the scripts that run it.
#>

# No Set-StrictMode here on purpose. Dot-sourcing applies it to the *caller's*
# scope, so setting it would silently impose Latest on Detection.ps1,
# Install.ps1 and Uninstall.ps1 - where a legitimately absent optional key such
# as Detection.MinimumVersion would start throwing. Helpers/Environment.ps1
# follows the same rule; the Studio modules set it because their entry points
# expect it.

function Get-SoleScriptBlockExpression {
    <#
        Returns the inner script block when a script block's entire body is
        one script-block literal, otherwise $null.

        Import-PowerShellDataFile wraps a .psd1 script-block value in another
        script block, so the value's body is the literal text '{ ... }'.
        Invoking it therefore yields a *script block* rather than running the
        code inside - see Get-ScriptBlockAstBody.
    #>
    param([Parameter(Mandatory)]$ScriptBlockAst)

    if ($ScriptBlockAst -isnot [System.Management.Automation.Language.ScriptBlockAst]) { return $null }
    if (-not $ScriptBlockAst.EndBlock) { return $null }

    $statements = @($ScriptBlockAst.EndBlock.Statements)
    if ($statements.Count -ne 1) { return $null }
    if ($statements[0] -isnot [System.Management.Automation.Language.PipelineAst]) { return $null }

    $elements = @($statements[0].PipelineElements)
    if ($elements.Count -ne 1) { return $null }
    if ($elements[0] -isnot [System.Management.Automation.Language.CommandExpressionAst]) { return $null }

    $expression = $elements[0].Expression
    if ($expression -isnot [System.Management.Automation.Language.ScriptBlockExpressionAst]) { return $null }

    return $expression.ScriptBlock
}

function Get-ScriptBlockAstBody {
    <#
        .SYNOPSIS
        Returns the source text inside a script block, without its braces.

        .DESCRIPTION
        The braces are stripped through the syntax tree rather than by trimming
        characters. Trimming is wrong: '{@{Type=1}}' trims both closing braces
        and yields unbalanced source.

        Nested single-expression wrappers are unwrapped first, because that is
        the shape Import-PowerShellDataFile produces and the reason custom
        detection returned a script block instead of a verdict.
    #>
    param([Parameter(Mandatory)]$ScriptBlockAst)

    $current = $ScriptBlockAst
    while ($true) {
        $inner = Get-SoleScriptBlockExpression -ScriptBlockAst $current
        if (-not $inner) { break }
        $current = $inner
    }

    if (-not $current.EndBlock) { return '' }
    return [string]$current.EndBlock.Extent.Text
}

function ConvertFrom-ConfigAst {
    <#
        .SYNOPSIS
        Converts a .psd1 expression tree into plain data.

        .DESCRIPTION
        Mirrors what Import-PowerShellDataFile produces - Hashtable, Object[],
        String, Int32, Boolean, $null - with one deliberate difference: a
        script-block literal becomes its source text rather than a
        [scriptblock]. Resolve-DetectionScript accepts either form, so the
        difference is invisible downstream.

        Unordered Hashtable (not [ordered]) is returned on purpose, so the
        Studio's key-ordering and save-stability behaviour is identical
        whichever loader ran.
    #>
    param(
        [Parameter(Mandatory)]
        [System.Management.Automation.Language.Ast]$Ast
    )

    $node = $Ast

    # [ordered]@{...} and other casts: the payload is what matters.
    while ($node -is [System.Management.Automation.Language.ConvertExpressionAst] -or
           $node -is [System.Management.Automation.Language.ParenExpressionAst]) {
        if ($node -is [System.Management.Automation.Language.ConvertExpressionAst]) {
            $node = $node.Child
        }
        else {
            $node = $node.Pipeline
        }
    }

    # A parenthesised expression unwraps to a pipeline; take its expression.
    if ($node -is [System.Management.Automation.Language.PipelineAst]) {
        $elements = @($node.PipelineElements)
        if ($elements.Count -ne 1) {
            throw "Unsupported expression in configuration at line $($node.Extent.StartLineNumber): $($node.Extent.Text)"
        }
        $node = $elements[0].Expression
    }
    if ($node -is [System.Management.Automation.Language.CommandExpressionAst]) {
        $node = $node.Expression
    }

    # --- Script block: the whole reason this loader exists ---
    if ($node -is [System.Management.Automation.Language.ScriptBlockExpressionAst]) {
        return Get-ScriptBlockAstBody -ScriptBlockAst $node.ScriptBlock
    }

    # --- Hashtable ---
    if ($node -is [System.Management.Automation.Language.HashtableAst]) {
        $result = @{}
        foreach ($pair in $node.KeyValuePairs) {
            $key = ConvertFrom-ConfigAst -Ast $pair.Item1
            $result[[string]$key] = ConvertFrom-ConfigAst -Ast $pair.Item2
        }
        return $result
    }

    # --- Arrays ---
    if ($node -is [System.Management.Automation.Language.ArrayLiteralAst]) {
        $items = @()
        foreach ($element in $node.Elements) { $items += , (ConvertFrom-ConfigAst -Ast $element) }
        return , $items
    }

    if ($node -is [System.Management.Automation.Language.ArrayExpressionAst]) {
        $items = @()
        foreach ($statement in $node.SubExpression.Statements) {
            $value = ConvertFrom-ConfigAst -Ast $statement
            # A single statement may itself have produced an array literal.
            if ($null -ne $value -and $value -isnot [string] -and
                $value -is [System.Collections.IEnumerable] -and
                $value -isnot [System.Collections.IDictionary]) {
                foreach ($inner in $value) { $items += , $inner }
            }
            else {
                $items += , $value
            }
        }
        return , $items
    }

    # --- Literals ---
    if ($node -is [System.Management.Automation.Language.StringConstantExpressionAst]) {
        return $node.Value
    }

    if ($node -is [System.Management.Automation.Language.ConstantExpressionAst]) {
        return $node.Value
    }

    # $true / $false / $null
    if ($node -is [System.Management.Automation.Language.VariableExpressionAst]) {
        $name = $node.VariablePath.UserPath
        if ($name -eq 'true')  { return $true }
        if ($name -eq 'false') { return $false }
        if ($name -eq 'null')  { return $null }
        throw "Configuration may not reference the variable `$$name (line $($node.Extent.StartLineNumber))."
    }

    # Negative numbers parse as a unary expression.
    if ($node -is [System.Management.Automation.Language.UnaryExpressionAst]) {
        $operand = ConvertFrom-ConfigAst -Ast $node.Child
        if ($node.TokenKind -eq [System.Management.Automation.Language.TokenKind]::Minus) { return -$operand }
        if ($node.TokenKind -eq [System.Management.Automation.Language.TokenKind]::Plus)  { return $operand }
        throw "Unsupported operator in configuration at line $($node.Extent.StartLineNumber): $($node.Extent.Text)"
    }

    throw "Unsupported expression in configuration at line $($node.Extent.StartLineNumber): $($node.Extent.Text)"
}

function Import-PackageConfiguration {
    <#
        .SYNOPSIS
        Loads a Configuration.psd1 on any PowerShell version.

        .DESCRIPTION
        Uses Import-PowerShellDataFile when it works, which is the common case
        and keeps behaviour identical to every previous release. When the
        native loader refuses the file - on 5.1 that is almost always a
        script-block literal - the file is re-read from its syntax tree
        instead.

        The fallback parses; it never executes. A configuration cannot run code
        by being loaded.

        .PARAMETER Path
        The .psd1 to read.

        .PARAMETER Strict
        Skip the native loader and always use the syntax-tree reader. This is
        how the test suite exercises the 5.1 path from PowerShell 7, where the
        native loader is too permissive to reproduce the failure.
    #>
    param(
        [Parameter(Mandatory)][string]$Path,
        [switch]$Strict
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        throw "Configuration file not found: $Path"
    }

    if (-not $Strict) {
        try {
            return Import-PowerShellDataFile -LiteralPath $Path -ErrorAction Stop
        }
        catch {
            # Fall through. The reason is re-reported below if the tree reader
            # also fails, so nothing is swallowed.
            $nativeError = $_.Exception.Message
        }
    }

    $tokens = $null
    $parseErrors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$tokens, [ref]$parseErrors)

    if ($parseErrors -and @($parseErrors).Count -gt 0) {
        $first = @($parseErrors)[0]
        throw "Configuration.psd1 does not parse: $($first.Message) (line $($first.Extent.StartLineNumber))"
    }

    $hashtableAst = $ast.Find(
        {
            param($n)
            $n -is [System.Management.Automation.Language.HashtableAst]
        },
        $false)

    if (-not $hashtableAst) {
        throw "Configuration.psd1 does not contain a hashtable."
    }

    try {
        return ConvertFrom-ConfigAst -Ast $hashtableAst
    }
    catch {
        if (-not $Strict -and $nativeError) {
            throw "Configuration.psd1 could not be loaded. PowerShell reported: $nativeError. Reading it directly also failed: $($_.Exception.Message)"
        }
        throw
    }
}

function Get-PackageConfiguration {
    <#
        .SYNOPSIS
        Loads the configuration that sits beside a package's scripts.

        .DESCRIPTION
        The single place Install, Uninstall and Detection read their
        configuration, so all three behave identically on every runtime.

        Setting INTUNE_FORCE_PS51_LOADER makes the syntax-tree reader run even
        where the native loader would have succeeded. That is how the test
        suite exercises the Windows PowerShell 5.1 path end to end from
        PowerShell 7, whose native loader is too permissive to reproduce it.
    #>
    param(
        [Parameter(Mandatory)][string]$PackageRoot,
        [string]$FileName = 'Configuration.psd1'
    )

    $path = Join-Path $PackageRoot $FileName
    $forceTreeReader = [bool]$env:INTUNE_FORCE_PS51_LOADER
    return Import-PackageConfiguration -Path $path -Strict:$forceTreeReader
}

function Test-ConfigurationLoadsOnPS51 {
    <#
        .SYNOPSIS
        Reports whether a .psd1 loads natively under Windows PowerShell 5.1.

        .DESCRIPTION
        5.1's loader rejects any construct its restricted evaluator does not
        implement. The two that occur in practice are a script-block literal
        and an interpolated string. Both are found here by inspecting the
        syntax tree, so the answer is the same on any platform - this does not
        need 5.1 to run.

        A $false result is not a failure. It means the file needs the
        syntax-tree reader, which Import-PackageConfiguration falls back to
        automatically. It is reported so the Studio can steer new
        configurations towards the form that needs no fallback.

        Returns @{ Loads = <bool>; Reasons = <string[]> }.
    #>
    param([Parameter(Mandatory)][string]$Path)

    $tokens = $null
    $parseErrors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$tokens, [ref]$parseErrors)

    $reasons = @()

    if ($parseErrors -and @($parseErrors).Count -gt 0) {
        foreach ($e in @($parseErrors)) {
            $reasons += "Parse error on line $($e.Extent.StartLineNumber): $($e.Message)"
        }
        return @{ Loads = $false; Reasons = $reasons }
    }

    $unsafe = $ast.FindAll(
        {
            param($n)
            $n -is [System.Management.Automation.Language.ScriptBlockExpressionAst] -or
            $n -is [System.Management.Automation.Language.ExpandableStringExpressionAst] -or
            $n -is [System.Management.Automation.Language.SubExpressionAst]
        },
        $true)

    foreach ($node in @($unsafe)) {
        if ($node -is [System.Management.Automation.Language.ScriptBlockExpressionAst]) {
            $reasons += "Line $($node.Extent.StartLineNumber): a script block literal. Windows PowerShell 5.1 cannot load one from a .psd1. Use Script (a string) or ScriptFile (a path) instead."
        }
        elseif ($node -is [System.Management.Automation.Language.ExpandableStringExpressionAst]) {
            # Only flag genuine interpolation; "plain text" in double quotes is fine.
            if (@($node.NestedExpressions).Count -gt 0) {
                $reasons += "Line $($node.Extent.StartLineNumber): an interpolated string. Use a single-quoted literal."
            }
        }
        else {
            $reasons += "Line $($node.Extent.StartLineNumber): a subexpression. A .psd1 may only contain literals."
        }
    }

    return @{ Loads = (@($reasons).Count -eq 0); Reasons = $reasons }
}

function Resolve-DetectionScript {
    <#
        .SYNOPSIS
        Turns a Custom detection configuration into an executable script block.

        .DESCRIPTION
        Accepts, in order of preference:

          ScriptFile   a path to a .ps1. Relative paths resolve against the
                       package root, so a detection script ships in the
                       .intunewin alongside Detection.ps1.
          Script       inline PowerShell source, as a string.
          ScriptBlock  the original form. A real [scriptblock] when the native
                       loader ran, or its source text when the syntax-tree
                       reader did. Both are handled.

        Returns $null when none is configured; the caller reports that, since
        only it knows how to exit.

        .PARAMETER PackageRoot
        Directory that a relative ScriptFile resolves against.
    #>
    param(
        [Parameter(Mandatory)][AllowNull()]$Detection,
        [string]$PackageRoot = '.'
    )

    if ($null -eq $Detection) { return $null }

    $getField = {
        param($name)
        if ($Detection -is [System.Collections.IDictionary]) {
            if ($Detection.Contains($name)) { return $Detection[$name] }
            return $null
        }
        $p = $Detection.PSObject.Properties[$name]
        if ($p) { return $p.Value }
        return $null
    }

    $scriptFile = & $getField 'ScriptFile'
    if ($scriptFile) {
        $resolved = [string]$scriptFile
        if (-not [System.IO.Path]::IsPathRooted($resolved)) {
            $resolved = Join-Path $PackageRoot $resolved
        }
        if (-not (Test-Path -LiteralPath $resolved)) {
            throw "Detection.ScriptFile was not found: $resolved"
        }
        $text = Get-Content -LiteralPath $resolved -Raw
        return [scriptblock]::Create($text)
    }

    $inline = & $getField 'Script'
    if ($inline) {
        return [scriptblock]::Create([string]$inline)
    }

    $legacy = & $getField 'ScriptBlock'
    if ($legacy) {
        # A [scriptblock] here came from Import-PowerShellDataFile, whose body
        # is the literal '{ ... }'. Invoking it directly returns a script block
        # - which is always truthy, so detection reported every application as
        # installed. Rebuild from the unwrapped source instead.
        if ($legacy -is [scriptblock]) {
            return [scriptblock]::Create((Get-ScriptBlockAstBody -ScriptBlockAst $legacy.Ast))
        }
        return [scriptblock]::Create([string]$legacy)
    }

    return $null
}
