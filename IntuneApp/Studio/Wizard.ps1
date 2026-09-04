#Requires -Version 5.1
<#
    Wizard.ps1

    The interactive configuration generator.

    The wizard's entire job is to produce a configuration file. It analyses the
    installer, asks the technician the questions needed to fill in the model,
    writes the .psd1, and stops. Execution is a separate, explicitly approved
    step handled by Invoke-Configuration.

    Nothing in this file installs software, edits PATH, writes to the registry,
    creates shortcuts or services, or builds a package.
#>

Set-StrictMode -Version Latest

function Invoke-ConfigurationWizard {
    <#
        .SYNOPSIS
        Walks the technician through building a package configuration.

        .PARAMETER InstallerPath
        The .exe or .msi to package. Prompted for when omitted.

        .PARAMETER PackageRoot
        Package directory the configuration belongs to.

        .PARAMETER ExistingConfig
        Path to a configuration to open and edit instead of starting fresh.

        .PARAMETER OutputPath
        Where to write the generated .psd1.

        .OUTPUTS
        The completed configuration model.
    #>
    param(
        [string]$InstallerPath = '',
        [string]$PackageRoot = '',
        [string]$ExistingConfig = '',
        [string]$OutputPath = ''
    )

    if (-not $PackageRoot) { $PackageRoot = (Get-Location).Path }

    Write-WizardTitle 'Intune Application Packaging Studio' 'Interactive Configuration Generator'
    Write-WizardNote 'This wizard only writes a configuration file.'
    Write-WizardNote 'Nothing is installed or changed until you explicitly approve it.'

    # ---------------------------------------------------------------- Model
    $model = $null
    if ($ExistingConfig) {
        Write-WizardSection "Opening $ExistingConfig"
        $model = Import-ConfigModel -Path $ExistingConfig
        Write-WizardNote "Loaded configuration for: $($model.ApplicationName)"
    }

    # ------------------------------------------------------ Step 1: installer
    Write-WizardTitle 'Select the installer' 'Step 1/9'

    if (-not $InstallerPath) {
        $filesDir = Join-Path $PackageRoot 'Files'
        if (Test-Path -LiteralPath $filesDir) {
            $found = @(Get-ChildItem -LiteralPath $filesDir -File -ErrorAction SilentlyContinue |
                Where-Object { $_.Extension -in @('.exe', '.msi') })
            if ($found.Count -gt 0) {
                Write-WizardNote "Installers found in $filesDir :"
                $opts = @()
                foreach ($f in $found) {
                    $opts += @{ Label = "$($f.Name)  ($('{0:N1} MB' -f ($f.Length / 1MB)))"; Value = $f.FullName }
                }
                $opts += @{ Label = 'Enter a different path'; Value = '__other__' }
                $InstallerPath = Read-WizardChoice -Question 'Which installer?' -Options $opts
            }
        }
        if (-not $InstallerPath -or $InstallerPath -eq '__other__') {
            $InstallerPath = Read-WizardText -Question 'Path to the .exe or .msi'
        }
    }

    # ------------------------------------------------------- Step 2: analyse
    Write-WizardTitle 'Analyzing the installer' 'Step 2/9'
    Write-WizardNote 'Reading file metadata only. The installer is not executed.'

    $analysis = Get-InstallerAnalysis -Path $InstallerPath

    Write-WizardSection 'Application'
    Write-Host "  Name         : $($analysis.ApplicationName)"
    Write-Host "  Publisher    : $($analysis.Publisher)"
    Write-Host "  Version      : $($analysis.Version)"
    Write-Host "  Architecture : $($analysis.Architecture)"

    Write-WizardSection 'Installer'
    Write-Host "  File         : $($analysis.FileName)  ($($analysis.FileSizeText))"
    Write-Host "  Type         : $($analysis.InstallerType)"
    Write-Host "  Technology   : $($analysis.Technology)  (confidence: $($analysis.TechnologyConfidence))"
    Write-Host "  Silent args  : $($analysis.SilentArguments)"
    if ($analysis.ProductCode) { Write-Host "  ProductCode  : $($analysis.ProductCode)" }
    Write-Host "  SHA256       : $($analysis.Sha256)"
    Write-Host "  Signature    : $($analysis.Signature.Status)"
    if ($analysis.Signature.Signer) { Write-Host "  Signer       : $($analysis.Signature.Signer)" }

    foreach ($note in @($analysis.Notes)) { Write-WizardWarning $note }

    # Seed the model from the analysis (existing values win when re-editing).
    if (-not $model) {
        $model = New-ConfigModel `
            -ApplicationName $analysis.ApplicationName `
            -Publisher $analysis.Publisher `
            -Version $analysis.Version
    }

    # ------------------------------------------------- Step 3: identity edits
    Write-WizardTitle 'Application details' 'Step 3/9'

    $model.ApplicationName = Read-WizardText -Question 'Application name' -Default ([string]$model.ApplicationName)
    $model.Publisher       = Read-WizardText -Question 'Publisher' -Default ([string]$model.Publisher) -AllowEmpty
    $model.Version         = Read-WizardText -Question 'Version' -Default ([string]$model.Version) -AllowEmpty

    $archDefault = @('x64', 'x86', 'ARM64').IndexOf([string]$analysis.Architecture)
    if ($archDefault -lt 0) { $archDefault = 0 }
    $model.Architecture = Read-WizardChoice -Question 'Architecture' -DefaultIndex $archDefault -Options @(
        @{ Label = 'x64';   Value = 'x64' }
        @{ Label = 'x86';   Value = 'x86' }
        @{ Label = 'ARM64'; Value = 'ARM64' }
    )

    # ------------------------------------------------ Step 4: install options
    Write-WizardTitle 'Installation' 'Step 4/9'

    $model.Installer.Type = $analysis.InstallerType
    $model.Installer.File = $analysis.FileName

    $model.Installer.Context = Read-WizardChoice -Question 'Installation context' -Options @(
        @{ Label = 'System / All Users'; Value = 'System'; Note = 'Standard for Intune Win32 apps.' }
        @{ Label = 'Current User';       Value = 'User';   Note = 'Only for per-user applications.' }
    )
    $model.Intune.InstallBehavior = $model.Installer.Context

    $model.Installer.UserInterface = Read-WizardChoice -Question 'Installation interface' -Options @(
        @{ Label = 'Silent';      Value = 'Silent';      Note = 'Required for unattended deployment.' }
        @{ Label = 'Basic UI';    Value = 'BasicUI';     Note = 'Progress only. Not visible under SYSTEM.' }
        @{ Label = 'Interactive'; Value = 'Interactive'; Note = 'Cannot work in the SYSTEM context.' }
    )

    $suggested = switch ($model.Installer.UserInterface) {
        'Silent'  { $analysis.SilentArguments }
        'BasicUI' { $analysis.BasicUIArguments }
        default   { '' }
    }
    if ($analysis.TechnologyConfidence -ne 'High') {
        Write-WizardWarning "Installer technology confidence is $($analysis.TechnologyConfidence). Verify these switches against vendor documentation."
    }
    $model.Installer.Arguments = Read-WizardText -Question 'Install arguments' -Default $suggested -AllowEmpty

    $model.Installer.Restart = Read-WizardChoice -Question 'Restart behavior' -Options @(
        @{ Label = 'Suppress restart'; Value = 'Suppress' }
        @{ Label = 'Allow restart';    Value = 'Allow' }
        @{ Label = 'Prompt';           Value = 'Prompt' }
    )

    # ------------------------------------------------------ Step 5: uninstall
    Write-WizardTitle 'Uninstall' 'Step 5/9'

    $recUn = $analysis.Recommendations.Uninstall
    Write-WizardNote "Recommendation: $($recUn.Type) (confidence: $($recUn.Confidence))"
    Write-WizardNote $recUn.Reason

    $unDefaultIndex = if ($recUn.Type -eq 'MSI') { 1 } else { 0 }
    $model.Uninstaller.Type = Read-WizardChoice -Question 'Uninstall method' -DefaultIndex $unDefaultIndex -Options @(
        @{ Label = 'EXE uninstaller'; Value = 'EXE' }
        @{ Label = 'MSI ProductCode'; Value = 'MSI' }
    )

    if ($model.Uninstaller.Type -eq 'MSI') {
        $codeDefault = if ($analysis.ProductCode) { $analysis.ProductCode } else { '' }
        $model.Uninstaller.ProductCode = Read-WizardText -Question 'MSI ProductCode' -Default $codeDefault -AllowEmpty
        $model.Uninstaller.File = ''
        $model.Uninstaller.Arguments = ''
    }
    else {
        Write-WizardNote 'An absolute path is normally correct here - the uninstaller lives with the'
        Write-WizardNote 'installed application, not inside the package.'
        $model.Uninstaller.File = Read-WizardText -Question 'Uninstaller path or command' -Default ([string]$model.Uninstaller.File) -AllowEmpty
        $model.Uninstaller.Arguments = Read-WizardText -Question 'Uninstall arguments' -Default $recUn.Arguments -AllowEmpty
        $model.Uninstaller.ProductCode = $null
    }

    # ------------------------------------------------------ Step 6: detection
    Write-WizardTitle 'Detection' 'Step 6/9'

    $recDet = $analysis.Recommendations.Detection
    Write-WizardNote "Recommendation: $($recDet.Type) (confidence: $($recDet.Confidence))"
    Write-WizardNote $recDet.Reason
    Write-WizardNote 'Detection must describe the application itself, not its PATH or shortcuts.'

    $detDefault = switch ($recDet.Type) { 'MSI' { 2 } 'Registry' { 1 } default { 0 } }
    $model.Detection.Type = Read-WizardChoice -Question 'Detection method' -DefaultIndex $detDefault -Options @(
        @{ Label = 'File exists (+ optional version)'; Value = 'File' }
        @{ Label = 'Registry value';                   Value = 'Registry' }
        @{ Label = 'MSI ProductCode';                  Value = 'MSI' }
        @{ Label = 'Custom PowerShell';                Value = 'Custom' }
    )

    switch ($model.Detection.Type) {
        'File' {
            $pathDefault = if ($recDet.Contains('Path') -and $recDet.Path) { $recDet.Path } else { [string]$model.Detection.Path }
            $model.Detection.Path     = Read-WizardText -Question 'Install directory' -Default $pathDefault
            $model.Detection.FileName = Read-WizardText -Question 'Executable to detect' -Default ([string]$model.Detection.FileName)

            if (Read-WizardYesNo -Question 'Require a minimum version?' -Default $false) {
                $model.Detection.MinimumVersion = Read-WizardText -Question 'Minimum version' -Default ([string]$analysis.Version)
            }
            else {
                $model.Detection.MinimumVersion = $null
            }
        }
        'Registry' {
            $model.Detection['RegistryPath']  = Read-WizardText -Question 'Registry path' -Default 'HKLM:\SOFTWARE\'
            $model.Detection['ValueName']     = Read-WizardText -Question 'Value name' -AllowEmpty
            $model.Detection['ExpectedValue'] = Read-WizardText -Question 'Expected value (blank = any)' -AllowEmpty
        }
        'MSI' {
            $codeDefault = if ($analysis.ProductCode) { $analysis.ProductCode } else { '' }
            $model.Detection['ProductCode'] = Read-WizardText -Question 'MSI ProductCode' -Default $codeDefault -AllowEmpty
        }
        'Custom' {
            Write-WizardWarning 'Custom detection is harder to reason about. Prefer File, Registry or MSI where possible.'
        }
    }

    # -------------------------------------------- Step 7: environment / PATH
    Write-WizardTitle 'Environment and PATH' 'Step 7/9'

    if (Read-WizardYesNo -Question 'Enable command-line access (PATH) or environment variables?' -Default $false) {
        $model.Environment.Enabled = $true
        Invoke-EnvironmentQuestions -Model $model -Analysis $analysis
    }
    else {
        $model.Environment.Enabled = $false
        Write-WizardNote 'Skipped. Detection will not depend on PATH either way.'
    }

    # ------------------------------------------ Step 8: Windows integration
    Write-WizardTitle 'Windows integration' 'Step 8/9'
    Write-WizardNote 'These choices are recorded in the configuration for review.'
    Write-WizardNote 'The installer itself normally creates shortcuts, associations and services.'

    if (Read-WizardYesNo -Question 'Record Windows integration settings?' -Default $false) {
        $model.WindowsIntegration.Enabled = $true
        Invoke-IntegrationQuestions -Model $model
    }
    else {
        $model.WindowsIntegration.Enabled = $false
    }

    # ---------------------------------------------------- Step 9: generation
    Write-WizardTitle 'Generate the configuration' 'Step 9/9'

    if (-not $OutputPath) {
        $OutputPath = Join-Path $PackageRoot 'Configuration.psd1'
        $OutputPath = Read-WizardText -Question 'Write configuration to' -Default $OutputPath
    }

    if (Test-Path -LiteralPath $OutputPath) {
        Write-WizardWarning "$OutputPath already exists."
        if (-not (Read-WizardYesNo -Question 'Overwrite it?' -Default $false)) {
            $OutputPath = Read-WizardText -Question 'Write configuration to'
        }
    }

    $comments = Get-ConfigurationComments
    Export-ConfigurationFile -Model $model -Path $OutputPath -Comments $comments | Out-Null

    Write-Host ''
    Write-Host "Configuration written to: $OutputPath" -ForegroundColor Green

    return [pscustomobject]@{
        Model      = $model
        Path       = $OutputPath
        Analysis   = $analysis
    }
}

function Invoke-EnvironmentQuestions {
    <#
        PATH and environment-variable questions. Writes into the model only.
    #>
    param(
        [Parameter(Mandatory)]$Model,
        [Parameter(Mandatory)]$Analysis
    )

    # --- Offer discovered CLI directories when the app is already installed ---
    $candidates = @()
    $installDir = [string](Get-ModelValue $Model 'Detection.Path')

    if ($installDir -and (Test-Path -LiteralPath $installDir)) {
        Write-WizardSection 'Detect paths'
        Write-WizardNote "Scanning $installDir for command-line tools..."
        $discovered = Get-InstalledIntegrationCandidates -InstallPath $installDir
        $candidates = @($discovered.PathCandidates)
    }
    else {
        Write-WizardSection 'Detect paths'
        Write-WizardNote "The install directory does not exist on this machine yet, so"
        Write-WizardNote "automatic discovery is unavailable. Enter PATH directories manually,"
        Write-WizardNote "or re-run the wizard after a test install to have them detected."
    }

    $selectedPaths = @()

    if ($candidates.Count -gt 0) {
        $options = @()
        foreach ($c in $candidates) {
            $exeNames = @($c.Executables | Where-Object { $_.IsCli } | ForEach-Object { $_.Name })
            if ($exeNames.Count -eq 0) {
                $exeNames = @($c.Executables | Select-Object -First 3 | ForEach-Object { $_.Name })
            }
            $note = "CLI confidence: $($c.Confidence)"
            if ($exeNames.Count -gt 0) { $note += "`nDetected: $($exeNames -join ', ')" }

            $options += @{
                Label   = $c.Directory
                Value   = $c.Directory
                Checked = ($c.Confidence -eq 'High')
                Note    = $note
            }
        }

        Write-WizardNote 'Nothing is added until you select it.'
        $selectedPaths = @(Read-WizardMultiSelect -Question 'Potential command-line directories detected:' -Options $options)
    }

    if ($selectedPaths.Count -eq 0) {
        $selectedPaths = @(Read-WizardList -Question 'PATH directories to add (blank line to finish):')
    }

    if ($selectedPaths.Count -gt 0) {
        Write-Host ''
        Write-Host '  SYSTEM PATH   applies to all users; needs SYSTEM/administrator rights.' -ForegroundColor DarkGray
        Write-Host '  USER PATH     applies to one profile; under SYSTEM it writes only the' -ForegroundColor DarkGray
        Write-Host '                Default profile, not every existing user.' -ForegroundColor DarkGray

        $scope = Read-WizardChoice -Question 'PATH scope' -Options @(
            @{ Label = 'System / All Users'; Value = 'System' }
            @{ Label = 'Current User';       Value = 'User' }
            @{ Label = 'Both';               Value = 'Both' }
        )

        $removeOnUninstall = Read-WizardYesNo -Question 'Remove these PATH entries during uninstall?' -Default $true

        if ($scope -in @('System', 'Both')) {
            $Model.Environment.SystemPath.Enabled           = $true
            $Model.Environment.SystemPath.Entries           = $selectedPaths
            $Model.Environment.SystemPath.RemoveOnUninstall = $removeOnUninstall
        }
        if ($scope -in @('User', 'Both')) {
            $Model.Environment.UserPath.Enabled           = $true
            $Model.Environment.UserPath.Entries           = $selectedPaths
            $Model.Environment.UserPath.RemoveOnUninstall = $removeOnUninstall

            if ([string](Get-ModelValue $Model 'Intune.InstallBehavior') -eq 'System') {
                Write-WizardWarning 'User PATH with a SYSTEM-context install does not configure every existing user.'
                Write-WizardWarning 'This is recorded as a warning on the validation screen.'
            }
        }
    }

    # --- Named environment variables ---
    if (Read-WizardYesNo -Question 'Configure named environment variables (e.g. JAVA_HOME)?' -Default $false) {
        $vars = @()
        while ($true) {
            $name = Read-WizardText -Question 'Variable name (blank to finish)' -AllowEmpty
            if (-not $name) { break }

            $value = Read-WizardText -Question "Value for $name"
            $vScope = Read-WizardChoice -Question "Scope for $name" -Options @(
                @{ Label = 'System (Machine)'; Value = 'Machine' }
                @{ Label = 'User';             Value = 'User' }
            )
            $expandable = Read-WizardYesNo -Question 'Value contains %VARIABLES% that should stay expandable?' -Default $false
            $removeVar  = Read-WizardYesNo -Question 'Remove during uninstall?' -Default $true

            $vars += New-EnvironmentVariableEntry -Name $name -Value $value -Scope $vScope `
                -Expandable $expandable -RemoveOnUninstall $removeVar
        }
        $Model.Environment.Variables = $vars
    }
}

function Invoke-IntegrationQuestions {
    <#
        Shortcut / association / service / task questions. Recorded only.
    #>
    param([Parameter(Mandatory)]$Model)

    $appName = [string]$Model.ApplicationName
    $target = ''
    $detPath = [string](Get-ModelValue $Model 'Detection.Path')
    $detFile = [string](Get-ModelValue $Model 'Detection.FileName')
    if ($detPath -and $detFile) { $target = Join-Path $detPath $detFile }

    # Start Menu
    if (Read-WizardYesNo -Question 'Create a Start Menu shortcut?' -Default $false) {
        $Model.WindowsIntegration.StartMenuShortcut.Enabled = $true
        $Model.WindowsIntegration.StartMenuShortcut.Name    = Read-WizardText -Question 'Shortcut name' -Default $appName
        $Model.WindowsIntegration.StartMenuShortcut.Target  = Read-WizardText -Question 'Target executable' -Default $target
    }

    # Desktop
    if (Read-WizardYesNo -Question 'Create a Desktop shortcut?' -Default $false) {
        $Model.WindowsIntegration.DesktopShortcut.Enabled = $true
        $Model.WindowsIntegration.DesktopShortcut.Name    = Read-WizardText -Question 'Shortcut name' -Default $appName
        $Model.WindowsIntegration.DesktopShortcut.Target  = Read-WizardText -Question 'Target executable' -Default $target
    }

    # File associations
    if (Read-WizardYesNo -Question 'Record file associations?' -Default $false) {
        Write-WizardNote 'Registering an association does not force the Windows default app.'
        Write-WizardNote 'The user still confirms any default application change.'

        $assocs = @()
        while ($true) {
            $ext = Read-WizardText -Question 'Extension (e.g. .rvt, blank to finish)' -AllowEmpty
            if (-not $ext) { break }
            $desc = Read-WizardText -Question "Description for $ext" -AllowEmpty
            $assocs += New-FileAssociationEntry -Extension $ext -Description $desc -OpenCommand $target
        }
        if ($assocs.Count -gt 0) {
            $Model.WindowsIntegration.FileAssociations.Enabled      = $true
            $Model.WindowsIntegration.FileAssociations.Associations = $assocs
        }
    }

    # Services
    if (Read-WizardYesNo -Question 'Record Windows services installed by this application?' -Default $false) {
        $services = @()
        while ($true) {
            $svc = Read-WizardText -Question 'Service name (blank to finish)' -AllowEmpty
            if (-not $svc) { break }
            $startup = Read-WizardChoice -Question "Startup type for $svc" -Options @(
                @{ Label = 'Leave as the installer set it'; Value = 'Unchanged' }
                @{ Label = 'Automatic';                     Value = 'Automatic' }
                @{ Label = 'Manual';                        Value = 'Manual' }
                @{ Label = 'Disabled';                      Value = 'Disabled' }
            )
            $keep = Read-WizardYesNo -Question "Keep $svc after uninstall?" -Default $false
            $services += New-ServiceEntry -Name $svc -StartupType $startup -Keep $keep
        }
        if ($services.Count -gt 0) {
            $Model.WindowsIntegration.Services.Enabled  = $true
            $Model.WindowsIntegration.Services.Services = $services
        }
    }

    # Scheduled tasks
    if (Read-WizardYesNo -Question 'Record scheduled tasks created by this application?' -Default $false) {
        $tasks = @()
        while ($true) {
            $t = Read-WizardText -Question 'Task name (blank to finish)' -AllowEmpty
            if (-not $t) { break }
            $keep = Read-WizardYesNo -Question "Keep $t after uninstall?" -Default $false
            $tasks += New-ScheduledTaskEntry -Name $t -Keep $keep
        }
        if ($tasks.Count -gt 0) {
            $Model.WindowsIntegration.ScheduledTasks.Enabled = $true
            $Model.WindowsIntegration.ScheduledTasks.Tasks   = $tasks
        }
    }
}

function Get-ConfigurationComments {
    <#
        Comments written into the generated .psd1 so the file explains itself
        when someone opens it later without the Studio.
    #>
    return @{
        'Installer'                  = 'How the application is installed.'
        'Installer.Arguments'        = 'Silent switches. Verify these against vendor documentation.'
        'Uninstaller'                = 'How the application is removed.'
        'Detection'                  = 'What Intune checks to decide the app is installed. Describe the application itself - never PATH or shortcuts.'
        'SuccessExitCodes'           = 'Exit codes treated as success. 3010 means success with a pending reboot.'
        'Environment'                = 'PATH and environment variables. Disabled by default.'
        'WindowsIntegration'         = "Recorded for review. The installer normally creates these itself;`nthe packaging engine does not apply this section."
        'Intune'                     = 'Values to enter in the Intune portal.'
    }
}
