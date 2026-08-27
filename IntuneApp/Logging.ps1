#Requires -Version 5.1
<#
.SYNOPSIS
    Centralized logging module for the Intune Win32 deployment framework.
.DESCRIPTION
    Provides structured logging to files under C:\ProgramData\<CompanyName>\IntuneApps\<AppName>\.
    All log entries include timestamp, computer name, context, and severity.
#>

$script:LogState = @{
    Initialized   = $false
    LogDirectory  = ''
    CurrentLogFile = ''
    ApplicationName = ''
    ApplicationVersion = ''
    CompanyName   = ''
    ScriptName    = ''
    StartTime     = $null
}

function Initialize-Logging {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ApplicationName,
        [Parameter(Mandatory)][string]$CompanyName,
        [Parameter(Mandatory)][string]$ScriptName,
        [string]$ApplicationVersion = ''
    )

    $script:LogState.ApplicationName    = $ApplicationName
    $script:LogState.ApplicationVersion = $ApplicationVersion
    $script:LogState.CompanyName        = $CompanyName
    $script:LogState.ScriptName         = $ScriptName
    $script:LogState.StartTime          = Get-Date

    $basePath = Join-Path $env:ProgramData $CompanyName
    $appsPath = Join-Path $basePath 'IntuneApps'
    $appPath  = Join-Path $appsPath $ApplicationName
    $script:LogState.LogDirectory = $appPath

    if (-not (Test-Path $appPath)) {
        New-Item -Path $appPath -ItemType Directory -Force | Out-Null
    }

    $logFileName = "$ScriptName.log"
    $script:LogState.CurrentLogFile = Join-Path $appPath $logFileName
    $script:LogState.Initialized = $true

    Write-Log -Message "=== $ScriptName Started ===" -Level 'Info'
    Write-Log -Message "Application: $ApplicationName $ApplicationVersion" -Level 'Info'
    Write-Log -Message "Computer: $env:COMPUTERNAME" -Level 'Info'
    Write-Log -Message "User Context: $([System.Security.Principal.WindowsIdentity]::GetCurrent().Name)" -Level 'Info'
    Write-Log -Message "PowerShell Version: $($PSVersionTable.PSVersion)" -Level 'Info'
    Write-Log -Message "OS: $([System.Environment]::OSVersion.VersionString)" -Level 'Info'
}

function Write-Log {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Message,
        [ValidateSet('Info','Warning','Error','Debug')][string]$Level = 'Info'
    )

    if (-not $script:LogState.Initialized) {
        Write-Warning "Logging not initialized. Call Initialize-Logging first."
        return
    }

    $timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss.fff'
    $entry = "[$timestamp] [$Level] [$($script:LogState.ScriptName)] $Message"

    try {
        Add-Content -Path $script:LogState.CurrentLogFile -Value $entry -ErrorAction Stop
    }
    catch {
        Write-Warning "Failed to write to log file: $_"
    }

    switch ($Level) {
        'Error'   { Write-Error $Message -ErrorAction Continue }
        'Warning' { Write-Warning $Message }
        'Debug'   { Write-Verbose $Message }
        default   { Write-Verbose $Message }
    }
}

function Write-DeploymentSummary {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Action,
        [Parameter(Mandatory)][int]$ExitCode,
        [string]$DetectionResult = 'N/A',
        [string]$ValidationResult = 'N/A',
        [string]$ErrorDetail = ''
    )

    $endTime  = Get-Date
    $duration = $endTime - $script:LogState.StartTime

    $summaryFile = Join-Path $script:LogState.LogDirectory 'DeploymentSummary.log'

    $summary = @"

================================================================================
DEPLOYMENT SUMMARY
================================================================================
Timestamp       : $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
Computer        : $env:COMPUTERNAME
Application     : $($script:LogState.ApplicationName)
Version         : $($script:LogState.ApplicationVersion)
Action          : $Action
User Context    : $([System.Security.Principal.WindowsIdentity]::GetCurrent().Name)
Start Time      : $($script:LogState.StartTime.ToString('yyyy-MM-dd HH:mm:ss'))
End Time        : $($endTime.ToString('yyyy-MM-dd HH:mm:ss'))
Duration        : $($duration.ToString('hh\:mm\:ss'))
Exit Code       : $ExitCode
Detection       : $DetectionResult
Validation      : $ValidationResult
$(if ($ErrorDetail) { "Error           : $ErrorDetail" })
================================================================================

"@

    try {
        Add-Content -Path $summaryFile -Value $summary -ErrorAction Stop
    }
    catch {
        Write-Warning "Failed to write deployment summary: $_"
    }

    Write-Log -Message "Deployment Summary written. Exit Code: $ExitCode | Detection: $DetectionResult | Validation: $ValidationResult" -Level 'Info'

    if ($ErrorDetail) {
        Write-Log -Message "Error Detail: $ErrorDetail" -Level 'Error'
    }

    Write-Log -Message "=== $($script:LogState.ScriptName) Completed (Duration: $($duration.ToString('hh\:mm\:ss'))) ===" -Level 'Info'
}

function Get-LogDirectory {
    return $script:LogState.LogDirectory
}

function Get-LogFilePath {
    return $script:LogState.CurrentLogFile
}
