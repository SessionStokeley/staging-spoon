#Requires -Version 5.1
<#
.SYNOPSIS
    Shared helper functions for the Intune Win32 deployment framework.
.DESCRIPTION
    Provides identity checks, installer/uninstaller execution engines,
    process/service management, PATH modification, file associations,
    registry operations, shortcuts, environment variables, and post-install
    action execution. Dot-sourced by Install.ps1, Uninstall.ps1, and Test-Local.ps1.
#>

# --- Identity Helpers ---

function Test-IsSystem {
    [CmdletBinding()]
    param()

    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    return ($identity.User.Value -eq 'S-1-5-18' -or $identity.Name -eq 'NT AUTHORITY\SYSTEM')
}

function Test-IsElevated {
    [CmdletBinding()]
    param()

    $identity  = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]$identity
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

# --- Installation Engine ---

function Invoke-Installation {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][hashtable]$InstallerConfig,
        [Parameter(Mandatory)][string]$PackagePath
    )

    $installerFile  = Join-Path $PackagePath (Join-Path 'Files' $InstallerConfig.File)
    $installerType  = if ($InstallerConfig.Type) { $InstallerConfig.Type } else { 'EXE' }
    $installExitCode = 0

    switch ($installerType.ToUpper()) {
        'MSI' {
            $msiArgs = @('/i', "`"$installerFile`"")
            if ($InstallerConfig.InstallArguments) {
                $msiArgs += $InstallerConfig.InstallArguments -split ' '
            }
            else {
                $msiArgs += @('/qn', '/norestart')
            }

            Write-Log -Message "Executing: msiexec.exe $($msiArgs -join ' ')" -Level 'Info'
            $process = Start-Process -FilePath 'msiexec.exe' -ArgumentList $msiArgs `
                -Wait -PassThru -NoNewWindow -ErrorAction Stop
            $installExitCode = $process.ExitCode
        }

        'MSIX' {
            Write-Log -Message "Executing MSIX: Add-AppxPackage -Path `"$installerFile`"" -Level 'Info'
            try {
                Add-AppxPackage -Path $installerFile -ErrorAction Stop
                $installExitCode = 0
            }
            catch {
                Write-Log -Message "MSIX installation failed: $_" -Level 'Error'
                $installExitCode = 1
            }
        }

        'PS1' {
            Write-Log -Message "Executing PowerShell installer: $installerFile" -Level 'Info'
            try {
                & $installerFile
                $installExitCode = $LASTEXITCODE
                if ($null -eq $installExitCode) { $installExitCode = 0 }
            }
            catch {
                Write-Log -Message "PowerShell installer failed: $_" -Level 'Error'
                $installExitCode = 1
            }
        }

        { $_ -in 'CMD', 'BAT' } {
            Write-Log -Message "Executing: cmd.exe /c `"$installerFile`" $($InstallerConfig.Arguments)" -Level 'Info'
            $process = Start-Process -FilePath 'cmd.exe' `
                -ArgumentList "/c `"$installerFile`" $($InstallerConfig.Arguments)" `
                -Wait -PassThru -NoNewWindow -ErrorAction Stop
            $installExitCode = $process.ExitCode
        }

        default {
            $startParams = @{
                FilePath    = $installerFile
                Wait        = $true
                PassThru    = $true
                NoNewWindow = $true
                ErrorAction = 'Stop'
            }
            if ($InstallerConfig.Arguments) {
                $startParams.ArgumentList = $InstallerConfig.Arguments
            }

            Write-Log -Message "Executing: $installerFile $($InstallerConfig.Arguments)" -Level 'Info'
            $process = Start-Process @startParams
            $installExitCode = $process.ExitCode
        }
    }

    return $installExitCode
}

# --- Uninstallation Engine ---

