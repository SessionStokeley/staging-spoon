<#
.SYNOPSIS
    Path, user-profile and working-directory validation for deployment scripts.
.DESCRIPTION
    Absolute paths are not automatically invalid, but every one must be
    explicitly classified. Payload paths must resolve from $PSScriptRoot.
#>

Set-StrictMode -Version Latest

# Absolute paths that legitimately appear in a SYSTEM-context deployment.
$script:SystemPathPatterns = @(
    '^[A-Za-z]:\\Program Files( \(x86\))?\\'
    '^[A-Za-z]:\\ProgramData\\'
    '^[A-Za-z]:\\Windows\\'
)

# Absolute paths that indicate a developer machine. Never valid in a package.
# Shared profiles (Public, Default, All Users) are excluded: an all-users
# shortcut legitimately lives in C:\Users\Public\Desktop.
$script:DeveloperPathPatterns = @(
    '^[A-Za-z]:\\Users\\(?!Public\\|Default\\|Default User\\|All Users\\)'
    '%USERPROFILE%'
    '%APPDATA%'
    '%LOCALAPPDATA%'
    '\\OneDrive'
)

# Absolute paths that usually mean a build/staging directory leaked into the package.
$script:BuildPathPatterns = @(
    '^[A-Za-z]:\\Build\\'
    '^[A-Za-z]:\\Dev\\'
    '^[A-Za-z]:\\Source\\'
    '^[A-Za-z]:\\Staging\\'
    '^[A-Za-z]:\\Projects?\\'
    '^[A-Za-z]:\\Repos?\\'
    '^[A-Za-z]:\\Temp\\'
    '^[A-Za-z]:\\Packaging\\'
)

$script:UserProfileTokens = @(
    '%USERPROFILE%'
    '%APPDATA%'
    '%LOCALAPPDATA%'
    '$env:USERPROFILE'
    '$env:APPDATA'
    '$env:LOCALAPPDATA'
    '$HOME'
    'HKCU:'
    'HKEY_CURRENT_USER'
)

$script:ScannableExtensions = @('.ps1', '.psm1', '.psd1', '.cmd', '.bat', '.json', '.xml', '.ini', '.config')

function Get-PathClassification {
    <#
    .SYNOPSIS
        Classifies a single absolute path as VALID, SUSPECT or INVALID.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)

    foreach ($pattern in $script:DeveloperPathPatterns) {
        if ($Path -match $pattern) {
            return [PSCustomObject]@{
                Path           = $Path
                Classification = 'INVALID'
                Reason         = 'Developer-machine path; will not exist on a managed device'
            }
        }
    }

    if ($Path -match '^\\\\') {
        return [PSCustomObject]@{
            Path           = $Path
            Classification = 'INVALID'
            Reason         = 'UNC path; unreachable from SYSTEM context without machine credentials'
        }
    }

    foreach ($pattern in $script:BuildPathPatterns) {
        if ($Path -match $pattern) {
            return [PSCustomObject]@{
                Path           = $Path
                Classification = 'INVALID'
                Reason         = 'Build/staging path; payload must resolve from $PSScriptRoot'
            }
        }
    }

    foreach ($pattern in $script:SystemPathPatterns) {
        if ($Path -match $pattern) {
            return [PSCustomObject]@{
                Path           = $Path
                Classification = 'VALID'
                Reason         = 'System install location'
            }
        }
    }

    # Drive letters beyond the system drive are not guaranteed to exist on a device.
    if ($Path -match '^[D-Zd-z]:\\') {
        return [PSCustomObject]@{
            Path           = $Path
            Classification = 'INVALID'
            Reason         = 'Non-system drive; not guaranteed to exist on the target device'
        }
    }

    [PSCustomObject]@{
        Path           = $Path
        Classification = 'SUSPECT'
        Reason         = 'Absolute path requires explicit review'
    }
}

