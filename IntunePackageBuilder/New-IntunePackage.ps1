#Requires -Version 5.1

<#
    New-IntunePackage.ps1

    The one command you run. Everything else in Builder\ is a function this
    calls.

    A package is a folder. You create it, edit one file in it, build, test, and
    read off the two commands Intune needs:

        MyApp\
        ├── Configuration.psd1      you edit this
        ├── Installer\              you put the vendor's installer here
        │   └── ExampleSetup.exe
        └── PackageSource\          generated - this is what becomes the .intunewin
            ├── setup.exe
            ├── Install.ps1
            ├── Uninstall.ps1
            ├── Detection.ps1
            └── Configuration.psd1

    Modes, in the order you use them:

        New       create the folder and a starter configuration
        Build     generate PackageSource from the configuration
        Test      install, verify and uninstall on this machine, as SYSTEM
        Status    say whether this package has a test result that still applies
        Intune    print exactly what to enter in the Intune portal
        Pack      print the IntuneWinAppUtil command that produces the .intunewin

    Run with no arguments in a package folder and it reports where you are and
    what to do next.

    .EXAMPLE
    .\New-IntunePackage.ps1 -Mode New -Path C:\Packages\ExampleTool `
        -ApplicationName 'Example Tool' -Publisher 'Example Corp' -Version 2.1.0

    .EXAMPLE
    .\New-IntunePackage.ps1 -Mode Build -Path C:\Packages\ExampleTool

    .EXAMPLE
    .\New-IntunePackage.ps1 -Mode Test -Path C:\Packages\ExampleTool
#>

[CmdletBinding()]
param(
    [ValidateSet('New', 'Build', 'Test', 'Status', 'Intune', 'Pack', 'Where')]
    [string]$Mode = 'Where',

    # The package folder. Defaults to where you are.
    [string]$Path = '.',

    # -Mode New only.
    [string]$ApplicationName = 'Example Application',
    [string]$Publisher = 'Example Publisher',
    [string]$Version = '1.0.0',
    [ValidateSet('EXE', 'MSI', 'BAT')][string]$InstallerType = 'EXE',

    # -Mode Build. Defaults to the single file in Installer\.
    [string]$InstallerPath = '',

    # -Mode Test. -Force skips the confirmation prompt; automation that passes
    # it is asserting it already has approval to install software here.
    [switch]$Force,
    [switch]$SkipUninstall,
    [int]$TimeoutSeconds = 1800,

    # -Mode Pack.
    [string]$UtilPath = ''
)

$ErrorActionPreference = 'Stop'
$AppRoot = Split-Path -Parent $MyInvocation.MyCommand.Definition
$BuilderDir = Join-Path $AppRoot 'Builder'

. (Join-Path $BuilderDir 'Psd1.ps1')
. (Join-Path $BuilderDir 'PackageConfig.ps1')
. (Join-Path $BuilderDir 'Generator.ps1')
. (Join-Path $BuilderDir 'LocalTest.ps1')

function Write-Heading {
    param([string]$Text)
    Write-Host ''
    Write-Host $Text -ForegroundColor Cyan
    Write-Host ('-' * [Math]::Max(4, $Text.Length)) -ForegroundColor DarkCyan
}

function Write-Next {
    param([string[]]$Lines)
    Write-Host ''
    Write-Host 'Next:' -ForegroundColor White
    foreach ($line in $Lines) { Write-Host "  $line" -ForegroundColor Gray }
    Write-Host ''
}

function Resolve-PackageFolder {
    param([string]$Candidate, [switch]$MustExist)
    if (-not $MustExist -and -not (Test-Path -LiteralPath $Candidate)) { return $Candidate }
    if (-not (Test-Path -LiteralPath $Candidate)) {
        throw "No such folder: $Candidate"
    }
    return (Resolve-Path -LiteralPath $Candidate).Path
}

function Get-ConfigPath { param([string]$Folder) return (Join-Path $Folder 'Configuration.psd1') }
function Get-SourcePath { param([string]$Folder) return (Join-Path $Folder 'PackageSource') }

function Assert-ConfigExists {
    param([string]$Folder)
    $configPath = Get-ConfigPath -Folder $Folder
    if (-not (Test-Path -LiteralPath $configPath)) {
        throw "No Configuration.psd1 in $Folder. Create the package first: .\New-IntunePackage.ps1 -Mode New -Path '$Folder'"
    }
    return $configPath
}

function Resolve-Installer {
    <#
        The installer named explicitly, or the single file in Installer\.
        Two files there is ambiguous and is reported rather than guessed at -
        packaging the wrong installer is not something you discover quickly.
    #>
    param([string]$Folder, [string]$Explicit)

    if ($Explicit) {
        if (-not (Test-Path -LiteralPath $Explicit)) { throw "No such installer: $Explicit" }
        return (Resolve-Path -LiteralPath $Explicit).Path
    }

    $installerDir = Join-Path $Folder 'Installer'
    if (-not (Test-Path -LiteralPath $installerDir)) {
        throw "No Installer\ folder in $Folder and no -InstallerPath given. Put the vendor's installer in $installerDir."
    }

    $candidates = @(Get-ChildItem -LiteralPath $installerDir -File)
    if ($candidates.Count -eq 0) {
        throw "Installer\ is empty. Put the vendor's installer in $installerDir."
    }
    if ($candidates.Count -gt 1) {
        $names = ($candidates | ForEach-Object { $_.Name }) -join ', '
        throw "Installer\ holds more than one file ($names), so which one to package is not clear. Pass -InstallerPath, or leave only the installer there."
    }
    return $candidates[0].FullName
}

# ============================================================== Mode: Where

function Invoke-Where {
    param([string]$Folder)

    Write-Heading "Package: $Folder"

    $configPath = Get-ConfigPath -Folder $Folder
    $sourcePath = Get-SourcePath -Folder $Folder

    if (-not (Test-Path -LiteralPath $configPath)) {
        Write-Host '  Configuration      not created' -ForegroundColor Yellow
        Write-Next @(
            ".\New-IntunePackage.ps1 -Mode New -Path '$Folder' -ApplicationName 'Your App' -Publisher 'Vendor' -Version 1.0.0"
        )
        return
    }

    $config = Import-PackageConfig -Path $configPath
    Write-Host "  Application        $($config.ApplicationName) $($config.Version)" -ForegroundColor Gray
    Write-Host "  Installer type     $($config.InstallerType)" -ForegroundColor Gray

    $complaints = @()
    if (-not $config.InstallerFile) { $complaints += 'Configuration.psd1 has no InstallerFile.' }
    if (-not $config.InstallArguments) { $complaints += "InstallArguments is empty, so the installer runs with no silent switches and will likely wait for a dialog nobody can answer as SYSTEM." }
    if (-not $config.Detection.Path -and $config.Detection.Type -ne 'MSI') { $complaints += 'Detection.Path is empty, so Intune has no way to tell whether the application is installed.' }
    if ($config.InstallerType -eq 'MSI' -and -not $config.ProductCode) { $complaints += 'InstallerType is MSI but ProductCode is empty, so it cannot be uninstalled.' }

    foreach ($complaint in $complaints) { Write-Host "  ! $complaint" -ForegroundColor Yellow }

    if (-not (Test-Path -LiteralPath $sourcePath)) {
        Write-Host '  Package            not built' -ForegroundColor Yellow
        Write-Next @(
            "Edit $configPath",
            "Put the installer in $(Join-Path $Folder 'Installer')",
            ".\New-IntunePackage.ps1 -Mode Build -Path '$Folder'"
        )
        return
    }

    Write-Host "  Package            built at $sourcePath" -ForegroundColor Gray

    $state = Test-PackageTestCurrent -PackagePath $sourcePath
    if ($state.Current) {
        Write-Host "  Local test         PASS - $($state.Reason)" -ForegroundColor Green
        Write-Next @(
            ".\New-IntunePackage.ps1 -Mode Pack -Path '$Folder'      # produce the .intunewin",
            ".\New-IntunePackage.ps1 -Mode Intune -Path '$Folder'    # what to enter in the portal"
        )
    }
    else {
        Write-Host "  Local test         not current - $($state.Reason)" -ForegroundColor Yellow
        Write-Next @(
            ".\New-IntunePackage.ps1 -Mode Test -Path '$Folder'      # elevated Windows, installs on this machine"
        )
    }
}

# ================================================================ Mode: New

function Invoke-New {
    param([string]$Folder)

    $configPath = Get-ConfigPath -Folder $Folder
    if (Test-Path -LiteralPath $configPath) {
        throw "$configPath already exists. Delete it first if you meant to start over - overwriting a configuration someone edited is not recoverable."
    }

    New-Item -Path $Folder -ItemType Directory -Force | Out-Null
    New-Item -Path (Join-Path $Folder 'Installer') -ItemType Directory -Force | Out-Null

    $config = New-PackageConfig -ApplicationName $ApplicationName -Publisher $Publisher -Version $Version
    $config.InstallerType = $InstallerType

    # A plausible starting point, not a guess at the vendor's switches. The
    # real ones come from the vendor's documentation; nothing here invents them.
    $safeName = ($ApplicationName -replace '[^A-Za-z0-9]', '')
    $config.InstallPath = "C:\Program Files\$ApplicationName"
    $config.Detection.Type = 'File'
    $config.Detection.Path = "C:\Program Files\$ApplicationName\$safeName.exe"

    Export-PackageConfig -Config $config -Path $configPath | Out-Null

    Write-Heading "Created $Folder"
    Write-Host "  Configuration.psd1   edit this" -ForegroundColor Gray
    Write-Host "  Installer\           put the vendor's installer here" -ForegroundColor Gray

    Write-Next @(
        "1. Copy the vendor's installer into $(Join-Path $Folder 'Installer')",
        "2. Open $configPath and set:",
        "     InstallerFile      the name the installer will have in the package, e.g. setup.exe",
        "     InstallArguments   the vendor's real silent switches, e.g. /S or /quiet /norestart",
        "     Detection.Path     a file that exists only once the application is installed",
        "3. .\New-IntunePackage.ps1 -Mode Build -Path '$Folder'"
    )
}

# ============================================================== Mode: Build

function Invoke-Build {
    param([string]$Folder)

    $configPath = Assert-ConfigExists -Folder $Folder
    $config = Import-PackageConfig -Path $configPath
    $installer = Resolve-Installer -Folder $Folder -Explicit $InstallerPath

    # InstallerFile is the name inside the package, which is not necessarily
    # what the vendor called the download. Fill it in from the real file rather
    # than failing, and say so.
    if (-not $config.InstallerFile) {
        $config.InstallerFile = Split-Path -Leaf $installer
        Export-PackageConfig -Config $config -Path $configPath | Out-Null
        Write-Host "InstallerFile was empty; set to $($config.InstallerFile) from the file in Installer\." -ForegroundColor Yellow
    }

    $sourcePath = Get-SourcePath -Folder $Folder
    $result = New-PackageSource -Config $config -InstallerPath $installer -OutputPath $sourcePath `
                                -BuilderVersion $config.Builder.Version

    Write-Heading "Built $sourcePath"
    foreach ($file in $result.Files) { Write-Host "  $file" -ForegroundColor Gray }
    foreach ($warning in $result.Warnings) { Write-Host "  ! $warning" -ForegroundColor Yellow }

    $check = Test-GeneratedScripts -PackagePath $sourcePath
    if (-not $check.Valid) {
        Write-Host ''
        Write-Host 'The generated scripts are not sound:' -ForegroundColor Red
        foreach ($problem in $check.Errors) { Write-Host "  $problem" -ForegroundColor Red }
        exit 1
    }
    Write-Host '  All three scripts parse and carry the runtime.' -ForegroundColor Green

    Write-Next @(
        ".\New-IntunePackage.ps1 -Mode Test -Path '$Folder'   # on an elevated Windows machine you can afford to change"
    )
}