function Invoke-Uninstallation {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][hashtable]$Config,
        [Parameter(Mandatory)][string]$PackagePath
    )

    $uninstallerConfig = $Config.Uninstaller
    $uninstallType     = if ($uninstallerConfig.Type) { $uninstallerConfig.Type } else { 'Executable' }
    $uninstallExitCode = 0

    switch ($uninstallType) {
        'MSI' {
            $productCode = $uninstallerConfig.ProductCode
            if (-not $productCode) {
                if ($Config.Detection.Type -eq 'MSI' -and $Config.Detection.ProductCode) {
                    $productCode = $Config.Detection.ProductCode
                }
            }
            if (-not $productCode) {
                throw "MSI uninstall requires ProductCode in Uninstaller or Detection configuration."
            }

            $msiArgs = @('/x', $productCode)
            if ($uninstallerConfig.Arguments) {
                $msiArgs += $uninstallerConfig.Arguments -split ' '
            }
            else {
                $msiArgs += @('/qn', '/norestart')
            }

            Write-Log -Message "Executing: msiexec.exe $($msiArgs -join ' ')" -Level 'Info'
            $process = Start-Process -FilePath 'msiexec.exe' -ArgumentList $msiArgs `
                -Wait -PassThru -NoNewWindow -ErrorAction Stop
            $uninstallExitCode = $process.ExitCode
        }

        'Registry' {
            $uninstallExitCode = Invoke-RegistryUninstall -Config $Config
        }

        'Custom' {
            $customCmd  = $uninstallerConfig.Command
            $customArgs = $uninstallerConfig.Arguments
            if (-not $customCmd) {
                throw "Custom uninstall requires Command in Uninstaller configuration."
            }

            Write-Log -Message "Executing custom: $customCmd $customArgs" -Level 'Info'
            $startParams = @{
                FilePath    = $customCmd
                Wait        = $true
                PassThru    = $true
                NoNewWindow = $true
                ErrorAction = 'Stop'
            }
            if ($customArgs) { $startParams.ArgumentList = $customArgs }

            $process = Start-Process @startParams
            $uninstallExitCode = $process.ExitCode
        }

        default {
            $uninstallFile = $uninstallerConfig.File
            $uninstallArgs = $uninstallerConfig.Arguments

            if (-not $uninstallFile) {
                throw "Executable uninstall requires File in Uninstaller configuration."
            }

            if (-not [System.IO.Path]::IsPathRooted($uninstallFile)) {
                $candidatePaths = @(
                    (Join-Path $PackagePath (Join-Path 'Files' $uninstallFile))
                    (Join-Path $PackagePath $uninstallFile)
                )
                $resolvedPath = $candidatePaths | Where-Object { Test-Path $_ } | Select-Object -First 1
                if ($resolvedPath) {
                    $uninstallFile = $resolvedPath
                }
            }

            Write-Log -Message "Executing: $uninstallFile $uninstallArgs" -Level 'Info'
            $startParams = @{
                FilePath    = $uninstallFile
                Wait        = $true
                PassThru    = $true
                NoNewWindow = $true
                ErrorAction = 'Stop'
            }
            if ($uninstallArgs) { $startParams.ArgumentList = $uninstallArgs }

            $process = Start-Process @startParams
            $uninstallExitCode = $process.ExitCode
        }
    }

    return $uninstallExitCode
}

function Invoke-RegistryUninstall {
    [CmdletBinding()]
    param([hashtable]$Config)

    $displayName = $Config.Uninstaller.DisplayName
    if (-not $displayName) { $displayName = $Config.Application.Name }

    $searchPaths = @(
        'HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*'
        'HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*'
    )

    $entry = $null
    foreach ($path in $searchPaths) {
        $entry = Get-ItemProperty -Path $path -ErrorAction SilentlyContinue |
            Where-Object { $_.DisplayName -like "*$displayName*" } |
            Select-Object -First 1
        if ($entry) { break }
    }

    if (-not $entry) {
        Write-Log -Message "No registry uninstall entry found for '$displayName'." -Level 'Warning'
        return 0
    }

    $uninstallString = $entry.QuietUninstallString
    if (-not $uninstallString) {
        $uninstallString = $entry.UninstallString
    }

    if (-not $uninstallString) {
        Write-Log -Message "No UninstallString found in registry for '$displayName'." -Level 'Error'
        return 1
    }

    Write-Log -Message "Found registry uninstall entry: $($entry.DisplayName) $($entry.DisplayVersion)" -Level 'Info'
    Write-Log -Message "Uninstall string: $uninstallString" -Level 'Info'

    $uninstallString = $uninstallString.Trim('"')

    if ($uninstallString -match 'msiexec' -or $uninstallString -match '/[Ii]') {
        $guidMatch = [regex]::Match($uninstallString, '\{[0-9A-Fa-f\-]+\}')
        if ($guidMatch.Success) {
            $msiArgs = @('/x', $guidMatch.Value, '/qn', '/norestart')
            Write-Log -Message "Executing: msiexec.exe $($msiArgs -join ' ')" -Level 'Info'
            $process = Start-Process -FilePath 'msiexec.exe' -ArgumentList $msiArgs `
                -Wait -PassThru -NoNewWindow -ErrorAction Stop
            return $process.ExitCode
        }
    }

    $silentFlags = $Config.Uninstaller.Arguments
    if (-not $silentFlags) { $silentFlags = '/quiet /norestart' }

    if ($uninstallString -match '^"?(.+\.exe)"?\s*(.*)$') {
        $exePath      = $Matches[1]
        $existingArgs = $Matches[2]
        $allArgs      = "$existingArgs $silentFlags".Trim()

        Write-Log -Message "Executing: $exePath $allArgs" -Level 'Info'
        $process = Start-Process -FilePath $exePath -ArgumentList $allArgs `
            -Wait -PassThru -NoNewWindow -ErrorAction Stop
        return $process.ExitCode
    }

    Write-Log -Message "Unable to parse uninstall string: $uninstallString" -Level 'Error'
    return 1
}

# --- Return Code Evaluation ---

function Get-ExitCodeResult {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][int]$ExitCode,
        [Parameter(Mandatory)][hashtable]$ReturnCodes
    )

    $successCodes = @()
    $rebootCodes  = @()
    if ($ReturnCodes.Success)           { $successCodes = $ReturnCodes.Success }
    if ($ReturnCodes.SuccessWithReboot) { $rebootCodes  = $ReturnCodes.SuccessWithReboot }

    if ($ExitCode -in $rebootCodes) {
        return [PSCustomObject]@{ Success = $true; RebootRequired = $true; Description = "SUCCESS - REBOOT REQUIRED" }
    }
    elseif ($ExitCode -in $successCodes) {
        return [PSCustomObject]@{ Success = $true; RebootRequired = $false; Description = "SUCCESS" }
    }
    else {
        return [PSCustomObject]@{ Success = $false; RebootRequired = $false; Description = "FAILURE" }
    }
}

# --- Process and Service Management ---

function Stop-ConfiguredProcesses {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string[]]$ProcessNames,
        [int]$TimeoutSeconds = 30
    )

    foreach ($procName in $ProcessNames) {
        $processes = Get-Process -Name $procName -ErrorAction SilentlyContinue
        if (-not $processes) {
            Write-Log -Message "Process '$procName' not running." -Level 'Info'
            continue
        }

        Write-Log -Message "Requesting graceful close for process '$procName' ($($processes.Count) instance(s))..." -Level 'Info'
        foreach ($proc in $processes) {
            try { $proc.CloseMainWindow() | Out-Null } catch {}
        }

        $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
        while ((Get-Date) -lt $deadline) {
            $remaining = Get-Process -Name $procName -ErrorAction SilentlyContinue
            if (-not $remaining) { break }
            Start-Sleep -Milliseconds 500
        }

        $remaining = Get-Process -Name $procName -ErrorAction SilentlyContinue
        if ($remaining) {
            Write-Log -Message "Force-stopping process '$procName'..." -Level 'Warning'
            $remaining | Stop-Process -Force -ErrorAction SilentlyContinue
        }
        else {
            Write-Log -Message "Process '$procName' stopped successfully." -Level 'Info'
        }
    }
}

function Stop-ConfiguredServices {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string[]]$ServiceNames)

    foreach ($svcName in $ServiceNames) {
        $service = Get-Service -Name $svcName -ErrorAction SilentlyContinue
        if (-not $service) {
            Write-Log -Message "Service '$svcName' not found." -Level 'Info'
            continue
        }
        if ($service.Status -eq 'Stopped') {
            Write-Log -Message "Service '$svcName' already stopped." -Level 'Info'
            continue
        }
        Write-Log -Message "Stopping service '$svcName'..." -Level 'Info'
        try {
            Stop-Service -Name $svcName -Force -ErrorAction Stop
            Write-Log -Message "Service '$svcName' stopped." -Level 'Info'
        }
        catch {
            Write-Log -Message "Failed to stop service '$svcName': $_" -Level 'Warning'
        }
    }
}

# --- PATH Management ---

function Add-PathEntries {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string[]]$Entries
    )

    $currentPath = [System.Environment]::GetEnvironmentVariable('Path', 'Machine')
    $pathItems = $currentPath -split ';' | Where-Object { $_ -ne '' }
    $changed = $false

    foreach ($entry in $Entries) {
        if (-not $entry) { continue }
        $normalized = $entry.TrimEnd('\')
        $exists = $pathItems | Where-Object { $_.TrimEnd('\') -eq $normalized }
        if ($exists) {
            Write-Log -Message "PATH already contains: $entry" -Level 'Info'
            continue
        }
        $pathItems += $entry
        $changed = $true
        Write-Log -Message "Added to Machine PATH: $entry" -Level 'Info'
    }

    if ($changed) {
        $newPath = ($pathItems -join ';')
        [System.Environment]::SetEnvironmentVariable('Path', $newPath, 'Machine')
        Write-Log -Message "Machine PATH updated successfully." -Level 'Info'
    }
}

function Remove-PathEntries {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string[]]$Entries
    )

    $currentPath = [System.Environment]::GetEnvironmentVariable('Path', 'Machine')
    $pathItems = $currentPath -split ';' | Where-Object { $_ -ne '' }
    $changed = $false

    foreach ($entry in $Entries) {
        if (-not $entry) { continue }
        $normalized = $entry.TrimEnd('\')
        $before = $pathItems.Count
        $pathItems = @($pathItems | Where-Object { $_.TrimEnd('\') -ne $normalized })
        if ($pathItems.Count -lt $before) {
            $changed = $true
            Write-Log -Message "Removed from Machine PATH: $entry" -Level 'Info'
        }
    }

    if ($changed) {
        $newPath = ($pathItems -join ';')
        [System.Environment]::SetEnvironmentVariable('Path', $newPath, 'Machine')
        Write-Log -Message "Machine PATH updated successfully." -Level 'Info'
    }
}

# --- Persistent Environment Variables ---

function Set-PersistentEnvironmentVariables {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][hashtable]$Variables
    )

    foreach ($key in $Variables.Keys) {
        $value = $Variables[$key]
        try {
            [System.Environment]::SetEnvironmentVariable($key, $value, 'Machine')
            Write-Log -Message "Set Machine env var: $key = $value" -Level 'Info'
        }
        catch {
            Write-Log -Message "Failed to set env var '$key': $_" -Level 'Warning'
        }
    }
}

function Remove-PersistentEnvironmentVariables {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][hashtable]$Variables
    )

    foreach ($key in $Variables.Keys) {
        try {
            [System.Environment]::SetEnvironmentVariable($key, $null, 'Machine')
            Write-Log -Message "Removed Machine env var: $key" -Level 'Info'
        }
        catch {
            Write-Log -Message "Failed to remove env var '$key': $_" -Level 'Warning'
        }
    }
}

# --- File Associations (Framework-managed) ---

function Set-FileAssociations {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][hashtable]$Associations,
        [Parameter(Mandatory)][string]$ApplicationName
    )

    $progIdBase = ($ApplicationName -replace '[^a-zA-Z0-9]', '') + '.AssocFile'

    foreach ($ext in $Associations.Keys) {
        $exePath = $Associations[$ext]
        $progId = "$progIdBase$ext"

        try {
            $extKey = "HKLM:\Software\Classes\$ext"
            if (-not (Test-Path $extKey)) {
                New-Item -Path $extKey -Force | Out-Null
            }

            $previousDefault = (Get-ItemProperty -Path $extKey -Name '(Default)' -ErrorAction SilentlyContinue).'(Default)'
            if (-not $previousDefault) { $previousDefault = '' }
            Set-ItemProperty -Path $extKey -Name 'IntuneApp_PreviousDefault' -Value $previousDefault
            Set-ItemProperty -Path $extKey -Name '(Default)' -Value $progId

            $progKey = "HKLM:\Software\Classes\$progId\shell\open\command"
            if (-not (Test-Path $progKey)) {
                New-Item -Path $progKey -Force | Out-Null
            }
            Set-ItemProperty -Path $progKey -Name '(Default)' -Value "`"$exePath`" `"%1`""

            Write-Log -Message "File association: $ext -> $exePath (ProgId: $progId)" -Level 'Info'
        }
        catch {
            Write-Log -Message "Failed to set file association for $ext : $_" -Level 'Warning'
        }
    }
}

