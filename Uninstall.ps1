#Requires -Version 5.1
<#
.SYNOPSIS
    Intune Win32 app uninstall script. Supports MSI and EXE uninstall methods.
.DESCRIPTION
    For MSI: uses product GUID from registry (preferred), falls back to MSI file.
    For EXE: uses QuietUninstallString from registry, falls back to configured uninstall command.
    Removes JAVA_HOME and managed PATH entries after product removal.
#>

$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'Config.ps1')
. (Join-Path $PSScriptRoot 'Helpers.ps1')

Initialize-Logging

try {
    Write-Log '=== Uninstallation started ==='
    Write-Log "Application: $($AppConfig.ApplicationName)"
    Write-Log "Uninstall type: $($AppConfig.UninstallType)"

    # --- Execute uninstaller ---
    $exitCode = Invoke-Uninstaller -PackageRoot $PSScriptRoot

    # -1 means no uninstall method was found (already removed or never installed)
    if ($exitCode -ne -1) {
        $allowedCodes = $AppConfig.SuccessExitCodes + @(1605)
        if ($exitCode -notin $allowedCodes) {
            Write-Log "Uninstall failed with exit code $exitCode" -Level ERROR
            exit 1
        }
    }

    # --- Clean up environment variables ---
    if ($AppConfig.ConfigureEnvironment) {
        Set-MachineEnvVar -Name 'JAVA_HOME' -Value ''
        Remove-ManagedPathEntries

        # Validate cleanup
        $javaHome = [Environment]::GetEnvironmentVariable('JAVA_HOME', 'Machine')
        if ($javaHome) {
            Write-Log "JAVA_HOME still set after removal: $javaHome" -Level WARN
        } else {
            Write-Log 'JAVA_HOME removed successfully'
        }

        if ($AppConfig.VendorPathPattern) {
            $machinePath = Get-MachinePathRaw
            $remaining = ($machinePath -split ';') | Where-Object {
                $expanded = Resolve-NormalizedPath ([Environment]::ExpandEnvironmentVariables($_))
                $expanded -match $AppConfig.VendorPathPattern
            }
            if ($remaining) {
                Write-Log "Managed PATH entries still present: $($remaining -join '; ')" -Level WARN
            } else {
                Write-Log 'All managed PATH entries removed successfully'
            }
        }
    }

    Write-Log '=== Uninstallation completed ==='
    exit 0

} catch {
    Write-Log "Unhandled error: $($_.Exception.Message)" -Level ERROR
    Write-Log "Stack trace: $($_.ScriptStackTrace)" -Level ERROR
    exit 1
}
