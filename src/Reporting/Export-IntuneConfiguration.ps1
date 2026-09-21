<#
.SYNOPSIS
    Exports the exact values to be entered into Intune.
.DESCRIPTION
    The exported commands must be identical to the commands that were
    validated. Any divergence means the package is not production ready.
#>

Set-StrictMode -Version Latest

. (Join-Path (Split-Path $PSScriptRoot -Parent) 'Core\CommandParser.ps1')

function Get-IntuneRestartBehavior {
    param([Parameter(Mandatory)][string]$RebootBehavior)

    switch ($RebootBehavior) {
        'Suppress'          { 'suppress' }
        'Force'             { 'force' }
        'Allow'             { 'allow' }
        'BasedOnReturnCode' { 'basedOnReturnCode' }
        default             { 'basedOnReturnCode' }
    }
}

function Get-IntuneReturnCodes {
    <#
    .SYNOPSIS
        Maps expected exit codes onto Intune return-code types.
    #>
    param([Parameter(Mandatory)][int[]]$ExpectedExitCodes)

    $codes = [System.Collections.Generic.List[PSCustomObject]]::new()

    foreach ($code in ($ExpectedExitCodes | Sort-Object -Unique)) {
        $type = switch ($code) {
            0     { 'success' }
            1641  { 'hardReboot' }
            3010  { 'softReboot' }
            1618  { 'retry' }
            default { 'success' }
        }
        $codes.Add([PSCustomObject]@{ ReturnCode = $code; Type = $type })
    }

    # Intune requires an explicit failure mapping for anything not listed.
    if (0 -notin $ExpectedExitCodes) {
        $codes.Insert(0, [PSCustomObject]@{ ReturnCode = 0; Type = 'success' })
    }

    $codes.ToArray()
}

