#Requires -Version 5.1

<#
    InstallerArguments.ps1

    Decides which installer arguments are used, and builds the one command line
    that actually runs.

    The separation
    --------------
    Configuration.psd1 keeps Installer.Arguments so a package has a
    reproducible local test. Installer.ArgumentSource decides whether those
    arguments are what a given execution uses:

      Configuration  Installer.Arguments is authoritative. This is the default,
                     and what every configuration written before ArgumentSource
                     existed means.
      Intune         The arguments come from the Intune Program command, passed
                     to Install.ps1. Installer.Arguments is then local-test
                     material only and is never sent to the installer.
      None           The installer is launched with no arguments at all.

    The invariant
    -------------
    Exactly one source is authoritative per execution. Arguments are never
    merged, never appended, and never quietly fall back to the other source.
    A configuration that asks for one source while supplying the other is a
    configuration error and is refused - silently picking one would produce an
    installer command nobody wrote.

    Quoting
    -------
    Windows splits a process command line with CommandLineToArgvW, where a
    backslash run before a quote is halved and `\"` is a literal quote. So a
    value ending in a backslash, or containing quotes, does not survive being
    typed into the Intune Program command as a quoted parameter:

        -InstallerArguments "INSTALLDIR=C:\Program Files\"

    ends the argument at the escaped quote and swallows what follows. That is a
    property of the Windows command line, not of this framework, and no amount
    of care inside PowerShell repairs it.

    -InstallerArgumentsBase64 therefore exists alongside -InstallerArguments.
    It carries the identical string through a chain that cannot misread it,
    because the encoded form contains no quotes, spaces or backslashes.
    Test-ArgumentQuotingRisk reports when a string needs it, and the Studio
    prints the encoded form so it never has to be produced by hand.
#>

# No Set-StrictMode: dot-sourcing would apply it to the caller's scope. See
# the note in ConfigLoader.ps1.

$script:ValidArgumentSources = @('Configuration', 'Intune', 'None')

# Values matching these are replaced in logs and on screen. Installer command
# lines carry licence keys and service-account passwords often enough that
# printing them unredacted is a real disclosure, and the log is world-readable
# under ProgramData.
$script:SensitiveArgumentPatterns = @(
    '(?i)(PASSWORD|PASSWD|PWD)\s*=\s*("[^"]*"|\S+)',
    '(?i)(TOKEN|APIKEY|API_KEY|SECRET|CLIENTSECRET)\s*=\s*("[^"]*"|\S+)',
    '(?i)(LICENSEKEY|LICENSE_KEY|PIDKEY|SERIALNUMBER|PRODUCTKEY)\s*=\s*("[^"]*"|\S+)',
    '(?i)(/|-{1,2})(p|pass|password|key)[:=]("[^"]*"|\S+)'
)

function Get-ArgumentSourceNames {
    return $script:ValidArgumentSources
}

function ConvertTo-Base64Argument {
    <#
        Encodes an argument string for -InstallerArgumentsBase64.

        UTF8 then base64: the result is alphanumeric plus + / =, none of which
        the Windows command line treats specially.
    #>
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Arguments)
    return [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($Arguments))
}

function ConvertFrom-Base64Argument {
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Encoded)
    if (-not $Encoded) { return '' }
    try {
        return [System.Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($Encoded))
    }
    catch {
        throw "InstallerArgumentsBase64 is not valid base64: $($_.Exception.Message)"
    }
}

