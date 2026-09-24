<#
.SYNOPSIS
    Turns an evaluation into a staging-spoon package.json, and a review report.
.DESCRIPTION
    The evaluator investigates; staging-spoon packages. The only coupling is
    this export, which produces exactly the package.json shape staging-spoon's
    Build-IntunePackage.ps1 reads, including the Integrations block. Observed
    integrations are exported as VALIDATE - the vendor installer creates them,
    and staging-spoon should verify rather than duplicate them - which a
    reviewer can change to MANAGE.
#>

Set-StrictMode -Version Latest

function Get-FieldValue {
    param([PSCustomObject]$Result, [string]$Path, $Default = $null)
    if ($Result.Fields.Contains($Path)) { return $Result.Fields[$Path].Value }
    $Default
}

function Get-FieldsByPrefix {
    param([PSCustomObject]$Result, [string]$Prefix)
    @($Result.Fields.Keys | Where-Object { $_ -like "$Prefix*" } | ForEach-Object { $Result.Fields[$_] })
}

function ConvertTo-StagingSpoonPackage {
    <#
    .SYNOPSIS
        Builds the package.json object staging-spoon consumes.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][PSCustomObject]$Result)

    $installerFileName = Get-FieldValue -Result $Result -Path 'installer.fileName' -Default ''
    $silentArgs        = Get-FieldValue -Result $Result -Path 'installer.silentArguments' -Default ''
    $installerType     = Get-FieldValue -Result $Result -Path 'installer.type' -Default 'EXE'

    # The install command is the wrapper form staging-spoon expects: the
    # installer name as a parameter, the silent switches as trailing tokens.
    $installParts = @('powershell.exe', '-NoProfile', '-ExecutionPolicy', 'Bypass', '-NonInteractive', '-File', './Install.ps1')
    if ($installerFileName) {
        $nameToken = if ($installerFileName -match '\s') { '"' + $installerFileName + '"' } else { $installerFileName }
        $installParts += @('-InstallerName', $nameToken)
        if ($silentArgs) { $installParts += @($silentArgs -split '\s+' | Where-Object { $_ }) }
    }
    $installCommand = $installParts -join ' '
    $uninstallCommand = 'powershell.exe -NoProfile -ExecutionPolicy Bypass -NonInteractive -File ./Uninstall.ps1'

    $integrations = [ordered]@{}

    # PATH: only entries actually observed on the machine become active (as
    # VALIDATE - the installer put them there). A recommended-but-absent entry
    # is not exported active; it appears in the report for the reviewer.
    $pathEntries = @(Get-FieldsByPrefix -Result $Result -Prefix 'integration.path' | Where-Object { $_.Path -eq 'integration.path' })
    if ($pathEntries.Count -gt 0) {
        $integrations['Path'] = @($pathEntries | ForEach-Object {
            [ordered]@{ Mode = 'VALIDATE'; Entry = [string]$_.Value; Scope = 'Machine' }
        })
    }

    $shortcutFields = @(Get-FieldsByPrefix -Result $Result -Prefix 'integration.shortcut.')
    if ($shortcutFields.Count -gt 0) {
        $integrations['Shortcut'] = @($shortcutFields | ForEach-Object {
            $sc = $_.Value
            $loc = if ($sc.PSObject.Properties.Name -contains 'MachineWide' -and $sc.MachineWide) { 'Public' } else { 'User' }
            [ordered]@{
                Mode   = 'VALIDATE'
                Name   = [string]$sc.Name
                Target = [string]$sc.Target
                Arguments = $(if ($sc.PSObject.Properties.Name -contains 'Arguments') { [string]$sc.Arguments } else { '' })
                WorkingDirectory = $(if ($sc.PSObject.Properties.Name -contains 'WorkingDirectory') { [string]$sc.WorkingDirectory } else { '' })
                Icon   = $(if ($sc.PSObject.Properties.Name -contains 'Icon') { [string]$sc.Icon } else { '' })
                Location = $loc
            }
        })
    }

    $menuFields = @(Get-FieldsByPrefix -Result $Result -Prefix 'integration.contextmenu.')
    if ($menuFields.Count -gt 0) {
        $integrations['ContextMenu'] = @($menuFields | ForEach-Object {
            $m = $_.Value
            [ordered]@{
                Mode        = 'VALIDATE'
                Verb        = $(if ($m.PSObject.Properties.Name -contains 'Verb') { [string]$m.Verb } else { 'Open' })
                DisplayName = $(if ($m.PSObject.Properties.Name -contains 'DisplayName') { [string]$m.DisplayName } else { 'Open' })
                Executable  = $(if ($m.PSObject.Properties.Name -contains 'Executable') { [string]$m.Executable } elseif ($m.PSObject.Properties.Name -contains 'Target') { [string]$m.Target } else { '' })
                Target      = $(if ($m.PSObject.Properties.Name -contains 'Scope') { [string]$m.Scope } else { 'File' })
                Extensions  = @(if ($m.PSObject.Properties.Name -contains 'Extensions') { $m.Extensions } else { @() })
            }
        })
    }

    $assocFields = @(Get-FieldsByPrefix -Result $Result -Prefix 'integration.association.')
    if ($assocFields.Count -gt 0) {
        $integrations['FileAssociation'] = @($assocFields | ForEach-Object {
            $a = $_.Value
            [ordered]@{
                Mode       = 'VALIDATE'
                Extension  = [string]$a.Extension
                ProgId     = $(if ($a.PSObject.Properties.Name -contains 'ProgId') { [string]$a.ProgId } else { '' })
                Executable = $(if ($a.PSObject.Properties.Name -contains 'Executable') { [string]$a.Executable } elseif ($a.PSObject.Properties.Name -contains 'Command') { [string]$a.Command } else { '' })
            }
        })
    }

    $package = [ordered]@{
        ApplicationName    = Get-FieldValue -Result $Result -Path 'application.name' -Default $Result.ApplicationName
        ApplicationVersion = Get-FieldValue -Result $Result -Path 'application.version' -Default ''
        PackageVersion     = '1.0.0'
        InstallerType      = $installerType
        SourceInstaller    = $installerFileName
        InstallCommand     = $installCommand
        UninstallCommand   = $uninstallCommand
        DetectionMethod    = 'Script'
        DetectionScript    = 'Detection.ps1'
        InstallBehavior    = Get-FieldValue -Result $Result -Path 'installation.context' -Default 'System'
        Architecture       = Get-FieldValue -Result $Result -Path 'application.architecture' -Default 'x64'
        MinimumOS          = 'W10_1809'
        ExpectedExitCodes  = @(0, 1641, 3010)
        RebootBehavior     = 'BasedOnReturnCode'
    }
    if ($integrations.Count -gt 0) { $package['Integrations'] = $integrations }

    [PSCustomObject]$package
}

