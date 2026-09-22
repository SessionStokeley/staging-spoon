<#
.SYNOPSIS
    Prepares a package by discovering what it can and asking only for the rest.
.DESCRIPTION
    Replaces hand-writing package.json. Select an installer and the platform
    reads its metadata, derives the application identity, works out the silent
    switches and the success exit codes, generates the install, uninstall and
    detection commands, and asks only for the deployment decisions nothing
    about the installer can settle. Answers are stored in the project, so a
    second run asks nothing.
.PARAMETER Root
    The project directory. Created if it does not exist.
.PARAMETER InstallerPath
    The installer to package. When omitted, the project is scanned and the
    candidates are offered.
.PARAMETER CapturePath
    An InstallDelta.json from a previous validation run. Everything it observed
    is published into the project instead of being asked for.
.PARAMETER PreviousManifest
    A PackageManifest.json from an earlier build. Its deployment decisions are
    carried forward; this version's own installer still wins on identity.
.PARAMETER ConfigPath
    Where to write package.json. Defaults to package.json in the project root.
.PARAMETER NonInteractive
    Accepts values the platform already found and leaves everything else
    unanswered, for use in a pipeline.
.EXAMPLE
    .\src\Build\New-PackageProject.ps1 -Root . -InstallerPath .\source\Setup.exe
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Root,
    [string]$InstallerPath = '',
    [string]$CapturePath = '',
    [string]$PreviousManifest = '',
    [string]$ConfigPath = '',
    [switch]$NonInteractive,
    [switch]$IncludeRecommended
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
$project = Initialize-InformationProject -Root $resolvedRoot

Write-Host ''
Write-Host "Project: $($project.Name)" -ForegroundColor Cyan
Write-Host "  $resolvedRoot"

if ($project.Fields.Count -gt 0) {
    Write-Host "  Reopened with $($project.Fields.Count) values already known." -ForegroundColor DarkGray
}

# --- 1. The installer -------------------------------------------------------
if (-not $InstallerPath -and -not (Test-ProjectFieldKnown -Project $project -Path 'installer.path')) {
    $candidates = @(Find-ProjectInstaller -Project $project)

    if ($candidates.Count -eq 1) {
        $InstallerPath = $candidates[0].Path
        Write-Host ''
        Write-Host "Found one installer: $($candidates[0].FileName)" -ForegroundColor Cyan
    } elseif ($candidates.Count -gt 1) {
        Write-Host ''
        Write-Host 'Installers found in this project' -ForegroundColor Cyan

        for ($index = 0; $index -lt $candidates.Count; $index++) {
            $candidate = $candidates[$index]
            Write-Host ("  [{0}] {1,-40} {2,-10} {3}" -f
                ($index + 1), $candidate.FileName, $candidate.Version,
                ([Math]::Round($candidate.Size / 1MB, 1).ToString() + ' MB'))
        }

        if ($NonInteractive) {
            throw 'Several installers are present. Pass -InstallerPath to choose one.'
        }

        while (-not $InstallerPath) {
            $answer = Read-Host '  Choose'
            $selection = 0
            if ([int]::TryParse($answer, [ref]$selection) -and $selection -ge 1 -and $selection -le $candidates.Count) {
                $InstallerPath = $candidates[$selection - 1].Path
            }
        }
    } else {
        throw "No installer found under $resolvedRoot. Pass -InstallerPath."
    }
}

if ($InstallerPath) {
    $selection = Select-ProjectInstaller -Project $project -Path (Resolve-Path -LiteralPath $InstallerPath).ProviderPath

    Write-Host ''
    Write-Host "Analysed $(Get-ProjectFieldValue -Project $project -Path 'installer.fileName')" -ForegroundColor Cyan
    if ($selection.Family) {
        Write-Host "  Installer toolkit: $($selection.Family)" -ForegroundColor DarkGray
    }
}

# --- 2. Everything already known --------------------------------------------
if ($PreviousManifest) {
    $reuse = Import-PreviousBuild -Project $project -ManifestPath $PreviousManifest

    Write-Host ''
    Write-Host "Carried forward from $([System.IO.Path]::GetFileName($PreviousManifest))" -ForegroundColor Cyan
    Write-Host "  $($reuse.FieldsImported.Count) values reused" -ForegroundColor DarkGray

    foreach ($change in $reuse.Changes) {
        $definition = Get-FieldDefinition -Path $change.Path
        $label = if ($null -eq $definition) { $change.Path } else { $definition.Label }
        Write-Host ("  Changed: {0,-22} {1} -> {2}" -f $label,
                    (Format-InformationValue -Value $change.Previous),
                    (Format-InformationValue -Value $change.Current)) -ForegroundColor Yellow
    }
}

