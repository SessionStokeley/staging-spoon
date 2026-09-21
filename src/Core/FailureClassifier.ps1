<#
.SYNOPSIS
    Failure classification and failure-report generation.
.DESCRIPTION
    A failed deployment is classified before anything is rebuilt.
    Reproduce first, fix second, rebuild third.
#>

Set-StrictMode -Version Latest

$script:FailureClassifications = @(
    'PACKAGING_FAILURE'
    'COMMAND_FAILURE'
    'CONTEXT_FAILURE'
    'INSTALLER_FAILURE'
    'DEPENDENCY_FAILURE'
    'DETECTION_FAILURE'
    'RETURN_CODE_FAILURE'
    'REBOOT_FAILURE'
    'PERMISSION_FAILURE'
    'PATH_FAILURE'
    'USER_CONTEXT_FAILURE'
    'SYSTEM_CONTEXT_FAILURE'
    'APPLICATION_FAILURE'
    'UNKNOWN'
)

# Exit codes whose meaning is unambiguous enough to classify on their own.
$script:ExitCodeClassification = @{
    5    = @{ Class = 'PERMISSION_FAILURE';  Reason = 'Access denied' }
    740  = @{ Class = 'PERMISSION_FAILURE';  Reason = 'Elevation required' }
    1601 = @{ Class = 'DEPENDENCY_FAILURE';  Reason = 'Windows Installer service unavailable' }
    1602 = @{ Class = 'INSTALLER_FAILURE';   Reason = 'User cancelled installation' }
    1603 = @{ Class = 'INSTALLER_FAILURE';   Reason = 'Fatal error during installation' }
    1605 = @{ Class = 'INSTALLER_FAILURE';   Reason = 'Product is not installed' }
    1608 = @{ Class = 'INSTALLER_FAILURE';   Reason = 'Unknown property' }
    1612 = @{ Class = 'PACKAGING_FAILURE';   Reason = 'Installation source unavailable' }
    1618 = @{ Class = 'DEPENDENCY_FAILURE';  Reason = 'Another installation is already in progress' }
    1619 = @{ Class = 'PATH_FAILURE';        Reason = 'Installation package could not be opened' }
    1620 = @{ Class = 'PACKAGING_FAILURE';   Reason = 'Installation package could not be opened; package may be corrupt' }
    1625 = @{ Class = 'PERMISSION_FAILURE';  Reason = 'Installation forbidden by system policy' }
    1633 = @{ Class = 'CONTEXT_FAILURE';     Reason = 'Platform not supported; architecture mismatch' }
    1638 = @{ Class = 'DEPENDENCY_FAILURE';  Reason = 'Another version of this product is already installed' }
    1641 = @{ Class = 'REBOOT_FAILURE';      Reason = 'Installer initiated a reboot' }
    3010 = @{ Class = 'REBOOT_FAILURE';      Reason = 'Reboot required to complete installation' }
}

# Message fragments that identify a failure mode regardless of exit code.
$script:MessageClassification = @(
    @{ Pattern = 'access is denied|unauthorizedaccess|0x80070005'; Class = 'PERMISSION_FAILURE';     Reason = 'Access denied in output' }
    @{ Pattern = 'could not find file|cannot find path|does not exist|0x80070002'; Class = 'PATH_FAILURE'; Reason = 'Missing file or path in output' }
    @{ Pattern = 'is not recognized as|commandnotfound'; Class = 'COMMAND_FAILURE';                  Reason = 'Command or executable not found' }
    @{ Pattern = 'no interactive|requires a user interface|desktop is not available'; Class = 'SYSTEM_CONTEXT_FAILURE'; Reason = 'Installer requires an interactive desktop' }
    @{ Pattern = 'userprofile|appdata|hkey_current_user|hkcu'; Class = 'USER_CONTEXT_FAILURE';       Reason = 'User-profile dependency surfaced at runtime' }
    @{ Pattern = 'prerequisite|requires \.net|missing dependency|not installed'; Class = 'DEPENDENCY_FAILURE'; Reason = 'Unmet prerequisite' }
    @{ Pattern = 'mapped drive|network path|\\\\'; Class = 'PATH_FAILURE';                           Reason = 'Network or UNC path referenced' }
)

