<#
.SYNOPSIS
    Deployment wrapper - detection (Autodesk Revit 2027).
.DESCRIPTION
    Implements the Intune custom-script detection contract exactly:

        detected      -> write output to STDOUT and exit 0
        not detected  -> write nothing and exit 0

    A non-zero exit is treated by Intune as "not detected". Writing output
    while exiting non-zero does NOT count as detected, so both halves of the
    contract must be honoured together.

    This script must never throw: an unhandled exception produces a non-zero
    exit that Intune reads as "not installed", which silently triggers a
    reinstall loop. Failures are therefore caught and reported as not-detected.

    When it finds nothing, it says on STDERR what it looked for and what it
    found instead. Intune ignores STDERR, so the contract is unaffected, and
    "not detected" stops being a dead end.
#>

[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# --- Detection criteria ------------------------------------------------------
# These are literal values on purpose. Anything that can fail belongs inside the
# try block below, because a statement out here that throws ends the script with
# a non-zero exit before the error handling exists.
#
# Revit 2027 registers in Add/Remove Programs as "Revit 2027" (Autodesk appends
# the year); the wildcard tolerates any edition/build suffix. The primary
# executable is the strongest evidence, since it proves the files are present
# and survives the registry naming varying between builds.
#
# $ExpectedVersion is a MINIMUM. It is left empty here so detection is
# presence-based: any installed Revit 2027 satisfies it. To require the 2027.3
# update specifically, install it on a reference machine, read the version of
# C:\Program Files\Autodesk\Revit 2027\Revit.exe (or the ARP DisplayVersion),
# and set that build number here.
$DisplayName           = 'Revit 2027*'
$ExpectedVersion       = ''
$ExpectedFile          = 'Autodesk\Revit 2027\Revit.exe'
$ProgramFilesVariable  = 'ProgramFiles'

# Revit is x64 and registers in the native view; both are listed so the view
# does not have to be known in advance. HKCU is deliberately absent: Intune
# runs a System-context app's detection as SYSTEM, whose HKCU is not the
# signed-in user's.
$RegistryViews = @(
    'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall'
    'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall'
)

# What was examined, reported on STDERR when nothing matched.
$script:Diagnostics = [System.Collections.Generic.List[string]]::new()

function Test-VersionSatisfied {
    param(
        [AllowNull()][string]$Installed,
        [AllowNull()][string]$Expected
    )

    if (-not $Installed) { return $false }
    if (-not $Expected)  { return $true }

    $parsedInstalled = $null
    $parsedExpected  = $null

    if ([version]::TryParse($Installed, [ref]$parsedInstalled) -and
        [version]::TryParse($Expected, [ref]$parsedExpected)) {
        return $parsedInstalled -ge $parsedExpected
    }

    $Installed -eq $Expected
}

function Resolve-ExpectedFile {
    if (-not $ExpectedFile) { return $null }

    $base = [Environment]::GetEnvironmentVariable($ProgramFilesVariable)
    if (-not $base) {
        $script:Diagnostics.Add("Environment variable '$ProgramFilesVariable' is not set, so the file criterion was skipped.")
        return $null
    }

    Join-Path $base $ExpectedFile
}

function Test-ApplicationPresent {
    $nameMatched = $false

    foreach ($view in $RegistryViews) {
        if (-not (Test-Path -LiteralPath $view)) {
            $script:Diagnostics.Add("Registry view not readable from this process: $view")
            continue
        }

        foreach ($item in (Get-ChildItem -LiteralPath $view -ErrorAction SilentlyContinue)) {
            $properties = Get-ItemProperty -LiteralPath $item.PSPath -ErrorAction SilentlyContinue
            if (-not $properties) { continue }
            if ($properties.PSObject.Properties.Name -notcontains 'DisplayName') { continue }
            if ($properties.DisplayName -notlike $DisplayName) { continue }

            $nameMatched = $true

            $installedVersion = if ($properties.PSObject.Properties.Name -contains 'DisplayVersion') {
                $properties.DisplayVersion
            } else {
                $null
            }

            # With no minimum version required, an ARP name match is sufficient.
            if (-not $ExpectedVersion) {
                return "Detected $($properties.DisplayName)$(if ($installedVersion) { " $installedVersion" })"
            }

            if (-not $installedVersion) {
                $script:Diagnostics.Add("Registry entry '$($properties.DisplayName)' matched but registers no DisplayVersion.")
                continue
            }

            if (Test-VersionSatisfied -Installed $installedVersion -Expected $ExpectedVersion) {
                return "Detected $($properties.DisplayName) $installedVersion"
            }

            $script:Diagnostics.Add("Registry entry '$($properties.DisplayName)' is version $installedVersion, below the expected $ExpectedVersion.")
        }
    }

    if (-not $nameMatched) {
        $script:Diagnostics.Add("No registry entry matched DisplayName '$DisplayName'.")
        Add-NameCandidate
    }

    $expectedFullPath = Resolve-ExpectedFile
    if ($expectedFullPath) {
        if (Test-Path -LiteralPath $expectedFullPath -PathType Leaf) {
            $fileVersion = (Get-Item -LiteralPath $expectedFullPath).VersionInfo.FileVersion

            if (Test-VersionSatisfied -Installed $fileVersion -Expected $ExpectedVersion) {
                return "Detected $expectedFullPath $fileVersion"
            }

            $script:Diagnostics.Add("File $expectedFullPath is version $fileVersion, below the expected $ExpectedVersion.")
        } else {
            $script:Diagnostics.Add("File not present: $expectedFullPath")
        }
    }

    $null
}

function Add-NameCandidate {
    $stem = ($DisplayName -replace '[\*\?]', '').Trim()
    if ($stem.Length -lt 3) { return }

    $firstWord = ($stem -split '\s+')[0]
    $candidates = [System.Collections.Generic.List[string]]::new()

    foreach ($view in $RegistryViews) {
        if (-not (Test-Path -LiteralPath $view)) { continue }

        foreach ($item in (Get-ChildItem -LiteralPath $view -ErrorAction SilentlyContinue)) {
            $properties = Get-ItemProperty -LiteralPath $item.PSPath -ErrorAction SilentlyContinue
            if (-not $properties) { continue }
            if ($properties.PSObject.Properties.Name -notcontains 'DisplayName') { continue }
            if ($properties.DisplayName -notlike "*$firstWord*") { continue }
            if ($candidates -contains $properties.DisplayName) { continue }

            $candidates.Add($properties.DisplayName)
            if ($candidates.Count -ge 10) { break }
        }
    }

    if ($candidates.Count -gt 0) {
        $script:Diagnostics.Add("Registered names containing '$firstWord': " + ($candidates -join '; '))
    } else {
        $script:Diagnostics.Add("Nothing registered contains '$firstWord'. The application may not be installed, may register under a different name, or may be a per-user install invisible to SYSTEM.")
    }
}

try {
    $evidence = Test-ApplicationPresent

    if ($evidence) {
        Write-Output $evidence
        exit 0
    }

    [Console]::Error.WriteLine("Not detected. Criteria checked:")
    foreach ($note in $script:Diagnostics) {
        [Console]::Error.WriteLine("  - $note")
    }
    exit 0
} catch {
    [Console]::Error.WriteLine("Detection failed: $($_.Exception.Message)")
    exit 0
}