function Find-AbsolutePath {
    <#
    .SYNOPSIS
        Extracts and classifies every absolute path in a package directory.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$PackagePath,
        [string[]]$AllowedPath = @(),
        [string[]]$ExcludeFile = @()
    )

    $findings = [System.Collections.Generic.List[PSCustomObject]]::new()

    # The lookbehind stops a registry provider path such as HKLM:\SOFTWARE
    # from matching as drive "M:\". Without it every package that reads the
    # registry would be reported as referencing a non-system drive.
    #
    # A single interior space is part of the path, because the most common
    # system locations contain one: stopping at whitespace truncates
    # "C:\Program Files\Vendor\App" to "C:\Program", which then matches no
    # known-good location and is reported as an unclassified path on virtually
    # every real package. Runs of two spaces, and a trailing space, end the
    # match so prose following a path is not swallowed.
    $pathRegex = '(?<![A-Za-z0-9_$:])(?:[A-Za-z]:\\|\\\\)' +
                 '(?:[^\s"''<>|*?\r\n;]|(?<![\s]) (?=[^\s"''<>|*?\r\n;$]))+'

    $files = Get-ChildItem -LiteralPath $PackagePath -Recurse -File |
             Where-Object { $_.Extension -in $script:ScannableExtensions -and $_.Name -notin $ExcludeFile }

    foreach ($file in $files) {
        $lineNumber = 0
        foreach ($line in (Get-Content -LiteralPath $file.FullName)) {
            $lineNumber++

            # Skip comment-only lines to reduce noise from documentation.
            if ($line -match '^\s*#') { continue }

            foreach ($match in [regex]::Matches($line, $pathRegex)) {
                $candidate = $match.Value.TrimEnd('\', '.', ',', ';', ')')
                if ($AllowedPath -contains $candidate) { continue }

                $classification = Get-PathClassification -Path $candidate
                $findings.Add([PSCustomObject]@{
                    File           = $file.FullName.Substring($PackagePath.Length).TrimStart('\', '/')
                    Line           = $lineNumber
                    Path           = $candidate
                    Classification = $classification.Classification
                    Reason         = $classification.Reason
                })
            }
        }
    }

    $findings.ToArray()
}

function Find-UserProfileDependency {
    <#
    .SYNOPSIS
        Finds user-context dependencies that break under SYSTEM.
    .DESCRIPTION
        These are flagged for review rather than failed outright: a package may
        legitimately write per-user state via an ActiveSetup or logon task.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$PackagePath,
        [ValidateSet('System', 'User')][string]$InstallBehavior = 'System',
        [string[]]$ExcludeFile = @()
    )

    $findings = [System.Collections.Generic.List[PSCustomObject]]::new()

    $files = Get-ChildItem -LiteralPath $PackagePath -Recurse -File |
             Where-Object { $_.Extension -in $script:ScannableExtensions -and $_.Name -notin $ExcludeFile }

    foreach ($file in $files) {
        $lineNumber = 0
        foreach ($line in (Get-Content -LiteralPath $file.FullName)) {
            $lineNumber++
            if ($line -match '^\s*#') { continue }

            foreach ($token in $script:UserProfileTokens) {
                if ($line -like "*$token*") {
                    $findings.Add([PSCustomObject]@{
                        File     = $file.FullName.Substring($PackagePath.Length).TrimStart('\', '/')
                        Line     = $lineNumber
                        Token    = $token
                        Severity = if ($InstallBehavior -eq 'System') { 'REVIEW' } else { 'INFO' }
                        Reason   = if ($InstallBehavior -eq 'System') {
                            "Under SYSTEM this resolves to the SYSTEM profile, not the signed-in user"
                        } else {
                            "Resolves to the invoking user's profile"
                        }
                    })
                }
            }
        }
    }

    $findings.ToArray()
}

