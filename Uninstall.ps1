#Requires -Version 5.1
<#
.SYNOPSIS
    Intune Win32 app uninstall script for Oracle JDK.
.DESCRIPTION
    Uninstalls JDK via product GUID (preferred) or MSI file fallback,
    removes JAVA_HOME and managed PATH entries.
#>

$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'Config.ps1')
. (Join-Path $PSScriptRoot 'Helpers.ps1')

Initialize-Logging

try {
    Write-Log '=== Uninstallation started ==='

    $msiLogFile = Join-Path $AppConfig.LogDirectory 'msi-uninstall.log'
    $uninstalled = $false

    # --- Strategy 1: Uninstall via product GUID from registry ---
    $productGuid = Get-InstalledProductGuid
    if ($productGuid) {
        Write-Log "Uninstalling via product GUID: $productGuid"
        $arguments = "/x `"$productGuid`" /qn /norestart /l*v `"$msiLogFile`""
        $process = Start-Process -FilePath 'msiexec.exe' -ArgumentList $arguments -Wait -PassThru -NoNewWindow

        Write-Log "MSI uninstall exit code: $($process.ExitCode)"

        if ($process.ExitCode -notin ($AppConfig.SuccessExitCodes + @(1605))) {
            Write-Log "MSI uninstall failed with exit code $($process.ExitCode)" -Level ERROR
            exit 1
        }
        $uninstalled = $true
    }

    # --- Strategy 2: Fallback to MSI file if GUID not found ---
    if (-not $uninstalled) {
        $msiPath = Join-Path $PSScriptRoot $AppConfig.MsiFileName
        if (Test-Path $msiPath) {
            Write-Log "Product GUID not found. Uninstalling via MSI file: $msiPath"
            $arguments = "/x `"$msiPath`" /qn /norestart /l*v `"$msiLogFile`""
            $process = Start-Process -FilePath 'msiexec.exe' -ArgumentList $arguments -Wait -PassThru -NoNewWindow

            Write-Log "MSI uninstall exit code: $($process.ExitCode)"

            if ($process.ExitCode -notin ($AppConfig.SuccessExitCodes + @(1605))) {
                Write-Log "MSI uninstall failed with exit code $($process.ExitCode)" -Level ERROR
                exit 1
            }
        } else {
            Write-Log 'No product GUID or MSI file found — performing environment cleanup only' -Level WARN
        }
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

    Write-Log '=== Uninstallation completed ==='
    exit 0

} catch {
    Write-Log "Unhandled error: $($_.Exception.Message)" -Level ERROR
    Write-Log "Stack trace: $($_.ScriptStackTrace)" -Level ERROR
    exit 1
}
