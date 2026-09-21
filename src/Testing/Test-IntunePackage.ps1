<#
.SYNOPSIS
    Simulates the Intune deployment environment end to end.
.DESCRIPTION
    Proves the exact Intune execution path works before a package is called
    successful. The package is copied to a random temporary directory so any
    dependency on its build location surfaces here rather than on a device.

    The full cycle is:
        install -> detection TRUE -> uninstall -> detection FALSE

    Anything less is NOT PRODUCTION READY.
.PARAMETER SourcePath
    The deployment source directory.
.PARAMETER ManifestPath
    PackageManifest.json describing the package.
.PARAMETER SystemContext
    Run every stage as NT AUTHORITY\SYSTEM. Requires an elevated session.
.PARAMETER SkipUninstall
    Run install and detection only. The package cannot be production ready.
.EXAMPLE
    .\Test-IntunePackage.ps1 -SourcePath .\source -ManifestPath .\source\PackageManifest.json -SystemContext
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$SourcePath,
    [Parameter(Mandatory)][string]$ManifestPath,
    [string]$OutputPath = (Join-Path $PWD 'TestResults'),
    [switch]$SystemContext,
    [switch]$SkipUninstall,
    [int]$DetectionSettleSeconds = 15,
    [int]$TimeoutSeconds = 1800,
    [hashtable]$PostInstallExpectation = @{}
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$coreRoot = Join-Path (Split-Path $PSScriptRoot -Parent) 'Core'
. (Join-Path $coreRoot 'PackageManifest.ps1')
. (Join-Path $coreRoot 'CommandParser.ps1')
. (Join-Path $coreRoot 'StateSnapshot.ps1')
. (Join-Path $coreRoot 'FailureClassifier.ps1')
. (Join-Path $coreRoot 'ProcessRunner.ps1')
. (Join-Path $PSScriptRoot 'SystemContext.ps1')

function Write-Stage {
    param([string]$Message, [ValidateSet('Info', 'Pass', 'Fail', 'Skip')][string]$Status = 'Info')

    $color = switch ($Status) {
        'Pass' { 'Green' }
        'Fail' { 'Red' }
        'Skip' { 'Yellow' }
        default { 'Cyan' }
    }
    Write-Host $Message -ForegroundColor $color
}

function Test-DetectionContract {
    <#
    .SYNOPSIS
        Evaluates an execution result against Intune's detection contract.
    .DESCRIPTION
        Intune treats a custom detection script as "detected" only when it
        exits 0 AND writes to STDOUT. Output with a non-zero exit does not
        count, and neither does a zero exit with no output.
    #>
    param([Parameter(Mandatory)][PSCustomObject]$Result)

    $hasOutput = -not [string]::IsNullOrWhiteSpace($Result.StdOut)
    $detected = ($Result.ExitCode -eq 0) -and $hasOutput

    [PSCustomObject]@{
        Detected  = $detected
        ExitCode  = $Result.ExitCode
        HasOutput = $hasOutput
        Evidence  = $Result.StdOut.Trim()
        Reason    = if ($detected) {
            'Exit code 0 with STDOUT output'
        } elseif ($Result.ExitCode -ne 0) {
            "Exit code $($Result.ExitCode); Intune reads any non-zero exit as not detected"
        } else {
            'Exit code 0 with no STDOUT output'
        }
    }
}

# --- Setup -------------------------------------------------------------------
$manifest = Import-PackageManifest -Path $ManifestPath
$manifestCheck = Test-PackageManifest -Manifest $manifest
if (-not $manifestCheck.IsValid) {
    throw "Manifest is invalid: $($manifestCheck.Errors -join '; ')"
}

$context = if ($SystemContext) { 'System' } else { 'Current' }
$identity = Get-ExecutionContextIdentity

if ($SystemContext -and -not $identity.IsElevated) {
    throw "SYSTEM-context testing requires an elevated session"
}