function Find-WorkingDirectoryAssumption {
    <#
    .SYNOPSIS
        Finds package-relative references that assume the current directory.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$PackagePath)

    $findings = [System.Collections.Generic.List[PSCustomObject]]::new()

    $patterns = @(
        @{ Regex = '(?<![\w$])\.\\[\w][\w\-. ]*\.(exe|msi|ps1|cmd|bat)'; Reason = 'Relative invocation depends on the current working directory; use Join-Path $PSScriptRoot' }
        @{ Regex = '(?<![\w-])Get-Location(?![\w-])';                    Reason = 'Get-Location returns the caller''s directory, not the package directory' }
        @{ Regex = '\$PWD(?![\w])';                                      Reason = '$PWD returns the caller''s directory, not the package directory' }
        @{ Regex = '(?<![\w-])Resolve-Path\s+["'']?\.[\\/]';             Reason = 'Resolves against the current working directory' }
    )

    $files = Get-ChildItem -LiteralPath $PackagePath -Recurse -File |
             Where-Object { $_.Extension -in @('.ps1', '.psm1', '.cmd', '.bat') }

    foreach ($file in $files) {
        $lineNumber = 0
        foreach ($line in (Get-Content -LiteralPath $file.FullName)) {
            $lineNumber++
            if ($line -match '^\s*#') { continue }

            foreach ($pattern in $patterns) {
                if ($line -match $pattern.Regex) {
                    $findings.Add([PSCustomObject]@{
                        File   = $file.FullName.Substring($PackagePath.Length).TrimStart('\', '/')
                        Line   = $lineNumber
                        Match  = $Matches[0]
                        Reason = $pattern.Reason
                    })
                }
            }
        }
    }

    $findings.ToArray()
}

function Test-ScriptRootUsage {
    <#
    .SYNOPSIS
        Verifies each deployment script resolves its own location.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string[]]$ScriptPath)

    $results = [System.Collections.Generic.List[PSCustomObject]]::new()

    foreach ($path in $ScriptPath) {
        if (-not (Test-Path -LiteralPath $path)) {
            $results.Add([PSCustomObject]@{
                Script          = $path
                UsesScriptRoot  = $false
                Reason          = 'Script not found'
            })
            continue
        }

        $content = Get-Content -LiteralPath $path -Raw
        $usesScriptRoot = $content -match '\$PSScriptRoot'

        $results.Add([PSCustomObject]@{
            Script         = $path
            UsesScriptRoot = $usesScriptRoot
            Reason         = if ($usesScriptRoot) {
                'Resolves package content from $PSScriptRoot'
            } else {
                'Does not reference $PSScriptRoot; package-relative content may not resolve'
            }
        })
    }

    $results.ToArray()
}

function Invoke-PathValidation {
    <#
    .SYNOPSIS
        Runs every path-related check and aggregates the result.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$PackagePath,
        [ValidateSet('System', 'User')][string]$InstallBehavior = 'System',
        [string[]]$AllowedPath = @(),
        [string[]]$ExcludeScript = @()
    )

    $absolutePaths    = @(Find-AbsolutePath -PackagePath $PackagePath -AllowedPath $AllowedPath -ExcludeFile $ExcludeScript)
    $userDependencies = @(Find-UserProfileDependency -PackagePath $PackagePath -InstallBehavior $InstallBehavior -ExcludeFile $ExcludeScript)
    $workingDirectory = @(Find-WorkingDirectoryAssumption -PackagePath $PackagePath)

    # $PSScriptRoot matters for scripts that must find payload shipped beside
    # them. A detection script inspects the installed application rather than
    # the package, so requiring it there reports a problem that is not one.
    $scripts = @(Get-ChildItem -LiteralPath $PackagePath -Recurse -File -Filter '*.ps1' |
                 Where-Object { $_.Name -notin $ExcludeScript } |
                 ForEach-Object { $_.FullName })
    $scriptRoot = if ($scripts.Count -gt 0) { @(Test-ScriptRootUsage -ScriptPath $scripts) } else { @() }

    $invalidPaths = @($absolutePaths | Where-Object { $_.Classification -eq 'INVALID' })
    $suspectPaths = @($absolutePaths | Where-Object { $_.Classification -eq 'SUSPECT' })

    [PSCustomObject]@{
        IsValid                    = ($invalidPaths.Count -eq 0 -and $workingDirectory.Count -eq 0)
        AbsolutePaths              = $absolutePaths
        InvalidPaths               = $invalidPaths
        SuspectPaths               = $suspectPaths
        UserProfileDependencies    = $userDependencies
        WorkingDirectoryAssumptions = $workingDirectory
        ScriptRootUsage            = $scriptRoot
    }
}
