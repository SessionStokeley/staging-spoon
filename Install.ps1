#Requires -Version 5.1
<#
.SYNOPSIS
    Intune Win32 app install script for Oracle JDK.
.DESCRIPTION
    Installs JDK via MSI, dynamically determines the installation path,
    configures JAVA_HOME and Machine PATH using .NET environment APIs.
    Idempotent, version-independent, safe for repeated execution.
.NOTES
    Run context: SYSTEM (Intune managed installer)
    Machine-level environment changes do not affect already-running processes.
    New processes launched after this script completes will inherit the updated PATH.
#>

$ErrorActionPreference = 'Stop'

# Load configuration and helpers
. (Join-Path $PSScriptRoot 'Config.ps1')
. (Join-Path $PSScriptRoot 'Helpers.ps1')

Initialize-Logging

try {
    Write-Log '=== Installation started ==='
    Write-Log "Application: $($AppConfig.ApplicationName)"

    # --- MSI Installation ---
    $msiPath = Join-Path $PSScriptRoot $AppConfig.MsiFileName

    if (-not (Test-Path $msiPath)) {
        Write-Log "MSI not found: $msiPath" -Level ERROR
        exit 1
    }

    Write-Log "Installing MSI: $msiPath"

    $msiLogFile = Join-Path $AppConfig.LogDirectory 'msi-install.log'
    $arguments = "/i `"$msiPath`" $($AppConfig.MsiArguments) /l*v `"$msiLogFile`""

    $process = Start-Process -FilePath 'msiexec.exe' -ArgumentList $arguments -Wait -PassThru -NoNewWindow

    Write-Log "MSI exit code: $($process.ExitCode)"

    if ($process.ExitCode -notin $AppConfig.SuccessExitCodes) {
        Write-Log "MSI installation failed with exit code $($process.ExitCode)" -Level ERROR
        exit 1
    }

    $rebootRequired = $process.ExitCode -in $AppConfig.RebootExitCodes

    # --- Determine Installed Path ---
    $javaHome = Get-InstalledJdkPath

    if (-not $javaHome) {
        Write-Log 'Failed to determine JDK installation path after MSI completed' -Level ERROR
        exit 1
    }

    # --- Verify Installation ---
    if (-not (Test-JdkInstalled -JdkPath $javaHome)) {
        Write-Log 'JDK verification failed — java.exe not found' -Level ERROR
        exit 1
    }

    $javaBin = Join-Path $javaHome 'bin'

    # --- Configure JAVA_HOME ---
    Set-MachineEnvVar -Name 'JAVA_HOME' -Value $javaHome

    # --- Configure PATH (removes obsolete JDK entries, adds current) ---
    Update-MachinePath -NewEntry $javaBin

    # --- Validate ---
    $configValid = Test-EnvironmentConfiguration -ExpectedJavaHome $javaHome -ExpectedBinDir $javaBin

    if (-not $configValid) {
        Write-Log 'Post-installation environment validation failed' -Level ERROR
        exit 1
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
