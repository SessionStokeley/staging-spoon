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
$DisplayName       = 'Vendor Application'
$ExpectedVersion   = '1.0.0'
$ExpectedFile      = Join-Path $env:ProgramFiles 'Vendor\Application\App.exe'

# Which registry view the application registers in. A 32-bit application on a
# 64-bit OS registers under WOW6432Node; looking in the wrong view is a
# common cause of false "not detected" results.
$RegistryViews = @(
    'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall'
    'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall'
)

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

    if ($ExpectedFile -and (Test-Path -LiteralPath $ExpectedFile -PathType Leaf)) {
        $fileVersion = (Get-Item -LiteralPath $ExpectedFile).VersionInfo.FileVersion
        if ($fileVersion -eq $ExpectedVersion) {
            return "Detected $ExpectedFile $fileVersion"
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
    # Never let an exception escape as a non-zero exit with output.
    exit 0
}
