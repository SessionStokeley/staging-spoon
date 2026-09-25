<#
.SYNOPSIS
    Builds and validates an Intune package end to end.
.DESCRIPTION
    Enforces the mandatory workflow. The .intunewin is not the product; the
    deployment behaviour is. Validation runs BEFORE packaging, so a package
    that cannot install, detect, uninstall and un-detect never becomes a file.

        CLEAN BUILD
          -> PRE-BUILD VALIDATION
          -> EMIT EXACT COMMANDS
          -> DEPLOYMENT VALIDATION (install/detect/uninstall/detect-false)
          -> CREATE .INTUNEWIN
          -> VERIFY PACKAGE + HASH
          -> GENERATE INTUNE CONFIGURATION
          -> FINAL VALIDATION

    The shortcut from "installer works" to ".intunewin ready" is prohibited.
.PARAMETER SourcePath
    Deployment source directory that becomes the package payload.
.PARAMETER ConfigPath
    Package configuration JSON used to build the manifest.
.PARAMETER SkipValidation
    Emit the .intunewin without running deployment validation. The package is
    marked NOT PRODUCTION READY and no Intune configuration is exported.
.EXAMPLE
    .\Build-IntunePackage.ps1 -SourcePath .\source -ConfigPath .\package.json -SystemContext
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$SourcePath,
    [Parameter(Mandatory)][string]$ConfigPath,
    [string]$OutputPath = (Join-Path $PWD 'build'),
    [string]$IntuneWinAppUtilPath = '',
    [switch]$SystemContext,
    [switch]$SkipValidation,
    [switch]$Force
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
. (Join-Path $repoRoot 'src\Core\Platform.ps1')
. (Join-Path $repoRoot 'src\Core\Integrations.ps1')
. (Join-Path $repoRoot 'src\Core\PackageManifest.ps1')
. (Join-Path $repoRoot 'src\Core\PreBuildValidator.ps1')
. (Join-Path $repoRoot 'src\Core\CommandParser.ps1')
. (Join-Path $repoRoot 'src\Reporting\New-ValidationReport.ps1')
. (Join-Path $repoRoot 'src\Reporting\Export-IntuneConfiguration.ps1')

function Write-Phase {
    param([Parameter(Mandatory)][string]$Name)
    Write-Host ""
    Write-Host "=== $Name ===" -ForegroundColor Cyan
}

function Stop-Build {
    param([Parameter(Mandatory)][string]$Reason)
    Write-Host ""
    Write-Host "BUILD STOPPED: $Reason" -ForegroundColor Red
    Write-Host "NOT PRODUCTION READY" -ForegroundColor Red
    exit 1
}

# --- Configuration -----------------------------------------------------------
if (-not (Test-Path -LiteralPath $ConfigPath)) {
    Stop-Build "Configuration not found: $ConfigPath"
}
$config = Get-Content -LiteralPath $ConfigPath -Raw | ConvertFrom-Json

if (-not (Test-Path -LiteralPath $SourcePath -PathType Container)) {
    Stop-Build "Source directory not found: $SourcePath"
}
$resolvedSource = (Resolve-Path -LiteralPath $SourcePath).Path

# --- Phase 1: clean build ----------------------------------------------------
Write-Phase 'CLEAN BUILD'

if (Test-Path -LiteralPath $OutputPath) {
    $existing = @(Get-ChildItem -LiteralPath $OutputPath -Recurse -File -ErrorAction SilentlyContinue)
    if ($existing.Count -gt 0 -and -not $Force) {
        Write-Host "Build directory contains $($existing.Count) files from a previous build." -ForegroundColor Yellow
        $answer = Read-Host "Remove them? (y/N)"
        if ($answer -notmatch '^[Yy]') {
            Stop-Build 'A clean build directory is required; stale files must not enter the package'
        }
    }
    Remove-Item -LiteralPath $OutputPath -Recurse -Force
    Write-Host "Removed previous build output" -ForegroundColor Green
}

New-Item -Path $OutputPath -ItemType Directory -Force | Out-Null
$testResultsPath = Join-Path $OutputPath 'TestResults'
New-Item -Path $testResultsPath -ItemType Directory -Force | Out-Null
Write-Host "Clean build directory: $OutputPath" -ForegroundColor Green

# --- Phase 2: manifest -------------------------------------------------------
Write-Phase 'MANIFEST'