function Get-FailureClassification {
    <#
    .SYNOPSIS
        Classifies a deployment failure.
    .PARAMETER Stage
        The pipeline stage that failed.
    .OUTPUTS
        PSCustomObject with Classification, Reason and Confidence.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateSet('PreBuild', 'Build', 'Install', 'Detection', 'Uninstall', 'DetectionRemoval', 'PostInstall')]
        [string]$Stage,

        [Nullable[int]]$ExitCode = $null,
        [string]$Output = '',
        [Nullable[bool]]$DetectionResult = $null,
        [int[]]$ExpectedExitCodes = @(0),
        [ValidateSet('System', 'Administrator', 'User')][string]$ExecutionContextName = 'System'
    )

    # Stage-level classification that no exit code can override.
    switch ($Stage) {
        'PreBuild' {
            return [PSCustomObject]@{
                Classification = 'PACKAGING_FAILURE'
                Reason         = 'Package failed pre-build validation'
                Confidence     = 'High'
            }
        }
        'Build' {
            return [PSCustomObject]@{
                Classification = 'PACKAGING_FAILURE'
                Reason         = 'Package creation failed'
                Confidence     = 'High'
            }
        }
    }

    $combinedOutput = $Output.ToLowerInvariant()

    # An installer that reported success while detection disagrees is a
    # detection failure only once the installer's own code is accounted for.
    if ($Stage -eq 'Detection' -and $DetectionResult -eq $false) {
        if ($null -ne $ExitCode -and $ExitCode -in $ExpectedExitCodes) {
            return [PSCustomObject]@{
                Classification = 'DETECTION_FAILURE'
                Reason         = 'Installer reported success but detection returned false'
                Confidence     = 'High'
            }
        }
    }

    if ($Stage -eq 'DetectionRemoval' -and $DetectionResult -eq $true) {
        return [PSCustomObject]@{
            Classification = 'DETECTION_FAILURE'
            Reason         = 'Detection still returns true after uninstall'
            Confidence     = 'High'
        }
    }

    if ($Stage -eq 'PostInstall') {
        return [PSCustomObject]@{
            Classification = 'APPLICATION_FAILURE'
            Reason         = 'Application state did not match declared expectations after installation'
            Confidence     = 'Medium'
        }
    }

    if ($null -ne $ExitCode -and $script:ExitCodeClassification.ContainsKey($ExitCode)) {
        $entry = $script:ExitCodeClassification[$ExitCode]

        # A reboot code is only a failure when the package did not declare it.
        if ($entry.Class -eq 'REBOOT_FAILURE' -and $ExitCode -in $ExpectedExitCodes) {
            return [PSCustomObject]@{
                Classification = 'REBOOT_FAILURE'
                Reason         = "$($entry.Reason) (declared in ExpectedExitCodes; handle via RebootBehavior)"
                Confidence     = 'High'
            }
        }

        return [PSCustomObject]@{
            Classification = $entry.Class
            Reason         = "Exit code $ExitCode`: $($entry.Reason)"
            Confidence     = 'High'
        }
    }

    foreach ($rule in $script:MessageClassification) {
        if ($combinedOutput -match $rule.Pattern) {
            $classification = $rule.Class

            # The same symptom means something different under SYSTEM.
            if ($classification -eq 'USER_CONTEXT_FAILURE' -and $ExecutionContextName -eq 'System') {
                $classification = 'SYSTEM_CONTEXT_FAILURE'
            }

            return [PSCustomObject]@{
                Classification = $classification
                Reason         = $rule.Reason
                Confidence     = 'Medium'
            }
        }
    }

    if ($null -ne $ExitCode -and $ExitCode -notin $ExpectedExitCodes) {
        return [PSCustomObject]@{
            Classification = 'RETURN_CODE_FAILURE'
            Reason         = "Exit code $ExitCode is not in ExpectedExitCodes ($($ExpectedExitCodes -join ', '))"
            Confidence     = 'Medium'
        }
    }

    [PSCustomObject]@{
        Classification = 'UNKNOWN'
        Reason         = 'Failure could not be classified from available evidence'
        Confidence     = 'Low'
    }
}

