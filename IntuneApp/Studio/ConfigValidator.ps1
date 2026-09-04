#Requires -Version 5.1
<#
    ConfigValidator.ps1

    Validates a configuration model before it is allowed to execute.

    Findings are graded, because not everything that deserves attention should
    block a package:

      Error       the configuration cannot safely execute
      Warning     it can execute, but the technician should look first
      Information context worth knowing, no action implied

    Headless: no UI dependencies.
#>

Set-StrictMode -Version Latest

function New-ValidationFinding {
    param(
        [Parameter(Mandatory)][ValidateSet('Error', 'Warning', 'Information')][string]$Severity,
        [Parameter(Mandatory)][string]$Category,
        [Parameter(Mandatory)][string]$Message,
        [string]$Remedy = ''
    )
    return [pscustomobject]@{
        Severity = $Severity
        Category = $Category
        Message  = $Message
        Remedy   = $Remedy
    }
}

function Get-ModelValue {
    <#
        Safe dotted-path read against the model. Returns $null when any segment
        is missing, so validation never throws on an incomplete configuration.
    #>
    param(
        [Parameter(Mandatory)]$Model,
        [Parameter(Mandatory)][string]$Path
    )

    $current = $Model
    foreach ($segment in $Path.Split('.')) {
        if ($null -eq $current) { return $null }
        if ($current -isnot [System.Collections.IDictionary]) { return $null }
        if (-not $current.Contains($segment)) { return $null }
        $current = $current[$segment]
    }
    return $current
}

