<#
.SYNOPSIS
    Evaluates an installed Windows application and prepares a staging-spoon package.
.DESCRIPTION
    Investigates the installed application - not just its installer - and
    produces an evidenced evaluation, a human-readable report, and, on request,
    a package.json ready for staging-spoon's Build-IntunePackage.ps1.

    Every value carries its source, confidence and whether it was verified
    against the live system, so an inferred value is never presented as
    verified. Values that still need a person's eye (a guessed silent switch,
    a per-user install's SYSTEM behaviour) are reported as requiring
    confirmation and, unless -Force, block export.

    Reading the live machine requires Windows. Off Windows the evaluation still
    runs against injected evidence, which is how the test suite drives it.
.PARAMETER Name
    The application to evaluate, as it appears in Add/Remove Programs.
.PARAMETER InstallerPath
    Optional installer, for the installer type and a suggested silent switch.
.PARAMETER OutputPath
    Directory for the exported package.json and evaluation.json.
.PARAMETER Export
    Write package.json (and the full evaluation) to OutputPath.
.PARAMETER Force
    Export even while some values still require confirmation.
.EXAMPLE
    .\Invoke-AppEvaluation.ps1 -Name 'IntelliJ IDEA*' -Export -OutputPath .\out
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Name,
    [string]$InstallerPath = '',
    [string]$OutputPath = (Join-Path $PWD 'evaluation'),
    [switch]$Export,
    [switch]$Force,
    [switch]$ShowEvidence
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'src/Load.ps1')

if (-not (Test-WindowsPlatform)) {
    Write-Host 'This evaluator reads the live Windows registry, PATH and shortcuts; run it on the target Windows machine.' -ForegroundColor Yellow
    Write-Host 'Continuing would produce an empty evaluation, so stopping here.' -ForegroundColor Yellow
    exit 2
}

$evalArgs = @{ Name = $Name }
if ($InstallerPath) { $evalArgs['InstallerPath'] = $InstallerPath }
$result = Invoke-ApplicationEvaluation @evalArgs

Write-EvaluationReport -Result $result -ShowEvidence:$ShowEvidence

$unconfirmed = @(Get-UnconfirmedFields -Result $result)

Write-Host ''
if ($unconfirmed.Count -gt 0) {
    Write-Host "$($unconfirmed.Count) value(s) require confirmation before export:" -ForegroundColor Yellow
    foreach ($field in $unconfirmed) { Write-Host "  - $($field.Path): $($field.Evidence -join '; ')" -ForegroundColor Yellow }
}

if (-not $Export) {
    Write-Host ''
    Write-Host 'Review the values above. Re-run with -Export to write package.json.' -ForegroundColor Cyan
    exit 0
}

if ($unconfirmed.Count -gt 0 -and -not $Force) {
    Write-Host ''
    Write-Host 'Not exporting while values require confirmation. Re-run with -Force to export anyway, or correct them first.' -ForegroundColor Red
    exit 1
}

if (-not (Test-Path -LiteralPath $OutputPath)) { New-Item -Path $OutputPath -ItemType Directory -Force | Out-Null }

$package = ConvertTo-StagingSpoonPackage -Result $result
$packagePath = Join-Path $OutputPath 'package.json'
($package | ConvertTo-Json -Depth 8) | Set-Content -LiteralPath $packagePath -Encoding UTF8

# The full evaluation, with evidence, is written beside it for the record.
$evaluationPath = Join-Path $OutputPath 'evaluation.json'
([PSCustomObject]@{
    ApplicationName = $result.ApplicationName
    Fields          = $result.Fields
    Notes           = $result.Notes
} | ConvertTo-Json -Depth 10) | Set-Content -LiteralPath $evaluationPath -Encoding UTF8

Write-Host ''
Write-Host "Wrote $packagePath" -ForegroundColor Green
Write-Host "Wrote $evaluationPath" -ForegroundColor Green
Write-Host 'Hand package.json to staging-spoon: Build-IntunePackage.ps1 -ConfigPath package.json' -ForegroundColor Cyan
exit 0
