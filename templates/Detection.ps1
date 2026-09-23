<#
.SYNOPSIS
    Deployment wrapper template - detection.
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
#>

[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# --- Detection criteria ------------------------------------------------------
# These are literal values on purpose. Anything that can fail - reading an
# environment variable, joining a path, touching the disk - belongs inside the
# try block below, because a statement out here that throws ends the script
# with a non-zero exit before the error handling exists. Intune reads that as
# "not installed" and reinstalls, every cycle, forever.
#
# $ExpectedFile is relative to Program Files. For a 32-bit application on a
# 64-bit OS, set $ProgramFilesVariable to 'ProgramFiles(x86)'. Note that
# $env:ProgramFiles(x86) is NOT valid PowerShell - the (x86) parses as a
# separate expression - which is why the name is given as text here.
$DisplayName           = 'Vendor Application'
$ExpectedVersion       = '1.0.0'
$ExpectedFile          = 'Vendor\Application\App.exe'
$ProgramFilesVariable  = 'ProgramFiles'

# Which registry view the application registers in. A 32-bit application on a
# 64-bit OS registers under WOW6432Node; looking in the wrong view is a
# common cause of false "not detected" results.
$RegistryViews = @(
    'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall'
    'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall'
)

function Resolve-ExpectedFile {
    <#
    .SYNOPSIS
        Builds the full path to the expected file, or nothing if it cannot.
    .DESCRIPTION
        Runs inside the guarded path, so a missing environment variable turns
        into "no file criterion" rather than into a non-zero exit that Intune
        would read as "not installed".
    #>
    if (-not $ExpectedFile) { return $null }

    $base = [Environment]::GetEnvironmentVariable($ProgramFilesVariable)
    if (-not $base) { return $null }

    Join-Path $base $ExpectedFile
}

function Test-ApplicationPresent {
    foreach ($view in $RegistryViews) {
        if (-not (Test-Path -LiteralPath $view)) { continue }

        foreach ($item in (Get-ChildItem -LiteralPath $view -ErrorAction SilentlyContinue)) {
            $properties = Get-ItemProperty -LiteralPath $item.PSPath -ErrorAction SilentlyContinue
            if (-not $properties) { continue }
            if ($properties.PSObject.Properties.Name -notcontains 'DisplayName') { continue }
            if ($properties.DisplayName -notlike $DisplayName) { continue }

            $installedVersion = if ($properties.PSObject.Properties.Name -contains 'DisplayVersion') {
                $properties.DisplayVersion
            } else {
                $null
            }

            if (-not $installedVersion) { continue }

            $parsedInstalled = $null
            $parsedExpected  = $null
            if ([version]::TryParse($installedVersion, [ref]$parsedInstalled) -and
                [version]::TryParse($ExpectedVersion, [ref]$parsedExpected)) {
                if ($parsedInstalled -ge $parsedExpected) {
                    return "Detected $($properties.DisplayName) $installedVersion"
                }
            } elseif ($installedVersion -eq $ExpectedVersion) {
                return "Detected $($properties.DisplayName) $installedVersion"
            }
        }
    }

    $expectedFullPath = Resolve-ExpectedFile
    if ($expectedFullPath -and (Test-Path -LiteralPath $expectedFullPath -PathType Leaf)) {
        $fileVersion = (Get-Item -LiteralPath $expectedFullPath).VersionInfo.FileVersion
        if ($fileVersion -eq $ExpectedVersion) {
            return "Detected $expectedFullPath $fileVersion"
        }
    }

    $null
}

try {
    $evidence = Test-ApplicationPresent

    if ($evidence) {
        Write-Output $evidence
        exit 0
    }

    # Not detected: no output, exit 0.
    exit 0
} catch {
    # Never let an exception escape as a non-zero exit with output. The reason
    # goes to STDERR, which Intune ignores and the validation harness records,
    # so a detection script that is quietly failing is still visible somewhere.
    [Console]::Error.WriteLine("Detection failed: $($_.Exception.Message)")
    exit 0
}
