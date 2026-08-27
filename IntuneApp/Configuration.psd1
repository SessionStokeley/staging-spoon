@{
    # ================================================================
    # APPLICATION METADATA
    # ================================================================
    Application = @{
        Name         = "Example Application"
        Version      = "1.0.0"
        Publisher    = "Example Vendor"
        Architecture = "x64"
    }

    # Deploying organization (used for log paths)
    CompanyName = "CompanyName"

    # ================================================================
    # INSTALLER
    # ================================================================
    # Supported types: EXE, MSI, MSIX, CMD, BAT, PS1
    Installer = @{
        Type             = "EXE"
        File             = "Setup.exe"
        Arguments        = "/quiet /norestart"
        TimeoutSeconds   = 3600

        # MSI only
        ProductCode      = $null
        InstallArguments = $null

        # Optional integrity verification (SHA256 hash of installer file)
        SHA256           = $null
    }

    # ================================================================
    # UNINSTALLER
    # ================================================================
    # Supported types: Executable, MSI, Registry, Custom
    #
    # Executable - Run a specific uninstall executable with arguments
    # MSI        - Use msiexec.exe /x {ProductCode} /qn /norestart
    # Registry   - Discover uninstall command from Windows registry
    # Custom     - Specify a custom command and arguments
    Uninstaller = @{
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
    # Supported types: File, Registry, MSI, Service, Custom
    Detection = @{
        Type              = "File"
        Path              = "C:\Program Files\Example"
        FileName          = "Application.exe"
        MinimumVersion    = "1.0.0.0"
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
        Architecture          = @("x64")
        MinimumDiskSpaceGB    = 5
        MinimumRAMGB          = 4
    }

    # ================================================================
    # PRIVILEGES
    # ================================================================
    # Controls the identity context for installation.
    # InstallAsSystem  = $true  -> Script expects NT AUTHORITY\SYSTEM
    #                              (Intune Install behavior: System)
    # InstallAsSystem  = $false -> Script runs under current user
    #                              (Intune Install behavior: User)
    # RequireElevation = $true  -> Requires administrative privileges
    Privileges = @{
        InstallAsSystem  = $true
        RequireElevation = $true
    }

    # ================================================================
    # PROCESS AND SERVICE MANAGEMENT
    # ================================================================
    # Processes and services to stop before install/uninstall.
    # Processes are gracefully closed then force-stopped after 30 seconds.
    ProcessesToStop = @()
    ServicesToStop  = @()

    # ================================================================
    # ENVIRONMENT
    # ================================================================
    Environment = @{
        # Directories to add to the Machine-level PATH after installation.
        # Automatically removed on uninstall.
        AddToMachinePath = @(
            # "C:\Program Files\Example\bin"
        )

        # Persistent Machine-level environment variables created after installation.
        # Automatically removed on uninstall.
        Variables = @{
            # "JAVA_HOME" = "C:\Program Files\Java\jdk"
        }
    }

    # ================================================================
    # FILE ASSOCIATIONS
    # ================================================================
    # Mode controls who manages file associations:
    #   Installer  - The application installer handles associations (framework does nothing)
    #   Framework  - The Intune framework configures associations from the Associations table
    #   None       - Don't modify file associations
    FileAssociations = @{
        Mode         = "None"
        Associations = @{
            # ".ext" = "C:\Program Files\Example\Application.exe"
        }
    }

    # ================================================================
    # REGISTRY MODIFICATIONS
    # ================================================================
    # Registry entries to add or remove after installation.
    # Add entries are created during install and removed during uninstall.
    # Remove entries are deleted during install.
    Registry = @{
        Add = @(
            # @{ Path = "HKLM:\Software\MyApp"; Name = "Setting"; Value = "Value"; Type = "String" }
        )
        Remove = @(
            # @{ Path = "HKLM:\Software\OldApp"; Name = "OldSetting" }
        )
    }

    # ================================================================
    # SHORTCUTS
    # ================================================================
    # Shortcuts to create or remove after installation.
    # Location: StartMenu, Desktop
    Shortcuts = @{
        Create = @(
            # @{ Name = "My Application"; TargetPath = "C:\Program Files\MyApp\app.exe"; Location = "StartMenu" }
        )
        Remove = @(
            # @{ Name = "Old Application"; Location = "StartMenu" }
        )
    }

    # ================================================================
    # POST-INSTALL
    # ================================================================
    # Validation and custom actions after installation.
    # Supported action types: RunCommand, RunPowerShell, RestartService, CopyFile
    PostInstall = @{
        Validate = $true
        Actions  = @(
            # @{ Type = "RunCommand"; Command = "app.exe"; Arguments = "/configure" }
            # @{ Type = "RunPowerShell"; Script = "Set-Content -Path 'C:\config.ini' -Value 'data'" }
            # @{ Type = "RestartService"; Service = "MyAppService" }
        )
    }

    # ================================================================
    # USER EXPERIENCE
    # ================================================================
    # Controls standard shortcut creation via Company Portal / Intune.
    # Uses the detected application executable as the shortcut target.
    UserExperience = @{
        CreateStartMenuShortcut = $true
        CreateDesktopShortcut   = $false
        LaunchAfterInstall      = $false
    }

    # ================================================================
    # UPGRADE / SUPERSEDENCE
    # ================================================================
    Upgrade = @{
        RemovePreviousVersion = $false
        PreviousVersions      = @()
        AllowDowngrade        = $false
    }

    # ================================================================
    # RETURN CODES
    # ================================================================
    ReturnCodes = @{
        Success           = @(0)
        SuccessWithReboot = @(3010, 1641)
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
