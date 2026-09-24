<#
.SYNOPSIS
    Turns what the inspector finds into an evidenced, reviewable evaluation.
.DESCRIPTION
    Orchestrates discovery of the installed application into a set of fields,
    each carrying its source, confidence and verification. Reads the live
    machine on Windows; accepts injected fixtures otherwise, so the whole
    orchestration is testable without a Windows host.
#>

Set-StrictMode -Version Latest

function Invoke-ApplicationEvaluation {
    <#
    .SYNOPSIS
        Evaluates an installed application into an evaluation result.
    .PARAMETER Name
        The application to find in Add/Remove Programs (name or wildcard).
    .PARAMETER InstallerPath
        Optional installer, used only for what the installed app cannot show:
        the installer type and a toolkit-suggested silent switch (flagged for
        confirmation, never presented as verified).
    .PARAMETER ArpRecords / MachinePath / UserPath / Executables / Shortcuts
        Injected evidence. When omitted on Windows, each is read live; supplying
        them (as tests do) drives the same orchestration off Windows.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Name,
        [string]$InstallerPath = '',
        [object[]]$ArpRecords,
        [string]$MachinePath,
        [string]$UserPath,
        [string[]]$Executables,
        [object[]]$Shortcuts,
        [object[]]$ContextMenus,
        [object[]]$FileAssociations
    )

    if (-not $PSBoundParameters.ContainsKey('ArpRecords')) { $ArpRecords = @(Read-UninstallRegistry) }
    if (-not $PSBoundParameters.ContainsKey('MachinePath')) { $MachinePath = Read-PathValue -Scope 'Machine' }
    if (-not $PSBoundParameters.ContainsKey('UserPath'))    { $UserPath    = Read-PathValue -Scope 'User' }

    $result = New-EvaluationResult -ApplicationName $Name

    $app = Select-ArpApplication -Records @($ArpRecords) -Name $Name
    if ($null -eq $app) {
        $result.Notes.Add("No installed application matched '$Name' in Add/Remove Programs.")
        return $result
    }

    # Fill any properties the record omits, so a partial ARP entry does not
    # throw under StrictMode when a field is read.
    foreach ($property in @('Publisher', 'DisplayVersion', 'InstallLocation', 'DisplayIcon', 'UninstallString', 'QuietUninstallString', 'Hive', 'KeyName')) {
        if ($app.PSObject.Properties.Name -notcontains $property) {
            Add-Member -InputObject $app -NotePropertyName $property -NotePropertyValue '' -Force
        }
    }

    $result.ApplicationName = $app.DisplayName
    $installLocation = [string]$app.InstallLocation

    # --- Application identity (observed from the ARP registration) ----------
    $null = Add-EvaluatedField -Result $result -Field (New-EvaluatedField -Path 'application.name' -Value $app.DisplayName `
        -Source 'UninstallRegistry' -Confidence 'High' -Verified $true -Group 'Application' -Evidence "ARP DisplayName in $($app.Hive)")
    if ($app.Publisher) {
        $null = Add-EvaluatedField -Result $result -Field (New-EvaluatedField -Path 'application.publisher' -Value $app.Publisher `
            -Source 'UninstallRegistry' -Confidence 'High' -Verified $true -Group 'Application' -Evidence 'ARP Publisher')
    }
    if ($app.DisplayVersion) {
        $null = Add-EvaluatedField -Result $result -Field (New-EvaluatedField -Path 'application.version' -Value $app.DisplayVersion `
            -Source 'UninstallRegistry' -Confidence 'High' -Verified $true -Group 'Application' -Evidence 'ARP DisplayVersion')
    }
    if ($installLocation) {
        $null = Add-EvaluatedField -Result $result -Field (New-EvaluatedField -Path 'installation.installLocation' -Value $installLocation `
            -Source 'UninstallRegistry' -Confidence 'High' -Verified $true -Group 'Application' -Evidence 'ARP InstallLocation')
    }

    # --- Architecture (inferred from the hive / install root) ---------------
    $arch = if ($app.Hive -match 'WOW6432Node') { 'x86' } elseif ($installLocation -match '(?i)Program Files \(x86\)') { 'x86' } else { 'x64' }
    $null = Add-EvaluatedField -Result $result -Field (New-EvaluatedField -Path 'application.architecture' -Value $arch `
        -Source 'UninstallRegistry' -Confidence 'Medium' -Group 'Application' `
        -Evidence $(if ($app.Hive -match 'WOW6432Node') { 'registered under WOW6432Node' } else { 'registered under the native 64-bit view' }))

    # --- Main executable ----------------------------------------------------
    if (-not $PSBoundParameters.ContainsKey('Executables')) {
        $Executables = if ($installLocation) { @(Read-ExecutablesUnder -InstallLocation $installLocation) } else { @() }
    }
    $mainExe = Resolve-MainExecutable -DisplayIcon $app.DisplayIcon -InstallLocation $installLocation -ApplicationName $app.DisplayName -Executables @($Executables)
    if ($null -ne $mainExe) {
        $verified = (Test-WindowsPlatform) -and (Test-Path -LiteralPath $mainExe.Path)
        $null = Add-EvaluatedField -Result $result -Field (New-EvaluatedField -Path 'installation.executable' -Value $mainExe.Path `
            -Source 'InstalledSystem' -Confidence $mainExe.Confidence -Verified $verified -Group 'Application' -Evidence $mainExe.Reason)
    } else {
        $result.Notes.Add('Could not determine the main executable; set installation.executable during review.')
    }

    # --- Uninstall / product code -------------------------------------------
    $productCode = Get-MsiProductCode -KeyName $app.KeyName
    if ($productCode) {
        $null = Add-EvaluatedField -Result $result -Field (New-EvaluatedField -Path 'installer.productCode' -Value $productCode `
            -Source 'UninstallRegistry' -Confidence 'High' -Verified $true -Group 'Installation' -Evidence 'ARP key is the MSI product code')
        $null = Add-EvaluatedField -Result $result -Field (New-EvaluatedField -Path 'installer.type' -Value 'MSI' `
            -Source 'UninstallRegistry' -Confidence 'High' -Verified $true -Group 'Installation' -Evidence 'product code present / WindowsInstaller set')
    }
    $quiet = if ($app.PSObject.Properties.Name -contains 'QuietUninstallString') { [string]$app.QuietUninstallString } else { '' }
    if ($quiet) {
        $null = Add-EvaluatedField -Result $result -Field (New-EvaluatedField -Path 'installation.uninstallString' -Value $quiet `
            -Source 'UninstallRegistry' -Confidence 'High' -Verified $true -Group 'Installation' -Evidence 'ARP QuietUninstallString (silent)')
    } elseif ($app.UninstallString) {
        $null = Add-EvaluatedField -Result $result -Field (New-EvaluatedField -Path 'installation.uninstallString' -Value $app.UninstallString `
            -Source 'UninstallRegistry' -Confidence 'Medium' -RequiresConfirmation $true -Group 'Installation' `
            -Evidence 'ARP UninstallString has no silent form; confirm the silent switch')
    }
    $null = Add-EvaluatedField -Result $result -Field (New-EvaluatedField -Path 'installation.uninstallDisplayName' -Value $app.DisplayName `
        -Source 'UninstallRegistry' -Confidence 'High' -Verified $true -Group 'Installation' -Evidence 'matches ARP DisplayName')

    # --- Installer type / silent args from the installer file (if given) ----
    if ($InstallerPath) { Add-InstallerEvidence -Result $result -InstallerPath $InstallerPath }

    # An ARP application with no MSI product code is, in practice, an EXE
    # installer. Recorded as inferred (not verified), since the installed
    # application alone cannot confirm the installer technology.
    if (-not $result.Fields.Contains('installer.type')) {
        $null = Add-EvaluatedField -Result $result -Field (New-EvaluatedField -Path 'installer.type' -Value 'EXE' `
            -Source 'UninstallRegistry' -Confidence 'Medium' -Group 'Installation' `
            -Evidence 'no MSI product code in the ARP registration; assuming an EXE installer')
    }

    # --- Elevation / SYSTEM compatibility -----------------------------------
    $elevation = Test-RequiresElevation -InstallLocation $installLocation -UninstallString $app.UninstallString
    $null = Add-EvaluatedField -Result $result -Field (New-EvaluatedField -Path 'installation.requiresElevation' -Value $elevation.RequiresElevation `
        -Source 'InstalledSystem' -Confidence 'Medium' -Group 'Installation' -Evidence $elevation.Reason)
    # A machine-wide install is what SYSTEM can reproduce; a per-user one is not.
    $null = Add-EvaluatedField -Result $result -Field (New-EvaluatedField -Path 'installation.context' -Value $(if ($elevation.RequiresElevation) { 'System' } else { 'User' }) `
        -Source 'InstalledSystem' -Confidence 'Medium' -Group 'Installation' `
        -Evidence $(if ($elevation.RequiresElevation) { 'installed machine-wide; SYSTEM-compatible' } else { 'installed per-user; confirm SYSTEM behaviour' }) `
        -RequiresConfirmation (-not $elevation.RequiresElevation))

    # --- PATH ---------------------------------------------------------------
    $mainExePath = if ($null -ne $mainExe) { $mainExe.Path } else { '' }
    $pathHits = @()
    if ($installLocation) {
        $pathHits += @(Select-PathEntriesUnder -PathValue $MachinePath -InstallLocation $installLocation -Scope 'Machine')
        $pathHits += @(Select-PathEntriesUnder -PathValue $UserPath -InstallLocation $installLocation -Scope 'User')
    }
    if ($pathHits.Count -gt 0) {
        foreach ($hit in $pathHits) {
            $null = Add-EvaluatedField -Result $result -Field (New-EvaluatedField -Path 'integration.path' -Value $hit.Entry `
                -Source 'InstalledSystem' -Confidence 'High' -Verified $true -Group 'PATH' `
                -Evidence "present in the $($hit.Scope) PATH and under the install location")
        }
    } elseif ($mainExePath) {
        # No entry today; recommend the executable's directory but do not claim
        # it is required.
        $binDir = Split-Path -Parent $mainExePath
        $null = Add-EvaluatedField -Result $result -Field (New-EvaluatedField -Path 'integration.path.recommended' -Value $binDir `
            -Source 'ToolkitHeuristic' -Confidence 'Low' -RequiresConfirmation $true -Group 'PATH' `
            -Evidence 'the executable directory; not currently on PATH, so confirm whether it is required')
    }

    # --- Shortcuts ----------------------------------------------------------
    if (-not $PSBoundParameters.ContainsKey('Shortcuts') -and (Test-WindowsPlatform)) {
        $snapshot = New-SystemStateSnapshot
        $Shortcuts = @($snapshot.Shortcuts)
    }
    if ($PSBoundParameters.ContainsKey('Shortcuts') -or $null -ne $Shortcuts) {
        $appShortcuts = @(Select-ArtifactsForApp -Items @($Shortcuts) -Executable $mainExePath -InstallLocation $installLocation -ApplicationName $app.DisplayName)
        foreach ($sc in $appShortcuts) {
            $loc = if ($sc.PSObject.Properties.Name -contains 'Location') { $sc.Location } else { 'Unknown' }
            $vendor = ($sc.PSObject.Properties.Name -contains 'MachineWide' -and $sc.MachineWide)
            $null = Add-EvaluatedField -Result $result -Field (New-EvaluatedField -Path "integration.shortcut.$($sc.Name)" -Value $sc `
                -Source 'InstalledSystem' -Confidence 'High' -Verified $true -Group 'Shortcuts' `
                -Evidence "$loc shortcut targeting the application$(if ($vendor) { ', machine-wide (vendor-created)' } else { ', per-user' })")
        }
    }

    # --- Context menus (from injected or captured observations) -------------
    if ($PSBoundParameters.ContainsKey('ContextMenus')) {
        $appMenus = @(Select-ArtifactsForApp -Items @($ContextMenus) -Executable $mainExePath -InstallLocation $installLocation -ApplicationName $app.DisplayName)
        foreach ($menu in $appMenus) {
            $label = if ($menu.PSObject.Properties.Name -contains 'DisplayName' -and $menu.DisplayName) { $menu.DisplayName } else { 'context menu' }
            $null = Add-EvaluatedField -Result $result -Field (New-EvaluatedField -Path "integration.contextmenu.$label" -Value $menu `
                -Source 'InstalledSystem' -Confidence 'High' -Verified $true -Group 'ContextMenu' `
                -Evidence 'registry shell verb whose command targets the application')
        }
    }

    # --- File associations (from injected or captured observations) ---------
    if ($PSBoundParameters.ContainsKey('FileAssociations')) {
        $appAssoc = @(Select-ArtifactsForApp -Items @($FileAssociations) -Executable $mainExePath -InstallLocation $installLocation -ApplicationName $app.DisplayName)
        foreach ($assoc in $appAssoc) {
            $ext = if ($assoc.PSObject.Properties.Name -contains 'Extension') { $assoc.Extension } else { '?' }
            $null = Add-EvaluatedField -Result $result -Field (New-EvaluatedField -Path "integration.association.$ext" -Value $assoc `
                -Source 'InstalledSystem' -Confidence 'High' -Verified $true -Group 'Associations' `
                -Evidence "extension $ext opens with the application")
        }
    }

    $result
}

function Add-InstallerEvidence {
    <#
    .SYNOPSIS
        Adds installer type and a suggested silent switch from the installer file.
    .DESCRIPTION
        The installed application cannot reveal what silent switch was used, so
        this reads the installer extension for the type and, for known toolkits,
        suggests a switch - always marked RequiresConfirmation, never verified,
        because a switch the vendor does not support ships a package that stops
        for a user who is not there.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][PSCustomObject]$Result, [Parameter(Mandatory)][string]$InstallerPath)

    $extension = ([System.IO.Path]::GetExtension($InstallerPath)).TrimStart('.').ToUpperInvariant()
    $type = switch ($extension) { 'MSI' { 'MSI' } 'EXE' { 'EXE' } 'MSIX' { 'MSIX' } 'APPX' { 'APPX' } default { 'EXE' } }

    if (-not $Result.Fields.Contains('installer.type')) {
        $null = Add-EvaluatedField -Result $Result -Field (New-EvaluatedField -Path 'installer.type' -Value $type `
            -Source 'InstallerMetadata' -Confidence 'High' -Verified $true -Group 'Installation' -Evidence "installer extension .$extension")
    }
    $null = Add-EvaluatedField -Result $Result -Field (New-EvaluatedField -Path 'installer.fileName' -Value (Split-Path -Leaf $InstallerPath) `
        -Source 'InstallerMetadata' -Confidence 'High' -Verified $true -Group 'Installation' -Evidence 'installer file name')

    if ($type -eq 'MSI') {
        $null = Add-EvaluatedField -Result $Result -Field (New-EvaluatedField -Path 'installer.silentArguments' -Value '/qn /norestart' `
            -Source 'InstallerMetadata' -Confidence 'High' -Group 'Installation' -Evidence 'MSI standard silent switches')
        return
    }

    # A toolkit marker suggests a switch, but only as a suggestion to confirm.
    $suggestion = $null
    if (Test-Path -LiteralPath $InstallerPath) {
        try {
            $bytes = [System.IO.File]::ReadAllBytes($InstallerPath)
            $ascii = -join ($bytes | Where-Object { $_ -ge 32 -and $_ -lt 127 } | ForEach-Object { [char]$_ })
            if ($ascii -match 'Nullsoft')       { $suggestion = @{ Args = '/S'; Toolkit = 'NSIS' } }
            elseif ($ascii -match 'Inno Setup') { $suggestion = @{ Args = '/VERYSILENT /NORESTART'; Toolkit = 'Inno Setup' } }
            elseif ($ascii -match 'InstallShield') { $suggestion = @{ Args = '/s /v"/qn"'; Toolkit = 'InstallShield' } }
        } catch { }
    }
    if ($suggestion) {
        $null = Add-EvaluatedField -Result $Result -Field (New-EvaluatedField -Path 'installer.silentArguments' -Value $suggestion.Args `
            -Source 'ToolkitHeuristic' -Confidence 'Medium' -RequiresConfirmation $true -Group 'Installation' `
            -Evidence "suggested for $($suggestion.Toolkit); confirm against the vendor's documentation")
    } else {
        $result.Notes.Add('Silent install arguments could not be determined; supply them during review.')
    }
}
