#Requires -Version 5.1

# Centralized configuration — update these values per deployment, not the scripts.

$script:AppConfig = @{
    ApplicationName    = 'Oracle JDK'
    MsiFileName        = 'jdk-installer.msi'
    MsiArguments       = '/qn /norestart'

    # Registry path where JavaSoft registers the JDK
    RegistryPath       = 'HKLM:\SOFTWARE\JavaSoft\JDK'

    # Filesystem fallback: parent directory under which JDK versions are installed
    InstallParentDir   = Join-Path $env:ProgramFiles 'Java'

    # Pattern matching any JDK bin directory this package manages (used for old-entry cleanup)
    # Must match paths like C:\Program Files\Java\jdk-21\bin, C:\Program Files\Java\jdk-26\bin, etc.
    VendorPathPattern  = '(?i)^[A-Z]:\\Program Files\\Java\\jdk-[\d.]+\\bin\\?$'

    # Log file location
    LogDirectory       = Join-Path $env:ProgramData 'IntuneApps\OracleJDK'
    LogFileName        = 'deployment.log'

    # MSI exit codes that indicate success or reboot-required
    SuccessExitCodes   = @(0, 1641, 3010)
    RebootExitCodes    = @(1641, 3010)
}
