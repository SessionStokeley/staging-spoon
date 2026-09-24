<#
.SYNOPSIS
    Package manifest generation and validation.
.DESCRIPTION
    The manifest is the authoritative description of what was packaged.
    Every .intunewin build must have an associated PackageManifest.json.
#>

Set-StrictMode -Version Latest

$script:ManifestSchemaVersion = '1.0'

$script:RequiredManifestFields = @(
    'ApplicationName'
    'ApplicationVersion'
    'PackageVersion'
    'InstallerType'
    'SourceInstaller'
    'InstallCommand'
    'UninstallCommand'
    'DetectionMethod'
    'InstallBehavior'
    'Architecture'
    'MinimumOS'
    'ExpectedExitCodes'
    'RebootBehavior'
    'ContentDirectory'
    'BuildTimestamp'
)

$script:ValidInstallerTypes  = @('MSI', 'EXE', 'MSIX', 'APPX', 'Script', 'Wrapper')
$script:ValidInstallBehavior = @('System', 'User')
$script:ValidArchitectures   = @('x64', 'x86', 'ARM64', 'Neutral')
$script:ValidDetectionMethods = @('Script', 'MSI', 'File', 'Registry')
$script:ValidRebootBehavior  = @(
    'Suppress'
    'Force'
    'BasedOnReturnCode'
    'Allow'
)

function New-PackageManifest {
    <#
    .SYNOPSIS
        Builds a manifest object from package configuration.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ApplicationName,
        [Parameter(Mandatory)][string]$ApplicationVersion,
        [Parameter(Mandatory)][string]$PackageVersion,
        [Parameter(Mandatory)][ValidateScript({ $_ -in $script:ValidInstallerTypes })][string]$InstallerType,
        [Parameter(Mandatory)][string]$SourceInstaller,
        [Parameter(Mandatory)][string]$InstallCommand,
        [Parameter(Mandatory)][string]$UninstallCommand,
        [Parameter(Mandatory)][ValidateScript({ $_ -in $script:ValidDetectionMethods })][string]$DetectionMethod,
        [Parameter(Mandatory)][string]$ContentDirectory,

        [string]$DetectionScript = '',
        [ValidateScript({ $_ -in $script:ValidInstallBehavior })][string]$InstallBehavior = 'System',
        [ValidateScript({ $_ -in $script:ValidArchitectures })][string]$Architecture = 'x64',
        [string]$MinimumOS = 'W10_1809',
        [int[]]$ExpectedExitCodes = @(0, 1641, 3010),
        [ValidateScript({ $_ -in $script:ValidRebootBehavior })][string]$RebootBehavior = 'BasedOnReturnCode',
        [string]$PackageHash = '',
        [AllowNull()]$Integrations = $null
    )

    [PSCustomObject]@{
        SchemaVersion      = $script:ManifestSchemaVersion
        ApplicationName    = $ApplicationName
        ApplicationVersion = $ApplicationVersion
        PackageVersion     = $PackageVersion
        InstallerType      = $InstallerType
        SourceInstaller    = $SourceInstaller
        InstallCommand     = $InstallCommand
        UninstallCommand   = $UninstallCommand
        DetectionMethod    = $DetectionMethod
        DetectionScript    = $DetectionScript
        InstallBehavior    = $InstallBehavior
        Architecture       = $Architecture
        MinimumOS          = $MinimumOS
        ExpectedExitCodes  = $ExpectedExitCodes
        RebootBehavior     = $RebootBehavior
        ContentDirectory   = $ContentDirectory
        BuildTimestamp     = (Get-Date).ToString('o')
        PackageHash        = $PackageHash
        Integrations       = $Integrations
    }
}

