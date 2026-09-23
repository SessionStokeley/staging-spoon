<#
.SYNOPSIS
    The catalog of information the platform knows how to need.
.DESCRIPTION
    Every field the platform can ask for is declared once, here, with what it
    means, which operations require it, how it can be discovered, and how it may
    be supplied when discovery fails. Forms are generated from this catalog, so
    there is no static form to drift out of step with the build.
#>

Set-StrictMode -Version Latest

# Priority drives the order of prompting. Lower runs first, and the platform
# never interrupts for a high number while a low one is unresolved.
$script:PromptPriority = [ordered]@{
    BlocksProgress     = 1
    InstallSuccess     = 2
    Detection          = 3
    Uninstall          = 4
    DeploymentContext  = 5
    ApplicationBehavior= 6
    Customization      = 7
    Cosmetic           = 8
}

$script:Operations = @(
    'DiscoverApplication'
    'AnalyzeInstaller'
    'CaptureInstallation'
    'CreateBlueprint'
    'GenerateScripts'
    'GenerateDetection'
    'BuildPackage'
    'Validate'
    'Rebuild'
    'VersionUpdate'
    'Troubleshoot'
)

# How a value may be supplied when the platform has to ask. These are the
# actions a UI renders as buttons; none of them is "type the path by hand"
# unless FreeText is present.
$script:InputMethods = @(
    'UseDetected'
    'UseCaptured'
    'UseInstalled'
    'UsePreviousBuild'
    'UseInstallerMetadata'
    'BrowseFile'
    'BrowseFolder'
    'DetectInstalledExecutables'
    'Choice'
    'FreeText'
    'Redetect'
)

function New-FieldDefinition {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Label,
        [Parameter(Mandatory)][ValidateSet('String', 'Path', 'Directory', 'Choice', 'Boolean', 'List', 'Integer', 'Command', 'Object')][string]$Type,
        [Parameter(Mandatory)][string]$Why,
        [string[]]$RequiredFor = @(),
        [string[]]$RecommendedFor = @(),
        [string[]]$Choices = @(),
        [string[]]$DerivesFrom = @(),
        [string[]]$Discoverers = @(),
        [string[]]$InputMethods = @('FreeText'),
        [ValidateSet('BlocksProgress', 'InstallSuccess', 'Detection', 'Uninstall', 'DeploymentContext', 'ApplicationBehavior', 'Customization', 'Cosmetic')][string]$Priority = 'DeploymentContext',
        [string]$Group = 'General',
        [switch]$IsDecision
    )

    [PSCustomObject]@{
        Path           = $Path
        Label          = $Label
        Type           = $Type
        Why            = $Why
        RequiredFor    = $RequiredFor
        RecommendedFor = $RecommendedFor
        Choices        = $Choices
        DerivesFrom    = $DerivesFrom
        Discoverers    = $Discoverers
        InputMethods   = $InputMethods
        Priority       = $Priority
        PriorityRank   = $script:PromptPriority[$Priority]
        Group          = $Group
        IsDecision     = [bool]$IsDecision
    }
}

$script:FieldCatalog = $null