function Export-IntuneConfiguration {
    <#
    .SYNOPSIS
        Writes IntuneConfiguration.json and IntuneConfiguration.md.
    .PARAMETER ValidatedCommands
        The commands that were actually executed during validation. These are
        compared against the manifest commands destined for Intune.
    .OUTPUTS
        PSCustomObject with JsonPath, MarkdownPath, Comparisons and IsConsistent.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][PSCustomObject]$Manifest,
        [Parameter(Mandatory)][string]$OutputPath,
        [hashtable]$ValidatedCommands = @{},
        [bool]$ValidationPassed = $false
    )

    if (-not (Test-Path -LiteralPath $OutputPath)) {
        New-Item -Path $OutputPath -ItemType Directory -Force | Out-Null
    }

    $detectionCommand = if ($Manifest.DetectionMethod -eq 'Script' -and $Manifest.DetectionScript) {
        "powershell.exe -NoProfile -ExecutionPolicy Bypass -File `".\$($Manifest.DetectionScript)`""
    } else {
        ''
    }

    # --- Sanity check: tested vs production ---------------------------------
    $comparisons = [System.Collections.Generic.List[PSCustomObject]]::new()

    $commandPairs = @(
        @{ Type = 'Install';   Intune = $Manifest.InstallCommand;   Key = 'Install' }
        @{ Type = 'Uninstall'; Intune = $Manifest.UninstallCommand; Key = 'Uninstall' }
        @{ Type = 'Detection'; Intune = $detectionCommand;          Key = 'Detection' }
    )

    foreach ($pair in $commandPairs) {
        if (-not $ValidatedCommands.ContainsKey($pair.Key)) { continue }
        $comparisons.Add((Compare-IntuneCommand -TestedCommand $ValidatedCommands[$pair.Key] `
                                                -IntuneCommand $pair.Intune `
                                                -CommandType $pair.Type))
    }

    $allComparisons = $comparisons.ToArray()
    $isConsistent = @($allComparisons | Where-Object { -not $_.Matches }).Count -eq 0
    $isProductionReady = $ValidationPassed -and $isConsistent

    # --- JSON ----------------------------------------------------------------
    $configuration = [PSCustomObject]@{
        GeneratedAt = (Get-Date).ToString('o')
        Application = [PSCustomObject]@{
            Name            = $Manifest.ApplicationName
            Version         = $Manifest.ApplicationVersion
            PackageVersion  = $Manifest.PackageVersion
            Publisher       = if ($Manifest.PSObject.Properties.Name -contains 'Publisher') { $Manifest.Publisher } else { '' }
        }
        ProgramInformation = [PSCustomObject]@{
            InstallCommand   = $Manifest.InstallCommand
            UninstallCommand = $Manifest.UninstallCommand
            InstallBehavior  = $Manifest.InstallBehavior
            DeviceRestartBehavior = Get-IntuneRestartBehavior -RebootBehavior $Manifest.RebootBehavior
            ReturnCodes      = @(Get-IntuneReturnCodes -ExpectedExitCodes $Manifest.ExpectedExitCodes)
        }
        Requirements = [PSCustomObject]@{
            Architecture      = $Manifest.Architecture
            MinimumOS         = $Manifest.MinimumOS
        }
        DetectionRules = [PSCustomObject]@{
            Method           = $Manifest.DetectionMethod
            ScriptFile       = $Manifest.DetectionScript
            DetectionCommand = $detectionCommand
            RunAs32Bit       = $Manifest.Architecture -eq 'x86'
            EnforceSignatureCheck = $false
        }
        Package = [PSCustomObject]@{
            ContentDirectory = $Manifest.ContentDirectory
            SourceInstaller  = $Manifest.SourceInstaller
            InstallerType    = $Manifest.InstallerType
            PackageHash      = $Manifest.PackageHash
            BuildTimestamp   = $Manifest.BuildTimestamp
        }
        Validation = [PSCustomObject]@{
            ValidationPassed        = $ValidationPassed
            CommandsMatchValidated  = $isConsistent
            Status                  = if ($isProductionReady) { 'PRODUCTION READY' } else { 'FAILED VALIDATION' }
            Comparisons             = $allComparisons
        }
    }

    $jsonPath = Join-Path $OutputPath 'IntuneConfiguration.json'
    $configuration | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $jsonPath -Encoding UTF8

    # --- Markdown ------------------------------------------------------------
    $lines = [System.Collections.Generic.List[string]]::new()

    $lines.Add("# Intune Configuration - $($Manifest.ApplicationName) $($Manifest.ApplicationVersion)")
    $lines.Add('')
    $lines.Add("Generated: $((Get-Date).ToString('o'))")
    $lines.Add('')

    if (-not $isProductionReady) {
        $lines.Add('> **WARNING: NOT PRODUCTION READY**')
        $lines.Add('>')
        if (-not $ValidationPassed) {
            $lines.Add('> The package did not pass full deployment validation.')
        }
        if (-not $isConsistent) {
            $lines.Add('> PRODUCTION CONFIGURATION DOES NOT MATCH VALIDATED CONFIGURATION.')
        }
        $lines.Add('')
    }

    $lines.Add('## App information')
    $lines.Add('')
    $lines.Add('| Field | Value |')
    $lines.Add('| --- | --- |')
    $lines.Add("| Name | $($Manifest.ApplicationName) |")
    $lines.Add("| Version | $($Manifest.ApplicationVersion) |")
    $lines.Add("| Package version | $($Manifest.PackageVersion) |")
    $lines.Add('')

    $lines.Add('## Program')
    $lines.Add('')
    $lines.Add('**Install command:**')
    $lines.Add('')
    $lines.Add('```')
    $lines.Add($Manifest.InstallCommand)
    $lines.Add('```')
    $lines.Add('')
    $lines.Add('**Uninstall command:**')
    $lines.Add('')
    $lines.Add('```')
    $lines.Add($Manifest.UninstallCommand)
    $lines.Add('```')
    $lines.Add('')
    $lines.Add("**Install behavior:** $($Manifest.InstallBehavior)")
    $lines.Add('')
    $lines.Add("**Device restart behavior:** $(Get-IntuneRestartBehavior -RebootBehavior $Manifest.RebootBehavior)")
    $lines.Add('')

    $lines.Add('### Return codes')
    $lines.Add('')
    $lines.Add('| Return code | Code type |')
    $lines.Add('| --- | --- |')
    foreach ($code in (Get-IntuneReturnCodes -ExpectedExitCodes $Manifest.ExpectedExitCodes)) {
        $lines.Add("| $($code.ReturnCode) | $($code.Type) |")
    }
    $lines.Add('')

    $lines.Add('## Requirements')
    $lines.Add('')
    $lines.Add('| Field | Value |')
    $lines.Add('| --- | --- |')
    $lines.Add("| Operating system architecture | $($Manifest.Architecture) |")
    $lines.Add("| Minimum operating system | $($Manifest.MinimumOS) |")
    $lines.Add('')

    $lines.Add('## Detection rules')
    $lines.Add('')
    $lines.Add("**Rules format:** $(if ($Manifest.DetectionMethod -eq 'Script') { 'Use a custom detection script' } else { "Manually configure detection rules ($($Manifest.DetectionMethod))" })")
    $lines.Add('')
    if ($detectionCommand) {
        $lines.Add("**Script file:** ``$($Manifest.DetectionScript)``")
        $lines.Add('')
        $lines.Add("**Run script as 32-bit process on 64-bit clients:** $(if ($Manifest.Architecture -eq 'x86') { 'Yes' } else { 'No' })")
        $lines.Add('')
        $lines.Add("**Enforce script signature check:** No")
        $lines.Add('')
        $lines.Add('Validated locally with:')
        $lines.Add('')
        $lines.Add('```')
        $lines.Add($detectionCommand)
        $lines.Add('```')
        $lines.Add('')
    }

    $lines.Add('## Package')
    $lines.Add('')
    $lines.Add('| Field | Value |')
    $lines.Add('| --- | --- |')
    $lines.Add("| Installer type | $($Manifest.InstallerType) |")
    $lines.Add("| Source installer | $($Manifest.SourceInstaller) |")
    $lines.Add("| Content directory | $($Manifest.ContentDirectory) |")
    $lines.Add("| SHA256 | ``$($Manifest.PackageHash)`` |")
    $lines.Add("| Built | $($Manifest.BuildTimestamp) |")
    $lines.Add('')

    if ($allComparisons.Count -gt 0) {
        $lines.Add('## Command sanity check')
        $lines.Add('')
        $lines.Add('| Command | Result |')
        $lines.Add('| --- | --- |')
        foreach ($comparison in $allComparisons) {
            $lines.Add("| $($comparison.CommandType) | $(if ($comparison.Matches) { 'Matches validated command' } else { '**MISMATCH**' }) |")
        }
        $lines.Add('')

        foreach ($comparison in ($allComparisons | Where-Object { -not $_.Matches })) {
            $lines.Add("### $($comparison.CommandType) mismatch")
            $lines.Add('')
            $lines.Add('Tested:')
            $lines.Add('')
            $lines.Add('```')
            $lines.Add($comparison.TestedCommand)
            $lines.Add('```')
            $lines.Add('')
            $lines.Add('Configured for Intune:')
            $lines.Add('')
            $lines.Add('```')
            $lines.Add($comparison.IntuneCommand)
            $lines.Add('```')
            $lines.Add('')
        }
    }

    $lines.Add('## Status')
    $lines.Add('')
    $lines.Add('```')
    $lines.Add($(if ($isProductionReady) { 'PRODUCTION READY' } else { 'FAILED VALIDATION' }))
    $lines.Add('```')
    $lines.Add('')

    $markdownPath = Join-Path $OutputPath 'IntuneConfiguration.md'
    $lines -join "`n" | Set-Content -LiteralPath $markdownPath -Encoding UTF8

    [PSCustomObject]@{
        JsonPath          = $jsonPath
        MarkdownPath      = $markdownPath
        Comparisons       = $allComparisons
        IsConsistent      = $isConsistent
        IsProductionReady = $isProductionReady
    }
}