# =============================================================== Mode: Test

function Invoke-Test {
    param([string]$Folder)

    Assert-ConfigExists -Folder $Folder | Out-Null
    $sourcePath = Get-SourcePath -Folder $Folder
    if (-not (Test-Path -LiteralPath $sourcePath)) {
        throw "Nothing built yet. Run: .\New-IntunePackage.ps1 -Mode Build -Path '$Folder'"
    }

    $result = Invoke-LocalPackageTest -PackagePath $sourcePath -Force:$Force `
                                      -SkipUninstall:$SkipUninstall -TimeoutSeconds $TimeoutSeconds
    Write-LocalTestReport -Result $result

    # A skipped or cancelled run is not a result, and recording one would let
    # it satisfy the check before packaging.
    if ($result.Overall -eq 'PASS' -or $result.Overall -eq 'FAILED') {
        $recorded = Save-TestResult -PackagePath $sourcePath -Result $result
        Write-Host "Recorded: $recorded" -ForegroundColor DarkGray
    }

    if ($result.InstallOutput) {
        $logPath = Join-Path $Folder 'LastTest-Install.log'
        Set-Content -LiteralPath $logPath -Value $result.InstallOutput -Encoding UTF8
        Write-Host "Install output: $logPath" -ForegroundColor DarkGray
    }
    if ($result.UninstallOutput) {
        $logPath = Join-Path $Folder 'LastTest-Uninstall.log'
        Set-Content -LiteralPath $logPath -Value $result.UninstallOutput -Encoding UTF8
        Write-Host "Uninstall output: $logPath" -ForegroundColor DarkGray
    }

    if ($result.Overall -eq 'PASS') {
        Write-Next @(".\New-IntunePackage.ps1 -Mode Pack -Path '$Folder'")
    }
    elseif ($result.Overall -eq 'SKIPPED') {
        Write-Next @(
            'Nothing was run. The local test needs an elevated Windows session,',
            'because it registers a scheduled task that runs as NT AUTHORITY\SYSTEM.'
        )
        exit 2
    }
    elseif ($result.Overall -ne 'CANCELLED') { exit 1 }
}

# ============================================================= Mode: Status

function Invoke-Status {
    param([string]$Folder)

    $sourcePath = Get-SourcePath -Folder $Folder
    if (-not (Test-Path -LiteralPath $sourcePath)) {
        Write-Host 'Not built.' -ForegroundColor Yellow
        exit 1
    }

    $state = Test-PackageTestCurrent -PackagePath $sourcePath
    $record = Get-TestResult -PackagePath $sourcePath

    Write-Heading 'Test state'
    if ($record) {
        Write-Host "  Last result        $($record.Overall)" -ForegroundColor Gray
        Write-Host "  Tested on          $($record.TestedOn)" -ForegroundColor Gray
        Write-Host "  Tested by          $($record.TestedBy)" -ForegroundColor Gray
        if ($record.Failure) { Write-Host "  Failure            $($record.Failure)" -ForegroundColor Red }
    }

    if ($state.Current) {
        Write-Host "  Still applies      yes" -ForegroundColor Green
    }
    else {
        Write-Host "  Still applies      no - $($state.Reason)" -ForegroundColor Yellow
        exit 1
    }
}

# ============================================================= Mode: Intune

function Invoke-Intune {
    param([string]$Folder)

    $configPath = Assert-ConfigExists -Folder $Folder
    $config = Import-PackageConfig -Path $configPath

    Write-Heading 'Intune - Apps > Windows > Add > Windows app (Win32)'

    Write-Host ''
    Write-Host 'App information' -ForegroundColor White
    Write-Host "  Name             $($config.ApplicationName)" -ForegroundColor Gray
    Write-Host "  Publisher        $($config.Publisher)" -ForegroundColor Gray
    Write-Host "  App version      $($config.Version)" -ForegroundColor Gray
    if ($config.Description) { Write-Host "  Description      $($config.Description)" -ForegroundColor Gray }

    Write-Host ''
    Write-Host 'Program' -ForegroundColor White
    Write-Host '  Install command' -ForegroundColor Gray
    Write-Host '    powershell.exe -ExecutionPolicy Bypass -NoProfile -WindowStyle Hidden -File .\Install.ps1' -ForegroundColor Green
    Write-Host '  Uninstall command' -ForegroundColor Gray
    Write-Host '    powershell.exe -ExecutionPolicy Bypass -NoProfile -WindowStyle Hidden -File .\Uninstall.ps1' -ForegroundColor Green
    Write-Host '  Install behavior  System' -ForegroundColor Gray
    $restart = if ($config.RebootBehavior -eq 'Force') { 'Force a restart' }
               elseif ($config.RebootBehavior -eq 'Allow') { 'App install may force a device restart' }
               else { 'No specific action' }
    Write-Host "  Device restart behavior  $restart" -ForegroundColor Gray

    Write-Host ''
    Write-Host '  These commands take NO installer arguments, on purpose.' -ForegroundColor Yellow
    Write-Host "  The arguments live in Configuration.psd1 (InstallArguments = '$($config.InstallArguments)')," -ForegroundColor DarkGray
    Write-Host '  which is inside the package. That is what was tested locally, so what' -ForegroundColor DarkGray
    Write-Host '  runs on the endpoint is the same thing - byte for byte. Adding switches' -ForegroundColor DarkGray
    Write-Host '  to the Intune command line would not reach the installer.' -ForegroundColor DarkGray

    Write-Host ''
    Write-Host 'Return codes' -ForegroundColor White
    foreach ($code in @($config.SuccessExitCodes)) {
        $meaning = if ($code -eq 3010) { 'Soft reboot' } else { 'Success' }
        Write-Host "  $code$(' ' * [Math]::Max(1, 16 - "$code".Length))$meaning" -ForegroundColor Gray
    }
    Write-Host '  Leave the default 1707/1618/1641 rows as they are.' -ForegroundColor DarkGray

    Write-Host ''
    Write-Host 'Detection rules  -  Rules format: Use a custom detection script' -ForegroundColor White
    Write-Host "  Script file           $(Join-Path (Get-SourcePath -Folder $Folder) 'Detection.ps1')" -ForegroundColor Green
    Write-Host '  Run script as 32-bit  No' -ForegroundColor Gray
    Write-Host '  Enforce signature     No' -ForegroundColor Gray
    Write-Host ''
    Write-Host '  Upload the Detection.ps1 from PackageSource\ - the same file that is in' -ForegroundColor DarkGray
    Write-Host '  the package, so the rule and the package agree on what "installed" means.' -ForegroundColor DarkGray
    Write-Host "  It reports installed by checking: $($config.Detection.Type) $($config.Detection.Path)" -ForegroundColor DarkGray

    Write-Host ''
    Write-Host 'Requirements' -ForegroundColor White
    Write-Host "  Operating system architecture   $($config.Architecture)" -ForegroundColor Gray
    Write-Host '  Minimum operating system        whatever your estate requires' -ForegroundColor Gray
    Write-Host ''
}

# =============================================================== Mode: Pack

function Invoke-Pack {
    param([string]$Folder)

    $sourcePath = Get-SourcePath -Folder $Folder
    if (-not (Test-Path -LiteralPath $sourcePath)) {
        throw "Nothing built yet. Run: .\New-IntunePackage.ps1 -Mode Build -Path '$Folder'"
    }

    # Section 23. Packaging an untested configuration is the thing this is
    # here to stop, so it is a refusal rather than a warning.
    $state = Test-PackageTestCurrent -PackagePath $sourcePath
    if (-not $state.Current -and -not $Force) {
        Write-Host ''
        Write-Host "This package has no test result that still applies: $($state.Reason)" -ForegroundColor Red
        Write-Host 'Run -Mode Test first, or pass -Force to package it anyway.' -ForegroundColor Red
        Write-Host ''
        exit 1
    }

    $util = $UtilPath
    if (-not $util) {
        foreach ($candidate in @(
            (Join-Path $AppRoot 'IntuneWinAppUtil.exe'),
            (Join-Path $Folder 'IntuneWinAppUtil.exe'),
            'C:\Tools\IntuneWinAppUtil.exe'
        )) {
            if (Test-Path -LiteralPath $candidate) { $util = $candidate; break }
        }
    }
    if (-not $util) {
        $found = Get-Command 'IntuneWinAppUtil.exe' -ErrorAction SilentlyContinue
        if ($found) { $util = $found.Source }
    }

    $outputPath = Join-Path $Folder 'Output'
    New-Item -Path $outputPath -ItemType Directory -Force | Out-Null

    if (-not $util) {
        Write-Heading 'IntuneWinAppUtil.exe not found'
        Write-Host '  It is Microsoft''s tool and is not shipped here. Download it from' -ForegroundColor Gray
        Write-Host '  github.com/microsoft/Microsoft-Win32-Content-Prep-Tool and put it' -ForegroundColor Gray
        Write-Host "  in C:\Tools, or pass -UtilPath." -ForegroundColor Gray
        Write-Host ''
        Write-Host '  Do NOT put it inside the package folder: IntuneWinAppUtil -c archives' -ForegroundColor Yellow
        Write-Host '  everything beneath the folder it is given, so a copy sitting there' -ForegroundColor Yellow
        Write-Host '  ships to every managed machine.' -ForegroundColor Yellow
        Write-Host ''
        Write-Host '  Then run:' -ForegroundColor Gray
        Write-Host "    IntuneWinAppUtil.exe -c `"$sourcePath`" -s Install.ps1 -o `"$outputPath`"" -ForegroundColor Green
        Write-Host ''
        exit 1
    }

    Write-Heading 'Packing'
    Write-Host "  $util -c `"$sourcePath`" -s Install.ps1 -o `"$outputPath`"" -ForegroundColor DarkGray

    & $util -c $sourcePath -s 'Install.ps1' -o $outputPath -q
    if ($LASTEXITCODE -ne 0) {
        Write-Host "IntuneWinAppUtil.exe exited $LASTEXITCODE." -ForegroundColor Red
        exit 1
    }

    $package = @(Get-ChildItem -LiteralPath $outputPath -Filter '*.intunewin' -File |
                 Sort-Object LastWriteTime -Descending)
    if ($package.Count -eq 0) {
        Write-Host 'IntuneWinAppUtil.exe reported success but produced no .intunewin.' -ForegroundColor Red
        exit 1
    }

    Write-Host "  $($package[0].FullName)" -ForegroundColor Green
    Write-Next @(".\New-IntunePackage.ps1 -Mode Intune -Path '$Folder'   # what to enter in the portal")
}

# ==================================================================== drive

$folder = Resolve-PackageFolder -Candidate $Path -MustExist:($Mode -ne 'New')

switch ($Mode) {
    'New'    { Invoke-New -Folder (Resolve-PackageFolder -Candidate $Path) }
    'Build'  { Invoke-Build -Folder $folder }
    'Test'   { Invoke-Test -Folder $folder }
    'Status' { Invoke-Status -Folder $folder }
    'Intune' { Invoke-Intune -Folder $folder }
    'Pack'   { Invoke-Pack -Folder $folder }
    default  { Invoke-Where -Folder $folder }
}
