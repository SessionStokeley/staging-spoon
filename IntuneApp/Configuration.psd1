@{
    ApplicationName = "Example Application"
    Publisher       = "Example Vendor"
    Version         = "1.0.0"

    Installer = @{
        Type      = "EXE"   # EXE or MSI
        File      = "Setup.exe"
        Arguments = "/quiet /norestart"
    }

    Uninstaller = @{
        Type        = "EXE"   # EXE or MSI
        File        = "uninstall.exe"
        Arguments   = "/quiet /norestart"
        ProductCode = $null   # For MSI: "{XXXXXXXX-XXXX-XXXX-XXXX-XXXXXXXXXXXX}"
    }

    Detection = @{
        Type           = "File"   # File, Registry, MSI, or Custom
        Path           = "C:\Program Files\Example"
        FileName       = "Example.exe"
        MinimumVersion = $null    # Optional: "1.0.0.0"
        # Registry detection:
        # RegistryPath   = "HKLM:\SOFTWARE\Company\Example"
        # ValueName      = "InstalledVersion"
        # ExpectedValue  = "1.0.0"
        # MSI detection:
        # ProductCode    = "{XXXXXXXX-XXXX-XXXX-XXXX-XXXXXXXXXXXX}"
        # Custom detection:
        # ScriptBlock    = { Test-Path "C:\Program Files\Example\Example.exe" }
    }

    SuccessExitCodes = @(0, 3010)

    Logging = @{
        Enabled = $true
        Path    = "C:\ProgramData\Company\IntuneApps"
    }
}
