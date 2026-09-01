#Requires -Version 5.1

# Centralized configuration — update these values per deployment, not the scripts.
# Supports both MSI and EXE installer types.

$script:AppConfig = @{
    ApplicationName    = 'Oracle JDK'

    # --- Installer configuration ---
    # InstallerType: 'MSI' or 'EXE'
    InstallerType      = 'MSI'
    InstallerFileName  = 'jdk-installer.msi'
    InstallerArguments = '/qn /norestart'

    # --- Uninstall configuration ---
    # UninstallType: 'MSI' or 'EXE'
    # For MSI: uses product GUID from registry, falls back to InstallerFileName
    # For EXE: uses QuietUninstallString from registry, falls back to UninstallFileName + UninstallArguments
    UninstallType      = 'MSI'
    UninstallFileName  = ''
    UninstallArguments = ''

    # --- Exit codes ---
    SuccessExitCodes   = @(0, 1641, 3010)
    RebootExitCodes    = @(1641, 3010)

    # --- Detection configuration ---
    # At least one detection method should be configured.
    # DetectionMethod: 'Registry', 'File', or 'Both'
    # Registry: uses ProductNamePattern against uninstall registry
    # File: uses DetectionFilePath to check for a file on disk
    DetectionMethod    = 'Both'

    # Registry-based detection
    UninstallRegistryPaths = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*'
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*'
    )
    ProductNamePattern = 'Java*JDK*'

    # File-based detection (set to the primary executable or a sentinel file)
    DetectionFilePath  = ''  # e.g. 'C:\Program Files\Vendor\app.exe' — leave empty to auto-discover

    # --- Application-specific: JDK path discovery ---
    # Set these for applications that register in a vendor-specific registry location
    JdkRegistryPath    = 'HKLM:\SOFTWARE\JavaSoft\JDK'

    # Filesystem fallback: parent directories under which versions may be installed
    InstallParentDirs  = @(
        (Join-Path $env:ProgramFiles 'Java')
        (Join-Path ${env:ProgramFiles(x86)} 'Java')
    )

    # --- PATH / environment variable management ---
    # Set to $true to enable PATH and env-var configuration after install
    ConfigureEnvironment = $true

    # Regex matching managed PATH entries for old-version cleanup
    VendorPathPattern  = '(?i)^[A-Z]:\\Program Files( \(x86\))?\\Java\\jdk-[\d.]+\\bin\\?$'

    # Environment variables to set (hashtable of Name = scriptblock-or-value)
    # The install script resolves these after determining the installation path.
    # JAVA_HOME is handled explicitly by the JDK-specific post-install logic.
    EnvironmentVariables = @{
        JAVA_HOME = $null  # set dynamically during install
    }

    # Relative path under the install root to add to PATH (e.g. 'bin')
    PathSubdirectory   = 'bin'

    # --- Logging ---
    LogDirectory       = Join-Path $env:ProgramData 'IntuneApps\OracleJDK'
    LogFileName        = 'deployment.log'
}
