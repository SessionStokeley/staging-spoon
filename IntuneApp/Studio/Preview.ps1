#Requires -Version 5.1
<#
    Preview.ps1

    Renders, in plain language, what a configuration would do if it were run.

    Nothing here executes anything. This is the screen the technician reads
    before granting approval, so it must describe the configuration honestly -
    including the parts the current engine does not act on.

    Headless apart from Write-Host rendering.
#>

Set-StrictMode -Version Latest

function Get-ConfigurationPreview {
    <#
        .SYNOPSIS
        Builds a structured description of the effects of a configuration.

        .OUTPUTS
        An ordered dictionary of section name -> array of description lines.
    #>
    param([Parameter(Mandatory)]$Model)

    $get = { param($p) Get-ModelValue $Model $p }

    $preview = [ordered]@{}

    # ------------------------------------------------------------- Application
    $preview['Application'] = @(
        "Name        : $(& $get 'ApplicationName')"
        "Publisher   : $(& $get 'Publisher')"
        "Version     : $(& $get 'Version')"
        "Architecture: $(& $get 'Architecture')"
    )

    # ----------------------------------------------------------- Installation
    $insType = [string](& $get 'Installer.Type')
    $insFile = [string](& $get 'Installer.File')
    $insArgs = [string](& $get 'Installer.Arguments')

    $command = if ($insType.ToUpperInvariant() -eq 'MSI') {
        "msiexec.exe /i `"Files\$insFile`" $insArgs"
    }
    else {
        "Files\$insFile $insArgs"
    }

    $preview['Installation'] = @(
        "Context   : $(& $get 'Installer.Context')"
        "Interface : $(& $get 'Installer.UserInterface')"
        "Restart   : $(& $get 'Installer.Restart')"
        "Command   : $command"
        "Success   : exit codes $(@(& $get 'SuccessExitCodes') -join ', ')"
    )

    # ---------------------------------------------------------------- PATH
    $pathLines = @()
    if (& $get 'Environment.Enabled') {
        if (& $get 'Environment.SystemPath.Enabled') {
            $entries = @(& $get 'Environment.SystemPath.Entries')
            if ($entries.Count -gt 0) {
                $pathLines += 'System PATH (all users):'
                $pathLines += ($entries | ForEach-Object { "  + $_" })
                $removes = & $get 'Environment.SystemPath.RemoveOnUninstall'
                $pathLines += "  Removed on uninstall: $(if ($removes) { 'yes' } else { 'no' })"
            }
        }
        if (& $get 'Environment.UserPath.Enabled') {
            $entries = @(& $get 'Environment.UserPath.Entries')
            if ($entries.Count -gt 0) {
                $pathLines += 'User PATH:'
                $pathLines += ($entries | ForEach-Object { "  + $_" })
                $removes = & $get 'Environment.UserPath.RemoveOnUninstall'
                $pathLines += "  Removed on uninstall: $(if ($removes) { 'yes' } else { 'no' })"
                if ([string](& $get 'Intune.InstallBehavior') -eq 'System') {
                    $pathLines += '  NOTE: running as SYSTEM writes the Default user profile,'
                    $pathLines += '        not the profile of each existing user.'
                }
            }
        }
    }
    if ($pathLines.Count -eq 0) { $pathLines = @('No PATH changes.') }
    $preview['PATH'] = $pathLines

    # ------------------------------------------------- Environment variables
    $varLines = @()
    if (& $get 'Environment.Enabled') {
        foreach ($v in @(& $get 'Environment.Variables')) {
            if ($v -isnot [System.Collections.IDictionary]) { continue }
            $scope = if ($v.Contains('Scope')) { $v['Scope'] } else { 'Machine' }
            $varLines += "  $($v['Name']) = $($v['Value'])  [$scope]"
        }
    }
    if ($varLines.Count -eq 0) { $varLines = @('No environment variable changes.') }
    $preview['Environment Variables'] = $varLines

    # ----------------------------------------------------------- Shortcuts
    $scLines = @()
    foreach ($kind in @(
        @{ Key = 'StartMenuShortcut'; Label = 'Start Menu' },
        @{ Key = 'DesktopShortcut';   Label = 'Desktop' }
    )) {
        if (& $get "WindowsIntegration.$($kind.Key).Enabled") {
            $scLines += "$($kind.Label): $(& $get "WindowsIntegration.$($kind.Key).Name")"
            $scLines += "  -> $(& $get "WindowsIntegration.$($kind.Key).Target")"
        }
    }
    if ($scLines.Count -eq 0) { $scLines = @('No shortcuts configured.') }
    $preview['Shortcuts'] = $scLines

    # --------------------------------------------------- File associations
    $assocLines = @()
    if (& $get 'WindowsIntegration.FileAssociations.Enabled') {
        foreach ($a in @(& $get 'WindowsIntegration.FileAssociations.Associations')) {
            if ($a -isnot [System.Collections.IDictionary]) { continue }
            $desc = if ($a.Contains('Description') -and $a['Description']) { " - $($a['Description'])" } else { '' }
            $assocLines += "  $($a['Extension'])$desc"
        }
        if ($assocLines.Count -gt 0) {
            $assocLines += '  (Windows still asks the user before changing their default app.)'
        }
    }
    if ($assocLines.Count -eq 0) { $assocLines = @('No file associations configured.') }
    $preview['File Associations'] = $assocLines

    # -------------------------------------------------------- Context menu
    $cmLines = @()
    if (& $get 'WindowsIntegration.ContextMenu.Enabled') {
        foreach ($e in @(& $get 'WindowsIntegration.ContextMenu.Entries')) {
            $cmLines += "  $(if ($e -is [System.Collections.IDictionary]) { $e['Name'] } else { $e })"
        }
    }
    if ($cmLines.Count -eq 0) { $cmLines = @('No context menu entries configured.') }
    $preview['Context Menu'] = $cmLines

    # ------------------------------------------------------------ Services
    $svcLines = @()
    if (& $get 'WindowsIntegration.Services.Enabled') {
        foreach ($s in @(& $get 'WindowsIntegration.Services.Services')) {
            if ($s -isnot [System.Collections.IDictionary]) { continue }
            $keep = if ($s.Contains('Keep') -and $s['Keep']) { 'keep' } else { 'remove' }
            $svcLines += "  $($s['Name'])  startup=$($s['StartupType'])  ($keep)"
        }
    }
    if ($svcLines.Count -eq 0) { $svcLines = @('No services configured.') }
    $preview['Services'] = $svcLines

    # ----------------------------------------------------- Scheduled tasks
    $taskLines = @()
    if (& $get 'WindowsIntegration.ScheduledTasks.Enabled') {
        foreach ($t in @(& $get 'WindowsIntegration.ScheduledTasks.Tasks')) {
            if ($t -isnot [System.Collections.IDictionary]) { continue }
            $keep = if ($t.Contains('Keep') -and $t['Keep']) { 'keep' } else { 'remove' }
            $taskLines += "  $($t['Path'])$($t['Name'])  ($keep)"
        }
    }
    if ($taskLines.Count -eq 0) { $taskLines = @('No scheduled tasks configured.') }
    $preview['Scheduled Tasks'] = $taskLines

    # --------------------------------------------------------- Detection
    $detType = [string](& $get 'Detection.Type')
    $detLines = switch ($detType.ToUpperInvariant()) {
        'FILE' {
            $l = @("Type: File", "Path: $(& $get 'Detection.Path')\$(& $get 'Detection.FileName')")
            $mv = & $get 'Detection.MinimumVersion'
            if ($mv) { $l += "Minimum version: $mv" }
            $l
        }
        'REGISTRY' {
            @("Type: Registry", "Path: $(& $get 'Detection.RegistryPath')",
              "Value: $(& $get 'Detection.ValueName')")
        }
        'MSI'     { @("Type: MSI", "ProductCode: $(& $get 'Detection.ProductCode')") }
        'CUSTOM'  { @('Type: Custom PowerShell scriptblock') }
        default   { @("Type: $detType") }
    }
    $preview['Detection'] = $detLines

    # --------------------------------------------------------- Uninstall
    $unType = [string](& $get 'Uninstaller.Type')
    $unLines = if ($unType.ToUpperInvariant() -eq 'MSI') {
        @("msiexec.exe /x $(& $get 'Uninstaller.ProductCode') /qn /norestart")
    }
    else {
        @("$(& $get 'Uninstaller.File') $(& $get 'Uninstaller.Arguments')")
    }

    $cleanup = @()
    if (& $get 'Environment.Enabled') {
        if ((& $get 'Environment.SystemPath.Enabled') -and (& $get 'Environment.SystemPath.RemoveOnUninstall')) {
            $cleanup += 'System PATH entries added by this package'
        }
        if ((& $get 'Environment.UserPath.Enabled') -and (& $get 'Environment.UserPath.RemoveOnUninstall')) {
            $cleanup += 'User PATH entries added by this package'
        }
        foreach ($v in @(& $get 'Environment.Variables')) {
            if ($v -is [System.Collections.IDictionary] -and
                (-not $v.Contains('RemoveOnUninstall') -or $v['RemoveOnUninstall'])) {
                $cleanup += "Environment variable $($v['Name'])"
            }
        }
    }
    if ($cleanup.Count -gt 0) {
        $unLines += 'Also removed:'
        $unLines += ($cleanup | ForEach-Object { "  - $_" })
    }
    $preview['Uninstall'] = $unLines

    # ------------------------------------------------------------ Intune
    $preview['Intune'] = @(
        "Install behavior : $(& $get 'Intune.InstallBehavior')"
        "Install command  : $(& $get 'Intune.InstallCommand')"
        "Uninstall command: $(& $get 'Intune.UninstallCommand')"
        "Detection script : $(& $get 'Intune.DetectionScript')"
    )

    return $preview
}

function Show-ConfigurationPreview {
    <#
        Renders the preview to the console.
    #>
    param(
        [Parameter(Mandatory)]$Model,
        [string]$Title = 'Configuration Preview'
    )

    $preview = Get-ConfigurationPreview -Model $Model

    Write-Host ''
    Write-Host ('=' * 62) -ForegroundColor Cyan
    Write-Host $Title -ForegroundColor Cyan
    Write-Host ('=' * 62) -ForegroundColor Cyan

    foreach ($section in $preview.Keys) {
        Write-Host ''
        Write-Host $section -ForegroundColor White
        Write-Host ('-' * $section.Length) -ForegroundColor DarkGray
        foreach ($line in @($preview[$section])) {
            Write-Host "  $line"
        }
    }

    Write-Host ''
    Write-Host ('=' * 62) -ForegroundColor Cyan
    Write-Host ''
}

function Get-ExecutionWarningText {
    <#
        The text shown immediately before execution is approved. It lists only
        the categories the configuration actually enables, so the warning stays
        meaningful instead of being boilerplate the technician learns to skip.
    #>
    param([Parameter(Mandatory)]$Model, [string]$ConfigPath = '')

    $get = { param($p) Get-ModelValue $Model $p }
    $effects = @('Install software on this machine')

    if (& $get 'Environment.Enabled') {
        if (& $get 'Environment.SystemPath.Enabled') { $effects += 'Modify the system-wide Windows PATH' }
        if (& $get 'Environment.UserPath.Enabled')   { $effects += 'Modify the user PATH' }
        if (@(& $get 'Environment.Variables').Count -gt 0) { $effects += 'Create or change environment variables' }
        $effects += 'Write package state under C:\ProgramData'
    }

    foreach ($pair in @(
        @{ P = 'WindowsIntegration.StartMenuShortcut.Enabled'; T = 'Create a Start Menu shortcut' },
        @{ P = 'WindowsIntegration.DesktopShortcut.Enabled';   T = 'Create a Desktop shortcut' },
        @{ P = 'WindowsIntegration.FileAssociations.Enabled';  T = 'Register file associations' },
        @{ P = 'WindowsIntegration.ContextMenu.Enabled';       T = 'Add context menu entries' },
        @{ P = 'WindowsIntegration.Services.Enabled';          T = 'Configure Windows services' },
        @{ P = 'WindowsIntegration.ScheduledTasks.Enabled';    T = 'Configure scheduled tasks' }
    )) {
        if (& $get $pair.P) { $effects += $pair.T }
    }

    return [pscustomobject]@{
        Effects    = $effects
        ConfigPath = $ConfigPath
        Text       = ($effects | ForEach-Object { "  - $_" }) -join [Environment]::NewLine
    }
}
