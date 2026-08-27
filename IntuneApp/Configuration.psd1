@{
    # =========================================================================
    # APPLICATION INFORMATION
    # =========================================================================
    ApplicationName    = "Example Application"
    ApplicationVersion = "1.0.0"
    Publisher          = "Example Vendor"

    # Company name used for log directory paths
    # Logs stored under: C:\ProgramData\<CompanyName>\IntuneApps\<ApplicationName>\
    CompanyName = "CompanyName"

    # =========================================================================
    # INSTALLER CONFIGURATION
    # =========================================================================
    Installer = @{
        # Supported types: EXE, MSI, MSIX, CMD, BAT, PS1
        Type             = "EXE"
        File             = "Setup.exe"
        Arguments        = "/quiet /norestart"
        WorkingDirectory = "Files"

        # MSI-specific settings (used when Type = "MSI")
        # ProductCode      = "{00000000-0000-0000-0000-000000000000}"
        # InstallArguments = "/qn /norestart ALLUSERS=1"

        # Timeout in seconds for the installer process (default 3600 = 1 hour)
        TimeoutSeconds = 3600
    }

    # =========================================================================
    # UNINSTALLER CONFIGURATION
    # =========================================================================
    Uninstaller = @{
        # Supported types: Executable, MSI, Registry, Custom
        #
        # Executable  - Run a specific uninstall executable with arguments
        # MSI         - Use msiexec.exe /x {ProductCode} /qn /norestart
        # Registry    - Discover uninstall command from Windows registry
        # Custom      - Specify a custom command and arguments
        Type      = "Executable"
        File      = "uninstall.exe"
        Arguments = "/quiet /norestart"

        # MSI-specific (used when Type = "MSI")
        # ProductCode        = "{00000000-0000-0000-0000-000000000000}"
        # UninstallArguments = "/qn /norestart"

        # Registry-specific (used when Type = "Registry")
        # DisplayName = "Example Application"

        # Custom-specific (used when Type = "Custom")
        # Command   = "C:\Program Files\Example\uninstall.exe"
        # Arguments = "--silent --remove-all"

        # Timeout in seconds for the uninstaller process
        TimeoutSeconds = 3600
    }

    # =========================================================================
    # DETECTION CONFIGURATION
    # =========================================================================
    Detection = @{
        # Supported types: File, Registry, MSI, Service, Custom
        Type           = "File"
        Path           = "C:\Program Files\Example"
        FileName       = "Application.exe"
        MinimumVersion = "1.0.0.0"

        # Registry-specific (used when Type = "Registry")
        # RegistryPath  = "HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\{GUID}"
        # ValueName     = "DisplayVersion"
        # MinimumVersion = "1.0.0"

        # MSI-specific (used when Type = "MSI")
        # ProductCode = "{00000000-0000-0000-0000-000000000000}"

        # Service-specific (used when Type = "Service")
        # ServiceName = "ExampleService"

        # Custom-specific (used when Type = "Custom")
        # A ScriptBlock string that returns $true if detected, $false otherwise.
        # CustomScript = 'Test-Path "C:\Program Files\Example\marker.txt"'
    }

    # =========================================================================
    # REQUIREMENTS
    # =========================================================================
    Requirements = @{
        MinimumWindowsVersion = "10.0"
        # WindowsEdition      = "Enterprise"
        Architecture          = "x64"
        MinimumDiskSpaceGB    = 5
        MinimumRAMGB          = 4
        # CPUArchitecture     = "AMD64"
        # DeviceType          = "Workstation"

        # Custom requirements: array of ScriptBlock strings that return $true if met.
        # CustomRequirements = @(
        #     '(Get-Service "SomeService" -ErrorAction SilentlyContinue) -ne $null'
        # )
    }

    # =========================================================================
    # PROCESS AND SERVICE MANAGEMENT
    # =========================================================================
    # Processes to stop before install/uninstall (by process name, no .exe)
    ProcessesToStop = @()

    # Services to stop before install/uninstall (by service name)
    ServicesToStop = @()

    # Force-kill processes that do not stop gracefully within the timeout
    ForceStopProcesses = $false

    # Seconds to wait for graceful process termination
    GracefulStopTimeoutSeconds = 30

    # =========================================================================
    # RETURN CODES
    # =========================================================================
    ReturnCodes = @{
        Success            = @(0)
        SuccessWithReboot  = @(3010, 1641)
    }

    # =========================================================================
    # POST-INSTALL VALIDATION
    # =========================================================================
    PostInstallValidation = @{
        # Files that must exist after installation
        ExpectedFiles = @(
            # "C:\Program Files\Example\Application.exe"
        )

        # Registry entries that must exist after installation
        ExpectedRegistryEntries = @(
            # @{ Path = "HKLM:\Software\Example"; Name = "Installed"; Value = "1" }
        )

        # Expected version (uses detection method to verify)
        ValidateVersion = $false
    }

    # =========================================================================
    # TESTING
    # =========================================================================
    Testing = @{
        # Allow running outside SYSTEM context for local testing
        AllowNonSystemExecution = $false
    }
}