function Remove-FileAssociations {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][hashtable]$Associations,
        [Parameter(Mandatory)][string]$ApplicationName
    )

    $progIdBase = ($ApplicationName -replace '[^a-zA-Z0-9]', '') + '.AssocFile'

    foreach ($ext in $Associations.Keys) {
        $progId = "$progIdBase$ext"

        try {
            $extKey = "HKLM:\Software\Classes\$ext"
            $currentDefault = (Get-ItemProperty -Path $extKey -Name '(Default)' -ErrorAction SilentlyContinue).'(Default)'

            if ($currentDefault -eq $progId) {
                $previous = (Get-ItemProperty -Path $extKey -Name 'IntuneApp_PreviousDefault' -ErrorAction SilentlyContinue).'IntuneApp_PreviousDefault'
                if ($previous) {
                    Set-ItemProperty -Path $extKey -Name '(Default)' -Value $previous
                }
                else {
                    Remove-ItemProperty -Path $extKey -Name '(Default)' -ErrorAction SilentlyContinue
                }
                Remove-ItemProperty -Path $extKey -Name 'IntuneApp_PreviousDefault' -ErrorAction SilentlyContinue
            }

            $progKey = "HKLM:\Software\Classes\$progId"
            if (Test-Path $progKey) {
                Remove-Item -Path $progKey -Recurse -Force
            }

            Write-Log -Message "Removed file association: $ext (ProgId: $progId)" -Level 'Info'
        }
        catch {
            Write-Log -Message "Failed to remove file association for $ext : $_" -Level 'Warning'
        }
    }
}

