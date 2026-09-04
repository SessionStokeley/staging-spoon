#Requires -Version 5.1
param(
    [Parameter(Mandatory)]
    [ValidateSet('Install', 'Uninstall', 'Detection', 'Validate', 'Environment', 'DetectPaths', 'TestCommand', 'PathDiagnostics')]
    [string]$Mode,

    [string]$Command,

    [string]$InstallPath
)

$ErrorActionPreference = 'Stop'
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Definition

# Load shared helpers
$helpersDir = Join-Path $ScriptDir 'Helpers'
if (Test-Path (Join-Path $helpersDir 'Environment.ps1')) {
    . (Join-Path $helpersDir 'Environment.ps1')
}

function Write-Banner {
    param([string]$Text)
    Write-Host ""
    Write-Host "========================================" -ForegroundColor Cyan
    Write-Host $Text -ForegroundColor Cyan
    Write-Host "========================================" -ForegroundColor Cyan
}

function Write-Result {
    param([string]$Label, [bool]$Pass)
    $status = if ($Pass) { "PASS" } else { "FAIL" }
    $color = if ($Pass) { "Green" } else { "Red" }
    Write-Host ("{0,-30} {1}" -f "${Label}:", $status) -ForegroundColor $color
}

function Write-Warning-Msg {
    param([string]$Text)
    Write-Host "  ! $Text" -ForegroundColor Yellow
}

# Validate package structure and configuration
function Test-Package {
    $Config = Import-PowerShellDataFile (Join-Path $ScriptDir 'Configuration.psd1')
    $allPass = $true

    Write-Banner "Package Validation"
    Write-Host "Application: $($Config.ApplicationName)"
    Write-Host ""

    # Required files
    $requiredFiles = @('Install.ps1', 'Uninstall.ps1', 'Detection.ps1', 'Configuration.psd1')
    foreach ($file in $requiredFiles) {
        $exists = Test-Path (Join-Path $ScriptDir $file)
        Write-Result "File: $file" $exists
        if (-not $exists) { $allPass = $false }
    }

    # Installer file
    $filesDir = Join-Path $ScriptDir 'Files'
    $installerPath = Join-Path $filesDir $Config.Installer.File
    $installerExists = Test-Path $installerPath
    Write-Result "Installer: $($Config.Installer.File)" $installerExists
    if (-not $installerExists) {
        $allPass = $false
        if (Test-Path $filesDir) {
            $found = Get-ChildItem $filesDir -File | Select-Object -ExpandProperty Name
            if ($found) {
                Write-Host "  Files directory contains:" -ForegroundColor Yellow
                $found | ForEach-Object { Write-Host "    $_" -ForegroundColor Yellow }
                Write-Host "  Update Configuration.psd1 Installer.File to match." -ForegroundColor Yellow
            }
            else {
                Write-Host "  Files directory is empty. Place your installer there." -ForegroundColor Yellow
            }
        }
        else {
            Write-Host "  Files directory missing. Create it and place your installer there." -ForegroundColor Yellow
        }
    }

    # Configuration checks
    $hasName = [bool]$Config.ApplicationName
    Write-Result "ApplicationName" $hasName
    if (-not $hasName) { $allPass = $false }

    $hasInstallerType = [bool]$Config.Installer.Type
    Write-Result "Installer.Type" $hasInstallerType
    if (-not $hasInstallerType) { $allPass = $false }

    $hasDetectionType = [bool]$Config.Detection.Type
    Write-Result "Detection.Type" $hasDetectionType
    if (-not $hasDetectionType) { $allPass = $false }

    # Script syntax validation
    $allScripts = @($requiredFiles | Where-Object { $_ -like '*.ps1' })
    $helperPath = Join-Path $ScriptDir 'Helpers\Environment.ps1'
    if (Test-Path $helperPath) { $allScripts += 'Helpers\Environment.ps1' }

    foreach ($file in $allScripts) {
        $path = Join-Path $ScriptDir $file
        if (Test-Path $path) {
            $errors = $null
            [System.Management.Automation.PSParser]::Tokenize((Get-Content $path -Raw), [ref]$errors) | Out-Null
            $syntaxOk = ($errors.Count -eq 0)
            Write-Result "Syntax: $file" $syntaxOk
            if (-not $syntaxOk) { $allPass = $false }
        }
    }

    # Environment config validation
    if ($Config.Environment -and $Config.Environment.Enabled) {
        Write-Host ""
        Write-Host "Environment Configuration" -ForegroundColor Cyan
        Write-Host "-------------------------"

        if ($Config.Environment.SystemPath -and $Config.Environment.SystemPath.Enabled) {
            $entryCount = @($Config.Environment.SystemPath.Entries).Count
            Write-Result "System PATH entries" ($entryCount -gt 0)
            foreach ($entry in $Config.Environment.SystemPath.Entries) {
                Write-Host "    $entry"
            }
            if ($entryCount -eq 0) {
                $allPass = $false
                Write-Warning-Msg "System PATH enabled but no entries configured."
            }
        }

        if ($Config.Environment.UserPath -and $Config.Environment.UserPath.Enabled) {
            $entryCount = @($Config.Environment.UserPath.Entries).Count
            Write-Result "User PATH entries" ($entryCount -gt 0)
            foreach ($entry in $Config.Environment.UserPath.Entries) {
                Write-Host "    $entry"
            }
            if ($entryCount -eq 0) {
                $allPass = $false
                Write-Warning-Msg "User PATH enabled but no entries configured."
            }
            Write-Warning-Msg "User PATH from SYSTEM context only affects the Default user profile."
        }

        if ($Config.Environment.Variables -and $Config.Environment.Variables.Count -gt 0) {
            Write-Result "Environment variables" $true
            foreach ($var in $Config.Environment.Variables) {
                Write-Host "    $($var.Name) = $($var.Value) ($($var.Scope))"
            }
        }
    }

    Write-Host ""
    $overallColor = if ($allPass) { "Green" } else { "Red" }
    $overallResult = if ($allPass) { "VALIDATION PASSED" } else { "VALIDATION FAILED" }
    Write-Host "RESULT: $overallResult" -ForegroundColor $overallColor
    Write-Host "========================================" -ForegroundColor Cyan
}