if ($manifest.InstallBehavior -eq 'System' -and -not $SystemContext) {
    Write-Stage "WARNING: manifest declares InstallBehavior=System but -SystemContext was not specified." 'Skip'
    Write-Stage "         Working as Administrator does not prove the package works as SYSTEM." 'Skip'
}

if (-not (Test-Path -LiteralPath $OutputPath)) {
    New-Item -Path $OutputPath -ItemType Directory -Force | Out-Null
}

# Self-containment: run from an arbitrary directory, never the build directory.
$packageId = [guid]::NewGuid().ToString('N').Substring(0, 12)
$testRoot  = Join-Path $env:SystemRoot "Temp\IntunePkg-$packageId"

$stages = [System.Collections.Generic.List[PSCustomObject]]::new()

function Add-Stage {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][ValidateSet('PASS', 'FAIL', 'NOT TESTED')][string]$Result,
        [string]$Command = '',
        [Nullable[int]]$ExitCode = $null,
        [string]$Output = '',
        [string]$Detail = '',
        [timespan]$Duration = [timespan]::Zero
    )

    $stages.Add([PSCustomObject]@{
        Name     = $Name
        Result   = $Result
        Command  = $Command
        ExitCode = $ExitCode
        Output   = $Output
        Detail   = $Detail
        Duration = $Duration
    })
}

$overallStart = Get-Date
$snapshotBefore = $null
$installDelta = $null
$failureClassification = $null