function New-FailureReport {
    <#
    .SYNOPSIS
        Writes FailureReport.md so a failure can be reproduced before it is fixed.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][PSCustomObject]$Manifest,
        [Parameter(Mandatory)][PSCustomObject]$Classification,
        [Parameter(Mandatory)][string]$Path,

        [string]$Stage = '',
        [string]$Command = '',
        [Nullable[int]]$ExitCode = $null,
        [Nullable[bool]]$DetectionResult = $null,
        [string]$Output = '',
        [string]$DeviceContext = $env:COMPUTERNAME,
        [string]$ExecutionContextName = 'System',
        [PSCustomObject]$InstallDelta = $null
    )

    $lines = [System.Collections.Generic.List[string]]::new()

    $lines.Add('# Failure Report')
    $lines.Add('')
    $lines.Add("Generated: $((Get-Date).ToString('o'))")
    $lines.Add('')
    $lines.Add('## Classification')
    $lines.Add('')
    $lines.Add('```')
    $lines.Add($Classification.Classification)
    $lines.Add('```')
    $lines.Add('')
    $lines.Add("**Reason:** $($Classification.Reason)")
    $lines.Add('')
    $lines.Add("**Confidence:** $($Classification.Confidence)")
    $lines.Add('')

    $lines.Add('## Package')
    $lines.Add('')
    $lines.Add("| Field | Value |")
    $lines.Add("| --- | --- |")
    $lines.Add("| Application | $($Manifest.ApplicationName) |")
    $lines.Add("| Application version | $($Manifest.ApplicationVersion) |")
    $lines.Add("| Package version | $($Manifest.PackageVersion) |")
    $lines.Add("| Installer type | $($Manifest.InstallerType) |")
    $lines.Add("| Architecture | $($Manifest.Architecture) |")
    $lines.Add("| Install behavior | $($Manifest.InstallBehavior) |")
    $lines.Add("| Package hash | $($Manifest.PackageHash) |")
    $lines.Add('')

    $lines.Add('## Failure Context')
    $lines.Add('')
    $lines.Add("| Field | Value |")
    $lines.Add("| --- | --- |")
    $lines.Add("| Stage | $Stage |")
    $lines.Add("| Device | $DeviceContext |")
    $lines.Add("| Execution context | $ExecutionContextName |")
    $lines.Add("| Exit code | $(if ($null -ne $ExitCode) { $ExitCode } else { 'n/a' }) |")
    $lines.Add("| Expected exit codes | $($Manifest.ExpectedExitCodes -join ', ') |")
    $lines.Add("| Detection result | $(if ($null -ne $DetectionResult) { $DetectionResult } else { 'not evaluated' }) |")
    $lines.Add('')

    if ($Command) {
        $lines.Add('## Command')
        $lines.Add('')
        $lines.Add('```')
        $lines.Add($Command)
        $lines.Add('```')
        $lines.Add('')
    }

    if ($Output) {
        $lines.Add('## Output')
        $lines.Add('')
        $lines.Add('```')
        $lines.Add($Output.Trim())
        $lines.Add('```')
        $lines.Add('')
    }

    if ($InstallDelta) {
        $lines.Add('## Observed State Change')
        $lines.Add('')
        $lines.Add("- Applications added: $($InstallDelta.Applications.Added.Count)")
        $lines.Add("- Files added: $($InstallDelta.Files.Added.Count)")
        $lines.Add("- Registry values added: $($InstallDelta.Registry.Added.Count)")
        $lines.Add("- Services added: $($InstallDelta.Services.Added.Count)")
        $lines.Add("- Shortcuts added: $($InstallDelta.Shortcuts.Added.Count)")
        $lines.Add('')
    }

    $lines.Add('## Reproduction')
    $lines.Add('')
    $lines.Add('Reproduce this failure locally before rebuilding. Use the same command,')
    $lines.Add('context, architecture and package content:')
    $lines.Add('')
    $lines.Add('```powershell')
    $lines.Add(".\src\Testing\Test-IntunePackage.ps1 ``")
    $lines.Add("    -SourcePath <package source> ``")
    $lines.Add("    -ManifestPath <PackageManifest.json> ``")
    $lines.Add($(if ($ExecutionContextName -eq 'System') { "    -SystemContext" } else { "    -Stage Install" }))
    $lines.Add('```')
    $lines.Add('')
    $lines.Add('Order of work: **reproduce first, fix second, rebuild third.**')
    $lines.Add('')

    $directory = Split-Path -Path $Path -Parent
    if ($directory -and -not (Test-Path -LiteralPath $directory)) {
        New-Item -Path $directory -ItemType Directory -Force | Out-Null
    }

    $lines -join "`n" | Set-Content -LiteralPath $Path -Encoding UTF8
    $Path
}
