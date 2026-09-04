#Requires -Version 5.1
<#
    New-IntuneApp.ps1

    Entry point for the Intune Application Packaging Studio.

    The flow is deliberately staged so that analysis and configuration are
    always separated from execution:

        Select installer -> Analyze -> Questions -> Generate Config.psd1
        -> Review -> Validate -> Approve -> Run -> Validate -> Build

    The generated .psd1 is the source of truth. This script never installs
    anything on its own; it hands the approved configuration to the existing
    packaging engine.

    Examples
        # Full interactive flow
        .\New-IntuneApp.ps1

        # Analyze a specific installer
        .\New-IntuneApp.ps1 -InstallerPath .\Files\Setup.exe

        # Re-open an existing configuration to edit it
        .\New-IntuneApp.ps1 -OpenConfig .\Configuration.psd1

        # Validate a configuration without running anything
        .\New-IntuneApp.ps1 -Mode Validate -OpenConfig .\Configuration.psd1

        # Preview exactly what a configuration would do
        .\New-IntuneApp.ps1 -Mode Preview -OpenConfig .\Configuration.psd1

        # Analyze only - no questions, no file written
        .\New-IntuneApp.ps1 -Mode Analyze -InstallerPath .\Files\Setup.exe
#>

[CmdletBinding()]
param(
    [ValidateSet('Wizard', 'Gui', 'Analyze', 'Validate', 'Preview', 'Run', 'Build')]
    [string]$Mode = 'Wizard',

    [string]$InstallerPath = '',

    [string]$OpenConfig = '',

    [string]$PackageRoot = '',

    [string]$OutputPath = '',

    # Skips the interactive approval prompt. Only for automation that has
    # already obtained approval.
    [switch]$Force,

    # Scripted answers, used by the test suite to drive the wizard.
    [string[]]$Answers
)

$ErrorActionPreference = 'Stop'
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Definition
if (-not $PackageRoot) { $PackageRoot = $ScriptDir }

# --- Load the Studio modules and the engine helpers ------------------------
$studioDir = Join-Path $ScriptDir 'Studio'
foreach ($module in @(
    'ConfigGenerator.ps1', 'ConfigModel.ps1', 'ConfigValidator.ps1',
    'Analyzer.ps1', 'Preview.ps1', 'Prompt.ps1', 'Wizard.ps1', 'Runner.ps1'
)) {
    $path = Join-Path $studioDir $module
    if (-not (Test-Path -LiteralPath $path)) { throw "Studio module missing: $path" }
    . $path
}

# CLI discovery and PATH helpers come from the existing engine helpers, so the
# Studio does not duplicate that logic.
$envHelper = Join-Path $ScriptDir 'Helpers\Environment.ps1'
if (Test-Path -LiteralPath $envHelper) { . $envHelper }

if ($PSBoundParameters.ContainsKey('Answers') -and $Answers) {
    Set-WizardAnswers -Answers $Answers
}

function Resolve-ConfigPath {
    param([string]$Preferred)
    if ($Preferred) { return $Preferred }
    $default = Join-Path $PackageRoot 'Configuration.psd1'
    if (Test-Path -LiteralPath $default) { return $default }
    throw 'No configuration specified. Pass -OpenConfig, or run the wizard first.'
}