# --- Registry Operations ---

function Set-RegistryEntries {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][array]$Entries
    )

    foreach ($entry in $Entries) {
        try {
            if (-not (Test-Path $entry.Path)) {
                New-Item -Path $entry.Path -Force | Out-Null
                Write-Log -Message "Created registry key: $($entry.Path)" -Level 'Info'
            }

            if ($entry.Name) {
                $regType = if ($entry.Type) { $entry.Type } else { 'String' }
                Set-ItemProperty -Path $entry.Path -Name $entry.Name -Value $entry.Value -Type $regType
                Write-Log -Message "Set registry value: $($entry.Path)\$($entry.Name) = $($entry.Value) [$regType]" -Level 'Info'
            }
        }
        catch {
            Write-Log -Message "Failed to set registry entry $($entry.Path)\$($entry.Name): $_" -Level 'Warning'
        }
    }
}

function Remove-RegistryEntries {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][array]$Entries
    )

    foreach ($entry in $Entries) {
        try {
            if ($entry.Name) {
                if (Test-Path $entry.Path) {
                    Remove-ItemProperty -Path $entry.Path -Name $entry.Name -ErrorAction Stop
                    Write-Log -Message "Removed registry value: $($entry.Path)\$($entry.Name)" -Level 'Info'
                }
            }
            else {
                if (Test-Path $entry.Path) {
                    Remove-Item -Path $entry.Path -Recurse -Force
                    Write-Log -Message "Removed registry key: $($entry.Path)" -Level 'Info'
                }
            }
        }
        catch {
            Write-Log -Message "Failed to remove registry entry $($entry.Path): $_" -Level 'Warning'
        }
    }
}