function Get-UnconfirmedFields {
    <#
    .SYNOPSIS
        The fields a reviewer should look at before exporting.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][PSCustomObject]$Result)
    @($Result.Fields.Values | Where-Object { (Get-FieldStatus -Field $_) -eq 'RequiresConfirmation' })
}

function Write-EvaluationReport {
    <#
    .SYNOPSIS
        Renders the human-readable evaluation, grouped, with status and evidence.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][PSCustomObject]$Result, [switch]$ShowEvidence)

    $glyph = @{ Detected = "[+]"; Confirmed = "[*]"; Inferred = "[~]"; RequiresConfirmation = "[?]" }

    Write-Host ''
    Write-Host 'INTUNE APPLICATION EVALUATOR' -ForegroundColor Cyan
    Write-Host "Application: $($Result.ApplicationName)"
    $counts = Get-EvaluationSummaryCounts -Result $Result
    Write-Host ("Status: {0} detected, {1} confirmed, {2} inferred, {3} require confirmation" -f `
        $counts.Detected, $counts.Confirmed, $counts.Inferred, $counts.RequiresConfirmation)

    $groups = @($Result.Fields.Values | Group-Object Group | Sort-Object Name)
    foreach ($group in $groups) {
        Write-Host ''
        Write-Host "[$($group.Name)]" -ForegroundColor White
        foreach ($field in $group.Group) {
            $status = Get-FieldStatus -Field $field
            $mark = $glyph[$status]
            $colour = switch ($status) { 'Detected' { 'Green' } 'Confirmed' { 'Green' } 'Inferred' { 'Yellow' } default { 'Red' } }
            $shown = if ($field.Value -is [string] -or $field.Value -is [bool]) { [string]$field.Value } else { '(object)' }
            Write-Host ("  {0} {1,-34} {2}" -f $mark, $field.Path, $shown) -ForegroundColor $colour
            Write-Host ("      source: {0}  confidence: {1}  verified: {2}" -f $field.Source, $field.Confidence, $field.Verified) -ForegroundColor DarkGray
            if ($ShowEvidence) { foreach ($e in @($field.Evidence)) { Write-Host "      evidence: $e" -ForegroundColor DarkGray } }
        }
    }

    foreach ($note in $Result.Notes) { Write-Host ''; Write-Host "  ! $note" -ForegroundColor Yellow }
}