function Get-DetectionCommand {
    <#
    .SYNOPSIS
        Builds the detection command line for a manifest.
    .DESCRIPTION
        One definition, used by the validation run, by the string written for
        Intune, and by the exported configuration. A command that is validated
        in one form and deployed in another proves nothing about the form that
        actually runs on a device.
    .OUTPUTS
        The command line, or an empty string when detection is not a script.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][PSCustomObject]$Manifest)

    if ($Manifest.DetectionMethod -ne 'Script') { return '' }

    $hasScript = $Manifest.PSObject.Properties.Name -contains 'DetectionScript' -and $Manifest.DetectionScript
    if (-not $hasScript) { return '' }

    # Quoted only when the path needs it: quotes a path does not need are
    # stripped unevenly by anything that re-parses the command line.
    $target = ".\$($Manifest.DetectionScript)"
    if ($target -match '\s') { $target = "`"$target`"" }

    "powershell.exe -NoProfile -ExecutionPolicy Bypass -File $target"
}

function Save-PackageManifest {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][PSCustomObject]$Manifest,
        [Parameter(Mandatory)][string]$Path
    )

    $directory = Split-Path -Path $Path -Parent
    if ($directory -and -not (Test-Path -LiteralPath $directory)) {
        New-Item -Path $directory -ItemType Directory -Force | Out-Null
    }

    $Manifest | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $Path -Encoding UTF8
    $Path
}

function Import-PackageManifest {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) {
        throw "Manifest not found: $Path"
    }

    Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
}

function Test-PackageManifest {
    <#
    .SYNOPSIS
        Validates manifest completeness and field values.
    .OUTPUTS
        PSCustomObject with IsValid and Errors.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][PSCustomObject]$Manifest)

    $errors = [System.Collections.Generic.List[string]]::new()
    $manifestProperties = $Manifest.PSObject.Properties.Name

    foreach ($field in $script:RequiredManifestFields) {
        if ($field -notin $manifestProperties) {
            $errors.Add("Missing required field: $field")
            continue
        }

        $value = $Manifest.$field
        $isEmpty = $null -eq $value -or
                   ($value -is [string] -and [string]::IsNullOrWhiteSpace($value)) -or
                   ($value -is [array] -and $value.Count -eq 0)

        if ($isEmpty) {
            $errors.Add("Field is empty: $field")
        }
    }

    $enumChecks = @(
        @{ Field = 'InstallerType';   Valid = $script:ValidInstallerTypes }
        @{ Field = 'InstallBehavior'; Valid = $script:ValidInstallBehavior }
        @{ Field = 'Architecture';    Valid = $script:ValidArchitectures }
        @{ Field = 'DetectionMethod'; Valid = $script:ValidDetectionMethods }
        @{ Field = 'RebootBehavior';  Valid = $script:ValidRebootBehavior }
    )

    foreach ($check in $enumChecks) {
        if ($check.Field -in $manifestProperties) {
            $value = $Manifest.($check.Field)
            if ($value -and $value -notin $check.Valid) {
                $errors.Add("Invalid $($check.Field) '$value'. Expected one of: $($check.Valid -join ', ')")
            }
        }
    }

    if ('DetectionMethod' -in $manifestProperties -and $Manifest.DetectionMethod -eq 'Script') {
        if ([string]::IsNullOrWhiteSpace($Manifest.DetectionScript)) {
            $errors.Add('DetectionMethod is Script but DetectionScript is not set')
        }
    }

    # Integrations are validated by the same normaliser that applies them, so a
    # malformed or under-specified integration is caught at manifest time rather
    # than on the target. Only checked when the integration engine is loaded, so
    # the manifest module stays usable on its own.
    if ('Integrations' -in $manifestProperties -and $null -ne $Manifest.Integrations -and
        (Get-Command -Name 'ConvertTo-IntegrationConfig' -ErrorAction SilentlyContinue)) {
        try {
            ConvertTo-IntegrationConfig -Integrations $Manifest.Integrations | Out-Null
        } catch {
            $errors.Add("Invalid Integrations: $($_.Exception.Message)")
        }
    }

    [PSCustomObject]@{
        IsValid = $errors.Count -eq 0
        Errors  = $errors.ToArray()
    }
}

function Get-PackageHash {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "Cannot hash missing file: $Path"
    }

    (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash
}
