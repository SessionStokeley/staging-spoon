#Requires -Version 5.1
<#
    Runner.ps1

    The boundary between configuration and execution.

    Everything before this point is analysis and configuration. Nothing here
    runs until Confirm-ConfigurationExecution returns true, and execution
    itself is delegated to the existing engine (Install.ps1, Uninstall.ps1,
    Detection.ps1) rather than reimplemented.
#>

Set-StrictMode -Version Latest

function Confirm-ConfigurationExecution {
    <#
        .SYNOPSIS
        The approval gate. Shows exactly what the configuration will do and
        requires an explicit confirmation.

        .PARAMETER Force
        Bypass the interactive prompt. Intended for automation that has already
        obtained approval; never set this by default.
    #>
    param(
        [Parameter(Mandatory)]$Model,
        [string]$ConfigPath = '',
        [switch]$Force
    )

    $warning = Get-ExecutionWarningText -Model $Model -ConfigPath $ConfigPath

    Write-Host ''
    Write-Host ('=' * 62) -ForegroundColor Yellow
    Write-Host ' You are about to execute this configuration.' -ForegroundColor Yellow
    Write-Host ('=' * 62) -ForegroundColor Yellow
    Write-Host ''
    Write-Host ' This may:' -ForegroundColor Yellow
    foreach ($effect in $warning.Effects) {
        Write-Host "   - $effect" -ForegroundColor Yellow
    }
    Write-Host ''
    if ($ConfigPath) {
        Write-Host " Configuration: $ConfigPath"
    }
    Write-Host " Application  : $(Get-ModelValue $Model 'ApplicationName')"
    Write-Host ''

    if ($Force) {
        Write-Host ' Approval bypassed (-Force).' -ForegroundColor DarkYellow
        return $true
    }

    $answer = Read-WizardInput -Prompt " Type 'run' to continue, anything else to cancel"
    $approved = ($answer.Trim().ToLowerInvariant() -eq 'run')

    if (-not $approved) {
        Write-Host ' Cancelled. Nothing was executed.' -ForegroundColor Green
    }
    return $approved
}

function Invoke-Configuration {
    <#
        .SYNOPSIS
        Hands an approved configuration to the existing packaging engine.

        .DESCRIPTION
        This does not contain installation logic of its own. It runs the
        engine's own scripts against the configuration that was approved.

        .PARAMETER Mode
        Install, Uninstall, or Detect.
    #>
    param(
        [Parameter(Mandatory)][string]$PackageRoot,
        [ValidateSet('Install', 'Uninstall', 'Detect')][string]$Mode = 'Install',
        [switch]$LocalTest
    )

    $scriptName = switch ($Mode) {
        'Install'   { 'Install.ps1' }
        'Uninstall' { 'Uninstall.ps1' }
        'Detect'    { 'Detection.ps1' }
    }

    $scriptPath = Join-Path $PackageRoot $scriptName
    if (-not (Test-Path -LiteralPath $scriptPath)) {
        throw "Packaging engine script not found: $scriptPath"
    }

    # Signals the engine that this is a technician-run local test rather than
    # an Intune SYSTEM deployment, so it relaxes its SYSTEM-context check.
    if ($LocalTest) { $env:INTUNE_LOCAL_TEST = '1' }

    Write-Host ''
    Write-Host "Running $scriptName ..." -ForegroundColor Cyan

    & $scriptPath
    $exitCode = $LASTEXITCODE

    if ($LocalTest) { Remove-Item Env:\INTUNE_LOCAL_TEST -ErrorAction SilentlyContinue }

    return [pscustomobject]@{
        Mode     = $Mode
        Script   = $scriptName
        ExitCode = $exitCode
        Success  = ($exitCode -in @(0, 3010))
    }
}