$manifest = New-PackageManifest -ApplicationName    $config.ApplicationName `
                                -ApplicationVersion $config.ApplicationVersion `
                                -PackageVersion     $config.PackageVersion `
                                -InstallerType      $config.InstallerType `
                                -SourceInstaller    $config.SourceInstaller `
                                -InstallCommand     $config.InstallCommand `
                                -UninstallCommand   $config.UninstallCommand `
                                -DetectionMethod    $config.DetectionMethod `
                                -DetectionScript    $(if ($config.PSObject.Properties.Name -contains 'DetectionScript') { $config.DetectionScript } else { '' }) `
                                -ContentDirectory   $resolvedSource `
                                -InstallBehavior    $(if ($config.PSObject.Properties.Name -contains 'InstallBehavior') { $config.InstallBehavior } else { 'System' }) `
                                -Architecture       $(if ($config.PSObject.Properties.Name -contains 'Architecture') { $config.Architecture } else { 'x64' }) `
                                -MinimumOS          $(if ($config.PSObject.Properties.Name -contains 'MinimumOS') { $config.MinimumOS } else { 'W10_1809' }) `
                                -ExpectedExitCodes  $(if ($config.PSObject.Properties.Name -contains 'ExpectedExitCodes') { $config.ExpectedExitCodes } else { @(0, 1641, 3010) }) `
                                -RebootBehavior     $(if ($config.PSObject.Properties.Name -contains 'RebootBehavior') { $config.RebootBehavior } else { 'BasedOnReturnCode' }) `
                                -Integrations       $(if ($config.PSObject.Properties.Name -contains 'Integrations') { $config.Integrations } else { $null })

Write-Host "$($manifest.ApplicationName) $($manifest.ApplicationVersion) (package $($manifest.PackageVersion))" -ForegroundColor Green
Write-Host "Install behavior: $($manifest.InstallBehavior) | Architecture: $($manifest.Architecture)" -ForegroundColor Green

# --- Phase 3: exact commands -------------------------------------------------
Write-Phase 'EXACT COMMANDS'

$detectionCommand = Get-DetectionCommand -Manifest $manifest

# These are the strings entered into Intune. The tested command and the
# production command are the same string, read from the same source.
$manifest.InstallCommand   | Set-Content -LiteralPath (Join-Path $OutputPath 'InstallCommand.txt')   -Encoding UTF8 -NoNewline
$manifest.UninstallCommand | Set-Content -LiteralPath (Join-Path $OutputPath 'UninstallCommand.txt') -Encoding UTF8 -NoNewline
if ($detectionCommand) {
    $detectionCommand | Set-Content -LiteralPath (Join-Path $OutputPath 'DetectionCommand.txt') -Encoding UTF8 -NoNewline
}

Write-Host "Install  : $($manifest.InstallCommand)" -ForegroundColor Gray
Write-Host "Uninstall: $($manifest.UninstallCommand)" -ForegroundColor Gray
if ($detectionCommand) { Write-Host "Detection: $detectionCommand" -ForegroundColor Gray }

# --- Phase 3b: stage Windows integrations ------------------------------------
# When the package declares integrations, the engine and the apply/remove
# scripts are staged beside the wrappers and the integration set is written as
# integrations.json, so the packaged content is self-contained: Install.ps1
# applies them on the target and Uninstall.ps1 removes exactly what it owns.
if ($null -ne $manifest.Integrations) {
    Write-Phase 'WINDOWS INTEGRATIONS'

    # The engine is shared code from src\Core; the apply/remove wrappers are
    # templates. Both are staged beside the install wrappers so the package is
    # self-contained on the target.
    Copy-Item -LiteralPath (Join-Path $repoRoot 'src\Core\Integrations.ps1') `
              -Destination (Join-Path $resolvedSource 'Integrations.ps1') -Force
    foreach ($script in @('Apply-Integrations.ps1', 'Remove-Integrations.ps1')) {
        Copy-Item -LiteralPath (Join-Path $repoRoot "templates\$script") `
                  -Destination (Join-Path $resolvedSource $script) -Force
    }

    $integrationDocument = [PSCustomObject]@{
        ApplicationKey = $manifest.ApplicationName
        Integrations   = $manifest.Integrations
    }
    ($integrationDocument | ConvertTo-Json -Depth 8) |
        Set-Content -LiteralPath (Join-Path $resolvedSource 'integrations.json') -Encoding UTF8

    $staged = @(ConvertTo-IntegrationConfig -Integrations $manifest.Integrations)
    Write-Host "Staged $($staged.Count) integration(s): $((($staged | ForEach-Object { "$($_.Kind)/$($_.Mode)" }) -join ', '))" -ForegroundColor Green
}

# --- Phase 4: pre-build validation -------------------------------------------
Write-Phase 'PRE-BUILD VALIDATION'

$requiredFiles = if ($config.PSObject.Properties.Name -contains 'RequiredFiles') { $config.RequiredFiles } else { @() }
$allowedPaths  = if ($config.PSObject.Properties.Name -contains 'AllowedPaths')  { $config.AllowedPaths }  else { @() }

$preBuild = Invoke-PreBuildValidation -SourcePath $resolvedSource `
                                      -Manifest $manifest `
                                      -RequiredFile $requiredFiles `
                                      -AllowedPath $allowedPaths
Write-PreBuildResult -Result $preBuild

if (-not $preBuild.CanBuild) {
    Stop-Build 'Pre-build validation failed; the .intunewin was not created'
}

# --- Phase 5: deployment validation ------------------------------------------
$validationResult = $null
$validationPassed = $false

if ($SkipValidation) {
    Write-Phase 'DEPLOYMENT VALIDATION'
    Write-Host "SKIPPED - package cannot be classified production ready" -ForegroundColor Yellow
} else {
    Write-Phase 'DEPLOYMENT VALIDATION'

    # The manifest is written to the source so the test runs against the exact
    # content that will be packaged.
    $stagedManifestPath = Join-Path $resolvedSource 'PackageManifest.json'
    Save-PackageManifest -Manifest $manifest -Path $stagedManifestPath | Out-Null

    $expectation = if ($config.PSObject.Properties.Name -contains 'PostInstallExpectation') {
        $table = @{}
        foreach ($property in $config.PostInstallExpectation.PSObject.Properties) {
            $table[$property.Name] = $property.Value
        }
        $table
    } else { @{} }

    $testScript = Join-Path $repoRoot 'src\Testing\Test-IntunePackage.ps1'
    $validationResult = & $testScript -SourcePath $resolvedSource `
                                      -ManifestPath $stagedManifestPath `
                                      -OutputPath $testResultsPath `
                                      -SystemContext:$SystemContext `
                                      -PostInstallExpectation $expectation

    $validationPassed = $validationResult.IsProductionReady

    if (-not $validationPassed -and -not $Force) {
        Stop-Build 'Deployment validation failed; the .intunewin was not created. Reproduce first, fix second, rebuild third.'
    }
    if (-not $validationPassed) {
        Write-Host "Validation failed but -Force was specified; continuing as NOT PRODUCTION READY" -ForegroundColor Yellow
    }
}

# --- Phase 6: create .intunewin ----------------------------------------------
Write-Phase 'CREATE .INTUNEWIN'

$utilPath = if ($IntuneWinAppUtilPath) {
    $IntuneWinAppUtilPath
} else {
    $candidate = Get-Command -Name 'IntuneWinAppUtil.exe' -ErrorAction SilentlyContinue
    if ($candidate) { $candidate.Source } else { '' }
}

$intuneWinPath = ''

if (-not $utilPath -or -not (Test-Path -LiteralPath $utilPath -PathType Leaf)) {
    Write-Host "IntuneWinAppUtil.exe not found; skipping .intunewin creation" -ForegroundColor Yellow
    Write-Host "Specify -IntuneWinAppUtilPath to produce the package file" -ForegroundColor Yellow
} else {
    $setupFile = Resolve-CommandTarget -CommandLine $manifest.InstallCommand -PackagePath $resolvedSource
    $setupName = if ($setupFile.IsSystemExecutable) { 'Install.ps1' } else { $setupFile.Target }

    Write-Host "Packaging with setup file: $setupName" -ForegroundColor Gray

    $arguments = @('-c', $resolvedSource, '-s', $setupName, '-o', $OutputPath, '-q')
    $process = Start-Process -FilePath $utilPath -ArgumentList $arguments -Wait -PassThru -NoNewWindow

    if ($process.ExitCode -ne 0) {
        Stop-Build "IntuneWinAppUtil.exe failed with exit code $($process.ExitCode)"
    }

    $produced = @(Get-ChildItem -LiteralPath $OutputPath -Filter '*.intunewin' -File)
    if ($produced.Count -eq 0) {
        Stop-Build 'IntuneWinAppUtil.exe reported success but produced no .intunewin'
    }

    $intuneWinPath = $produced[0].FullName
    Write-Host "Created: $($produced[0].Name)" -ForegroundColor Green
}

# --- Phase 7: verify package and hash ----------------------------------------
Write-Phase 'VERIFY PACKAGE'

if ($intuneWinPath) {
    $packageFile = Get-Item -LiteralPath $intuneWinPath
    $hash = Get-PackageHash -Path $intuneWinPath
    $manifest.PackageHash = $hash

    $hash | Set-Content -LiteralPath (Join-Path $OutputPath 'PackageHash.txt') -Encoding UTF8

    Write-Host "Filename : $($packageFile.Name)" -ForegroundColor Green
    Write-Host "Size     : $([math]::Round($packageFile.Length / 1MB, 2)) MB" -ForegroundColor Green
    Write-Host "SHA256   : $hash" -ForegroundColor Green
    Write-Host "Built    : $($manifest.BuildTimestamp)" -ForegroundColor Green
} else {
    Write-Host "No package file to verify" -ForegroundColor Yellow
}

Save-PackageManifest -Manifest $manifest -Path (Join-Path $OutputPath 'PackageManifest.json') | Out-Null

# --- Phase 8: Intune configuration -------------------------------------------
Write-Phase 'INTUNE CONFIGURATION'

# Commands are compared against what validation actually executed, so a
# divergence between tested and production configuration cannot pass silently.
$validatedCommands = @{}
if ($validationResult) {
    foreach ($stage in $validationResult.Stages) {
        if (-not $stage.Command) { continue }
        switch ($stage.Name) {
            'Install'                   { $validatedCommands['Install']   = $stage.Command }
            'Uninstall'                 { $validatedCommands['Uninstall'] = $stage.Command }
            'Detection after install'   { $validatedCommands['Detection'] = $stage.Command }
        }
    }
}

$export = Export-IntuneConfiguration -Manifest $manifest `
                                     -OutputPath $OutputPath `
                                     -ValidatedCommands $validatedCommands `
                                     -ValidationPassed $validationPassed

Write-Host "Wrote $(Split-Path $export.JsonPath -Leaf) and $(Split-Path $export.MarkdownPath -Leaf)" -ForegroundColor Green

foreach ($comparison in $export.Comparisons) {
    if ($comparison.Matches) {
        Write-Host "  [PASS] $($comparison.Message)" -ForegroundColor Green
    } else {
        Write-Host "  [FAIL] $($comparison.Message)" -ForegroundColor Red
    }
}

# --- Phase 9: report ---------------------------------------------------------
Write-Phase 'REPORT'

if ($validationResult) {
    $validationResult.PackageHash = $manifest.PackageHash
    $reportPath = New-ValidationReport -Result $validationResult `
                                       -Path (Join-Path $OutputPath 'IntuneValidationReport.html') `
                                       -CommandComparison $export.Comparisons `
                                       -PreBuildResult $preBuild
    Write-Host "Report: $reportPath" -ForegroundColor Green
} else {
    Write-Host "No validation result to report" -ForegroundColor Yellow
}