try {
    Write-Stage "Intune package validation"
    Write-Stage "  Package : $($manifest.ApplicationName) $($manifest.ApplicationVersion) (pkg $($manifest.PackageVersion))"
    Write-Stage "  Context : $(if ($SystemContext) { 'NT AUTHORITY\SYSTEM' } else { $identity.Context })"
    Write-Stage "  Test dir: $testRoot"
    Write-Stage ""

    # --- 1-2. Stage the package into a temporary directory --------------------
    Write-Stage "[1/9] Staging package to a temporary directory"
    New-Item -Path $testRoot -ItemType Directory -Force | Out-Null
    Copy-Item -Path (Join-Path $SourcePath '*') -Destination $testRoot -Recurse -Force

    $stagedFiles = @(Get-ChildItem -LiteralPath $testRoot -Recurse -File)
    Add-Stage -Name 'Package staging' -Result 'PASS' -Detail "$($stagedFiles.Count) files staged to $testRoot"
    Write-Stage "      Staged $($stagedFiles.Count) files" 'Pass'

    # --- 3. Capture pre-install state ----------------------------------------
    Write-Stage "[2/9] Capturing pre-install state"
    $snapshotBefore = Get-StateSnapshot
    Write-Stage "      $($snapshotBefore.Applications.Count) applications, $($snapshotBefore.Services.Count) services" 'Pass'

    # --- 4. Execute the exact install command ---------------------------------
    Write-Stage "[3/9] Executing install command"
    Write-Stage "      $($manifest.InstallCommand)"

    $installResult = Invoke-InContext -CommandLine $manifest.InstallCommand `
                                      -WorkingDirectory $testRoot `
                                      -Context $context `
                                      -TimeoutSeconds $TimeoutSeconds

    $exitCodeResult = Resolve-InstallerExitCode -VendorExitCode $installResult.ExitCode `
                                                -SuccessExitCodes @($manifest.ExpectedExitCodes | Where-Object { $_ -notin @(1641, 3010) }) `
                                                -RebootExitCodes @(1641, 3010)

    $installOutput = ($installResult.StdOut + "`n" + $installResult.StdErr).Trim()

    if ($exitCodeResult.IsSuccess) {
        Add-Stage -Name 'Install' -Result 'PASS' -Command $manifest.InstallCommand `
                  -ExitCode $installResult.ExitCode -Output $installOutput `
                  -Detail $exitCodeResult.Interpretation -Duration $installResult.Duration
        Write-Stage "      Exit code $($installResult.ExitCode) - $($exitCodeResult.Interpretation)" 'Pass'
    } else {
        Add-Stage -Name 'Install' -Result 'FAIL' -Command $manifest.InstallCommand `
                  -ExitCode $installResult.ExitCode -Output $installOutput `
                  -Detail $exitCodeResult.Interpretation -Duration $installResult.Duration
        Write-Stage "      Exit code $($installResult.ExitCode) - $($exitCodeResult.Interpretation)" 'Fail'

        $failureClassification = Get-FailureClassification -Stage 'Install' `
                                                           -ExitCode $installResult.ExitCode `
                                                           -Output $installOutput `
                                                           -ExpectedExitCodes $manifest.ExpectedExitCodes `
                                                           -ExecutionContextName $(if ($SystemContext) { 'System' } else { $identity.Context })
        Write-Stage "      Classification: $($failureClassification.Classification)" 'Fail'
    }

    # --- 5. Settle, then run the exact detection Intune will use -------------
    Write-Stage "[4/9] Allowing $DetectionSettleSeconds seconds for asynchronous components"
    Start-Sleep -Seconds $DetectionSettleSeconds

    Write-Stage "[5/9] Running detection (expecting TRUE)"
    $detectionCommand = "powershell.exe -NoProfile -ExecutionPolicy Bypass -File `".\$($manifest.DetectionScript)`""

    $detectionResult = Invoke-InContext -CommandLine $detectionCommand `
                                        -WorkingDirectory $testRoot `
                                        -Context $context `
                                        -TimeoutSeconds 300
    $detection = Test-DetectionContract -Result $detectionResult

    if ($detection.Detected) {
        Add-Stage -Name 'Detection after install' -Result 'PASS' -Command $detectionCommand `
                  -ExitCode $detection.ExitCode -Output $detection.Evidence -Detail $detection.Reason
        Write-Stage "      Detected: $($detection.Evidence)" 'Pass'
    } else {
        Add-Stage -Name 'Detection after install' -Result 'FAIL' -Command $detectionCommand `
                  -ExitCode $detection.ExitCode -Output $detection.Evidence -Detail $detection.Reason
        Write-Stage "      Not detected - $($detection.Reason)" 'Fail'

        if (-not $failureClassification) {
            $failureClassification = Get-FailureClassification -Stage 'Detection' `
                                                               -ExitCode $installResult.ExitCode `
                                                               -Output $installOutput `
                                                               -DetectionResult $false `
                                                               -ExpectedExitCodes $manifest.ExpectedExitCodes `
                                                               -ExecutionContextName $(if ($SystemContext) { 'System' } else { $identity.Context })
            Write-Stage "      Classification: $($failureClassification.Classification)" 'Fail'
        }
    }

    # --- 6. Post-install state and delta -------------------------------------
    Write-Stage "[6/9] Capturing post-install state"
    $snapshotAfter = Get-StateSnapshot
    $installDelta = Compare-StateSnapshot -Before $snapshotBefore -After $snapshotAfter
    Save-InstallDelta -Delta $installDelta -Path (Join-Path $OutputPath 'InstallDelta.json') | Out-Null

    Write-Stage "      +$($installDelta.Applications.Added.Count) applications, +$($installDelta.Files.Added.Count) files, +$($installDelta.Services.Added.Count) services" 'Pass'

    if ($PostInstallExpectation.Count -gt 0) {
        Write-Stage "[7/9] Validating declared application state"
        $postInstall = Test-PostInstallState -Expectation $PostInstallExpectation
        $failedExpectations = @($postInstall.Results | Where-Object { -not $_.Passed })

        if ($postInstall.Passed) {
            Add-Stage -Name 'Post-install validation' -Result 'PASS' -Detail "$($postInstall.Results.Count) expectations met"
            Write-Stage "      All $($postInstall.Results.Count) expectations met" 'Pass'
        } else {
            Add-Stage -Name 'Post-install validation' -Result 'FAIL' `
                      -Detail (($failedExpectations | ForEach-Object { "$($_.Category) $($_.Target): $($_.Detail)" }) -join '; ')
            Write-Stage "      $($failedExpectations.Count) expectations not met" 'Fail'

            if (-not $failureClassification) {
                $failureClassification = Get-FailureClassification -Stage 'PostInstall'
            }
        }
    } else {
        Add-Stage -Name 'Post-install validation' -Result 'NOT TESTED' -Detail 'No expectations declared'
        Write-Stage "[7/9] Post-install validation skipped - no expectations declared" 'Skip'
    }

    # --- 7-9. Uninstall and detection removal ---------------------------------
    if ($SkipUninstall) {
        Add-Stage -Name 'Uninstall' -Result 'NOT TESTED' -Detail '-SkipUninstall specified'
        Add-Stage -Name 'Detection after uninstall' -Result 'NOT TESTED' -Detail '-SkipUninstall specified'
        Write-Stage "[8/9] Uninstall skipped" 'Skip'
        Write-Stage "[9/9] Detection removal skipped" 'Skip'
    } else {
        Write-Stage "[8/9] Executing uninstall command"
        Write-Stage "      $($manifest.UninstallCommand)"

        $uninstallResult = Invoke-InContext -CommandLine $manifest.UninstallCommand `
                                            -WorkingDirectory $testRoot `
                                            -Context $context `
                                            -TimeoutSeconds $TimeoutSeconds

        $uninstallExitResult = Resolve-InstallerExitCode -VendorExitCode $uninstallResult.ExitCode `
                                                         -SuccessExitCodes @($manifest.ExpectedExitCodes | Where-Object { $_ -notin @(1641, 3010) }) `
                                                         -RebootExitCodes @(1641, 3010)
        $uninstallOutput = ($uninstallResult.StdOut + "`n" + $uninstallResult.StdErr).Trim()

        if ($uninstallExitResult.IsSuccess) {
            Add-Stage -Name 'Uninstall' -Result 'PASS' -Command $manifest.UninstallCommand `
                      -ExitCode $uninstallResult.ExitCode -Output $uninstallOutput `
                      -Detail $uninstallExitResult.Interpretation -Duration $uninstallResult.Duration
            Write-Stage "      Exit code $($uninstallResult.ExitCode) - $($uninstallExitResult.Interpretation)" 'Pass'
        } else {
            Add-Stage -Name 'Uninstall' -Result 'FAIL' -Command $manifest.UninstallCommand `
                      -ExitCode $uninstallResult.ExitCode -Output $uninstallOutput `
                      -Detail $uninstallExitResult.Interpretation -Duration $uninstallResult.Duration
            Write-Stage "      Exit code $($uninstallResult.ExitCode) - $($uninstallExitResult.Interpretation)" 'Fail'

            if (-not $failureClassification) {
                $failureClassification = Get-FailureClassification -Stage 'Uninstall' `
                                                                   -ExitCode $uninstallResult.ExitCode `
                                                                   -Output $uninstallOutput `
                                                                   -ExpectedExitCodes $manifest.ExpectedExitCodes `
                                                                   -ExecutionContextName $(if ($SystemContext) { 'System' } else { $identity.Context })
            }
        }

        Start-Sleep -Seconds $DetectionSettleSeconds

        Write-Stage "[9/9] Running detection (expecting FALSE)"
        $removalResult = Invoke-InContext -CommandLine $detectionCommand `
                                          -WorkingDirectory $testRoot `
                                          -Context $context `
                                          -TimeoutSeconds 300
        $removalDetection = Test-DetectionContract -Result $removalResult

        if (-not $removalDetection.Detected) {
            Add-Stage -Name 'Detection after uninstall' -Result 'PASS' -Command $detectionCommand `
                      -ExitCode $removalDetection.ExitCode -Detail 'Detection correctly returns false after uninstall'
            Write-Stage "      Not detected - correct" 'Pass'
        } else {
            Add-Stage -Name 'Detection after uninstall' -Result 'FAIL' -Command $detectionCommand `
                      -ExitCode $removalDetection.ExitCode -Output $removalDetection.Evidence `
                      -Detail 'Detection still returns true after uninstall; Company Portal will report the app as installed'
            Write-Stage "      Still detected - uninstall did not remove detection evidence" 'Fail'

            if (-not $failureClassification) {
                $failureClassification = Get-FailureClassification -Stage 'DetectionRemoval' -DetectionResult $true
            }
        }
    }
} finally {
    if (Test-Path -LiteralPath $testRoot) {
        Remove-Item -LiteralPath $testRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}

# --- Result ------------------------------------------------------------------
$allStages = $stages.ToArray()
$failed    = @($allStages | Where-Object { $_.Result -eq 'FAIL' })
$notTested = @($allStages | Where-Object { $_.Result -eq 'NOT TESTED' })

# The golden rule: every stage of the cycle must pass, with none untested.
$requiredStages = @('Install', 'Detection after install', 'Uninstall', 'Detection after uninstall')
$requiredPassed = @($allStages | Where-Object { $_.Name -in $requiredStages -and $_.Result -eq 'PASS' }).Count -eq $requiredStages.Count

$result = [PSCustomObject]@{
    ApplicationName    = $manifest.ApplicationName
    ApplicationVersion = $manifest.ApplicationVersion
    PackageVersion     = $manifest.PackageVersion
    PackageHash        = $manifest.PackageHash
    TestedAt           = $overallStart.ToString('o')
    Duration           = (Get-Date) - $overallStart
    ExecutionContext   = if ($SystemContext) { 'NT AUTHORITY\SYSTEM' } else { $identity.Context }
    Environment        = [PSCustomObject]@{
        ComputerName      = $env:COMPUTERNAME
        OSVersion         = [Environment]::OSVersion.VersionString
        Architecture      = if ([Environment]::Is64BitOperatingSystem) { 'x64' } else { 'x86' }
        PowerShellVersion = $PSVersionTable.PSVersion.ToString()
        Is64BitProcess    = [Environment]::Is64BitProcess
    }
    Stages             = $allStages
    InstallDelta       = $installDelta
    Classification     = $failureClassification
    IsProductionReady  = $requiredPassed -and $failed.Count -eq 0
}

Write-Stage ""
if ($result.IsProductionReady) {
    Write-Stage "RESULT: PRODUCTION READY" 'Pass'
} else {
    Write-Stage "RESULT: FAILED VALIDATION" 'Fail'
    if ($failed.Count -gt 0) {
        Write-Stage "  Failed stages: $(($failed | ForEach-Object { $_.Name }) -join ', ')" 'Fail'
    }
    if ($notTested.Count -gt 0) {
        Write-Stage "  Untested stages: $(($notTested | ForEach-Object { $_.Name }) -join ', ')" 'Skip'
    }
    if ($failureClassification) {
        Write-Stage "  Classification: $($failureClassification.Classification) - $($failureClassification.Reason)" 'Fail'
    }
}

$resultPath = Join-Path $OutputPath 'ValidationResult.json'
$result | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $resultPath -Encoding UTF8

if ($failureClassification) {
    $failedStage = if ($failed.Count -gt 0) { $failed[0] } else { $null }
    New-FailureReport -Manifest $manifest `
                      -Classification $failureClassification `
                      -Path (Join-Path $OutputPath 'FailureReport.md') `
                      -Stage $(if ($failedStage) { $failedStage.Name } else { 'Unknown' }) `
                      -Command $(if ($failedStage) { $failedStage.Command } else { '' }) `
                      -ExitCode $(if ($failedStage -and $null -ne $failedStage.ExitCode) { $failedStage.ExitCode } else { $null }) `
                      -Output $(if ($failedStage) { $failedStage.Output } else { '' }) `
                      -ExecutionContextName $result.ExecutionContext `
                      -InstallDelta $installDelta | Out-Null
    Write-Stage "  Failure report: $(Join-Path $OutputPath 'FailureReport.md')" 'Skip'
}

$result
