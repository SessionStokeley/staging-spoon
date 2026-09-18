@{
    ApplicationName = "Example Application"
    Publisher       = "Example Vendor"
    Version         = "1.0.0"

    Installer = @{
        # EXE  launched directly
        # MSI  run as msiexec.exe /i "<file>" <arguments>
        # BAT  run as cmd.exe /c call "<file>" <arguments>, from its own
        #      directory. A .cmd is also accepted.
        #
        # A batch script reports the exit code of whatever ran last unless it
        # ends with "exit /b %ERRORLEVEL%" - without that, a failed install can
        # be reported to Intune as a success.
        Type      = "EXE"
        File      = "Setup.exe"

        # Used for local testing, and for deployment when ArgumentSource is
        # "Configuration". Keeping it either way means the package always has
        # a reproducible local test, even when Intune supplies the arguments
        # in production.
        Arguments = "/quiet /norestart"

        # Where the installer's arguments come from at execution time:
        #
        #   "Configuration"  Arguments above is authoritative. This is the
        #                    default, and what a configuration without this
        #                    key has always meant.
        #   "Intune"         The Intune Program command supplies them:
        #                      powershell.exe -ExecutionPolicy Bypass -File Install.ps1 -InstallerArguments "/quiet /norestart"
        #                    Arguments above is then local-test material only
        #                    and is never sent to the installer.
        #   "None"           The installer is launched with no arguments.
        #
        # Exactly one source is authoritative. They are never merged, and a
        # configuration that asks for one while supplying the other is
        # refused rather than guessed at.
        ArgumentSource = "Configuration"
    }

    Uninstaller = @{
        Type        = "EXE"   # EXE, MSI, or BAT
        File        = "uninstall.exe"
        Arguments   = "/quiet /norestart"
        ProductCode = $null   # For MSI: "{XXXXXXXX-XXXX-XXXX-XXXX-XXXXXXXXXXXX}"
    }

    Detection = @{
        Type           = "File"   # File, Registry, MSI, or Custom
        Path           = "C:\Program Files\Example"
        FileName       = "Example.exe"
        MinimumVersion = $null    # Optional: "1.0.0.0"

        # Custom detection. Use ONE of these:
        #   Script     = 'Test-Path "C:\Program Files\Example\Example.exe"'
        #   ScriptFile = 'Detect-Example.ps1'   # relative to this package
        #
        # Both are ordinary .psd1 strings, which Windows PowerShell 5.1 reads.
        # A script block literal - ScriptBlock = { ... } - is still accepted,
        # but 5.1 cannot load one from a .psd1, so the framework has to fall
        # back to reading this file's syntax tree. Prefer Script or ScriptFile.
        #
        # The LAST value the script emits is the verdict, so it may print
        # progress before deciding.
    }

    SuccessExitCodes = @(0, 3010)

    Logging = @{
        Enabled = $true
        Path    = "C:\ProgramData\Company\IntuneApps"
    }

    # Environment & PATH configuration (disabled by default)
    Environment = @{
        Enabled = $false
        SystemPath = @{
            Enabled            = $false
            Entries            = @()
            AddIfMissing       = $true
            RemoveOnUninstall  = $true
        }
        UserPath = @{
            Enabled            = $false
            Entries            = @()
            AddIfMissing       = $true
            RemoveOnUninstall  = $true
        }
        Variables = @(
            # Mode is Append, Prepend or Set.
            #   Append/Prepend  add to a ';'-separated list, keeping what is there
            #   Set             replace the whole value (single-value variables)
            # @{ Name = "JAVA_HOME"; Value = "C:\Program Files\Java\jdk-21"; Scope = "Machine"; Mode = "Set"; Expandable = $false; RemoveOnUninstall = $true }
            # @{ Name = "CLASSPATH"; Value = "C:\Program Files\Example\lib"; Scope = "Machine"; Mode = "Append"; Expandable = $false; RemoveOnUninstall = $true }
        )
        BroadcastChange                = $true
        PreserveExistingPath           = $true
        PreserveExpandableVariables    = $true
        CaseInsensitivePathComparison  = $true
    }

    # Windows integration, applied after the application installs.
    #
    # Each feature is independently one of three modes:
    #
    #   DISABLED  the framework does nothing.
    #   VALIDATE  the framework checks the installer created it, and reports.
    #             It never creates and never removes.
    #   MANAGE    the framework creates it, records that it owns it, and
    #             removes it on uninstall.
    #
    # Most commercial installers create their own shortcuts and associations.
    # For those, VALIDATE confirms the installer did its job without the
    # framework duplicating it and then deleting the vendor's copy.
    #
    # Required = $true makes a failure to create fail the whole install.
    # Required = $false logs a warning and carries on.
    #
    # Anything that already exists is left alone and is never claimed as owned,
    # so uninstall can never remove another product's shortcut or registry key.
    WindowsIntegration = @{
        Enabled = $false   # Master switch; $false turns every feature off

        DesktopShortcut = @{
            Mode              = "DISABLED"
            Required          = $false
            Name              = ""
            Target            = ""
            Arguments         = ""
            WorkingDirectory  = ""
            Icon              = ""
            Description       = ""
            Location          = "PublicDesktop"   # PublicDesktop or UserDesktop
            RemoveOnUninstall = $true
        }

        StartMenuShortcut = @{
            Mode              = "DISABLED"
            Required          = $false
            Name              = ""
            Target            = ""
            Arguments         = ""
            WorkingDirectory  = ""
            Icon              = ""
            Description       = ""
            Folder            = ""          # Subfolder under Programs, e.g. "Company\Application"
            Location          = "AllUsers"  # AllUsers or CurrentUser
            RemoveOnUninstall = $true
        }

        ContextMenu = @{
            Mode              = "DISABLED"
            Required          = $false
            Entries           = @(
                # Verb must be application-specific, so uninstall removes this
                # package's key and nothing else.
                # Target is FILE, FOLDER, DIRECTORY or ALL_FILES. FILE with
                # Extensions listed attaches per extension; without Extensions
                # it attaches to every file on the machine.
                # @{
                #     Name       = "Open with Example"
                #     Verb       = "Company.Example.Open"
                #     Target     = "FILE"
                #     Extensions = @(".abc", ".xyz")
                #     Executable = "C:\Program Files\Example\Example.exe"
                #     Arguments  = '"%1"'
                #     Icon       = ""
                # }
            )
            RemoveOnUninstall = $true
        }

        FileAssociations = @{
            Mode              = "DISABLED"
            Required          = $false
            Associations      = @(
                # @{
                #     Extension   = ".abc"
                #     ProgId      = "Company.Example"
                #     Description = "Example Document"
                #     Executable  = "C:\Program Files\Example\Example.exe"
                #     Arguments   = '"%1"'
                #     Icon        = "C:\Program Files\Example\Example.exe,0"
                # }
            )
            # $false registers the handler and offers it under "Open with",
            # without taking the extension over. $true makes it the default and
            # records the previous handler, which uninstall restores.
            SetAsDefault      = $false
            RemoveOnUninstall = $true
        }

        Services = @{
            Mode              = "DISABLED"
            Required          = $false
            Services          = @(
                # Leave this DISABLED when the vendor installer creates the
                # service itself, which is the usual case.
                # @{
                #     Name              = "ExampleSvc"
                #     DisplayName       = "Example Service"
                #     Description       = ""
                #     Executable        = "C:\Program Files\Example\svc.exe"
                #     Arguments         = ""
                #     StartupType       = "Automatic"   # Automatic, Manual or Disabled
                #     StartAfterInstall = $true
                # }
            )
            RemoveOnUninstall = $true
        }

        ScheduledTasks = @{
            Mode              = "DISABLED"
            Required          = $false
            Tasks             = @(
                # RunAsUser and RunLevel are honoured only when set here. A task
                # is never silently given SYSTEM or highest privileges.
                # @{
                #     Name                    = "ExampleUpdate"
                #     Path                    = "\Company\"
                #     Executable              = "C:\Program Files\Example\update.exe"
                #     Arguments               = ""
                #     Trigger                 = "AtLogon"   # AtStartup, AtLogon, Daily or Once
                #     RunAsUser               = ""
                #     RunLevel                = "Limited"   # Limited or Highest
                #     RunWhetherLoggedOnOrNot = $false
                # }
            )
            RemoveOnUninstall = $true
        }

        NotifyShell     = $true    # Tell Explorer that associations changed
        RestartExplorer = $false   # Explorer is never restarted unless asked
    }
}