# --- Main ---

$env:INTUNE_LOCAL_TEST = '1'

$Config = Import-PowerShellDataFile (Join-Path $ScriptDir 'Configuration.psd1')

switch ($Mode) {
    'Validate' {
        Test-Package
    }

    'Install' {
        Write-Banner "Intune Application Test - Install"
        Write-Host "Application: $($Config.ApplicationName)"
        Write-Host "Mode: Install"
        Write-Host ""

        $script = Join-Path $ScriptDir 'Install.ps1'
        & $script
        $installExit = $LASTEXITCODE

        Write-Host ""
        $success = ($installExit -in @(0, 3010))
        Write-Result "Exit Code" $success
        Write-Host "  Exit Code Value: $installExit"

        $overallColor = if ($success) { "Green" } else { "Red" }
        $overallResult = if ($success) { "SUCCESS" } else { "FAILURE" }
        Write-Host ""
        Write-Host "RESULT: $overallResult" -ForegroundColor $overallColor
        Write-Host "========================================" -ForegroundColor Cyan
    }

    'Uninstall' {
        Write-Banner "Intune Application Test - Uninstall"
        Write-Host "Application: $($Config.ApplicationName)"
        Write-Host "Mode: Uninstall"
        Write-Host ""

        $script = Join-Path $ScriptDir 'Uninstall.ps1'
        & $script
        $uninstallExit = $LASTEXITCODE

        Write-Host ""
        $success = ($uninstallExit -in @(0, 3010))
        Write-Result "Exit Code" $success
        Write-Host "  Exit Code Value: $uninstallExit"

        $overallColor = if ($success) { "Green" } else { "Red" }
        $overallResult = if ($success) { "SUCCESS" } else { "FAILURE" }
        Write-Host ""
        Write-Host "RESULT: $overallResult" -ForegroundColor $overallColor
        Write-Host "========================================" -ForegroundColor Cyan
    }

    'Detection' {
        Write-Banner "Intune Application Test - Detection"
        Write-Host "Application: $($Config.ApplicationName)"
        Write-Host "Mode: Detection"
        Write-Host ""

        $script = Join-Path $ScriptDir 'Detection.ps1'
        & $script
        $detectionExit = $LASTEXITCODE

        $detected = ($detectionExit -eq 0)
        Write-Result "Detection" $detected
        $status = if ($detected) { "Installed" } else { "Not Installed" }
        Write-Host "  Status: $status"

        Write-Host ""
        Write-Host "========================================" -ForegroundColor Cyan
    }

    'Environment' {
        Write-Banner "Intune Application Test - Environment"
        Write-Host "Application: $($Config.ApplicationName)"
        Write-Host "Mode: Environment Validation"
        Write-Host ""

        if (-not $Config.Environment -or -not $Config.Environment.Enabled) {
            Write-Host "Environment configuration is not enabled." -ForegroundColor Yellow
            Write-Host "========================================" -ForegroundColor Cyan
            return
        }

        $allPass = $true

        # System PATH checks
        if ($Config.Environment.SystemPath -and $Config.Environment.SystemPath.Enabled) {
            Write-Host "System PATH" -ForegroundColor Cyan
            Write-Host "-----------"
            foreach ($entry in $Config.Environment.SystemPath.Entries) {
                $registered = Test-PathEntry -Entry $entry -Scope 'Machine'
                Write-Result "  Registered: $entry" $registered
                if (-not $registered) { $allPass = $false }

                $dirExists = Test-Path $entry
                Write-Result "  Directory exists" $dirExists
                if (-not $dirExists) { Write-Warning-Msg "Directory does not exist yet (may be created by installer)." }
            }

            # Duplicate check
            $currentPath = Get-PersistentPath -Scope 'Machine'
            $entries = Split-PathString $currentPath
            $normalized = $entries | ForEach-Object { (Normalize-PathEntry $_).ToLower() }
            $dupes = $normalized | Group-Object | Where-Object { $_.Count -gt 1 }
            $noDupes = ($dupes.Count -eq 0)
            Write-Result "  No duplicates" $noDupes
            if (-not $noDupes) {
                foreach ($d in $dupes) { Write-Warning-Msg "Duplicate: $($d.Name)" }
            }
            Write-Host ""
        }

        # User PATH checks
        if ($Config.Environment.UserPath -and $Config.Environment.UserPath.Enabled) {
            Write-Host "User PATH" -ForegroundColor Cyan
            Write-Host "---------"
            Write-Warning-Msg "User PATH from SYSTEM context only affects Default user profile."
            foreach ($entry in $Config.Environment.UserPath.Entries) {
                $registered = Test-PathEntry -Entry $entry -Scope 'User'
                Write-Result "  Registered: $entry" $registered
                if (-not $registered) { $allPass = $false }
            }
            Write-Host ""
        }

        # Environment variables
        if ($Config.Environment.Variables -and $Config.Environment.Variables.Count -gt 0) {
            Write-Host "Environment Variables" -ForegroundColor Cyan
            Write-Host "---------------------"
            foreach ($var in $Config.Environment.Variables) {
                $scope = if ($var.Scope) { $var.Scope } else { 'Machine' }
                $target = [System.EnvironmentVariableTarget]::$scope
                $actual = [Environment]::GetEnvironmentVariable($var.Name, $target)
                $set = ($null -ne $actual)
                Write-Result "  $($var.Name) ($scope)" $set
                if ($set) { Write-Host "    Value: $actual" }
                if (-not $set) { $allPass = $false }
            }
            Write-Host ""
        }

        # State tracking
        $state = Get-EnvironmentState -ApplicationName $Config.ApplicationName
        $hasState = ($null -ne $state)
        Write-Result "State tracking file" $hasState
        if ($hasState) {
            Write-Host "    Machine entries tracked: $(($state.MachinePathEntriesAdded | Measure-Object).Count)"
            Write-Host "    User entries tracked: $(($state.UserPathEntriesAdded | Measure-Object).Count)"
            Write-Host "    Variables tracked: $(($state.EnvironmentVariablesAdded | Measure-Object).Count)"
        }

        Write-Host ""
        $overallColor = if ($allPass) { "Green" } else { "Red" }
        $overallResult = if ($allPass) { "ENVIRONMENT PASS" } else { "ENVIRONMENT FAIL" }
        Write-Host "RESULT: $overallResult" -ForegroundColor $overallColor
        Write-Host "========================================" -ForegroundColor Cyan
    }

    'PathDiagnostics' {
        # Read-only report explaining why PATH registration succeeds or fails.
        $entries = @()
        if ($Config.Environment) {
            if ($Config.Environment.SystemPath) { $entries += @($Config.Environment.SystemPath.Entries) }
            if ($Config.Environment.UserPath)   { $entries += @($Config.Environment.UserPath.Entries) }
        }
        Get-PathDiagnostics -Entries ($entries | Where-Object { $_ })
    }

    'DetectPaths' {
        Write-Banner "CLI Path Discovery"
        Write-Host "Application: $($Config.ApplicationName)"
        Write-Host ""

        $searchPath = $InstallPath
        if (-not $searchPath) {
            if ($Config.Detection.Type -eq 'File' -and $Config.Detection.Path) {
                $searchPath = $Config.Detection.Path
            }
        }

        if (-not $searchPath) {
            Write-Host "No install path specified. Use -InstallPath or configure Detection.Path." -ForegroundColor Red
            Write-Host "========================================" -ForegroundColor Cyan
            return
        }

        Write-Host "Scanning: $searchPath"
        Write-Host ""

        if (-not (Test-Path $searchPath)) {
            Write-Host "Directory does not exist: $searchPath" -ForegroundColor Red
            Write-Host "Install the application first." -ForegroundColor Yellow
            Write-Host "========================================" -ForegroundColor Cyan
            return
        }

        $candidates = Find-CliDirectories -InstallPath $searchPath

        if ($candidates.Count -eq 0) {
            Write-Host "No CLI directories detected." -ForegroundColor Yellow
            Write-Host "========================================" -ForegroundColor Cyan
            return
        }

        Write-Host "Potential command-line directories detected:" -ForegroundColor Green
        Write-Host ""

        foreach ($candidate in $candidates) {
            $conf = $candidate.Confidence
            $confColor = switch ($conf) {
                'High'   { 'Green' }
                'Medium' { 'Yellow' }
                default  { 'Gray' }
            }
            Write-Host "  $($candidate.Directory)" -ForegroundColor White
            Write-Host "    CLI Confidence: $conf" -ForegroundColor $confColor
            Write-Host "    Detected:"
            foreach ($exe in $candidate.Executables) {
                $marker = if ($exe.IsCli) { '[CLI]' } else { '[GUI]' }
                Write-Host "      $marker $($exe.Name)" -ForegroundColor $(if ($exe.IsCli) { 'Green' } else { 'Gray' })
            }
            Write-Host ""
        }

        Write-Host "To add these paths, update Configuration.psd1 Environment.SystemPath.Entries" -ForegroundColor Cyan
        Write-Host "========================================" -ForegroundColor Cyan
    }

    'TestCommand' {
        Write-Banner "Test Command Resolution"

        if (-not $Command) {
            Write-Host "Usage: .\Test-Local.ps1 -Mode TestCommand -Command 'example-cli --version'" -ForegroundColor Yellow
            Write-Host "========================================" -ForegroundColor Cyan
            return
        }

        $parts = $Command -split ' ', 2
        $exe = $parts[0]
        $args = if ($parts.Count -gt 1) { $parts[1] } else { $null }

        Write-Host "Command: $Command"
        Write-Host ""

        $resolution = Test-CommandResolution -Command $exe
        Write-Result "PATH Resolution" $resolution.Found

        if ($resolution.Found) {
            Write-Host "  Executable: $($resolution.Path)"

            if ($args) {
                Write-Host "  Running: $Command"
                try {
                    $proc = Start-Process -FilePath $resolution.Path -ArgumentList $args -Wait -PassThru -NoNewWindow -RedirectStandardOutput "$env:TEMP\testcmd_out.txt" -RedirectStandardError "$env:TEMP\testcmd_err.txt"
                    Write-Result "Exit Code" ($proc.ExitCode -eq 0)
                    Write-Host "  Exit Code: $($proc.ExitCode)"
                    $output = Get-Content "$env:TEMP\testcmd_out.txt" -Raw -ErrorAction SilentlyContinue
                    if ($output) {
                        Write-Host "  Output:"
                        Write-Host "    $($output.Trim())"
                    }
                    Remove-Item "$env:TEMP\testcmd_out.txt", "$env:TEMP\testcmd_err.txt" -ErrorAction SilentlyContinue
                }
                catch {
                    Write-Host "  ERROR: $($_.Exception.Message)" -ForegroundColor Red
                }
            }
        }
        else {
            Write-Host "  The executable could not be resolved from PATH." -ForegroundColor Red
            Write-Host "  Possible causes:" -ForegroundColor Yellow
            Write-Host "    - Existing terminal session has stale environment variables." -ForegroundColor Yellow
            Write-Host "    - PATH entry was not registered." -ForegroundColor Yellow
            Write-Host "    - Application executable does not exist." -ForegroundColor Yellow
            Write-Host "    - Incorrect PATH directory." -ForegroundColor Yellow
        }

        Write-Host ""
        Write-Host "========================================" -ForegroundColor Cyan
    }
}