# ---------------------------------------------------------------------------
switch ($Mode) {

    'Gui' {
        # WPF front end. Loaded on demand so the console path stays usable on
        # platforms where WPF does not exist.
        . (Join-Path $studioDir 'Studio.ps1')

        if (-not (Test-WpfAvailable)) {
            Write-Host ''
            Write-Host 'The graphical Studio requires Windows PowerShell or PowerShell 7 on Windows.' -ForegroundColor Yellow
            Write-Host 'Use the console wizard instead:' -ForegroundColor Yellow
            Write-Host '  .\New-IntuneApp.ps1' -ForegroundColor Yellow
            Write-Host ''
            exit 1
        }

        Show-PackagingStudio -PackageRoot $PackageRoot -InstallerPath $InstallerPath -ConfigPath $OpenConfig
    }

    'Analyze' {
        if (-not $InstallerPath) { throw 'Analyze mode requires -InstallerPath.' }

        $analysis = Get-InstallerAnalysis -Path $InstallerPath

        Write-Host ''
        Write-Host 'Installer Analysis' -ForegroundColor Cyan
        Write-Host ('=' * 62) -ForegroundColor Cyan
        Write-Host "  File          : $($analysis.FileName)  ($($analysis.FileSizeText))"
        Write-Host "  Type          : $($analysis.InstallerType)"
        Write-Host "  Application   : $($analysis.ApplicationName)"
        Write-Host "  Publisher     : $($analysis.Publisher)"
        Write-Host "  Version       : $($analysis.Version)"
        Write-Host "  Architecture  : $($analysis.Architecture)"
        Write-Host "  Technology    : $($analysis.Technology) (confidence: $($analysis.TechnologyConfidence))"
        Write-Host "  Silent args   : $($analysis.SilentArguments)"
        if ($analysis.ProductCode) { Write-Host "  ProductCode   : $($analysis.ProductCode)" }
        Write-Host "  SHA256        : $($analysis.Sha256)"
        Write-Host "  Signature     : $($analysis.Signature.Status)"

        Write-Host ''
        Write-Host 'Recommendations' -ForegroundColor Cyan
        Write-Host ('-' * 62)
        foreach ($key in $analysis.Recommendations.Keys) {
            $rec = $analysis.Recommendations[$key]
            Write-Host "  $key (confidence: $($rec.Confidence))" -ForegroundColor White
            foreach ($f in $rec.Keys) {
                if ($f -in @('Confidence', 'Reason')) { continue }
                Write-Host "    $f = $($rec[$f])"
            }
            Write-Host "    reason: $($rec.Reason)" -ForegroundColor DarkGray
        }

        foreach ($note in @($analysis.Notes)) {
            Write-Host "  ! $note" -ForegroundColor Yellow
        }
        Write-Host ''
        Write-Host 'Nothing was installed or changed.' -ForegroundColor Green
        Write-Host ''
    }

    'Validate' {
        $configPath = Resolve-ConfigPath $OpenConfig
        Write-Host "Validating: $configPath"
        $findings = @(Test-ConfigFile -Path $configPath -PackageRoot $PackageRoot)
        $summary = Write-ValidationReport -Findings $findings
        if (-not $summary.IsValid) { exit 1 }
        exit 0
    }

    'Preview' {
        $configPath = Resolve-ConfigPath $OpenConfig
        $model = Import-ConfigModel -Path $configPath
        Show-ConfigurationPreview -Model $model -Title "Configuration Preview - $($model.ApplicationName)"
        Write-Host 'This is a description only. Nothing has been executed.' -ForegroundColor Green
        Write-Host ''
    }

    'Run' {
        $configPath = Resolve-ConfigPath $OpenConfig
        $model = Import-ConfigModel -Path $configPath

        # Validation gates execution: errors block, warnings do not.
        $findings = @(Test-ConfigFile -Path $configPath -PackageRoot $PackageRoot)
        $summary = Write-ValidationReport -Findings $findings
        if (-not $summary.IsValid) {
            Write-Host 'Execution blocked: fix the errors above first.' -ForegroundColor Red
            exit 1
        }

        Show-ConfigurationPreview -Model $model -Title 'Review Configuration'

        if (-not (Confirm-ConfigurationExecution -Model $model -ConfigPath $configPath -Force:$Force)) {
            exit 0
        }

        $result = Test-PackageWorkflow -PackageRoot $PackageRoot
        if (-not $result.Success) { exit 1 }
        exit 0
    }

    'Build' {
        $configPath = Resolve-ConfigPath $OpenConfig
        $model = Import-ConfigModel -Path $configPath

        $findings = @(Test-ConfigFile -Path $configPath -PackageRoot $PackageRoot)
        $summary = Write-ValidationReport -Findings $findings
        if (-not $summary.IsValid) {
            Write-Host 'Build blocked: fix the errors above first.' -ForegroundColor Red
            exit 1
        }

        $build = Build-IntunePackage -PackageRoot $PackageRoot -OutputPath $OutputPath
        if ($build.Success) { Show-IntunePortalSettings -Model $model }
        if (-not $build.Success) { exit 1 }
        exit 0
    }

    'Wizard' {
        $result = Invoke-ConfigurationWizard `
            -InstallerPath $InstallerPath `
            -PackageRoot $PackageRoot `
            -ExistingConfig $OpenConfig `
            -OutputPath $OutputPath

        $model = $result.Model
        $configPath = $result.Path

        # --- Show the actual generated file, not just a summary -------------
        Write-Host ''
        Write-Host ('=' * 62) -ForegroundColor Cyan
        Write-Host " Generated configuration: $configPath" -ForegroundColor Cyan
        Write-Host ('=' * 62) -ForegroundColor Cyan
        Write-Host ''
        Show-Psd1Content -Path $configPath

        # --- Validate ------------------------------------------------------
        $findings = @(Test-ConfigFile -Path $configPath -PackageRoot $PackageRoot)
        $summary = Write-ValidationReport -Findings $findings

        # --- Review --------------------------------------------------------
        Show-ConfigurationPreview -Model $model -Title 'Review Configuration'

        Write-Host 'Next steps' -ForegroundColor Cyan
        Write-Host ('-' * 62)
        Write-Host "  Edit      : open $configPath in an editor"
        Write-Host "  Re-open   : .\New-IntuneApp.ps1 -OpenConfig `"$configPath`""
        Write-Host "  Validate  : .\New-IntuneApp.ps1 -Mode Validate"
        Write-Host "  Preview   : .\New-IntuneApp.ps1 -Mode Preview"
        Write-Host "  Run       : .\New-IntuneApp.ps1 -Mode Run"
        Write-Host "  Build     : .\New-IntuneApp.ps1 -Mode Build"
        Write-Host ('-' * 62)
        Write-Host ''

        if ($summary.IsValid) {
            Write-Host 'The configuration has been saved. Nothing has been executed.' -ForegroundColor Green
            Write-Host "Run it only when you are ready: .\New-IntuneApp.ps1 -Mode Run" -ForegroundColor Green
        }
        else {
            Write-Host 'The configuration was saved but has errors. Fix them before running.' -ForegroundColor Yellow
        }
        Write-Host ''
    }
}