if ($CapturePath) {
    $delta = Get-Content -LiteralPath $CapturePath -Raw | ConvertFrom-Json
    $capture = Import-CaptureResult -Project $project -Delta $delta

    Write-Host ''
    Write-Host 'Installation capture' -ForegroundColor Cyan
    Write-Host "  $($capture.FilesAdded) files observed, $($capture.FieldsLearned.Count) values learned" -ForegroundColor DarkGray
}

if (-not (Test-ProjectFieldKnown -Project $project -Path 'package.intuneWinAppUtilPath')) {
    $tool = Find-PackagingTool -Project $project
    if ($tool) {
        Write-Host ''
        Write-Host "Found IntuneWinAppUtil.exe" -ForegroundColor Cyan
        Write-Host "  $tool" -ForegroundColor DarkGray
    }
}

Show-DiscoverySummary -Project $project | Out-Null

# --- 3. Commands, generated rather than typed -------------------------------
$blueprint = New-DeploymentBlueprint -Project $project -UseWrapperScripts

Write-Host ''
Write-Host 'Generated commands' -ForegroundColor Cyan
Write-Host "  Install    $($blueprint.Install.Rendered)"
Write-Host "  Uninstall  $($blueprint.Uninstall.Rendered)"
Write-Host "  Detection  $($blueprint.Detection.Rendered)"

foreach ($command in @($blueprint.Install, $blueprint.Uninstall, $blueprint.Detection)) {
    $check = Test-StructuredCommand -Command $command.Structured
    foreach ($problem in $check.Problems) {
        Write-Host "  Warning: $problem" -ForegroundColor Yellow
    }
}

# --- 4. Only what is genuinely left -----------------------------------------
$pending = @(Get-PendingPrompt -Project $project -Operation 'BuildPackage' -IncludeRecommended:$IncludeRecommended)
$capturePending = @(Get-CaptureDecisionPrompt -Project $project)

if ($pending.Count -eq 0 -and $capturePending.Count -eq 0) {
    Write-Host ''
    Write-Host 'Nothing left to ask.' -ForegroundColor Green
} else {
    Write-Host ''
    Write-Host ("{0} decision(s) needed" -f ($pending.Count + $capturePending.Count)) -ForegroundColor Cyan

    $session = Invoke-InformationPromptSession -Project $project -Operation 'BuildPackage' `
                                               -IncludeRecommended:$IncludeRecommended `
                                               -NonInteractive:$NonInteractive

    Write-Host ''
    Write-Host "  $($session.Answered) answered, $($session.Skipped) skipped" -ForegroundColor DarkGray
}

# --- 5. Review, then persist ------------------------------------------------
$review = New-InformationReview -Project $project
Show-InformationReview -Review $review | Out-Null

Save-ProjectState -Project $project | Out-Null

if (-not $review.IsReady) {
    Write-Host ''
    Write-Host 'Project saved. Run this again to answer the remaining items.' -ForegroundColor Yellow
    exit 1
}

if (-not $ConfigPath) { $ConfigPath = Join-Path $resolvedRoot 'package.json' }

$manifest = Export-ProjectManifest -Project $project
Save-PackageManifest -Manifest $manifest -Path $ConfigPath | Out-Null

Write-Host ''
Write-Host "Wrote $ConfigPath" -ForegroundColor Green
Write-Host ''
Write-Host 'Next: run the build' -ForegroundColor Cyan
Write-Host "  .\src\Build\Build-IntunePackage.ps1 ``"
Write-Host "      -SourcePath $(Get-ProjectFieldValue -Project $project -Path 'package.sourceDirectory') ``"
Write-Host "      -ConfigPath $ConfigPath ``"
Write-Host "      -IntuneWinAppUtilPath $(Get-ProjectFieldValue -Project $project -Path 'package.intuneWinAppUtilPath' -Default '.\tools\IntuneWinAppUtil.exe') ``"
Write-Host "      -SystemContext"

exit 0
