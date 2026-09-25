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

    When it finds nothing, it says on STDERR what it looked for and what it
    found instead. Intune ignores STDERR, so the contract is unaffected, and
    "not detected" stops being a dead end: the usual cause is a $DisplayName
    that does not match what the installer actually registered.
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
# $DisplayName is matched against the registry's DisplayName with -like, so it
# must be what the installer REGISTERED, not the product's marketing name.
# Installers routinely append an edition or version: "Example App (64-bit)",
# "Example App 5.2.1". Look the value up rather than assuming it:
#
#   Get-ChildItem 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall',
#                 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall' |
#       ForEach-Object { (Get-ItemProperty $_.PSPath).DisplayName } |
#       Where-Object { $_ -like '*Example*' }
#
# Wildcards are allowed: 'Example App*' matches any version suffix. Prefer a
# pattern narrow enough that nothing else on the machine can satisfy it.
#
# $ExpectedVersion is a MINIMUM: an installed version at or above it counts as
# detected, so an application that updates itself is not reported as missing.
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
# 64-bit OS registers under WOW6432Node; looking in the wrong view is a common
# cause of false "not detected" results. Both are listed, so the view does not
# have to be known in advance.
#
# HKCU is deliberately absent. Intune runs a System-context app's detection as
# SYSTEM, whose HKCU is the service account's, not the signed-in user's. A
# per-user application cannot be detected from there, and adding HKCU would
# make it appear detectable while you test as yourself.
$RegistryViews = @(
    'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall'
    'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall'
)

# What was examined, reported on STDERR when nothing matched.
$script:Diagnostics = [System.Collections.Generic.List[string]]::new()

function Test-VersionSatisfied {
    <#
    .SYNOPSIS
        Whether an installed version meets the expected minimum.
    .DESCRIPTION
        Version-aware where both values parse, so 5.2.10 is correctly newer
        than 5.2.9 and '1.0.0' is satisfied by a file stamped '1.0.0.0'. Falls
        back to string equality only when they do not, since a vendor string
        like '2024 R2' has no ordering to apply.
    #>
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
            # A 32-bit PowerShell on a 64-bit OS is redirected and cannot see
            # WOW6432Node by that name. Worth knowing, because it changes which
            # view the script is actually reading.
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
    <#
    .SYNOPSIS
        Records registered names resembling the one being looked for.
    .DESCRIPTION
        A DisplayName that does not match what the installer registered is the
        most common cause of a detection script that finds nothing. Naming the
        near misses turns that from a guess into a correction.
    #>
    $stem = ($DisplayName -replace '[\*\?]', '').Trim()
    if ($stem.Length -lt 3) { return }

    # The first word is enough to find the vendor's own naming, and short
    # enough not to miss it over an edition or version suffix.
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

    # Not detected: no output, exit 0. The reasoning goes to STDERR, which
    # Intune ignores and the validation harness records.
    [Console]::Error.WriteLine("Not detected. Criteria checked:")
    foreach ($note in $script:Diagnostics) {
        [Console]::Error.WriteLine("  - $note")
    }
    exit 0
} catch {
    # Never let an exception escape as a non-zero exit with output. The reason
    # goes to STDERR, which Intune ignores and the validation harness records,
    # so a detection script that is quietly failing is still visible somewhere.
    [Console]::Error.WriteLine("Detection failed: $($_.Exception.Message)")
    exit 0
}