function Test-PackageWorkflow {
    <#
        .SYNOPSIS
        Runs the full success-criteria sequence against an approved package:
        install, detect, uninstall, detect.

        .PARAMETER SkipUninstall
        Stop after install and detection, leaving the application installed.
    #>
    param(
        [Parameter(Mandatory)][string]$PackageRoot,
        [switch]$SkipUninstall
    )

    $results = [ordered]@{}

    Write-Host ''
    Write-Host ('=' * 62) -ForegroundColor Cyan
    Write-Host ' Package workflow test' -ForegroundColor Cyan
    Write-Host ('=' * 62) -ForegroundColor Cyan

    $install = Invoke-Configuration -PackageRoot $PackageRoot -Mode Install -LocalTest
    $results['Install'] = $install

    $detectAfterInstall = Invoke-Configuration -PackageRoot $PackageRoot -Mode Detect -LocalTest
    $results['DetectionAfterInstall'] = [pscustomobject]@{
        Mode     = 'Detect'
        ExitCode = $detectAfterInstall.ExitCode
        Success  = ($detectAfterInstall.ExitCode -eq 0)   # 0 means detected
    }

    if (-not $SkipUninstall) {
        $uninstall = Invoke-Configuration -PackageRoot $PackageRoot -Mode Uninstall -LocalTest
        $results['Uninstall'] = $uninstall

        $detectAfterUninstall = Invoke-Configuration -PackageRoot $PackageRoot -Mode Detect -LocalTest
        $results['DetectionAfterUninstall'] = [pscustomobject]@{
            Mode     = 'Detect'
            ExitCode = $detectAfterUninstall.ExitCode
            Success  = ($detectAfterUninstall.ExitCode -ne 0)  # non-zero means gone
        }
    }

    Write-Host ''
    Write-Host 'Results' -ForegroundColor White
    Write-Host ('-' * 40)
    $allPass = $true
    foreach ($key in $results.Keys) {
        $r = $results[$key]
        $status = if ($r.Success) { 'PASS' } else { 'FAIL' }
        $color = if ($r.Success) { 'Green' } else { 'Red' }
        Write-Host ("  {0,-26} {1}  (exit {2})" -f $key, $status, $r.ExitCode) -ForegroundColor $color
        if (-not $r.Success) { $allPass = $false }
    }
    Write-Host ('-' * 40)
    Write-Host ("  OVERALL: {0}" -f $(if ($allPass) { 'PASS' } else { 'FAIL' })) `
        -ForegroundColor $(if ($allPass) { 'Green' } else { 'Red' })

    return [pscustomobject]@{
        Results = $results
        Success = $allPass
    }
}

function Find-IntuneWinAppUtil {
    <#
        Locates IntuneWinAppUtil.exe on PATH or in common locations.
    #>
    param([string]$ExplicitPath = '')

    if ($ExplicitPath) {
        if (Test-Path -LiteralPath $ExplicitPath) { return (Resolve-Path $ExplicitPath).Path }
        throw "IntuneWinAppUtil.exe not found at: $ExplicitPath"
    }

    $onPath = Get-Command 'IntuneWinAppUtil.exe' -ErrorAction SilentlyContinue
    if ($onPath) { return $onPath.Source }

    foreach ($candidate in @(
        (Join-Path $PSScriptRoot 'IntuneWinAppUtil.exe'),
        (Join-Path (Split-Path -Parent $PSScriptRoot) 'IntuneWinAppUtil.exe'),
        'C:\Tools\IntuneWinAppUtil.exe',
        'C:\Program Files\Microsoft\IntuneWinAppUtil.exe'
    )) {
        if (Test-Path -LiteralPath $candidate) { return $candidate }
    }

    return $null
}

function Build-IntunePackage {
    <#
        .SYNOPSIS
        Wraps IntuneWinAppUtil.exe so the technician does not invoke it by hand.

        .PARAMETER PackageRoot
        Directory containing Install.ps1 and the Files\ folder.

        .PARAMETER OutputPath
        Directory to write the .intunewin into.
    #>
    param(
        [Parameter(Mandatory)][string]$PackageRoot,
        [string]$OutputPath = '',
        [string]$SetupFile = 'Install.ps1',
        [string]$UtilPath = ''
    )

    if (-not $OutputPath) { $OutputPath = Join-Path $PackageRoot 'Output' }

    $util = Find-IntuneWinAppUtil -ExplicitPath $UtilPath
    if (-not $util) {
        Write-Host ''
        Write-Host 'IntuneWinAppUtil.exe was not found.' -ForegroundColor Red
        Write-Host 'Download it from the Microsoft Win32 Content Prep Tool repository,' -ForegroundColor Yellow
        Write-Host 'then place it on PATH or pass -UtilPath.' -ForegroundColor Yellow
        Write-Host ''
        Write-Host 'The equivalent manual command is:' -ForegroundColor DarkGray
        Write-Host "  IntuneWinAppUtil.exe -c `"$PackageRoot`" -s $SetupFile -o `"$OutputPath`"" -ForegroundColor DarkGray
        return [pscustomobject]@{ Success = $false; Path = $null; Reason = 'IntuneWinAppUtil.exe not found' }
    }

    if (-not (Test-Path -LiteralPath $OutputPath)) {
        New-Item -Path $OutputPath -ItemType Directory -Force | Out-Null
    }

    Write-Host ''
    Write-Host 'Building .intunewin package...' -ForegroundColor Cyan
    Write-Host "  Source : $PackageRoot"
    Write-Host "  Setup  : $SetupFile"
    Write-Host "  Output : $OutputPath"

    $proc = Start-Process -FilePath $util `
        -ArgumentList @('-c', "`"$PackageRoot`"", '-s', $SetupFile, '-o', "`"$OutputPath`"", '-q') `
        -Wait -PassThru -NoNewWindow

    if ($proc.ExitCode -ne 0) {
        Write-Host "IntuneWinAppUtil.exe failed with exit code $($proc.ExitCode)." -ForegroundColor Red
        return [pscustomobject]@{ Success = $false; Path = $null; Reason = "Exit code $($proc.ExitCode)" }
    }

    $built = Get-ChildItem -LiteralPath $OutputPath -Filter '*.intunewin' -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending | Select-Object -First 1

    if ($built) {
        Write-Host "Package built: $($built.FullName)" -ForegroundColor Green
        return [pscustomobject]@{ Success = $true; Path = $built.FullName; Reason = '' }
    }

    return [pscustomobject]@{ Success = $false; Path = $null; Reason = 'No .intunewin produced' }
}

function Show-IntunePortalSettings {
    <#
        Prints the values to enter in the Intune portal for this configuration.
    #>
    param([Parameter(Mandatory)]$Model)

    Write-Host ''
    Write-Host 'Intune portal settings' -ForegroundColor Cyan
    Write-Host ('-' * 62)
    Write-Host "  Name              : $(Get-ModelValue $Model 'ApplicationName')"
    Write-Host "  Publisher         : $(Get-ModelValue $Model 'Publisher')"
    Write-Host "  Install command   : $(Get-ModelValue $Model 'Intune.InstallCommand')"
    Write-Host "  Uninstall command : $(Get-ModelValue $Model 'Intune.UninstallCommand')"
    Write-Host "  Install behavior  : $(Get-ModelValue $Model 'Intune.InstallBehavior')"
    Write-Host "  Detection         : Custom script - $(Get-ModelValue $Model 'Intune.DetectionScript')"
    Write-Host ('-' * 62)
    Write-Host ''
}