function Test-ArgumentQuotingRisk {
    <#
        .SYNOPSIS
        Reports whether an argument string survives the Windows command line
        when typed into the Intune Program command.

        .DESCRIPTION
        Switch-only strings such as '/quiet /norestart' are safe. The two
        constructs that are not:

          * a double quote, which re-delimits the argument
          * a trailing backslash, which escapes the closing quote

        Returns @{ Safe = <bool>; Reasons = <string[]> }. Unsafe does not mean
        broken - it means use -InstallerArgumentsBase64 rather than the raw
        form.
    #>
    param([AllowEmptyString()][string]$Arguments)

    $reasons = @()
    if (-not $Arguments) { return @{ Safe = $true; Reasons = $reasons } }

    if ($Arguments.Contains('"')) {
        $reasons += 'It contains a double quote, which re-delimits the argument when Windows splits the command line.'
    }
    if ($Arguments.TrimEnd().EndsWith('\')) {
        $reasons += 'It ends with a backslash, which escapes the closing quote and swallows the rest of the command line.'
    }
    if ($Arguments.Contains('%')) {
        # Not fatal, but it is expanded if anything in the chain runs through
        # cmd.exe, and the result is then not what was typed.
        $reasons += 'It contains %, which is expanded as an environment variable if the command passes through cmd.exe.'
    }

    return @{ Safe = ($reasons.Count -eq 0); Reasons = $reasons }
}

function Get-RedactedArguments {
    <#
        Replaces the value of anything that looks like a credential, for
        logging and for on-screen output.
    #>
    param(
        [AllowEmptyString()][string]$Arguments,
        [string[]]$AdditionalPatterns = @()
    )

    if (-not $Arguments) { return '' }

    $result = $Arguments
    foreach ($pattern in ($script:SensitiveArgumentPatterns + $AdditionalPatterns)) {
        if (-not $pattern) { continue }
        $result = [regex]::Replace($result, $pattern, {
            param($match)
            # Keep the name so the log still says which argument was supplied,
            # and drop only the value.
            $text = $match.Value
            $separator = if ($text.Contains('=')) { '=' } elseif ($text.Contains(':')) { ':' } else { '' }
            if (-not $separator) { return '***REDACTED***' }
            $name = $text.Substring(0, $text.IndexOf($separator))
            return "$name$separator***REDACTED***"
        })
    }
    return $result
}

function Resolve-InstallerArguments {
    <#
        .SYNOPSIS
        Returns the one authoritative argument string for this execution.

        .DESCRIPTION
        Refuses, rather than guesses, when the configured source and the
        supplied arguments disagree. Every refusal names both sides, because
        the failure is always someone having entered the arguments in the
        wrong place.

        .PARAMETER Override
        An explicit -ArgumentSource, which beats Installer.ArgumentSource. Used
        by Test-Local.ps1 so a technician can test the Configuration arguments
        on a package configured for Intune, without editing the configuration.

        .OUTPUTS
        @{ Source; Arguments; Display; Warnings }
        Display is redacted and safe to print.
    #>
    param(
        [Parameter(Mandatory)][AllowNull()]$Config,
        [string]$Override = '',
        [AllowEmptyString()][string]$IntuneArguments = '',
        [AllowEmptyString()][string]$IntuneArgumentsBase64 = '',
        # Distinguishes "not supplied" from "supplied as empty on purpose".
        [bool]$IntuneArgumentsProvided = $false
    )

    $warnings = @()

    $installer = $null
    if ($Config) {
        if ($Config -is [System.Collections.IDictionary]) {
            if ($Config.Contains('Installer')) { $installer = $Config['Installer'] }
        }
        else {
            $property = $Config.PSObject.Properties['Installer']
            if ($property) { $installer = $property.Value }
        }
    }

    $getField = {
        param($name)
        if ($null -eq $installer) { return $null }
        if ($installer -is [System.Collections.IDictionary]) {
            if ($installer.Contains($name)) { return $installer[$name] }
            return $null
        }
        $p = $installer.PSObject.Properties[$name]
        if ($p) { return $p.Value }
        return $null
    }

    $configuredArguments = [string](& $getField 'Arguments')

    # --- Which source is authoritative -----------------------------------
    $configuredSource = [string](& $getField 'ArgumentSource')
    $source = ''

    if ($Override) { $source = $Override }
    elseif ($configuredSource) { $source = $configuredSource }
    else {
        # Absent means Configuration. That is what every package written
        # before ArgumentSource existed already does.
        $source = 'Configuration'
    }

    $matched = @($script:ValidArgumentSources | Where-Object { $_ -eq $source })
    if ($matched.Count -ne 1) {
        # Case-insensitive second pass, so 'intune' is accepted and normalised.
        $matched = @($script:ValidArgumentSources | Where-Object { $_.ToLower() -eq $source.ToLower() })
    }
    if ($matched.Count -ne 1) {
        throw "Installer.ArgumentSource '$source' is not valid. Use $($script:ValidArgumentSources -join ', ')."
    }
    $source = $matched[0]

    # --- Decode, and refuse two forms of the same thing -------------------
    if ($IntuneArguments -and $IntuneArgumentsBase64) {
        throw 'Both -InstallerArguments and -InstallerArgumentsBase64 were supplied. Pass exactly one: with both present there is no way to tell which was intended.'
    }

    $suppliedArguments = $IntuneArguments
    if ($IntuneArgumentsBase64) {
        $suppliedArguments = ConvertFrom-Base64Argument -Encoded $IntuneArgumentsBase64
        $IntuneArgumentsProvided = $true
    }
    if ($IntuneArguments) { $IntuneArgumentsProvided = $true }

    # --- Apply the invariant ----------------------------------------------
    $effective = ''

    switch ($source) {
        'Configuration' {
            if ($IntuneArgumentsProvided) {
                throw "Installer.ArgumentSource is 'Configuration', but installer arguments were also passed on the command line. Set ArgumentSource to 'Intune' to use the passed arguments, or stop passing them. They are never combined."
            }
            $effective = $configuredArguments
        }

        'Intune' {
            if (-not $IntuneArgumentsProvided) {
                # Falling back to Installer.Arguments here is exactly the
                # silent merge this model exists to prevent, and running a
                # silent installer with no switches under SYSTEM hangs until
                # Intune times out. Refuse instead.
                throw "Installer.ArgumentSource is 'Intune', but no installer arguments were passed. Add -InstallerArguments to the Intune Program command, or set ArgumentSource to 'Configuration' to use Installer.Arguments, or to 'None' if this installer genuinely takes no arguments."
            }
            $effective = $suppliedArguments
            if ($configuredArguments) {
                $warnings += "Installer.Arguments is set but not used: ArgumentSource is 'Intune', so the passed arguments are authoritative. Installer.Arguments remains available for local testing."
            }
        }

        'None' {
            if ($IntuneArgumentsProvided) {
                throw "Installer.ArgumentSource is 'None', but installer arguments were passed. 'None' means the installer is launched with no arguments; change ArgumentSource to 'Intune' to use them."
            }
            $effective = ''
            if ($configuredArguments) {
                $warnings += "Installer.Arguments is set but not used: ArgumentSource is 'None'."
            }
        }
    }

    $redactPattern = [string](& $getField 'RedactArgumentPattern')
    $additional = @()
    if ($redactPattern) { $additional = @($redactPattern) }

    return @{
        Source    = $source
        Arguments = $effective
        Display   = (Get-RedactedArguments -Arguments $effective -AdditionalPatterns $additional)
        Warnings  = $warnings
    }
}

function New-InstallerCommandLine {
    <#
        .SYNOPSIS
        Builds the command that runs, for both installer types.

        .DESCRIPTION
        The single place an installer command line is assembled. Both the dry
        run and the real execution call it, so what a dry run prints is what
        actually runs rather than a second rendering of it - and there is only
        one place duplication could be introduced.

        MSI arguments follow /i "<path>". EXE arguments are the whole tail.

        .OUTPUTS
        @{ FilePath; Arguments; Display }

        Arguments is a single string rather than an array on purpose.
        Start-Process re-quotes each element of an array, which mangles an MSI
        property whose value contains spaces: INSTALLDIR="C:\Program Files\X"
        would arrive at msiexec as a different string than the one configured.

        Arguments is $null when there are none. Start-Process rejects an empty
        -ArgumentList on Windows PowerShell 5.1, so callers omit the parameter
        entirely rather than passing an empty string.
    #>
    param(
        [Parameter(Mandatory)][string]$Type,
        [Parameter(Mandatory)][string]$InstallerPath,
        [AllowEmptyString()][string]$Arguments = '',
        [AllowEmptyString()][string]$DisplayArguments = ''
    )

    $normalizedType = $Type.ToUpper()
    $tail = $Arguments
    if ($tail) { $tail = $tail.Trim() }

    $displayTail = $DisplayArguments
    if (-not $displayTail) { $displayTail = $tail }
    if ($displayTail) { $displayTail = $displayTail.Trim() }

    if ($normalizedType -eq 'MSI') {
        $base = "/i `"$InstallerPath`""
        $full = $base
        if ($tail) { $full = "$base $tail" }

        $displayFull = $base
        if ($displayTail) { $displayFull = "$base $displayTail" }

        return @{
            FilePath  = 'msiexec.exe'
            Arguments = $full
            Display   = "msiexec.exe $displayFull"
        }
    }

    if ($normalizedType -eq 'EXE') {
        $argumentValue = $null
        if ($tail) { $argumentValue = $tail }

        $displayFull = $InstallerPath
        if ($displayTail) { $displayFull = "$InstallerPath $displayTail" }

        return @{
            FilePath  = $InstallerPath
            Arguments = $argumentValue
            Display   = $displayFull
        }
    }

    throw "Unknown installer type: $Type. Use EXE or MSI."
}

function Start-InstallerProcess {
    <#
        Runs a command line from New-InstallerCommandLine and returns the
        process.

        -ArgumentList is omitted rather than passed empty: Windows PowerShell
        5.1 rejects an empty string there, which would make ArgumentSource
        'None' - and any existing configuration with no arguments - fail on the
        runtime Intune actually uses.
    #>
    param([Parameter(Mandatory)]$CommandLine)

    if ($CommandLine.Arguments) {
        return Start-Process -FilePath $CommandLine.FilePath -ArgumentList $CommandLine.Arguments `
            -Wait -PassThru -NoNewWindow
    }
    return Start-Process -FilePath $CommandLine.FilePath -Wait -PassThru -NoNewWindow
}