# --- Shortcut Management ---

function New-ApplicationShortcuts {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][array]$Shortcuts
    )

    $shell = New-Object -ComObject WScript.Shell

    foreach ($sc in $Shortcuts) {
        try {
            $folder = switch ($sc.Location) {
                'Desktop'   { [System.Environment]::GetFolderPath('CommonDesktopDirectory') }
                'StartMenu' { Join-Path ([System.Environment]::GetFolderPath('CommonStartMenu')) 'Programs' }
                default     { Join-Path ([System.Environment]::GetFolderPath('CommonStartMenu')) 'Programs' }
            }

            if (-not (Test-Path $folder)) {
                New-Item -Path $folder -ItemType Directory -Force | Out-Null
            }

            $shortcutPath = Join-Path $folder "$($sc.Name).lnk"
            $shortcut = $shell.CreateShortcut($shortcutPath)
            $shortcut.TargetPath = $sc.TargetPath
            if ($sc.Arguments)  { $shortcut.Arguments = $sc.Arguments }
            if ($sc.WorkingDir) { $shortcut.WorkingDirectory = $sc.WorkingDir }
            if ($sc.IconPath)   { $shortcut.IconLocation = $sc.IconPath }
            $shortcut.Save()

            Write-Log -Message "Created shortcut: $shortcutPath -> $($sc.TargetPath)" -Level 'Info'
        }
        catch {
            Write-Log -Message "Failed to create shortcut '$($sc.Name)': $_" -Level 'Warning'
        }
    }
}

