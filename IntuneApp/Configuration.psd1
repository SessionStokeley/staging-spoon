@{
    ApplicationName = "Autodesk Revit 2026"
    Publisher       = "Autodesk"
    Version         = "2026.5"

    Installer = @{
        Type      = "EXE"
        File      = "Revit_2026_5.exe"
        Arguments = "--silent"
    }

    Uninstaller = @{
        Type      = "EXE"
        File      = "C:\Program Files\Autodesk\Revit 2026\Installer.exe"
        Arguments = "-i uninstall --silent"
    }

    Detection = @{
        Type           = "File"
        Path           = "C:\Program Files\Autodesk\Revit 2026"
        FileName       = "Revit.exe"
        MinimumVersion = $null
    }

    SuccessExitCodes = @(0, 3010)

    Logging = @{
        Enabled = $true
        Path    = "C:\ProgramData\Company\IntuneApps"
    }
}