function Get-FieldCatalog {
    <#
    .SYNOPSIS
        The full field catalog, built once per session.
    #>
    [CmdletBinding()]
    param()

    if ($null -ne $script:FieldCatalog) { return $script:FieldCatalog }

    $definitions = @(
        # --- Installer ------------------------------------------------------
        New-FieldDefinition -Path 'installer.path' -Label 'Installer' -Type 'Path' `
            -Why 'The installer is the payload of the package and the source of most other information.' `
            -RequiredFor @('AnalyzeInstaller', 'CaptureInstallation', 'CreateBlueprint', 'BuildPackage') `
            -Discoverers @('ProjectScan') `
            -InputMethods @('BrowseFile', 'UseDetected', 'Redetect') `
            -Priority 'BlocksProgress' -Group 'Installer'

        New-FieldDefinition -Path 'installer.fileName' -Label 'Installer File Name' -Type 'String' `
            -Why 'Identifies the installer inside the package content.' `
            -RequiredFor @('BuildPackage') -DerivesFrom @('installer.path') `
            -Discoverers @('Derivation') -InputMethods @('UseDetected') `
            -Priority 'BlocksProgress' -Group 'Installer'

        New-FieldDefinition -Path 'installer.type' -Label 'Installer Type' -Type 'Choice' `
            -Why 'Determines how the installer is invoked and how it can be uninstalled.' `
            -RequiredFor @('AnalyzeInstaller', 'CreateBlueprint', 'BuildPackage') `
            -Choices @('MSI', 'EXE', 'MSIX', 'APPX', 'Script', 'Wrapper') `
            -DerivesFrom @('installer.path') -Discoverers @('Derivation', 'InstallerMetadata') `
            -InputMethods @('UseDetected', 'Choice') -Priority 'BlocksProgress' -Group 'Installer'

        New-FieldDefinition -Path 'installer.size' -Label 'Installer Size' -Type 'Integer' `
            -Why 'Recorded so the installer can be recognised again if it moves.' `
            -DerivesFrom @('installer.path') -Discoverers @('Derivation') `
            -InputMethods @('UseDetected') -Priority 'Cosmetic' -Group 'Installer'

        New-FieldDefinition -Path 'installer.hash' -Label 'Installer SHA-256' -Type 'String' `
            -Why 'Proves the packaged installer is the one that was validated.' `
            -RecommendedFor @('BuildPackage') -DerivesFrom @('installer.path') `
            -Discoverers @('Derivation') -InputMethods @('UseDetected') `
            -Priority 'Cosmetic' -Group 'Installer'

        New-FieldDefinition -Path 'installer.silentArguments' -Label 'Silent Install Arguments' -Type 'String' `
            -Why 'Intune installs without a desktop, so the installer must run fully unattended.' `
            -RequiredFor @('GenerateScripts', 'BuildPackage') `
            -DerivesFrom @('installer.type') `
            -Discoverers @('InstallerMetadata', 'KnownInstallerFamily', 'PreviousBuild') `
            -InputMethods @('UseDetected', 'UsePreviousBuild', 'FreeText') `
            -Priority 'InstallSuccess' -Group 'Installer'

        New-FieldDefinition -Path 'installer.productCode' -Label 'Product Code' -Type 'String' `
            -Why 'An MSI product code gives an exact uninstall command and detection rule.' `
            -RecommendedFor @('GenerateScripts', 'GenerateDetection') `
            -Discoverers @('InstallerMetadata', 'InstalledSystem') `
            -InputMethods @('UseDetected', 'UseInstalled', 'FreeText') `
            -Priority 'Uninstall' -Group 'Installer'

        New-FieldDefinition -Path 'installer.upgradeCode' -Label 'Upgrade Code' -Type 'String' `
            -Why 'Identifies the product family across versions.' `
            -Discoverers @('InstallerMetadata') -InputMethods @('UseDetected', 'FreeText') `
            -Priority 'Cosmetic' -Group 'Installer'

        # --- Application ----------------------------------------------------
        New-FieldDefinition -Path 'application.name' -Label 'Application Name' -Type 'String' `
            -Why 'The display name of the application in Intune.' `
            -RequiredFor @('CreateBlueprint', 'BuildPackage', 'GenerateDetection') `
            -DerivesFrom @('installer.path') `
            -Discoverers @('InstallerMetadata', 'FileNameDerivation', 'InstalledSystem', 'PreviousBuild') `
            -InputMethods @('UseDetected', 'UseInstallerMetadata', 'UsePreviousBuild', 'FreeText') `
            -Priority 'BlocksProgress' -Group 'Application'

        New-FieldDefinition -Path 'application.publisher' -Label 'Publisher' -Type 'String' `
            -Why 'Shown in Intune and used to disambiguate similarly named applications.' `
            -RecommendedFor @('BuildPackage') `
            -Discoverers @('InstallerMetadata', 'InstalledSystem') `
            -InputMethods @('UseDetected', 'UseInstallerMetadata', 'FreeText') `
            -Priority 'DeploymentContext' -Group 'Application'

        New-FieldDefinition -Path 'application.version' -Label 'Version' -Type 'String' `
            -Why 'Detection compares against this version, and Intune uses it for supersedence.' `
            -RequiredFor @('CreateBlueprint', 'BuildPackage', 'GenerateDetection') `
            -DerivesFrom @('installer.path') `
            -Discoverers @('InstallerMetadata', 'FileNameDerivation', 'InstalledSystem') `
            -InputMethods @('UseDetected', 'UseInstallerMetadata', 'UseInstalled', 'FreeText') `
            -Priority 'Detection' -Group 'Application'

        New-FieldDefinition -Path 'application.architecture' -Label 'Architecture' -Type 'Choice' `
            -Why 'Determines the Intune requirement rule and whether detection runs as 32-bit.' `
            -RequiredFor @('BuildPackage') -Choices @('x64', 'x86', 'ARM64', 'Neutral') `
            -DerivesFrom @('installer.path') `
            -Discoverers @('InstallerMetadata', 'FileNameDerivation', 'InstalledSystem') `
            -InputMethods @('UseDetected', 'Choice') `
            -Priority 'InstallSuccess' -Group 'Application'

        # --- Installation ---------------------------------------------------
        New-FieldDefinition -Path 'installation.installLocation' -Label 'Install Location' -Type 'Directory' `
            -Why 'Detection and uninstall both need to know where the application lands.' `
            -RequiredFor @('GenerateDetection') -RecommendedFor @('CreateBlueprint') `
            -Discoverers @('InstallationCapture', 'InstalledSystem', 'Registry') `
            -InputMethods @('UseCaptured', 'UseInstalled', 'BrowseFolder', 'Redetect') `
            -Priority 'Detection' -Group 'Installation'

        New-FieldDefinition -Path 'installation.executable' -Label 'Primary Executable' -Type 'Path' `
            -Why 'The file whose presence and version prove the application is installed.' `
            -RequiredFor @('GenerateDetection') `
            -DerivesFrom @('installation.installLocation') `
            -Discoverers @('InstallationCapture', 'InstalledSystem') `
            -InputMethods @('UseCaptured', 'DetectInstalledExecutables', 'BrowseFile', 'Redetect') `
            -Priority 'Detection' -Group 'Installation'

        New-FieldDefinition -Path 'installation.context' -Label 'Install Context' -Type 'Choice' `
            -Why 'Intune runs a package as SYSTEM or as the signed-in user. The wrong choice installs to the wrong place or fails outright.' `
            -RequiredFor @('CreateBlueprint', 'BuildPackage') -Choices @('System', 'User') `
            -Discoverers @('InstallerMetadata', 'InstallationCapture', 'PreviousBuild') `
            -InputMethods @('UseDetected', 'UsePreviousBuild', 'Choice') `
            -Priority 'InstallSuccess' -Group 'Installation' -IsDecision

        New-FieldDefinition -Path 'installation.uninstallString' -Label 'Uninstall Command' -Type 'String' `
            -Why 'The vendor uninstall command registered by the installer.' `
            -RecommendedFor @('GenerateScripts') `
            -Discoverers @('InstalledSystem', 'Registry', 'InstallationCapture') `
            -InputMethods @('UseInstalled', 'UseCaptured', 'FreeText') `
            -Priority 'Uninstall' -Group 'Installation'

        New-FieldDefinition -Path 'installation.uninstallDisplayName' -Label 'Add/Remove Programs Name' -Type 'String' `
            -Why 'Matches the entry the installer registers, which uninstall and detection both look up.' `
            -RecommendedFor @('GenerateScripts', 'GenerateDetection') `
            -Discoverers @('InstalledSystem', 'Registry', 'InstallationCapture') `
            -InputMethods @('UseInstalled', 'UseCaptured', 'FreeText') `
            -Priority 'Uninstall' -Group 'Installation'

        # --- Observed installation changes (facts, then policy decisions) ----
        New-FieldDefinition -Path 'installation.machinePath' -Label 'Machine PATH Addition' -Type 'String' `
            -Why 'The installer modified the machine PATH. The package can reproduce that or leave it alone.' `
            -Discoverers @('InstallationCapture') -InputMethods @('UseCaptured') `
            -Priority 'ApplicationBehavior' -Group 'Environment'

        New-FieldDefinition -Path 'decision.applyMachinePath' -Label 'Apply Machine PATH Change?' -Type 'Boolean' `
            -Why 'Capture saw the installer change the machine PATH. Deployment policy decides whether to keep it.' `
            -InputMethods @('Choice') -Priority 'ApplicationBehavior' -Group 'Environment' -IsDecision

        New-FieldDefinition -Path 'installation.environmentVariables' -Label 'Environment Variables' -Type 'List' `
            -Why 'Variables the installer created, which some applications need to run.' `
            -Discoverers @('InstallationCapture') -InputMethods @('UseCaptured') `
            -Priority 'ApplicationBehavior' -Group 'Environment'

        New-FieldDefinition -Path 'decision.applyEnvironmentVariables' -Label 'Apply Environment Variables?' -Type 'Boolean' `
            -Why 'Capture saw new environment variables. Deployment policy decides whether to set them.' `
            -InputMethods @('Choice') -Priority 'ApplicationBehavior' -Group 'Environment' -IsDecision

        New-FieldDefinition -Path 'installation.shortcuts' -Label 'Shortcuts Created' -Type 'List' `
            -Why 'Shortcuts the installer created on the desktop or Start menu.' `
            -Discoverers @('InstallationCapture') -InputMethods @('UseCaptured') `
            -Priority 'Customization' -Group 'Shortcuts'

        New-FieldDefinition -Path 'decision.createDesktopShortcut' -Label 'Create Desktop Shortcut?' -Type 'Boolean' `
            -Why 'Capture saw a desktop shortcut. Deployment policy decides whether users get one.' `
            -InputMethods @('Choice') -Priority 'Customization' -Group 'Shortcuts' -IsDecision

        New-FieldDefinition -Path 'installation.fileAssociations' -Label 'File Associations' -Type 'List' `
            -Why 'Extensions the installer registered to open with this application.' `
            -Discoverers @('InstallationCapture', 'Registry') -InputMethods @('UseCaptured') `
            -Priority 'Customization' -Group 'Associations'

        New-FieldDefinition -Path 'decision.registerFileAssociations' -Label 'Register File Associations?' -Type 'Boolean' `
            -Why 'Capture saw file associations. Deployment policy decides whether to register them.' `
            -InputMethods @('Choice') -Priority 'Customization' -Group 'Associations' -IsDecision

        New-FieldDefinition -Path 'installation.services' -Label 'Services Installed' -Type 'List' `
            -Why 'Services the installer registered, which affect uninstall and detection.' `
            -Discoverers @('InstallationCapture') -InputMethods @('UseCaptured') `
            -Priority 'ApplicationBehavior' -Group 'Services'

        New-FieldDefinition -Path 'installation.scheduledTasks' -Label 'Scheduled Tasks' -Type 'List' `
            -Why 'Tasks the installer registered, typically updaters.' `
            -Discoverers @('InstallationCapture') -InputMethods @('UseCaptured') `
            -Priority 'ApplicationBehavior' -Group 'Services'

        New-FieldDefinition -Path 'installation.registryKeys' -Label 'Registry Keys Created' -Type 'List' `
            -Why 'Keys the installer created, usable as detection evidence.' `
            -Discoverers @('InstallationCapture') -InputMethods @('UseCaptured') `
            -Priority 'Detection' -Group 'Registry'

        # --- Deployment -----------------------------------------------------
        New-FieldDefinition -Path 'deployment.installCommand' -Label 'Install Command' -Type 'Command' `
            -Why 'The exact command Intune runs to install the application.' `
            -RequiredFor @('BuildPackage', 'Validate') `
            -DerivesFrom @('installer.path', 'installer.silentArguments') `
            -Discoverers @('CommandGeneration', 'PreviousBuild') `
            -InputMethods @('UseDetected', 'UsePreviousBuild', 'FreeText') `
            -Priority 'InstallSuccess' -Group 'Deployment'

        New-FieldDefinition -Path 'deployment.uninstallCommand' -Label 'Uninstall Command' -Type 'Command' `
            -Why 'The exact command Intune runs to remove the application.' `
            -RequiredFor @('BuildPackage', 'Validate') `
            -DerivesFrom @('installation.uninstallString', 'installer.productCode') `
            -Discoverers @('CommandGeneration', 'InstalledSystem', 'PreviousBuild') `
            -InputMethods @('UseDetected', 'UseInstalled', 'UsePreviousBuild', 'FreeText') `
            -Priority 'Uninstall' -Group 'Deployment'

        New-FieldDefinition -Path 'deployment.detectionMethod' -Label 'Detection Method' -Type 'Choice' `
            -Why 'How Intune decides the application is already installed.' `
            -RequiredFor @('GenerateDetection', 'BuildPackage') `
            -Choices @('Script', 'MSI', 'File', 'Registry') `
            -Discoverers @('CommandGeneration', 'PreviousBuild') `
            -InputMethods @('UseDetected', 'Choice') `
            -Priority 'Detection' -Group 'Deployment'

        # --- Detection proposal ---------------------------------------------
        # What the generated Detection.ps1 should check. Populated from the
        # strongest evidence the evaluation found, never from a default.
        New-FieldDefinition -Path 'detection.type' -Label 'Detection Type' -Type 'Choice' `
            -Why 'How Intune decides the application is present. The strongest available evidence is proposed.' `
            -RecommendedFor @('GenerateDetection') `
            -Choices @('MsiProductCode', 'File', 'Registry', 'Folder') `
            -Discoverers @('InstallerMetadata', 'InstalledSystem', 'InstallationCapture') `
            -InputMethods @('UseDetected', 'Choice') `
            -Priority 'Detection' -Group 'Detection'

        New-FieldDefinition -Path 'detection.path' -Label 'Detection Path' -Type 'String' `
            -Why 'The folder, file location or registry key the detection rule checks.' `
            -DerivesFrom @('detection.type') `
            -Discoverers @('InstalledSystem', 'InstallationCapture') `
            -InputMethods @('UseDetected', 'BrowseFolder', 'FreeText') `
            -Priority 'Detection' -Group 'Detection'

        New-FieldDefinition -Path 'detection.value' -Label 'Detection Value' -Type 'String' `
            -Why 'The file name, product code or registry value that identifies the application.' `
            -DerivesFrom @('detection.type') `
            -Discoverers @('InstallerMetadata', 'InstalledSystem', 'InstallationCapture') `
            -InputMethods @('UseDetected', 'FreeText') `
            -Priority 'Detection' -Group 'Detection'

        New-FieldDefinition -Path 'detection.version' -Label 'Detection Version' -Type 'String' `
            -Why 'Detecting a version as well as presence stops an upgrade reporting as already installed.' `
            -DerivesFrom @('application.version') `
            -Discoverers @('InstallerMetadata', 'InstalledSystem') `
            -InputMethods @('UseDetected', 'FreeText') `
            -Priority 'Detection' -Group 'Detection'

        New-FieldDefinition -Path 'deployment.rebootBehavior' -Label 'Restart Behavior' -Type 'Choice' `
            -Why 'Controls what Intune does when the installer returns a reboot code.' `
            -RequiredFor @('BuildPackage') `
            -Choices @('Suppress', 'Force', 'BasedOnReturnCode', 'Allow') `
            -Discoverers @('PreviousBuild') -InputMethods @('Choice', 'UsePreviousBuild') `
            -Priority 'DeploymentContext' -Group 'Deployment' -IsDecision

        New-FieldDefinition -Path 'deployment.expectedExitCodes' -Label 'Expected Exit Codes' -Type 'List' `
            -Why 'Exit codes the installer returns that mean success rather than failure.' `
            -RequiredFor @('BuildPackage') `
            -Discoverers @('KnownInstallerFamily', 'PreviousBuild') `
            -InputMethods @('UseDetected', 'UsePreviousBuild', 'FreeText') `
            -Priority 'InstallSuccess' -Group 'Deployment'

        New-FieldDefinition -Path 'deployment.packageVersion' -Label 'Package Version' -Type 'String' `
            -Why 'Distinguishes rebuilds of the same application version.' `
            -RequiredFor @('BuildPackage') `
            -Discoverers @('PreviousBuild', 'Derivation') `
            -InputMethods @('UseDetected', 'UsePreviousBuild', 'FreeText') `
            -Priority 'DeploymentContext' -Group 'Deployment'

        New-FieldDefinition -Path 'deployment.minimumOS' -Label 'Minimum Operating System' -Type 'Choice' `
            -Why 'Intune requirement rule; devices below it never receive the package.' `
            -RecommendedFor @('BuildPackage') `
            -Choices @('W10_1607', 'W10_1709', 'W10_1803', 'W10_1809', 'W10_1903', 'W10_1909', 'W10_2004', 'W11_21H2') `
            -Discoverers @('PreviousBuild') -InputMethods @('Choice', 'UsePreviousBuild') `
            -Priority 'DeploymentContext' -Group 'Deployment'

        # --- Package --------------------------------------------------------
        New-FieldDefinition -Path 'package.sourceDirectory' -Label 'Package Source Directory' -Type 'Directory' `
            -Why 'The folder that becomes the .intunewin payload.' `
            -RequiredFor @('BuildPackage') -DerivesFrom @('installer.path') `
            -Discoverers @('Derivation', 'ProjectScan') `
            -InputMethods @('UseDetected', 'BrowseFolder') `
            -Priority 'BlocksProgress' -Group 'Package'

        New-FieldDefinition -Path 'package.outputDirectory' -Label 'Output Directory' -Type 'Directory' `
            -Why 'Where the built package and its evidence are written.' `
            -RequiredFor @('BuildPackage') -Discoverers @('Derivation') `
            -InputMethods @('UseDetected', 'BrowseFolder') `
            -Priority 'DeploymentContext' -Group 'Package'

        New-FieldDefinition -Path 'package.intuneWinAppUtilPath' -Label 'IntuneWinAppUtil.exe' -Type 'Path' `
            -Why 'Microsoft tool that produces the .intunewin file.' `
            -RequiredFor @('BuildPackage') -Discoverers @('ProjectScan', 'KnownWindowsLocation') `
            -InputMethods @('UseDetected', 'BrowseFile', 'Redetect') `
            -Priority 'BlocksProgress' -Group 'Package'
    )

    $catalog = [ordered]@{}
    foreach ($definition in $definitions) { $catalog[$definition.Path] = $definition }

    $script:FieldCatalog = $catalog
    $catalog
}

function Get-FieldDefinition {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)

    $catalog = Get-FieldCatalog
    if ($catalog.Contains($Path)) { return $catalog[$Path] }
    $null
}

function Get-OperationName {
    [CmdletBinding()]
    param()
    $script:Operations
}

function Get-OperationRequirement {
    <#
    .SYNOPSIS
        The minimum information an operation needs, split into required and
        recommended. Only these fields are ever presented for that operation.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][ValidateScript({ $_ -in $script:Operations })][string]$Operation)

    $catalog = Get-FieldCatalog

    $required = @(
        foreach ($definition in $catalog.Values) {
            if ($Operation -in $definition.RequiredFor) { $definition }
        }
    )

    $recommended = @(
        foreach ($definition in $catalog.Values) {
            if ($Operation -in $definition.RecommendedFor) { $definition }
        }
    )

    [PSCustomObject]@{
        Operation   = $Operation
        Required    = @($required | Sort-Object PriorityRank, Path)
        Recommended = @($recommended | Sort-Object PriorityRank, Path)
    }
}

function Get-PriorityRank {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Priority)

    if ($script:PromptPriority.Contains($Priority)) { return $script:PromptPriority[$Priority] }
    99
}
