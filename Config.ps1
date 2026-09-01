#Requires -Version 5.1

# Centralized configuration — update these values per deployment, not the scripts.

$script:AppConfig = @{
    ApplicationName    = 'Oracle JDK'
    MsiFileName        = 'jdk-installer.msi'
    MsiArguments       = '/qn /norestart'

    # Registry path where JavaSoft registers the JDK
    JdkRegistryPath    = 'HKLM:\SOFTWARE\JavaSoft\JDK'

    # Uninstall registry locations to search for the installed product GUID
    UninstallRegistryPaths = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*'
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*'
    )

    # DisplayName pattern to match the JDK in the uninstall registry (case-insensitive -like)
    ProductNamePattern = 'Java*JDK*'

    # Filesystem fallback: parent directories under which JDK versions may be installed
    InstallParentDirs  = @(
        (Join-Path $env:ProgramFiles 'Java')
        (Join-Path ${env:ProgramFiles(x86)} 'Java')
    )

    # Regex matching any JDK bin directory this package manages (used for old-entry cleanup).
    # Matches: C:\Program Files\Java\jdk-21\bin, C:\Program Files (x86)\Java\jdk-26.0.1\bin, etc.
    VendorPathPattern  = '(?i)^[A-Z]:\\Program Files( \(x86\))?\\Java\\jdk-[\d.]+\\bin\\?$'

    # Log file location
    LogDirectory       = Join-Path $env:ProgramData 'IntuneApps\OracleJDK'
    LogFileName        = 'deployment.log'

    # MSI exit codes that indicate success or reboot-required
    SuccessExitCodes   = @(0, 1641, 3010)
    RebootExitCodes    = @(1641, 3010)
}
