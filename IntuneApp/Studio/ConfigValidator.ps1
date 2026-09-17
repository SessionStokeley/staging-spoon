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

            $customScript = [string](Get-ModelValue $Model 'Detection.Script')
            $customFile   = [string](Get-ModelValue $Model 'Detection.ScriptFile')
            $customBlock  = Get-ModelValue $Model 'Detection.ScriptBlock'

            if (-not $customScript -and -not $customFile -and -not $customBlock) {
                & $add 'Error' 'Detection' 'Custom detection has no script.' 'Set Detection.Script (inline PowerShell) or Detection.ScriptFile (a .ps1 in the package).'
            }

            if ($customBlock -and -not $customScript -and -not $customFile) {
                # Import-PowerShellDataFile on 5.1 rejects a script-block
                # literal and fails the whole file, not just this section.
                # The framework falls back to reading the syntax tree, so this
                # still works - but the string forms need no fallback.
                & $add 'Warning' 'Detection' 'Custom detection uses a script block literal.' 'Windows PowerShell 5.1 cannot load one from a .psd1, so the framework falls back to reading the file directly. Detection.Script or Detection.ScriptFile avoids the fallback entirely.'
            }

            if ($customFile -and -not $SkipFileChecks) {
                $resolvedCustom = $customFile
                if (-not [System.IO.Path]::IsPathRooted($resolvedCustom) -and $PackageRoot) {
                    $resolvedCustom = Join-Path $PackageRoot $resolvedCustom
                }
                if (-not (Test-Path -LiteralPath $resolvedCustom)) {
                    & $add 'Error' 'Detection' "Detection.ScriptFile was not found: $customFile" 'The path is relative to the package root, and the file must ship inside the .intunewin.'
                }
            }
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

            $vMode = if ($var.Contains('Mode')) { [string]$var['Mode'] } else { 'Set' }
            if ($vMode -and $vMode -notin @('Set', 'Append', 'Prepend')) {
                & $add 'Error' 'Environment' "Environment variable '$vName' has invalid mode '$vMode'." 'Use Set, Append or Prepend.'
            }

            $vValue = if ($var.Contains('Value')) { [string]$var['Value'] } else { '' }

            # A semicolon means several entries; each needs its own append so
            # the list stays de-duplicated and can be un-appended cleanly.
            if ($vMode -in @('Append', 'Prepend') -and $vValue.Contains(';')) {
                & $add 'Error' 'Environment' "Environment variable '$vName' appends a value containing a semicolon." 'Add one entry per variable definition; the semicolon is the list separator.'
            }

            # Replacing a variable whose name implies a list is usually a mistake.
            if ($vMode -eq 'Set' -and $vName -match '(?i)(PATH|CLASSPATH|LIB|INCLUDE)$') {
                & $add 'Warning' 'Environment' "'$vName' is set to replace its whole value." "Variables of this kind normally hold a ';'-separated list. Append is usually correct, or an existing value will be replaced (uninstall restores it)."
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

        # --- Modes ---
        # Mirrors Resolve-IntegrationMode in Helpers/WindowsIntegration.ps1.
        # The Studio deliberately carries no dependency on the execution
        # engine, so the rule is stated here rather than shared.
        $resolveMode = {
            param($sectionName)
            $mode = [string](Get-ModelValue $Model "WindowsIntegration.$sectionName.Mode")
            if ($mode) { return $mode.ToUpperInvariant() }
            if (Get-ModelValue $Model "WindowsIntegration.$sectionName.Enabled") { return 'MANAGE' }
            return 'DISABLED'
        }

        $allFeatures = @('StartMenuShortcut', 'DesktopShortcut', 'FileAssociations',
                         'ContextMenu', 'Services', 'ScheduledTasks')

        foreach ($sectionName in $allFeatures) {
            $mode = [string](Get-ModelValue $Model "WindowsIntegration.$sectionName.Mode")
            if ($mode -and $mode.ToUpperInvariant() -notin @('DISABLED', 'VALIDATE', 'MANAGE')) {
                & $add 'Error' 'Windows Integration' "WindowsIntegration.$sectionName.Mode '$mode' is not valid." 'Use DISABLED, VALIDATE or MANAGE.'
            }
        }

        $managed = @($allFeatures | Where-Object { (& $resolveMode $_) -eq 'MANAGE' })
        $validated = @($allFeatures | Where-Object { (& $resolveMode $_) -eq 'VALIDATE' })

        if ($validated.Count -gt 0) {
            & $add 'Information' 'Windows Integration' "Checked but not created: $($validated -join ', ')." 'VALIDATE confirms the installer created these. The framework never creates or removes them.'
        }
        if ($managed.Count -gt 0) {
            & $add 'Information' 'Windows Integration' "Created and owned by the framework: $($managed -join ', ')." 'These are recorded at install time and removed on uninstall. Anything that already exists is left alone.'
        }

        # --- Context menu ---
        if ((& $resolveMode 'ContextMenu') -ne 'DISABLED') {
            $cmEntries = @(Get-ModelValue $Model 'WindowsIntegration.ContextMenu.Entries')
            if ($cmEntries.Count -eq 0) {
                & $add 'Error' 'Context Menu' 'Context menu is enabled but no entries are configured.' 'Add an entry or set Mode to DISABLED.'
            }
            foreach ($e in $cmEntries) {
                if ($e -isnot [System.Collections.IDictionary]) { continue }
                $verb = if ($e.Contains('Verb')) { [string]$e['Verb'] } else { '' }
                if ([string]::IsNullOrWhiteSpace($verb)) {
                    & $add 'Error' 'Context Menu' 'A context menu entry has no Verb.' 'Use an application-specific verb such as Company.Application.Open, so uninstall removes only this package key.'
                }
                elseif ($verb -notmatch '\.') {
                    & $add 'Warning' 'Context Menu' "Verb '$verb' is not application-specific." 'A dotted, vendor-prefixed verb is far less likely to collide with another product.'
                }
                $cmTarget = if ($e.Contains('Target')) { [string]$e['Target'] } else { 'FILE' }
                if ($cmTarget.ToUpperInvariant() -notin @('FILE', 'FOLDER', 'DIRECTORY', 'ALL_FILES')) {
                    & $add 'Error' 'Context Menu' "Context menu Target '$cmTarget' is not valid." 'Use FILE, FOLDER, DIRECTORY or ALL_FILES.'
                }
                $extList = if ($e.Contains('Extensions')) { @($e['Extensions']) } else { @() }
                if ($cmTarget.ToUpperInvariant() -eq 'ALL_FILES' -or
                    ($cmTarget.ToUpperInvariant() -eq 'FILE' -and $extList.Count -eq 0)) {
                    & $add 'Warning' 'Context Menu' "Entry '$verb' applies to every file on the machine." 'List Extensions to narrow it to the file types this application handles.'
                }
            }
        }

        # --- Services and scheduled tasks ---
        if ((& $resolveMode 'Services') -eq 'MANAGE') {
            & $add 'Information' 'Services' 'The framework will create these services.' 'Most vendor installers create their own. If yours does, VALIDATE is the safer mode.'
        }
        foreach ($t in @(Get-ModelValue $Model 'WindowsIntegration.ScheduledTasks.Tasks')) {
            if ($t -isnot [System.Collections.IDictionary]) { continue }
            $runAs = if ($t.Contains('RunAsUser')) { [string]$t['RunAsUser'] } else { '' }
            $runLevel = if ($t.Contains('RunLevel')) { [string]$t['RunLevel'] } else { '' }
            if ($runAs -match '(?i)^(SYSTEM|NT AUTHORITY\\SYSTEM)$' -or $runLevel -eq 'Highest') {
                $taskName = if ($t.Contains('Name')) { [string]$t['Name'] } else { '(unnamed)' }
                & $add 'Warning' 'Scheduled Tasks' "Task '$taskName' runs with elevated rights." 'A task running as SYSTEM or at highest privileges is a standing privilege grant. Confirm the application genuinely needs it.'
            }
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
