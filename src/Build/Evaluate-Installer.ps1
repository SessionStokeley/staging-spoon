<#
.SYNOPSIS
    Evaluates an installer and proposes a package configuration to review.
.DESCRIPTION
    Inspects an EXE, MSI, MSIX, or a BAT/CMD/PS1 wrapper, and populates
    everything that can be established from evidence: application identity,
    install information, uninstall information and detection.

    Anything that could not be determined is reported as requiring the
    administrator rather than filled with a plausible default. Silent switches
    in particular are never guessed - a switch the vendor does not support
    produces a package that stops for a user who is not there.

    The proposal is written into the project, so every value can be reviewed,
    overridden or reset before the package is generated and tested.
.PARAMETER Root
    The project directory. Created if it does not exist.
.PARAMETER Path
    The installer or wrapper script to evaluate.
.PARAMETER Capture
    An InstallDelta.json from a validation run. What it observed is stronger
    evidence than anything static analysis can produce, and is merged in.
.PARAMETER PreviousManifest
    A PackageManifest.json from an earlier build, used to fill what evaluation
    could not establish.
.EXAMPLE
    .\src\Build\Evaluate-Installer.ps1 -Root . -Path .\source\ExampleSetup.exe
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Root,
    [Parameter(Mandatory)][string]$Path,
    [string]$Capture = '',
    [string]$PreviousManifest = ''
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repo = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
. (Join-Path $repo 'src/Core/PackageManifest.ps1')
. (Join-Path $repo 'src/Information/Load.ps1')

if (-not (Test-Path -LiteralPath $Root)) {
    New-Item -Path $Root -ItemType Directory -Force | Out-Null
}

$resolvedRoot = (Resolve-Path -LiteralPath $Root).ProviderPath
$resolvedPath = (Resolve-Path -LiteralPath $Path).ProviderPath

$project = Initialize-InformationProject -Root $resolvedRoot

function Write-Section {
    param([Parameter(Mandatory)][string]$Title)
    Write-Host ''
    Write-Host $Title.ToUpperInvariant() -ForegroundColor Cyan
}

function Write-Row {
    param(
        [Parameter(Mandatory)][string]$Label,
        [AllowEmptyString()][string]$Value,
        [string]$Confidence = '',
        [switch]$Required
    )

    if ($Value) {
        Write-Host ("  {0,-26} {1}" -f $Label, $Value)
        if ($Confidence) {
            Write-Host ("  {0,-26} {1}" -f '', $Confidence) -ForegroundColor DarkGray
        }
        return
    }

    $marker = if ($Required) { 'NOT DETECTED - administrator input required' } else { 'Not detected' }
    $colour = if ($Required) { 'Yellow' } else { 'DarkGray' }
    Write-Host ("  {0,-26} {1}" -f $Label, $marker) -ForegroundColor $colour
}

Write-Host ''
Write-Host "Evaluating $(Get-CanonicalLeaf -Path $resolvedPath)" -ForegroundColor Cyan

# Registering the file first means the rest of the project refers to one
# installer resource, recoverable by identity if it later moves.
Register-ProjectResource -Project $project -Id 'installer.primary' -Path $resolvedPath -Source 'USER_SELECTED' | Out-Null

$evaluation = Invoke-InstallerEvaluation -Project $project -Path $resolvedPath

Write-Host ("  Type: {0}{1}" -f $evaluation.InstallerKind,
    $(if ($evaluation.InstallerFamily) { " ($($evaluation.InstallerFamily))" } else { '' })) -ForegroundColor DarkGray

if ($null -ne $evaluation.ScriptAnalysis) {
    Write-Section 'Wrapper script'
    foreach ($invocation in $evaluation.ScriptAnalysis.Invocations) {
        Write-Host ("  Runs {0}" -f $invocation.Executable)
        if ($invocation.Arguments) {
            Write-Host ("  {0,-26} {1}" -f 'Arguments', $invocation.Arguments)
        }
        Write-Host ("  {0,-26} line {1}" -f '', $invocation.Line) -ForegroundColor DarkGray
    }

    foreach ($observation in @(
        @{ Label = 'Registry operations';    Items = $evaluation.ScriptAnalysis.RegistryOperations }
        @{ Label = 'Environment operations'; Items = $evaluation.ScriptAnalysis.EnvironmentOperations }
        @{ Label = 'File operations';        Items = $evaluation.ScriptAnalysis.FileOperations }
    )) {
        if (@($observation.Items).Count -gt 0) {
            Write-Host ("  {0,-26} {1} (requires review)" -f $observation.Label, @($observation.Items).Count) -ForegroundColor Yellow
        }
    }
}

