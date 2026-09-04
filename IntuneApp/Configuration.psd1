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
    }

    SuccessExitCodes = @(0, 3010)

    Logging = @{
        Enabled = $true
        Path    = "C:\ProgramData\Company\IntuneApps"
    }
}
