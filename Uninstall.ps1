#Requires -Version 5.1
<#
.SYNOPSIS
    Intune Win32 app uninstall script for Oracle JDK.
.DESCRIPTION
    Uninstalls JDK via MSI, removes JAVA_HOME and managed PATH entries.
#>

$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'Config.ps1')
. (Join-Path $PSScriptRoot 'Helpers.ps1')

Initialize-Logging

try {
    Write-Log '=== Uninstallation started ==='

    # --- Find the installed product for uninstall ---
    $msiPath = Join-Path $PSScriptRoot $AppConfig.MsiFileName
    $msiLogFile = Join-Path $AppConfig.LogDirectory 'msi-uninstall.log'

    if (Test-Path $msiPath) {
        Write-Log "Uninstalling via MSI: $msiPath"
        $arguments = "/x `"$msiPath`" /qn /norestart /l*v `"$msiLogFile`""
        $process = Start-Process -FilePath 'msiexec.exe' -ArgumentList $arguments -Wait -PassThru -NoNewWindow

        Write-Log "MSI uninstall exit code: $($process.ExitCode)"

        if ($process.ExitCode -notin ($AppConfig.SuccessExitCodes + @(1605))) {
            Write-Log "MSI uninstall failed with exit code $($process.ExitCode)" -Level ERROR
            exit 1
        }
    } else {
        Write-Log 'MSI file not found — attempting environment cleanup only' -Level WARN
    }

    # --- Remove JAVA_HOME ---
    Set-MachineEnvVar -Name 'JAVA_HOME' -Value ''

    # --- Remove managed PATH entries ---
    Remove-ManagedPathEntries

    # --- Validate cleanup ---
    $javaHome = [Environment]::GetEnvironmentVariable('JAVA_HOME', 'Machine')
    if ($javaHome) {
        Write-Log "JAVA_HOME still set after removal: $javaHome" -Level WARN
    } else {
        Write-Log 'JAVA_HOME removed successfully'
    }

    $machinePath = [Environment]::GetEnvironmentVariable('Path', 'Machine')
    $remaining = ($machinePath -split ';') | Where-Object {
        (Resolve-NormalizedPath $_) -match $AppConfig.VendorPathPattern
    }
    if ($remaining) {
        Write-Log "Managed PATH entries still present: $($remaining -join '; ')" -Level WARN
    } else {
        Write-Log 'All managed PATH entries removed successfully'
    }

    Write-Log '=== Uninstallation completed ==='
    exit 0

} catch {
    Write-Log "Unhandled error: $($_.Exception.Message)" -Level ERROR
    Write-Log "Stack trace: $($_.ScriptStackTrace)" -Level ERROR
    exit 1
}