# Observed evidence outranks anything read statically, so it is merged after.
if ($Capture) {
    $delta = Get-Content -LiteralPath $Capture -Raw | ConvertFrom-Json
    $captureResult = Import-CaptureResult -Project $project -Delta $delta

    Write-Section 'Installation capture'
    Write-Host ("  {0} files observed, {1} values learned" -f $captureResult.FilesAdded, $captureResult.FieldsLearned.Count)
    foreach ($decision in $captureResult.DecisionsRequired) {
        Write-Host ("  {0,-26} requires a decision" -f $decision) -ForegroundColor Yellow
    }
}

if ($PreviousManifest) {
    $reuse = Import-PreviousBuild -Project $project -ManifestPath $PreviousManifest
    Write-Section 'Carried forward'
    Write-Host ("  {0} values reused from the previous build" -f $reuse.FieldsImported.Count)
}

$summary = @(Get-EvaluationSummary -Project $project)

function Show-Rows {
    param([Parameter(Mandatory)][string[]]$Path)

    foreach ($fieldPath in $Path) {
        $row = @($summary | Where-Object { $_.Path -eq $fieldPath })
        if ($row.Count -eq 0) { continue }

        Write-Row -Label $row[0].Label -Value ([string]$row[0].Value) `
                  -Confidence $row[0].Confidence -Required:$row[0].Required
    }
}

Write-Section 'Application'
Show-Rows -Path @('application.name', 'application.publisher', 'application.version', 'application.architecture')

Write-Section 'Install'
Show-Rows -Path @('installer.fileName', 'installer.type', 'installer.silentArguments',
                  'installer.productCode', 'installation.context', 'installation.installLocation',
                  'installation.executable')

Write-Section 'Uninstall'
Show-Rows -Path @('installation.uninstallDisplayName', 'installation.uninstallString')

if ($null -ne $evaluation.UninstallProposal -and $evaluation.UninstallProposal.RequiresReview) {
    Write-Host ("  {0,-26} {1}" -f 'Review', $evaluation.UninstallProposal.Reason) -ForegroundColor Yellow
}

Write-Section 'Detection'
Show-Rows -Path @('detection.type', 'detection.path', 'detection.value', 'detection.version')

if ($evaluation.DetectionProposal.Reason) {
    Write-Host ("  {0,-26} {1}" -f 'Basis', $evaluation.DetectionProposal.Reason) -ForegroundColor DarkGray
}

if (-not $evaluation.DetectionProposal.IsReliable -and $evaluation.DetectionProposal.Type) {
    Write-Host ("  {0,-26} {1}" -f 'Warning', 'This rule cannot prove removal; review it before building') -ForegroundColor Yellow
}

foreach ($note in $evaluation.Notes) {
    Write-Host ''
    Write-Host "  $note" -ForegroundColor Yellow
}

$completeness = Test-EvaluationComplete -Project $project

Write-Section 'Result'
Write-Host ("  {0,-26} {1} of {2}" -f 'Values established', $completeness.DetectedCount, $completeness.TotalCount)

Save-ProjectState -Project $project | Out-Null

if (-not $completeness.IsComplete) {
    Write-Host ''
    Write-Host '  Required information missing:' -ForegroundColor Yellow
    foreach ($item in $completeness.Missing) {
        Write-Host "    - $item" -ForegroundColor Yellow
    }
    Write-Host ''
    Write-Host '  Supply these with New-PackageProject.ps1, which asks only for what is left.' -ForegroundColor Yellow
    exit 1
}

Write-Host ''
Write-Host '  Evaluation complete. Review the values above, then:' -ForegroundColor Green
Write-Host "    .\src\Build\New-PackageProject.ps1 -Root $Root"
exit 0