function Test-ConfigModel {
    <#
        .SYNOPSIS
        Validates a configuration model and returns graded findings.

        .PARAMETER Model
        The configuration model to check.

        .PARAMETER PackageRoot
        Package directory, used to confirm the installer exists under Files\.

        .PARAMETER SkipFileChecks
        Skip on-disk existence checks (useful when validating a configuration
        authored on a different machine).
    #>
    param(
        [Parameter(Mandatory)]$Model,
        [string]$PackageRoot = '',
        [switch]$SkipFileChecks
    )

    $findings = [System.Collections.Generic.List[object]]::new()
    $add = { param($s, $c, $m, $r = '') $findings.Add((New-ValidationFinding -Severity $s -Category $c -Message $m -Remedy $r)) }

    # ---------------------------------------------------------------- Identity
    $appName = Get-ModelValue $Model 'ApplicationName'
    if ([string]::IsNullOrWhiteSpace([string]$appName)) {
        & $add 'Error' 'Application' 'ApplicationName is required.' 'Set a display name for the application.'
    }

    if ([string]::IsNullOrWhiteSpace([string](Get-ModelValue $Model 'Publisher'))) {
        & $add 'Warning' 'Application' 'Publisher is empty.' 'Populate Publisher so the package is identifiable in Intune.'
    }

    if ([string]::IsNullOrWhiteSpace([string](Get-ModelValue $Model 'Version'))) {
        & $add 'Warning' 'Application' 'Version is empty.' 'Populate Version to support upgrade tracking.'
    }

    # --------------------------------------------------------------- Installer
    $insType = [string](Get-ModelValue $Model 'Installer.Type')
    $insFile = [string](Get-ModelValue $Model 'Installer.File')
    $insArgs = [string](Get-ModelValue $Model 'Installer.Arguments')
    $insUI   = [string](Get-ModelValue $Model 'Installer.UserInterface')

    if ([string]::IsNullOrWhiteSpace($insType)) {
        & $add 'Error' 'Installer' 'Installer.Type is required.' 'Set Installer.Type to EXE or MSI.'
    }
    elseif ($insType.ToUpperInvariant() -notin @('EXE', 'MSI')) {
        & $add 'Error' 'Installer' "Installer.Type '$insType' is not valid." 'Use EXE or MSI.'
    }

    if ([string]::IsNullOrWhiteSpace($insFile)) {
        & $add 'Error' 'Installer' 'Installer.File is required.' 'Name the installer file inside the Files\ directory.'
    }
    elseif (-not $SkipFileChecks -and $PackageRoot) {
        $installerPath = Join-Path (Join-Path $PackageRoot 'Files') $insFile
        if (-not (Test-Path -LiteralPath $installerPath)) {
            $present = @()
            $filesDir = Join-Path $PackageRoot 'Files'
            if (Test-Path -LiteralPath $filesDir) {
                $present = @(Get-ChildItem -LiteralPath $filesDir -File -ErrorAction SilentlyContinue |
                    Select-Object -ExpandProperty Name)
            }
            $hint = if ($present.Count -gt 0) { "Files\ contains: $($present -join ', ')" }
                    else { 'The Files\ directory is empty.' }
            & $add 'Error' 'Installer' "Installer file does not exist: $insFile" $hint
        }
    }

    if ($insUI -eq 'Silent' -and [string]::IsNullOrWhiteSpace($insArgs)) {
        & $add 'Warning' 'Installer' 'Silent installation selected but no arguments are configured.' 'Most installers need explicit silent switches. Confirm this installer is silent by default.'
    }

    # Interactive install cannot work under Intune's SYSTEM context.
    $installBehavior = [string](Get-ModelValue $Model 'Intune.InstallBehavior')
    if ($insUI -eq 'Interactive' -and $installBehavior -eq 'System') {
        & $add 'Error' 'Installer' 'Interactive installation cannot run in the Intune SYSTEM context.' 'Choose Silent, or change the install behavior to User.'
    }
    elseif ($insUI -eq 'BasicUI' -and $installBehavior -eq 'System') {
        & $add 'Warning' 'Installer' 'Basic UI selected for a SYSTEM-context deployment.' 'Installer UI is not visible to the user under SYSTEM. Silent is normally correct.'
    }

    # -------------------------------------------------------------- Uninstall
    $unType = [string](Get-ModelValue $Model 'Uninstaller.Type')
    if ([string]::IsNullOrWhiteSpace($unType)) {
        & $add 'Error' 'Uninstall' 'Uninstaller.Type is required.' 'Set Uninstaller.Type to EXE or MSI.'
    }
    elseif ($unType.ToUpperInvariant() -eq 'MSI') {
        $code = [string](Get-ModelValue $Model 'Uninstaller.ProductCode')
        if ([string]::IsNullOrWhiteSpace($code)) {
            & $add 'Error' 'Uninstall' 'MSI uninstall requires a ProductCode.' 'Supply the MSI ProductCode GUID.'
        }
        elseif ($code -notmatch '^\{[0-9A-Fa-f]{8}-([0-9A-Fa-f]{4}-){3}[0-9A-Fa-f]{12}\}$') {
            & $add 'Warning' 'Uninstall' "ProductCode does not look like a GUID: $code" 'Expected form: {XXXXXXXX-XXXX-XXXX-XXXX-XXXXXXXXXXXX}'
        }
    }
    elseif ($unType.ToUpperInvariant() -eq 'EXE') {
        if ([string]::IsNullOrWhiteSpace([string](Get-ModelValue $Model 'Uninstaller.File'))) {
            & $add 'Error' 'Uninstall' 'EXE uninstall requires Uninstaller.File.' 'Give the uninstaller path, or the command from the Windows uninstall registry key.'
        }
    }
    else {
        & $add 'Error' 'Uninstall' "Uninstaller.Type '$unType' is not valid." 'Use EXE or MSI.'
    }

    # -------------------------------------------------------------- Detection
    $detType = [string](Get-ModelValue $Model 'Detection.Type')
    switch ($detType.ToUpperInvariant()) {
        'FILE' {
            if ([string]::IsNullOrWhiteSpace([string](Get-ModelValue $Model 'Detection.Path'))) {
                & $add 'Error' 'Detection' 'File detection requires Detection.Path.' 'Set the installed application directory.'
            }
            if ([string]::IsNullOrWhiteSpace([string](Get-ModelValue $Model 'Detection.FileName'))) {
                & $add 'Error' 'Detection' 'File detection requires Detection.FileName.' 'Set the executable Intune should look for.'
            }
            $minVer = [string](Get-ModelValue $Model 'Detection.MinimumVersion')
            if ($minVer) {
                $parsed = $null
                if (-not [version]::TryParse($minVer, [ref]$parsed)) {
                    & $add 'Warning' 'Detection' "MinimumVersion '$minVer' is not a parseable version." 'Use a numeric form such as 1.0.0.0, or clear the field.'
                }
            }
        }
        'REGISTRY' {
            if ([string]::IsNullOrWhiteSpace([string](Get-ModelValue $Model 'Detection.RegistryPath'))) {
                & $add 'Error' 'Detection' 'Registry detection requires Detection.RegistryPath.' 'Example: HKLM:\SOFTWARE\Vendor\Product'
            }
        }
        'MSI' {
            $code = [string](Get-ModelValue $Model 'Detection.ProductCode')
            if ([string]::IsNullOrWhiteSpace($code)) {
                & $add 'Error' 'Detection' 'MSI detection requires Detection.ProductCode.' 'Supply the MSI ProductCode GUID.'
            }
        }
        'CUSTOM' {
            & $add 'Warning' 'Detection' 'Custom detection is in use.' 'Prefer File, Registry or MSI detection where possible - they are simpler to reason about.'
        }
        default {
            & $add 'Error' 'Detection' "Detection.Type '$detType' is not valid." 'Use File, Registry, MSI or Custom.'
        }
    }

    # ------------------------------------------------------------ Exit codes
    $codes = @(Get-ModelValue $Model 'SuccessExitCodes')
    if ($codes.Count -eq 0) {
        & $add 'Warning' 'Installer' 'No success exit codes configured.' 'Most packages need at least @(0, 3010).'
    }
    elseif (0 -notin $codes) {
        & $add 'Warning' 'Installer' 'Exit code 0 is not treated as success.' 'This is unusual - confirm it is intentional.'
    }

    # ---------------------------------------------------------- Environment
    $envEnabled = Get-ModelValue $Model 'Environment.Enabled'
    if ($envEnabled) {
        $sysEnabled = Get-ModelValue $Model 'Environment.SystemPath.Enabled'
        $usrEnabled = Get-ModelValue $Model 'Environment.UserPath.Enabled'
        $sysEntries = @(Get-ModelValue $Model 'Environment.SystemPath.Entries')
        $usrEntries = @(Get-ModelValue $Model 'Environment.UserPath.Entries')

        if (-not $sysEnabled -and -not $usrEnabled -and
            @(Get-ModelValue $Model 'Environment.Variables').Count -eq 0) {
            & $add 'Warning' 'Environment' 'Environment configuration is enabled but nothing is configured.' 'Add PATH entries or variables, or disable the Environment section.'
        }

        if ($sysEnabled -and $sysEntries.Count -eq 0) {
            & $add 'Error' 'Environment' 'System PATH is enabled but no entries are configured.' 'Add at least one directory, or disable System PATH.'
        }
        if ($usrEnabled -and $usrEntries.Count -eq 0) {
            & $add 'Error' 'Environment' 'User PATH is enabled but no entries are configured.' 'Add at least one directory, or disable User PATH.'
        }

        # The deployment-context caveat that actually bites people.
        if ($usrEnabled -and $installBehavior -eq 'System') {
            & $add 'Warning' 'Environment' 'User PATH is configured for a SYSTEM-context Intune application.' 'Running as SYSTEM writes the Default user profile, not each existing user. Confirm a user-context strategy, or use System PATH.'
        }

        foreach ($entry in ($sysEntries + $usrEntries)) {
            $text = [string]$entry
            if ([string]::IsNullOrWhiteSpace($text)) {
                & $add 'Error' 'Environment' 'A PATH entry is empty.' 'Remove the blank entry.'
                continue
            }
            if ($text.IndexOfAny([System.IO.Path]::GetInvalidPathChars()) -ge 0) {
                & $add 'Error' 'Environment' "PATH entry contains invalid characters: $text" 'Correct the path.'
            }
            if ($text.Contains(';')) {
                & $add 'Error' 'Environment' "PATH entry contains a semicolon: $text" 'Split it into separate entries - a semicolon is the PATH separator.'
            }
        }

        # Duplicates within the configuration itself.
        foreach ($scope in @(@{ N = 'System'; E = $sysEntries }, @{ N = 'User'; E = $usrEntries })) {
            $seen = @{}
            foreach ($entry in $scope.E) {
                $key = ([string]$entry).TrimEnd('\', '/').ToLowerInvariant()
                if (-not $key) { continue }
                if ($seen.ContainsKey($key)) {
                    & $add 'Warning' 'Environment' "Duplicate $($scope.N) PATH entry: $entry" 'Remove the duplicate - it will be collapsed at install time anyway.'
                }
                $seen[$key] = $true
            }
        }

        foreach ($var in @(Get-ModelValue $Model 'Environment.Variables')) {
            if ($var -isnot [System.Collections.IDictionary]) { continue }
            $vName = if ($var.Contains('Name')) { [string]$var['Name'] } else { '' }
            if ([string]::IsNullOrWhiteSpace($vName)) {
                & $add 'Error' 'Environment' 'An environment variable has no name.' 'Give the variable a name or remove it.'
            }
            $vScope = if ($var.Contains('Scope')) { [string]$var['Scope'] } else { '' }
            if ($vScope -and $vScope -notin @('Machine', 'User')) {
                & $add 'Error' 'Environment' "Environment variable '$vName' has invalid scope '$vScope'." 'Use Machine or User.'
            }
        }
    }

    # -------------------------------------------------- Windows integration
    $wiEnabled = Get-ModelValue $Model 'WindowsIntegration.Enabled'
    if ($wiEnabled) {
        foreach ($kind in @('StartMenuShortcut', 'DesktopShortcut')) {
            if (Get-ModelValue $Model "WindowsIntegration.$kind.Enabled") {
                if ([string]::IsNullOrWhiteSpace([string](Get-ModelValue $Model "WindowsIntegration.$kind.Name"))) {
                    & $add 'Error' 'Shortcuts' "$kind is enabled but has no Name." 'Set the shortcut display name.'
                }
                $target = [string](Get-ModelValue $Model "WindowsIntegration.$kind.Target")
                if ([string]::IsNullOrWhiteSpace($target)) {
                    & $add 'Error' 'Shortcuts' "$kind is enabled but has no Target." 'Set the executable the shortcut points at.'
                }
                elseif (-not $SkipFileChecks -and -not (Test-Path -LiteralPath $target)) {
                    & $add 'Warning' 'Shortcuts' "$kind target does not exist on this machine: $target" 'Expected if the application is not installed here yet.'
                }
            }
        }

        if (Get-ModelValue $Model 'WindowsIntegration.FileAssociations.Enabled') {
            $assocs = @(Get-ModelValue $Model 'WindowsIntegration.FileAssociations.Associations')
            if ($assocs.Count -eq 0) {
                & $add 'Error' 'Associations' 'File associations are enabled but none are configured.' 'Add an association or disable the section.'
            }
            foreach ($a in $assocs) {
                if ($a -isnot [System.Collections.IDictionary]) { continue }
                $ext = if ($a.Contains('Extension')) { [string]$a['Extension'] } else { '' }
                if ([string]::IsNullOrWhiteSpace($ext)) {
                    & $add 'Error' 'Associations' 'A file association has no extension.' 'Set the extension, e.g. .rvt'
                }
                elseif (-not $ext.StartsWith('.')) {
                    & $add 'Warning' 'Associations' "Extension '$ext' does not start with a dot." 'Use the leading-dot form, e.g. .rvt'
                }
            }
            & $add 'Information' 'Associations' 'Registering an association does not force it to become the user default.' 'Windows requires the user to confirm a default application change.'
        }

        # Be explicit about the boundary of what the engine actually performs.
        $recordedOnly = @()
        foreach ($section in @('StartMenuShortcut', 'DesktopShortcut', 'FileAssociations', 'ContextMenu', 'Services', 'ScheduledTasks')) {
            if (Get-ModelValue $Model "WindowsIntegration.$section.Enabled") { $recordedOnly += $section }
        }
        if ($recordedOnly.Count -gt 0) {
            & $add 'Information' 'Windows Integration' "Recorded in the configuration but not executed by the current packaging engine: $($recordedOnly -join ', ')." 'These settings are captured for review and hand-off. The installer itself usually creates them.'
        }
    }

    # -------------------------------------------------------------- Intune
    if ($installBehavior -and $installBehavior -notin @('System', 'User')) {
        & $add 'Error' 'Intune' "Intune.InstallBehavior '$installBehavior' is not valid." 'Use System or User.'
    }

    $insContext = [string](Get-ModelValue $Model 'Installer.Context')
    if ($insContext -and $installBehavior -and $insContext -ne $installBehavior) {
        & $add 'Warning' 'Intune' "Installer.Context ($insContext) does not match Intune.InstallBehavior ($installBehavior)." 'Align them so the package installs in the context it was configured for.'
    }

    return $findings.ToArray()
}

function Get-ValidationSummary {
    <#
        Reduces findings to a pass/fail decision plus counts.
        Only errors block execution.
    #>
    # A configuration with no findings at all is the success case, and an
    # empty result arrives here as $null, so both must bind.
    param(
        [AllowNull()][AllowEmptyCollection()]
        [object[]]$Findings = @()
    )

    # Drop nulls: an empty result can arrive as @($null) through binding.
    $all = @($Findings | Where-Object { $null -ne $_ })
    $errors   = @($all | Where-Object { $_.Severity -eq 'Error' })
    $warnings = @($all | Where-Object { $_.Severity -eq 'Warning' })
    $info     = @($all | Where-Object { $_.Severity -eq 'Information' })

    return [pscustomobject]@{
        IsValid      = ($errors.Count -eq 0)
        ErrorCount   = $errors.Count
        WarningCount = $warnings.Count
        InfoCount    = $info.Count
        Errors       = $errors
        Warnings     = $warnings
        Information  = $info
        All          = $all
    }
}

function Write-ValidationReport {
    <#
        Renders findings to the console in the graded layout.
    #>
    param(
        [AllowNull()][AllowEmptyCollection()]
        [object[]]$Findings = @(),
        [switch]$Quiet
    )

    # Drop nulls: an empty result can arrive as @($null) through binding.
    $all = @($Findings | Where-Object { $null -ne $_ })
    $summary = Get-ValidationSummary -Findings $all
    if ($Quiet) { return $summary }

    Write-Host ''
    Write-Host 'Configuration Validation' -ForegroundColor Cyan
    Write-Host ('-' * 60)

    if ($all.Count -eq 0) {
        Write-Host '  No findings.' -ForegroundColor Green
    }

    foreach ($group in @(
        @{ Sev = 'Error';       Glyph = '[X]'; Color = 'Red' },
        @{ Sev = 'Warning';     Glyph = '[!]'; Color = 'Yellow' },
        @{ Sev = 'Information'; Glyph = '[i]'; Color = 'Gray' }
    )) {
        $items = @($all | Where-Object { $_.Severity -eq $group.Sev })
        foreach ($f in $items) {
            Write-Host "  $($group.Glyph) [$($f.Category)] $($f.Message)" -ForegroundColor $group.Color
            if ($f.Remedy) {
                Write-Host "      -> $($f.Remedy)" -ForegroundColor DarkGray
            }
        }
    }

    Write-Host ('-' * 60)
    if ($summary.IsValid) {
        $msg = 'Configuration is valid.'
        if ($summary.WarningCount -gt 0) { $msg += " $($summary.WarningCount) warning(s) to review." }
        Write-Host $msg -ForegroundColor Green
    }
    else {
        Write-Host "Configuration is NOT valid. $($summary.ErrorCount) error(s) must be fixed." -ForegroundColor Red
    }
    Write-Host ''

    return $summary
}

function Test-ConfigFile {
    <#
        .SYNOPSIS
        Validates a .psd1 on disk: syntax first, then semantic checks.
    #>
    param(
        [Parameter(Mandatory)][string]$Path,
        [string]$PackageRoot = '',
        [switch]$SkipFileChecks
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        New-ValidationFinding -Severity 'Error' -Category 'File' `
            -Message "Configuration file not found: $Path"
        return
    }

    # Syntax gate: a file that does not parse cannot be checked semantically.
    if (Get-Command Test-Psd1Syntax -ErrorAction SilentlyContinue) {
        $syntax = Test-Psd1Syntax -Path $Path
        if (-not $syntax.Valid) {
            $out = foreach ($e in $syntax.Errors) {
                New-ValidationFinding -Severity 'Error' -Category 'Syntax' -Message $e `
                    -Remedy 'Fix the PowerShell syntax before the configuration can be used.'
            }
            $out
            return
        }
    }

    try {
        $model = Import-PowerShellDataFile -LiteralPath $Path -ErrorAction Stop
    }
    catch {
        New-ValidationFinding -Severity 'Error' -Category 'Syntax' `
            -Message "Configuration could not be loaded: $($_.Exception.Message)"
        return
    }

    if (-not $PackageRoot) { $PackageRoot = Split-Path -Parent $Path }

    Test-ConfigModel -Model $model -PackageRoot $PackageRoot -SkipFileChecks:$SkipFileChecks
}
