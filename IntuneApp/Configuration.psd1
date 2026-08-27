@{
    # ================================================================
    # APPLICATION
    # ================================================================
    ApplicationName    = "Example Application"
    ApplicationVersion = "1.0.0"
    Publisher          = "Example Vendor"
    CompanyName        = "CompanyName"

    # ================================================================
    # INSTALLATION
    # ================================================================
    Installer = @{
        # Supported types: EXE, MSI, MSIX, CMD, BAT, PS1
        Type             = "EXE"
        File             = "Setup.exe"
        Arguments        = "/quiet /norestart"
        WorkingDirectory = "Files"
        TimeoutSeconds   = 3600

        # MSI only
        ProductCode      = $null
        InstallArguments = $null

        # Optional integrity verification (SHA256 hash of installer file)
        SHA256 = $null
    }

    # ================================================================
    # INSTALL SCOPE AND PRIVILEGE
    # ================================================================
    # Machine = per-machine install (HKLM, Program Files)
    # User    = per-user install (HKCU, AppData)
    InstallScope = "Machine"

    # Installation privilege context.
    # System       = Runs as NT AUTHORITY\SYSTEM (Intune default for Install behavior: System)
    # Administrator = Requires local admin but not SYSTEM (rare; used for installers
    #                 that fail under SYSTEM, e.g. some that need a user profile)
    # User         = Runs under the logged-on user (Intune Install behavior: User)
    #
    # This controls which identity the Intune Management Extension uses.
    # Set "Install behavior" in Intune to match:
    #   System       -> Install behavior: System
    #   Administrator -> Install behavior: System  (SYSTEM is admin-equivalent)
    #   User         -> Install behavior: User
    InstallPrivilege = "System"

    # ================================================================
    # UNINSTALLATION
    # ================================================================
    Uninstaller = @{
        # Supported types: Executable, MSI, Registry, Custom
        #
        # Executable - Run a specific uninstall executable with arguments
        # MSI        - Use msiexec.exe /x {ProductCode} /qn /norestart
        # Registry   - Discover uninstall command from Windows registry
        # Custom     - Specify a custom command and arguments
        Type           = "Registry"
        DisplayName    = "Example Application"
        File           = $null
        Arguments      = "/quiet /norestart"
        Command        = $null
        ProductCode    = $null
        TimeoutSeconds = 3600
    }

    # ================================================================
    # DETECTION
    # ================================================================
    Detection = @{
        # Supported types: File, Registry, MSI, Service, Custom
        Type              = "File"
        Path              = "C:\Program Files\Example"
        FileName          = "Application.exe"
        MinimumVersion    = "1.0.0.0"

        # Version comparison operator
        # Supported: Equal, GreaterThan, GreaterThanOrEqual, LessThan, LessThanOrEqual
        VersionComparison = "GreaterThanOrEqual"

        # Registry detection
        RegistryPath      = $null
        ValueName         = $null

        # MSI detection
        ProductCode       = $null

        # Service detection
        ServiceName       = $null

        # Custom detection: ScriptBlock string returning $true/$false
        CustomScript      = $null
    }

    # ================================================================
    # REQUIREMENTS
    # ================================================================
    Requirements = @{
        MinimumWindowsVersion = "10.0"
        WindowsEdition        = $null
        Architecture          = @("x64")
        MinimumDiskSpaceGB    = 5
        MinimumRAMGB          = 4
        CPUArchitecture       = $null
        DeviceType            = $null

        # Custom requirements: array of ScriptBlock strings returning $true if met
        CustomRequirements = @()
    }

    # ================================================================
    # PROCESS / SERVICE MANAGEMENT
    # ================================================================
    ProcessManagement = @{
        Enabled                    = $true
        Processes                  = @()
        Services                   = @()
        ForceStop                  = $false
        GracefulStopTimeoutSeconds = 30
    }

    # ================================================================
    # RETURN CODES
    # ================================================================
    ReturnCodes = @{
        Success           = @(0)
        SuccessWithReboot = @(3010, 1641)
    }

    # ================================================================
    # POST-INSTALL VALIDATION
    # ================================================================
    PostInstallValidation = @{
        Enabled = $true
        ExpectedFiles = @()
        ExpectedRegistryEntries = @()
        ValidateVersion = $false
    }

    # ================================================================
    # UPGRADE / SUPERSEDENCE
    # ================================================================
    Upgrade = @{
        RemovePreviousVersion = $false
        PreviousVersions      = @()
        AllowDowngrade         = $false
    }

    # ================================================================
    # LOGGING
    # ================================================================
    Logging = @{
        Enabled           = $true
        RootPath          = $null
        IncludeTranscript = $true
        MaximumLogSizeMB  = 10
        RetainLogFiles    = 10
    }

    # ================================================================
    # PATH MODIFICATION
    # ================================================================
    # Entries to add to the system PATH after installation.
    # Entries are added to the Machine-level PATH (persistent across reboots).
    # On uninstall, these entries are removed.
    PathEntries = @(
        # "C:\Program Files\Example\bin"
    )

    # ================================================================
    # FILE ASSOCIATIONS
    # ================================================================
    # Map file extensions to the application executable.
    # Each entry creates/updates the registry association for that extension.
    # On uninstall, associations created by this framework are removed.
    FileAssociations = @{
        # Extension = full path to the executable that opens it
        # ".java"   = "C:\Program Files\JetBrains\IntelliJ IDEA\bin\idea64.exe"
        # ".kt"     = "C:\Program Files\JetBrains\IntelliJ IDEA\bin\idea64.exe"
        # ".kts"    = "C:\Program Files\JetBrains\IntelliJ IDEA\bin\idea64.exe"
        # ".gradle" = "C:\Program Files\JetBrains\IntelliJ IDEA\bin\idea64.exe"
    }

    # ================================================================
    # ENVIRONMENT
    # ================================================================
    Environment = @{
        # Process-scope variables set before the installer runs
        Variables = @{}

        # Persistent Machine-level environment variables created after installation.
        # On uninstall, these are removed.
        PersistentVariables = @{
            # "JAVA_HOME" = "C:\Program Files\Java\jdk"
        }
    }

    # ================================================================
    # EXECUTION
    # ================================================================
    Execution = @{
        RequireSystem    = $true
        AllowInteractive = $false
        AllowUserProfile = $false
    }

    # ================================================================
    # TESTING
    # ================================================================
    Testing = @{
        AllowNonSystemExecution = $false
        EnableDebugLogging      = $false
        SkipRequirementChecks   = $false
        SkipDetection           = $false
        SkipValidation          = $false
    }
}