# --- Phase 10: final validation ----------------------------------------------
Write-Phase 'FINAL VALIDATION'

$gates = @(
    [PSCustomObject]@{ Name = 'Pre-build validation passed';        Passed = $preBuild.CanBuild }
    [PSCustomObject]@{ Name = 'Install succeeded';                  Passed = $validationPassed }
    [PSCustomObject]@{ Name = 'Detection true after install';       Passed = $validationPassed }
    [PSCustomObject]@{ Name = 'Uninstall succeeded';                Passed = $validationPassed }
    [PSCustomObject]@{ Name = 'Detection false after uninstall';    Passed = $validationPassed }
    [PSCustomObject]@{ Name = 'Intune commands match validated';    Passed = $export.IsConsistent }
    [PSCustomObject]@{ Name = 'Package file produced';              Passed = [bool]$intuneWinPath }
)

foreach ($gate in $gates) {
    $symbol = if ($gate.Passed) { '[PASS]' } else { '[FAIL]' }
    $color  = if ($gate.Passed) { 'Green' } else { 'Red' }
    Write-Host "$symbol $($gate.Name)" -ForegroundColor $color
}

$isProductionReady = @($gates | Where-Object { -not $_.Passed }).Count -eq 0

Write-Host ""
if ($isProductionReady) {
    Write-Host "PRODUCTION READY" -ForegroundColor Green
    exit 0
}

Write-Host "NOT PRODUCTION READY" -ForegroundColor Red
exit 1