function Remove-ApplicationShortcuts {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][array]$Shortcuts
    )

    foreach ($sc in $Shortcuts) {
        try {
            $folder = switch ($sc.Location) {
                'Desktop'   { [System.Environment]::GetFolderPath('CommonDesktopDirectory') }
                'StartMenu' { Join-Path ([System.Environment]::GetFolderPath('CommonStartMenu')) 'Programs' }
                default     { Join-Path ([System.Environment]::GetFolderPath('CommonStartMenu')) 'Programs' }
            }

            $shortcutPath = Join-Path $folder "$($sc.Name).lnk"
            if (Test-Path $shortcutPath) {
                Remove-Item $shortcutPath -Force
                Write-Log -Message "Removed shortcut: $shortcutPath" -Level 'Info'
            }
        }
        catch {
            Write-Log -Message "Failed to remove shortcut '$($sc.Name)': $_" -Level 'Warning'
        }
    }
}

function New-UserExperienceShortcuts {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][hashtable]$UserExperience,
        [Parameter(Mandatory)][string]$ApplicationName,
        [string]$TargetPath
    )

    if (-not $TargetPath) {
        Write-Log -Message "No target path for UserExperience shortcuts; skipping." -Level 'Info'
        return
    }

    $shell = New-Object -ComObject WScript.Shell

    if ($UserExperience.CreateStartMenuShortcut) {
        try {
            $startMenuDir = Join-Path ([System.Environment]::GetFolderPath('CommonStartMenu')) 'Programs'
            if (-not (Test-Path $startMenuDir)) { New-Item -Path $startMenuDir -ItemType Directory -Force | Out-Null }
            $lnk = $shell.CreateShortcut((Join-Path $startMenuDir "$ApplicationName.lnk"))
            $lnk.TargetPath = $TargetPath
            $lnk.Save()
            Write-Log -Message "Created Start Menu shortcut for $ApplicationName" -Level 'Info'
        }
        catch {
            Write-Log -Message "Failed to create Start Menu shortcut: $_" -Level 'Warning'
        }
    }

    if ($UserExperience.CreateDesktopShortcut) {
        try {
            $desktopDir = [System.Environment]::GetFolderPath('CommonDesktopDirectory')
            $lnk = $shell.CreateShortcut((Join-Path $desktopDir "$ApplicationName.lnk"))
            $lnk.TargetPath = $TargetPath
            $lnk.Save()
            Write-Log -Message "Created Desktop shortcut for $ApplicationName" -Level 'Info'
        }
        catch {
            Write-Log -Message "Failed to create Desktop shortcut: $_" -Level 'Warning'
        }
    }
}

