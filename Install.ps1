#Requires -Version 5.1
<#
.SYNOPSIS
    Intune Win32 app install script. Supports MSI and EXE installers.
.DESCRIPTION
    Executes the configured installer (MSI via msiexec or EXE directly),
    dynamically determines the installation path, and optionally configures
    JAVA_HOME and Machine PATH using registry-safe APIs.
    Idempotent, version-independent, safe for repeated execution.
.NOTES
    Run context: SYSTEM (Intune managed installer)
    Machine-level environment changes do not affect already-running processes.
    New processes launched after this script completes will inherit the updated environment.
#>

$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'Config.ps1')
. (Join-Path $PSScriptRoot 'Helpers.ps1')

Initialize-Logging

try {
    Write-Log '=== Installation started ==='
    Write-Log "Application: $($AppConfig.ApplicationName)"
    Write-Log "Installer type: $($AppConfig.InstallerType)"

    # --- Validate configuration ---
    if (-not (Test-PackageConfiguration -PackageRoot $PSScriptRoot -ValidateInstallerExists)) {
        Write-Log 'Package configuration validation failed' -Level ERROR
        exit 1
    }

    # --- Execute installer ---
    $exitCode = Invoke-Installer -PackageRoot $PSScriptRoot

    if ($exitCode -notin $AppConfig.SuccessExitCodes) {
        Write-Log "Installation failed with exit code $exitCode" -Level ERROR
        exit 1
    }

    $rebootRequired = $exitCode -in $AppConfig.RebootExitCodes

    # --- Post-install: environment configuration ---
    if ($AppConfig.ConfigureEnvironment) {
        Write-Log 'Configuring environment variables...'

        # Determine installed application path
        $installPath = Get-InstalledJdkPath

        if (-not $installPath) {
            Write-Log 'Failed to determine installation path after installer completed' -Level ERROR
            exit 1
        }

        # Verify executable exists
        if (-not (Test-JdkInstalled -JdkPath $installPath)) {
            Write-Log 'Post-install verification failed' -Level ERROR
            exit 1
        }

        $binDir = Join-Path $installPath $AppConfig.PathSubdirectory

        # Set JAVA_HOME
        Set-MachineEnvVar -Name 'JAVA_HOME' -Value $installPath

        # Configure PATH (removes obsolete entries, adds current)
        Update-MachinePath -NewEntry $binDir

        # Validate environment
        $configValid = Test-EnvironmentConfiguration -ExpectedJavaHome $installPath -ExpectedBinDir $binDir

        if (-not $configValid) {
            Write-Log 'Post-installation environment validation failed' -Level ERROR
            exit 1
        }
    } else {
        Write-Log 'Environment configuration disabled — skipping PATH/env-var setup'
    }

    Write-Log '=== Installation completed successfully ==='

    if ($rebootRequired) {
        Write-Log 'A reboot is required to complete the installation'
        exit 3010
    }

    exit 0

} catch {
    Write-Log "Unhandled error: $($_.Exception.Message)" -Level ERROR
    Write-Log "Stack trace: $($_.ScriptStackTrace)" -Level ERROR
    exit 1
}
