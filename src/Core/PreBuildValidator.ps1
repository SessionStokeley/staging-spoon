<#
.SYNOPSIS
    Pre-build validation gate.
.DESCRIPTION
    Runs every check that must pass before an .intunewin is created.
    If any check fails, the build must not proceed.
#>

Set-StrictMode -Version Latest

. (Join-Path $PSScriptRoot 'PackageManifest.ps1')
. (Join-Path $PSScriptRoot 'PathValidator.ps1')
. (Join-Path $PSScriptRoot 'CommandParser.ps1')

$script:StaleArtifactPatterns = @('*.intunewin', '*.log', '*.tmp', '*.bak', '*.old')

function New-ValidationCheck {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][bool]$Passed,
        [string]$Detail = '',
        [ValidateSet('Error', 'Warning')][string]$Severity = 'Error'
    )

    [PSCustomObject]@{
        Name     = $Name
        Passed   = $Passed
        Severity = $Severity
        Detail   = $Detail
    }
}

function Invoke-PreBuildValidation {
    <#
    .SYNOPSIS
        Runs the full pre-build checklist against a package source directory.
    .PARAMETER SourcePath
        The deployment source directory that will become the .intunewin payload.
    .PARAMETER Manifest
        The package manifest describing what is being built.
    .OUTPUTS
        PSCustomObject with CanBuild, Checks, Errors and Warnings.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$SourcePath,
        [Parameter(Mandatory)][PSCustomObject]$Manifest,
        [string[]]$RequiredFile = @(),
        [string[]]$AllowedPath = @()
    )

    $checks = [System.Collections.Generic.List[PSCustomObject]]::new()

    if (-not (Test-Path -LiteralPath $SourcePath -PathType Container)) {
        $checks.Add((New-ValidationCheck -Name 'Source directory exists' -Passed $false -Detail "Not found: $SourcePath"))
        return [PSCustomObject]@{
            CanBuild = $false
            Checks   = $checks.ToArray()
            Errors   = @("Source directory not found: $SourcePath")
            Warnings = @()
        }
    }
    $checks.Add((New-ValidationCheck -Name 'Source directory exists' -Passed $true -Detail $SourcePath))

    $resolvedSource = (Resolve-Path -LiteralPath $SourcePath).Path

    # --- Installer payload -------------------------------------------------
    $installerPath = Join-Path $resolvedSource $Manifest.SourceInstaller
    $installerExists = Test-Path -LiteralPath $installerPath -PathType Leaf
    $checks.Add((New-ValidationCheck -Name 'Source installer exists' -Passed $installerExists `
                 -Detail $(if ($installerExists) { $Manifest.SourceInstaller } else { "Not found: $($Manifest.SourceInstaller)" })))

    if ($installerExists) {
        $readable = $false
        try {
            $stream = [System.IO.File]::OpenRead($installerPath)
            $stream.Dispose()
            $readable = $true
        } catch {
            $readable = $false
        }
        $checks.Add((New-ValidationCheck -Name 'Installer is readable' -Passed $readable `
                     -Detail $(if ($readable) { 'Readable' } else { 'Cannot open installer for reading' })))
    } else {
        $checks.Add((New-ValidationCheck -Name 'Installer is readable' -Passed $false -Detail 'Installer missing'))
    }

    # --- Required deployment scripts ---------------------------------------
    $installScript = Join-Path $resolvedSource 'Install.ps1'
    $checks.Add((New-ValidationCheck -Name 'Install.ps1 exists' -Passed (Test-Path -LiteralPath $installScript -PathType Leaf)))

    $uninstallScript = Join-Path $resolvedSource 'Uninstall.ps1'
    $checks.Add((New-ValidationCheck -Name 'Uninstall.ps1 exists' -Passed (Test-Path -LiteralPath $uninstallScript -PathType Leaf)))

    if ($Manifest.DetectionMethod -eq 'Script') {
        $detectionName = if ([string]::IsNullOrWhiteSpace($Manifest.DetectionScript)) { 'Detection.ps1' } else { $Manifest.DetectionScript }
        $detectionScript = Join-Path $resolvedSource $detectionName
        $checks.Add((New-ValidationCheck -Name 'Detection script exists' -Passed (Test-Path -LiteralPath $detectionScript -PathType Leaf) -Detail $detectionName))
    } else {
        $checks.Add((New-ValidationCheck -Name 'Detection script exists' -Passed $true -Detail "Not required for DetectionMethod '$($Manifest.DetectionMethod)'"))
    }

    foreach ($file in $RequiredFile) {
        $path = Join-Path $resolvedSource $file
        $checks.Add((New-ValidationCheck -Name "Required file exists: $file" -Passed (Test-Path -LiteralPath $path)))
    }

    # --- Command resolution -------------------------------------------------
    foreach ($entry in @(
        @{ Name = 'Install'; Command = $Manifest.InstallCommand }
        @{ Name = 'Uninstall'; Command = $Manifest.UninstallCommand }
    )) {
        try {
            $resolved = Resolve-CommandTarget -CommandLine $entry.Command -PackagePath $resolvedSource
            $checks.Add((New-ValidationCheck -Name "$($entry.Name) command resolves to an existing file" -Passed $resolved.Exists `
                         -Detail $(if ($resolved.Exists) { $resolved.Target } else { "Unresolved target: $($resolved.Target)" })))

            $interactive = @(Find-InteractiveArgument -CommandLine $entry.Command)
            $checks.Add((New-ValidationCheck -Name "$($entry.Name) command has no interactive arguments" -Passed ($interactive.Count -eq 0) `
                         -Detail $(($interactive | ForEach-Object { "$($_.Argument): $($_.Reason)" }) -join '; ')))

            $duplicates = @(Find-DuplicateArgument -CommandLine $entry.Command)
            $checks.Add((New-ValidationCheck -Name "$($entry.Name) command has no duplicate arguments" -Passed ($duplicates.Count -eq 0) `
                         -Detail $(($duplicates | ForEach-Object { "$($_.Argument) x$($_.Count)" }) -join '; ')))
        } catch {
            $checks.Add((New-ValidationCheck -Name "$($entry.Name) command is parsable" -Passed $false -Detail $_.Exception.Message))
        }
    }

    # --- Path hygiene -------------------------------------------------------
    $detectionScriptName = if ($Manifest.PSObject.Properties.Name -contains 'DetectionScript' -and $Manifest.DetectionScript) {
        @(Split-Path -Path $Manifest.DetectionScript -Leaf)
    } else {
        @()
    }

    $pathResult = Invoke-PathValidation -PackagePath $resolvedSource `
                                        -InstallBehavior $Manifest.InstallBehavior `
                                        -AllowedPath $AllowedPath `
                                        -ExcludeScript $detectionScriptName

    $invalid = @($pathResult.InvalidPaths)
    $checks.Add((New-ValidationCheck -Name 'No invalid absolute paths' -Passed ($invalid.Count -eq 0) `
                 -Detail $(($invalid | ForEach-Object { "$($_.File):$($_.Line) $($_.Path) - $($_.Reason)" }) -join "`n")))

    $suspect = @($pathResult.SuspectPaths)
    $checks.Add((New-ValidationCheck -Name 'No unclassified absolute paths' -Passed ($suspect.Count -eq 0) -Severity 'Warning' `
                 -Detail $(($suspect | ForEach-Object { "$($_.File):$($_.Line) $($_.Path)" }) -join "`n")))

    $workingDir = @($pathResult.WorkingDirectoryAssumptions)
    $checks.Add((New-ValidationCheck -Name 'No working-directory assumptions' -Passed ($workingDir.Count -eq 0) `
                 -Detail $(($workingDir | ForEach-Object { "$($_.File):$($_.Line) $($_.Match) - $($_.Reason)" }) -join "`n")))

    $userDeps = @($pathResult.UserProfileDependencies | Where-Object { $_.Severity -eq 'REVIEW' })
    $checks.Add((New-ValidationCheck -Name 'No unreviewed user-profile dependencies' -Passed ($userDeps.Count -eq 0) -Severity 'Warning' `
                 -Detail $(($userDeps | ForEach-Object { "$($_.File):$($_.Line) $($_.Token)" }) -join "`n")))

    $missingScriptRoot = @($pathResult.ScriptRootUsage | Where-Object { -not $_.UsesScriptRoot })
    $checks.Add((New-ValidationCheck -Name 'Scripts resolve content from $PSScriptRoot' -Passed ($missingScriptRoot.Count -eq 0) -Severity 'Warning' `
                 -Detail $(($missingScriptRoot | ForEach-Object { Split-Path $_.Script -Leaf }) -join ', ')))

    # --- Clean source -------------------------------------------------------
    $nested = @(Get-ChildItem -LiteralPath $resolvedSource -Recurse -File -Filter '*.intunewin' -ErrorAction SilentlyContinue)
    $checks.Add((New-ValidationCheck -Name 'No nested .intunewin files' -Passed ($nested.Count -eq 0) `
                 -Detail (@($nested | ForEach-Object { $_.Name }) -join ', ')))

    $stale = @(
        foreach ($pattern in $script:StaleArtifactPatterns) {
            Get-ChildItem -LiteralPath $resolvedSource -Recurse -File -Filter $pattern -ErrorAction SilentlyContinue
        }
    )
    $checks.Add((New-ValidationCheck -Name 'No stale build artifacts in source' -Passed ($stale.Count -eq 0) `
                 -Detail (@($stale | ForEach-Object { $_.Name } | Select-Object -Unique) -join ', ')))

    $logDirectories = @(Get-ChildItem -LiteralPath $resolvedSource -Recurse -Directory -ErrorAction SilentlyContinue |
                        Where-Object { $_.Name -in @('logs', 'log') })
    $checks.Add((New-ValidationCheck -Name 'No log directories in source' -Passed ($logDirectories.Count -eq 0) `
                 -Detail (@($logDirectories | ForEach-Object { $_.Name }) -join ', ')))

    # --- Manifest integrity -------------------------------------------------
    $manifestResult = Test-PackageManifest -Manifest $Manifest
    $checks.Add((New-ValidationCheck -Name 'Manifest is complete' -Passed $manifestResult.IsValid `
                 -Detail ($manifestResult.Errors -join '; ')))

    $failed   = @($checks | Where-Object { -not $_.Passed -and $_.Severity -eq 'Error' })
    $warnings = @($checks | Where-Object { -not $_.Passed -and $_.Severity -eq 'Warning' })

    [PSCustomObject]@{
        CanBuild = $failed.Count -eq 0
        Checks   = $checks.ToArray()
        Errors   = @($failed | ForEach-Object { "$($_.Name)$(if ($_.Detail) { ": $($_.Detail)" })" })
        Warnings = @($warnings | ForEach-Object { "$($_.Name)$(if ($_.Detail) { ": $($_.Detail)" })" })
        PathValidation = $pathResult
    }
}

function Write-PreBuildResult {
    <#
    .SYNOPSIS
        Renders a pre-build result to the host.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][PSCustomObject]$Result)

    foreach ($check in $Result.Checks) {
        $symbol = if ($check.Passed) { '[PASS]' } elseif ($check.Severity -eq 'Warning') { '[WARN]' } else { '[FAIL]' }
        $color  = if ($check.Passed) { 'Green' } elseif ($check.Severity -eq 'Warning') { 'Yellow' } else { 'Red' }
        Write-Host "$symbol $($check.Name)" -ForegroundColor $color
        if (-not $check.Passed -and $check.Detail) {
            foreach ($line in ($check.Detail -split "`n")) {
                if ($line.Trim()) { Write-Host "        $line" -ForegroundColor DarkGray }
            }
        }
    }

    if (-not $Result.CanBuild) {
        Write-Host "`nPRE-BUILD VALIDATION FAILED - .intunewin will not be created" -ForegroundColor Red
    }
}