function Remove-UserExperienceShortcuts {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ApplicationName
    )

    $startMenuPath = Join-Path (Join-Path ([System.Environment]::GetFolderPath('CommonStartMenu')) 'Programs') "$ApplicationName.lnk"
    $desktopPath   = Join-Path ([System.Environment]::GetFolderPath('CommonDesktopDirectory')) "$ApplicationName.lnk"

    foreach ($path in @($startMenuPath, $desktopPath)) {
        if (Test-Path $path) {
            Remove-Item $path -Force -ErrorAction SilentlyContinue
            Write-Log -Message "Removed shortcut: $path" -Level 'Info'
        }
    }
}

# --- Post-Install Action Runner ---

function Invoke-PostInstallActions {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][array]$Actions
    )

    $index = 0
    foreach ($action in $Actions) {
        $index++
        $actionType = $action.Type
        Write-Log -Message "Executing post-install action $index/$($Actions.Count): $actionType" -Level 'Info'

        try {
            switch ($actionType) {
                'RunCommand' {
                    $startParams = @{
                        FilePath    = $action.Command
                        Wait        = $(if ($null -ne $action.Wait) { $action.Wait } else { $true })
                        PassThru    = $true
                        NoNewWindow = $true
                        ErrorAction = 'Stop'
                    }
                    if ($action.Arguments) { $startParams.ArgumentList = $action.Arguments }
                    $proc = Start-Process @startParams
                    Write-Log -Message "RunCommand completed: $($action.Command) (exit code: $($proc.ExitCode))" -Level 'Info'
                }

                'RunPowerShell' {
                    $sb = [ScriptBlock]::Create($action.Script)
                    & $sb
                    Write-Log -Message "RunPowerShell completed." -Level 'Info'
                }

                'RestartService' {
                    Restart-Service -Name $action.Service -Force -ErrorAction Stop
                    Write-Log -Message "Restarted service: $($action.Service)" -Level 'Info'
                }

                'CopyFile' {
                    Copy-Item -Path $action.Source -Destination $action.Destination -Force
                    Write-Log -Message "Copied: $($action.Source) -> $($action.Destination)" -Level 'Info'
                }

                default {
                    Write-Log -Message "Unknown action type: $actionType" -Level 'Warning'
                }
            }
        }
        catch {
            Write-Log -Message "Post-install action $index ($actionType) failed: $_" -Level 'Warning'
        }
    }
}
