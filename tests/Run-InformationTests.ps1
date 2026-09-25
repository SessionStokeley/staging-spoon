<#
.SYNOPSIS
    Tests for the information intelligence layer.
.DESCRIPTION
    Covers the field model, path and resource resolution, discovery, capture
    integration, conflict handling, requirement calculation and prompting -
    including the acceptance scenario that proves the platform never asks for
    the same information twice.
.EXAMPLE
    pwsh -NoProfile -File .\tests\Run-InformationTests.ps1
#>

[CmdletBinding()]
param([string]$WorkPath = (Join-Path ([System.IO.Path]::GetTempPath()) 'staging-spoon-information-tests'))

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repo = Split-Path $PSScriptRoot -Parent

. (Join-Path $repo 'src/Core/PackageManifest.ps1')
. (Join-Path $repo 'src/Information/Load.ps1')

$script:failures = 0

function Test-Case {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][AllowNull()]$Condition,
        [string]$Detail = ''
    )

    if ($Condition) {
        Write-Host "  PASS $Name"
    } else {
        Write-Host "  FAIL $Name $Detail" -ForegroundColor Red
        $script:failures++
    }
}

function New-FakeInstaller {
    param(
        [Parameter(Mandatory)][string]$Path,
        [string]$Marker = 'Nullsoft Install System v3.08'
    )

    $directory = Split-Path -Path $Path -Parent
    if (-not (Test-Path -LiteralPath $directory)) {
        New-Item -Path $directory -ItemType Directory -Force | Out-Null
    }

    $content = 'MZ' + ('.' * 128) + $Marker + ('.' * 128)
    [System.IO.File]::WriteAllBytes($Path, (Get-Latin1Encoding).GetBytes($content))
    $Path
}

function New-FakeDelta {
    param([string[]]$Files = @(), [string[]]$PathAdded = @(), [string[]]$Shortcuts = @(), [string[]]$Applications = @())

    [PSCustomObject]@{
        Files                = [PSCustomObject]@{ Added = $Files; Removed = @() }
        Applications         = [PSCustomObject]@{ Added = $Applications; Removed = @() }
        Registry             = [PSCustomObject]@{ Added = @('HKLM:\SOFTWARE\Contoso\Reader'); Removed = @(); Changed = @() }
        Services             = [PSCustomObject]@{ Added = @(); Removed = @() }
        ScheduledTasks       = [PSCustomObject]@{ Added = @(); Removed = @() }
        EnvironmentVariables = [PSCustomObject]@{ Added = @(); Removed = @() }
        Path                 = [PSCustomObject]@{ Added = $PathAdded; Removed = @() }
        Shortcuts            = [PSCustomObject]@{ Added = $Shortcuts; Removed = @() }
    }
}

Remove-Item -LiteralPath $WorkPath -Recurse -Force -ErrorAction SilentlyContinue
New-Item -Path $WorkPath -ItemType Directory -Force | Out-Null

# --- Path resolution ---------------------------------------------------------
Write-Host "`nPath resolution"

# The canonical separator is "/" on every platform, so a path reads the same in
# the project file, the report and the console, and never acquires the doubled
# backslashes a Windows path picks up as soon as it is serialised to JSON.
Test-Case 'backslashes normalized'       ((ConvertTo-CanonicalPath -Path 'C:\Build\App') -eq 'C:/Build/App')
Test-Case 'forward slashes preserved'    ((ConvertTo-CanonicalPath -Path 'C:/Build/App') -eq 'C:/Build/App')
Test-Case 'mixed separators normalized'  ((ConvertTo-CanonicalPath -Path 'C:\Build/App\Sub') -eq 'C:/Build/App/Sub')
Test-Case 'trailing separator stripped'  ((ConvertTo-CanonicalPath -Path 'C:\Build\App\') -eq 'C:/Build/App')
Test-Case 'dot segments collapsed'       ((ConvertTo-CanonicalPath -Path 'C:\Build\.\A\..\B') -eq 'C:/Build/B')
Test-Case 'drive root keeps separator'   ((ConvertTo-CanonicalPath -Path 'C:\') -eq 'C:/')
Test-Case 'UNC prefix preserved'         ((ConvertTo-CanonicalPath -Path '\\srv\share\a.msi') -eq '//srv/share/a.msi')
Test-Case 'relative prefix dropped'      ((ConvertTo-CanonicalPath -Path '.\Source\App') -eq 'Source/App')
Test-Case 'forward relative prefix'      ((ConvertTo-CanonicalPath -Path './source/App.exe') -eq 'source/App.exe')
Test-Case 'spaces preserved in path'     ((ConvertTo-CanonicalPath -Path 'C:\Temp\Test Folder\App.exe') -eq 'C:/Temp/Test Folder/App.exe')

# A value that reached the platform still carrying its serialisation escaping
# must resolve to the same path, not to one with empty segments in it.
Test-Case 'escaped separators collapse'  ((ConvertTo-CanonicalPath -Path 'C:\\Users\\Example\\App') -eq 'C:/Users/Example/App')
Test-Case 'duplicate separators collapse' ((ConvertTo-CanonicalPath -Path 'C://Users//Example') -eq 'C:/Users/Example')

# Every spelling of one location must reach a single canonical value.
$equivalentPaths = @('C:\Users\Example\App', 'C:\\Users\\Example\\App', 'C:/Users/Example/App', 'C:\Users/Example\App')
Test-Case 'all spellings agree' (
    (@($equivalentPaths | ForEach-Object { ConvertTo-CanonicalPath -Path $_ } | Select-Object -Unique)).Count -eq 1
)

# The execution boundary hands back the native Windows spelling.
$nativeSample = ConvertTo-NativePath -Path 'C:/Users/Example/App'
Test-Case 'native form is a Windows path' ($nativeSample -eq 'C:\Users\Example\App') $nativeSample
Test-Case 'native round trips to canonical' ((ConvertTo-CanonicalPath -Path $nativeSample) -eq 'C:/Users/Example/App')

# Canonical Windows paths are split by the helpers directly so the result does
# not depend on the runtime's path separator.
Test-Case 'parent of a nested path'      ((Split-CanonicalPath -Path 'C:\A\B\c.exe') -eq 'C:/A/B')
Test-Case 'parent at the drive root'     ((Split-CanonicalPath -Path 'C:\c.exe') -eq 'C:/')
Test-Case 'bare name has no parent'      ((Split-CanonicalPath -Path 'c.exe') -eq '')
Test-Case 'parent of a UNC path'         ((Split-CanonicalPath -Path '\\srv\share\dir\a.msi') -eq '//srv/share/dir')
Test-Case 'UNC share has no parent'      ((Split-CanonicalPath -Path '\\srv\share') -eq '')
Test-Case 'leaf of a windows path'       ((Get-CanonicalLeaf -Path 'C:\A\B\c.exe') -eq 'c.exe')
Test-Case 'extension of a windows path'  ((Get-CanonicalExtension -Path 'C:\A\B\c.exe') -eq '.exe')
Test-Case 'dotted directory ignored'     ((Get-CanonicalExtension -Path 'C:\A.v2\readme') -eq '')
Test-Case 'base name drops extension'    ((Get-CanonicalBaseName -Path 'C:\A\B\c.tar.gz') -eq 'c.tar')

Test-Case 'absolute path detected'       (Test-AbsolutePath -Path 'C:\Build')
Test-Case 'relative path detected'       (-not (Test-AbsolutePath -Path 'Source\App'))

Test-Case 'inside project becomes relative' ((ConvertTo-RelativePath -Path 'C:\P\Source\a.exe' -BasePath 'C:\P') -eq 'Source/a.exe')
Test-Case 'outside project stays absolute'  ((ConvertTo-RelativePath -Path 'D:\X\a.exe' -BasePath 'C:\P') -eq '')

$storable = ConvertTo-StorablePath -Path 'C:\P\Source\a.exe' -ProjectRoot 'C:\P'
Test-Case 'storable path is relative'    ($storable.StoredPath -eq 'Source/a.exe' -and -not $storable.IsExternal)

$external = ConvertTo-StorablePath -Path 'D:\Shared\a.exe' -ProjectRoot 'C:\P'
Test-Case 'external path marked'         ($external.IsExternal)

Test-Case 'invalid character rejected'   (-not (Test-PathCharacterValid -Path 'C:\Bad<Name>').IsValid)
Test-Case 'reserved name rejected'       (-not (Test-PathCharacterValid -Path 'C:\Temp\CON.txt').IsValid)
Test-Case 'ordinary path accepted'       (Test-PathCharacterValid -Path 'C:\Program Files\App\app.exe').IsValid

# --- Field model -------------------------------------------------------------
Write-Host "`nField model"

$field = New-FieldValue -Path 'application.name' -Value 'Python' -Source 'INSTALLER_METADATA' -Evidence 'ProductName'
Test-Case 'discovered field is FOUND'     ($field.State -eq 'FOUND')
Test-Case 'source sets confidence'        ($field.Confidence -eq 'HIGH')
Test-Case 'discovered field not confirmed' (-not $field.ConfirmedByUser)
Test-Case 'discovered field resolves'     (Test-FieldResolved -Field $field)

$userField = New-FieldValue -Path 'installer.path' -Value 'C:\a.exe' -Source 'USER_SELECTED'
Test-Case 'user value is CONFIRMED'       ($userField.State -eq 'CONFIRMED' -and $userField.ConfirmedByUser)

$unknown = New-UnknownFieldValue -Path 'installation.context'
Test-Case 'unknown does not resolve'      (-not (Test-FieldResolved -Field $unknown))
Test-Case 'unknown is not false'          ($null -eq $unknown.Value -and $unknown.State -eq 'UNKNOWN')

Set-FieldOverride -Field $field -Value 'Python 3' -Reason 'vendor naming' | Out-Null
Test-Case 'override applies value'        ($field.Value -eq 'Python 3')
Test-Case 'override keeps original'       ($field.OriginalValue -eq 'Python')
Test-Case 'override records reason'       ($field.OverrideReason -eq 'vendor naming')
Test-Case 'override is user-confirmed'    ($field.ConfirmedByUser)

Reset-FieldToDiscovered -Field $field | Out-Null
Test-Case 'reset restores discovered'     ($field.Value -eq 'Python' -and -not $field.ConfirmedByUser)
Test-Case 'history records every change'  ($field.History.Count -ge 3)

Test-Case 'higher source outranks lower'  ((Get-FieldSourceRank -Source 'CAPTURED') -gt (Get-FieldSourceRank -Source 'DERIVED'))
Test-Case 'empty string counts as empty'  (Test-FieldValueEmpty -Value '   ')
Test-Case 'empty array counts as empty'   (Test-FieldValueEmpty -Value @())

# --- Source arbitration ------------------------------------------------------
Write-Host "`nSource arbitration"

$arbitration = New-ProjectState -Root (Join-Path $WorkPath 'arbitration')

Set-ProjectField -Project $arbitration -Path 'application.version' -Value '5.1' -Source 'REGISTRY' | Out-Null
Set-ProjectField -Project $arbitration -Path 'application.version' -Value '5.2' -Source 'FILESYSTEM' | Out-Null
Test-Case 'lower-trust source loses'      ((Get-ProjectFieldValue -Project $arbitration -Path 'application.version') -eq '5.1')

Set-ProjectField -Project $arbitration -Path 'application.version' -Value '5.2' -Source 'CAPTURED' | Out-Null
Test-Case 'higher-trust source wins'      ((Get-ProjectFieldValue -Project $arbitration -Path 'application.version') -eq '5.2')

$versionField = Get-ProjectField -Project $arbitration -Path 'application.version'
Set-FieldOverride -Field $versionField -Value '5.3' -Reason 'known vendor error' | Out-Null
Set-ProjectField -Project $arbitration -Path 'application.version' -Value '5.2' -Source 'CAPTURED' | Out-Null
Test-Case 'user value survives discovery' ((Get-ProjectFieldValue -Project $arbitration -Path 'application.version') -eq '5.3')

Set-ProjectField -Project $arbitration -Path 'application.publisher' -Value 'Contoso' -Source 'REGISTRY' | Out-Null
Set-ProjectField -Project $arbitration -Path 'application.publisher' -Value 'Contoso Ltd' -Source 'REGISTRY' | Out-Null
Test-Case 'equal sources produce CONFLICT' ((Get-ProjectField -Project $arbitration -Path 'application.publisher').State -eq 'CONFLICT')

$conflict = Get-FieldConflict -Project $arbitration -Path 'application.publisher'
Test-Case 'conflict lists both values'    ($conflict.Candidates.Count -eq 2)
Test-Case 'conflict names a recommendation' ($null -ne $conflict.Recommended)
Test-Case 'conflict preserves evidence'   (@(Get-Fact -Store $arbitration.Evidence -Key 'application.publisher').Count -eq 2)

Resolve-FieldConflict -Project $arbitration -Path 'application.publisher' -Value 'Contoso Ltd' -Rationale 'legal name' | Out-Null
Test-Case 'resolved conflict is settled'  ((Get-ProjectField -Project $arbitration -Path 'application.publisher').State -eq 'CONFIRMED')
Test-Case 'resolution clears the report'  (@(Get-ProjectConflict -Project $arbitration | Where-Object { $_.Path -eq 'application.publisher' }).Count -eq 0)

# --- Facts and decisions -----------------------------------------------------
Write-Host "`nFacts and decisions"

$store = New-EvidenceStore
Add-Fact -Store $store -Key 'machinePathAdded' -Value 'C:\Program Files\Example\bin' -Source 'CAPTURED' | Out-Null
Set-Decision -Store $store -Key 'applyMachinePath' -Value $false -Rationale 'policy' | Out-Null

Test-Case 'fact survives the decision'    ((Get-Fact -Store $store -Key 'machinePathAdded')[0].Value -eq 'C:\Program Files\Example\bin')
Test-Case 'decision stored separately'    ((Get-Decision -Store $store -Key 'applyMachinePath').Value -eq $false)
Test-Case 'decision is recorded'          (Test-DecisionRecorded -Store $store -Key 'applyMachinePath')
Test-Case 'audit trail captures both'     ((Get-AuditTrail -Store $store).Count -ge 2)

Clear-Decision -Store $store -Key 'applyMachinePath' | Out-Null
Test-Case 'cleared decision is forgotten'  (-not (Test-DecisionRecorded -Store $store -Key 'applyMachinePath'))
Test-Case 'clearing keeps the fact'       ((Get-Fact -Store $store -Key 'machinePathAdded').Count -eq 1)

# --- Resource identity and recovery ------------------------------------------
Write-Host "`nResource identity and recovery"

$resourceRoot = Join-Path $WorkPath 'resources'
$installerPath = New-FakeInstaller -Path (Join-Path $resourceRoot 'source/Setup.exe')

$reference = New-ResourceReference -Id 'installer.primary' -Path $installerPath -ProjectRoot $resourceRoot
Test-Case 'reference stores relative path' ($reference.StoredPath -eq 'source/Setup.exe')
Test-Case 'stored path has no backslash'   ($reference.StoredPath -notmatch '\\')
Test-Case 'reference classifies type'      ($reference.Type -eq 'installer')
Test-Case 'reference records a hash'       ($reference.SHA256.Length -eq 64)

$anchors = @{ ProjectRoot = $resourceRoot }
Test-Case 'reference resolves in place'    (Resolve-ResourceReference -Reference $reference -Anchors $anchors).Found

New-Item -Path (Join-Path $resourceRoot 'moved') -ItemType Directory -Force | Out-Null
Move-Item -LiteralPath $installerPath -Destination (Join-Path $resourceRoot 'moved/Setup.exe')

$recovered = Resolve-ResourceReference -Reference $reference -Anchors $anchors
Test-Case 'moved file recovered by hash'   ($recovered.Found -and $recovered.Strategy -eq 'FileNameAndHash')

$duplicate = New-FakeInstaller -Path (Join-Path $resourceRoot 'other/Setup.exe') -Marker 'Inno Setup 6'
$ambiguous = Resolve-ResourceReference -Reference $reference -Anchors $anchors
Test-Case 'identical hash still wins'      ($ambiguous.Found -and $ambiguous.Strategy -eq 'FileNameAndHash')

$stale = $reference.PSObject.Copy()
$stale.SHA256 = ('0' * 64)
$unresolvable = Resolve-ResourceReference -Reference $stale -Anchors $anchors
Test-Case 'ambiguity is surfaced'          ($unresolvable.Strategy -eq 'AmbiguousCandidates' -and $unresolvable.Candidates.Count -ge 2)

Test-Case 'changed file detected'          (-not (Test-ResourceCurrent -Reference $stale -Path $duplicate).IsCurrent)

$candidates = Find-CandidateResource -Path $resourceRoot -Type @('installer') -Recurse
Test-Case 'candidate scan finds installers' ($candidates.Count -eq 2)

# --- Derivation from file names ----------------------------------------------
Write-Host "`nDerivation from file names"

Test-Case 'version after separator dot'  ((Get-VersionFromText -Text 'npp.8.6.2.Installer.x64.exe') -eq '8.6.2')
Test-Case 'version before extension'     ((Get-VersionFromText -Text 'Firefox Setup 120.0.1.exe') -eq '120.0.1')
Test-Case 'no version invented'          ((Get-VersionFromText -Text 'AcroRdrDC2300820470.exe') -eq '')
Test-Case 'architecture from amd64'      ((Get-ArchitectureFromText -Text 'Python-3.13.7-amd64.exe') -eq 'x64')
Test-Case 'architecture from win32'      ((Get-ArchitectureFromText -Text 'tool-win32.msi') -eq 'x86')
Test-Case 'no architecture invented'     ((Get-ArchitectureFromText -Text 'Firefox Setup.exe') -eq '')
Test-Case 'name drops version and arch'  ((Get-ApplicationNameFromFileName -FileName 'Python-3.13.7-amd64.exe') -eq 'Python')
Test-Case 'name drops noise words'       ((Get-ApplicationNameFromFileName -FileName 'Firefox Setup 120.0.1.exe') -eq 'Firefox')
Test-Case 'camel case split'             ((Get-ApplicationNameFromFileName -FileName 'GoogleChrome.msi') -eq 'Google Chrome')

Test-Case 'MSI recognised by extension'  ((Get-InstallerFamily -Path (Join-Path $resourceRoot 'other/Setup.exe')) -eq 'InnoSetup')
Test-Case 'family profile has switches'  ((Get-InstallerFamilyProfile -Family 'NSIS').Silent -eq '/S')
Test-Case 'unknown family has no profile' ($null -eq (Get-InstallerFamilyProfile -Family 'Unheard'))

# --- Command model -----------------------------------------------------------
Write-Host "`nCommand model"

$scriptCommand = New-PowerShellScriptCommand -ScriptName 'Install.ps1'
$rendered = ConvertTo-CommandString -Command $scriptCommand
# A path without whitespace is rendered unquoted. Quotes it does not need
# survive into every layer that later re-parses the command line, and cmd.exe
# strips the outermost pair of a /c string, which leaves the rest unbalanced.
Test-Case 'script command renders'       ($rendered -eq 'powershell.exe -NoProfile -ExecutionPolicy Bypass -NonInteractive -File ./Install.ps1') $rendered
Test-Case 'unneeded quotes not emitted'  ($rendered -notmatch '"')
# The stored command carries no backslash, so it survives JSON, a log and a
# report without turning into the doubled form that makes a config unreadable.
Test-Case 'command carries no backslash' ($rendered -notmatch '\\')

$spacedCommand = New-PowerShellScriptCommand -ScriptName 'Install Contoso.ps1'
Test-Case 'path with spaces is quoted'   ((ConvertTo-CommandString -Command $spacedCommand) -match '-File "\./Install Contoso\.ps1"')

# A command written before the separator changed still renders canonically.
Test-Case 'legacy relative prefix converted' (
    (ConvertTo-CommandString -Command (New-PowerShellScriptCommand -ScriptName '.\Install.ps1')) -eq $rendered
)
Test-Case 'generated command is valid'   (Test-StructuredCommand -Command $scriptCommand).IsValid

$roundTrip = ConvertFrom-CommandString -CommandLine $rendered
Test-Case 'round trip keeps executable'  ($roundTrip.Executable -eq 'powershell.exe')
Test-Case 'round trip keeps quoting'     ((ConvertTo-CommandString -Command $roundTrip) -eq $rendered)

$duplicated = New-StructuredCommand -Executable 'msiexec.exe' -Arguments @('/i', 'a.msi', '/qb', '/norestart', '/qb')
$commandCheck = Test-StructuredCommand -Command $duplicated
Test-Case 'duplicate argument flagged'   (@($commandCheck.Problems | Where-Object { $_ -match 'Duplicate' }).Count -eq 1)
Test-Case 'interactive argument flagged' (@($commandCheck.Problems | Where-Object { $_ -match 'desktop' }).Count -ge 1)

$missingInteractive = New-StructuredCommand -Executable 'powershell.exe' -Arguments @('-NoProfile', '-File', 'x.ps1')
Test-Case 'missing -NonInteractive flagged' (@((Test-StructuredCommand -Command $missingInteractive).Problems | Where-Object { $_ -match 'NonInteractive' }).Count -eq 1)

Test-Case 'MSI uninstall uses product code' ((ConvertTo-CommandString -Command (New-MsiUninstallCommand -ProductCode '{ABC}')) -eq 'msiexec.exe /x {ABC} /qn /norestart')

# --- Capture integration -----------------------------------------------------
Write-Host "`nCapture integration"

Test-Case 'common directory derived' ((Get-CommonDirectory -Path @(
    'C:\Program Files\Contoso\Reader\Reader.exe'
    'C:\Program Files\Contoso\Reader\lib\core.dll'
)) -eq 'C:/Program Files/Contoso/Reader')

Test-Case 'unrelated files give no root' ((Get-CommonDirectory -Path @('C:\A\x.txt', 'D:\B\y.txt')) -eq '')

Test-Case 'primary executable preferred' ((Select-PrimaryExecutable -Path @(
    'C:\Program Files\Contoso\Reader\unins000.exe'
    'C:\Program Files\Contoso\Reader\Reader.exe'
    'C:\Program Files\Contoso\Reader\bin\helper.exe'
) -ApplicationName 'Contoso Reader' -InstallLocation 'C:\Program Files\Contoso\Reader') -eq 'C:/Program Files/Contoso/Reader/Reader.exe')

Test-Case 'uninstaller never chosen' ((Select-PrimaryExecutable -Path @(
    'C:\Program Files\App\unins000.exe'
    'C:\Program Files\App\App.exe'
)) -notmatch 'unins')

# --- Installer evaluation ----------------------------------------------------
Write-Host "`nInstaller evaluation"

Test-Case 'EXE classified'  ((Get-InstallerKind -Path 'C:/a/Setup.exe') -eq 'EXE')
Test-Case 'MSI classified'  ((Get-InstallerKind -Path 'C:/a/App.msi') -eq 'MSI')
Test-Case 'CMD classified'  ((Get-InstallerKind -Path 'C:/a/Deploy.cmd') -eq 'CMD')
Test-Case 'BAT classified'  ((Get-InstallerKind -Path 'C:/a/Deploy.bat') -eq 'BAT')
Test-Case 'PS1 classified'  ((Get-InstallerKind -Path 'C:/a/Install.ps1') -eq 'PS1')
Test-Case 'MSIX classified' ((Get-InstallerKind -Path 'C:/a/App.msix') -eq 'MSIX')
Test-Case 'unknown stays unknown' ((Get-InstallerKind -Path 'C:/a/readme.txt') -eq 'Unknown')

$scriptWork = Join-Path $WorkPath 'scripts'
New-Item -Path $scriptWork -ItemType Directory -Force | Out-Null

@'
@echo off
REM This comment names setup.exe /shouldbeignored
:: so does this one
start /wait "%~dp0VendorSetup.exe" /silent /norestart
reg add "HKLM\Software\Vendor" /v Installed /t REG_DWORD /d 1 /f
setx VENDOR_HOME "C:\Program Files\Vendor"
xcopy config.xml "C:\ProgramData\Vendor\" /Y
'@ | Set-Content -LiteralPath (Join-Path $scriptWork 'Deploy.cmd')

$cmdAnalysis = Get-ScriptInstallerReference -Path (Join-Path $scriptWork 'Deploy.cmd')

Test-Case 'cmd wrapper finds one invocation' ($cmdAnalysis.Invocations.Count -eq 1) ($cmdAnalysis.Invocations.Count)
Test-Case 'cmd wrapper reads the executable' ($cmdAnalysis.Invocations[0].Executable -match 'VendorSetup\.exe')
Test-Case 'cmd wrapper reads the switches'   ($cmdAnalysis.Invocations[0].Arguments -eq '/silent /norestart')
Test-Case 'cmd comments are ignored'         ($cmdAnalysis.Invocations[0].Line -eq 4) $cmdAnalysis.Invocations[0].Line
Test-Case 'cmd registry work reported'       ($cmdAnalysis.RegistryOperations.Count -eq 1)
Test-Case 'cmd environment work reported'    ($cmdAnalysis.EnvironmentOperations.Count -eq 1)
Test-Case 'cmd file work reported'           ($cmdAnalysis.FileOperations.Count -eq 1)

@'
# Install the vendor package
$ErrorActionPreference = "Stop"
Start-Process -FilePath "msiexec.exe" -ArgumentList @("/i", "Vendor.msi", "/qn", "/norestart") -Wait
Start-Process -FilePath $ComputedInstaller -ArgumentList @("/S") -Wait
'@ | Set-Content -LiteralPath (Join-Path $scriptWork 'Install-Vendor.ps1')

$ps1Analysis = Get-ScriptInstallerReference -Path (Join-Path $scriptWork 'Install-Vendor.ps1')

Test-Case 'ps1 wrapper finds msiexec'      ($ps1Analysis.Invocations[0].Executable -eq 'msiexec.exe')
Test-Case 'ps1 wrapper reads argument list' ($ps1Analysis.Invocations[0].Arguments -eq '/i Vendor.msi /qn /norestart') $ps1Analysis.Invocations[0].Arguments
Test-Case 'ps1 wrapper knows it is an MSI'  ($ps1Analysis.Invocations[0].Kind -eq 'MSI')
# A target built from a variable is not a discovered installer.
Test-Case 'variable target not invented'    ($ps1Analysis.Invocations.Count -eq 1) ($ps1Analysis.Invocations.Count)

# THE RULE THIS ENFORCES: a silent switch that was not found stays empty. A
# guessed switch produces a package that installs interactively on every
# device, which is exactly the failure this tool exists to prevent.
$blankProject = New-ProjectState -Root (Join-Path $WorkPath 'noevidence')
$plainInstaller = Join-Path $WorkPath 'noevidence/source/Mystery.exe'
New-Item -Path (Split-Path $plainInstaller -Parent) -ItemType Directory -Force | Out-Null
[System.IO.File]::WriteAllBytes($plainInstaller, (Get-Latin1Encoding).GetBytes('MZ' + ('.' * 400)))

Invoke-InstallerDiscovery -Project $blankProject -InstallerPath $plainInstaller | Out-Null
Test-Case 'silent switches never invented' (-not (Test-ProjectFieldKnown -Project $blankProject -Path 'installer.silentArguments'))

# Detection is proposed from the strongest evidence, in a fixed order.
$msiDetection = New-DetectionProposal -ProductCode '{11111111-2222-3333-4444-555555555555}' `
                                      -PrimaryExecutable 'C:/PF/V/v.exe' -InstallLocation 'C:/PF/V'
Test-Case 'product code outranks a file' ($msiDetection.Type -eq 'MsiProductCode')
Test-Case 'product code is high confidence' ($msiDetection.Confidence -eq 'HIGH')

$fileDetection = New-DetectionProposal -PrimaryExecutable 'C:/Program Files/Vendor/Vendor.exe' `
                                       -ExpectedVersion '5.2.1' -InstallLocation 'C:/Program Files/Vendor'
Test-Case 'executable outranks a folder' ($fileDetection.Type -eq 'File')
Test-Case 'detection splits path and file' (
    $fileDetection.Path -eq 'C:/Program Files/Vendor' -and $fileDetection.Value -eq 'Vendor.exe'
)
Test-Case 'detection keeps the version' ($fileDetection.Version -eq '5.2.1')

$registryDetection = New-DetectionProposal -UninstallDisplayName 'Vendor App' -InstallLocation 'C:/PF/V'
Test-Case 'registry outranks a folder' ($registryDetection.Type -eq 'Registry')

$folderDetection = New-DetectionProposal -InstallLocation 'C:/Program Files/Vendor'
Test-Case 'folder is the last resort'   ($folderDetection.Type -eq 'Folder')
# A folder commonly survives an uninstall, so it cannot prove removal.
Test-Case 'folder detection flagged weak' (-not $folderDetection.IsReliable)
Test-Case 'folder detection is low confidence' ($folderDetection.Confidence -eq 'LOW')

$noDetection = New-DetectionProposal
Test-Case 'no evidence proposes nothing' ($noDetection.Type -eq '')

# Uninstall: the vendor's own quiet string first, then an exact MSI command.
$quietProposal = New-UninstallProposal -Registration ([PSCustomObject]@{
    QuietUninstallString = '"C:\PF\V\unins.exe" /quiet'
    UninstallString      = '"C:\PF\V\unins.exe"'
    ProductCode          = 'Vendor'
})
Test-Case 'quiet uninstall preferred'   ($quietProposal.Command -match '/quiet')
Test-Case 'quiet uninstall needs no review' (-not $quietProposal.RequiresReview)

$msiProposal = New-UninstallProposal -Registration ([PSCustomObject]@{
    QuietUninstallString = ''
    UninstallString      = 'MsiExec.exe /X{11111111-2222-3333-4444-555555555555}'
    ProductCode          = '{11111111-2222-3333-4444-555555555555}'
})
Test-Case 'product code gives a silent uninstall' ($msiProposal.Command -eq 'msiexec.exe /x {11111111-2222-3333-4444-555555555555} /qn /norestart') $msiProposal.Command

# A bare uninstall string is not known to run unattended, so it is not assumed to.
$bareProposal = New-UninstallProposal -Registration ([PSCustomObject]@{
    QuietUninstallString = ''
    UninstallString      = '"C:\PF\V\unins.exe"'
    ProductCode          = 'Vendor'
})
Test-Case 'bare uninstall flagged for review' ($bareProposal.RequiresReview)
Test-Case 'bare uninstall gains no switch'    ($bareProposal.Command -eq '"C:\PF\V\unins.exe"')

$noProposal = New-UninstallProposal -Registration ([PSCustomObject]@{
    QuietUninstallString = ''; UninstallString = ''; ProductCode = 'Vendor'
})
Test-Case 'no uninstall string proposes nothing' ($noProposal.Command -eq '')

# A wrapper script resolves to the installer it actually runs, and the switches
# written in the script outrank a toolkit default.
$wrapperProject = New-ProjectState -Root (Join-Path $WorkPath 'wrapperproj')
$wrapperSource = Join-Path $WorkPath 'wrapperproj/source'
New-Item -Path $wrapperSource -ItemType Directory -Force | Out-Null
New-FakeInstaller -Path (Join-Path $wrapperSource 'VendorSetup-5.2.1-x64.exe') | Out-Null

@'
@echo off
start /wait "%~dp0VendorSetup-5.2.1-x64.exe" /VERYSILENT /NORESTART
'@ | Set-Content -LiteralPath (Join-Path $wrapperSource 'Deploy.cmd')

$wrapperEvaluation = Invoke-InstallerEvaluation -Project $wrapperProject -Path (Join-Path $wrapperSource 'Deploy.cmd')

Test-Case 'wrapper resolves to the installer' ($wrapperEvaluation.EvaluatedPath -match 'VendorSetup-5\.2\.1-x64\.exe')
Test-Case 'wrapper reports the toolkit'       ($wrapperEvaluation.InstallerFamily -eq 'NSIS')
Test-Case 'script switches beat the default'  ((Get-ProjectFieldValue -Project $wrapperProject -Path 'installer.silentArguments') -eq '/VERYSILENT /NORESTART')
Test-Case 'identity derived from the installer' ((Get-ProjectFieldValue -Project $wrapperProject -Path 'application.version') -eq '5.2.1')

$wrapperCompleteness = Test-EvaluationComplete -Project $wrapperProject
Test-Case 'incomplete evaluation names what is missing' ($wrapperCompleteness.Missing.Count -gt 0)
Test-Case 'incomplete evaluation blocks'                (-not $wrapperCompleteness.IsComplete)

$wrapperSummary = @(Get-EvaluationSummary -Project $wrapperProject)
Test-Case 'summary reports undetected values' (@($wrapperSummary | Where-Object { -not $_.Detected }).Count -gt 0)
Test-Case 'summary carries confidence'        (@($wrapperSummary | Where-Object { $_.Detected -and $_.Confidence }).Count -gt 0)

# --- Requirements and completeness -------------------------------------------
Write-Host "`nRequirements and completeness"

$requirement = Get-OperationRequirement -Operation 'BuildPackage'
Test-Case 'build requires information'   ($requirement.Required.Count -gt 0)
Test-Case 'requirements sorted by priority' ($requirement.Required[0].PriorityRank -le $requirement.Required[-1].PriorityRank)

$detectionRequirement = Get-OperationRequirement -Operation 'GenerateDetection'
Test-Case 'operations differ in needs'   ($detectionRequirement.Required.Count -lt $requirement.Required.Count)
Test-Case 'detection needs an executable' ('installation.executable' -in @($detectionRequirement.Required.Path))

# Conventions that follow from creating a project are derived, not asked for.
$initialised = Initialize-InformationProject -Root (Join-Path $WorkPath 'initialised')
Test-Case 'output directory derived'     (Test-ProjectFieldKnown -Project $initialised -Path 'package.outputDirectory')
Test-Case 'first package version derived' ((Get-ProjectFieldValue -Project $initialised -Path 'deployment.packageVersion') -eq '1.0.0')
Test-Case 'derived value is not confirmed' (-not (Get-ProjectField -Project $initialised -Path 'deployment.packageVersion').ConfirmedByUser)

$empty = New-ProjectState -Root (Join-Path $WorkPath 'empty')
$emptyReadiness = Get-OperationReadiness -Project $empty -Operation 'BuildPackage'
Test-Case 'empty project cannot build'   (-not $emptyReadiness.CanProceed)
Test-Case 'blockers are listed'          ($emptyReadiness.Blockers.Count -gt 0)
Test-Case 'blockers ordered by priority' ($emptyReadiness.Blockers[0].Rank -le $emptyReadiness.Blockers[-1].Rank)

$emptyCompleteness = Get-ProjectCompleteness -Project $empty -Operation 'BuildPackage'
Test-Case 'empty project scores zero'    ($emptyCompleteness.Readiness -eq 0)
Test-Case 'completeness reports blockers' ($emptyCompleteness.BlockerCount -gt 0)

# --- Acceptance scenario -----------------------------------------------------
Write-Host "`nAcceptance scenario"

$projectRoot = Join-Path $WorkPath 'acceptance'
$sourceDirectory = Join-Path $projectRoot 'source'
New-FakeInstaller -Path (Join-Path $sourceDirectory 'ContosoReader-4.2.1-x64.exe') | Out-Null

# 1-3. A new project and one installer selection.
$project = Initialize-InformationProject -Root $projectRoot -Name 'Contoso Reader'
$selection = Select-ProjectInstaller -Project $project -Path (Join-Path $sourceDirectory 'ContosoReader-4.2.1-x64.exe')

Test-Case 'installer registered as a resource' ($null -ne (Get-ProjectResource -Project $project -Id 'installer.primary'))
Test-Case 'installer family identified'        ($selection.Family -eq 'NSIS')

# 4-5. Metadata and behaviour populate without any prompting.
Test-Case 'name discovered'         ((Get-ProjectFieldValue -Project $project -Path 'application.name') -eq 'Contoso Reader')
Test-Case 'version discovered'      ((Get-ProjectFieldValue -Project $project -Path 'application.version') -eq '4.2.1')
Test-Case 'architecture discovered' ((Get-ProjectFieldValue -Project $project -Path 'application.architecture') -eq 'x64')
Test-Case 'installer type derived'  ((Get-ProjectFieldValue -Project $project -Path 'installer.type') -eq 'EXE')
Test-Case 'silent switches derived' ((Get-ProjectFieldValue -Project $project -Path 'installer.silentArguments') -eq '/S')
Test-Case 'exit codes derived'      (@(Get-ProjectFieldValue -Project $project -Path 'deployment.expectedExitCodes') -contains 0)
Test-Case 'package source derived'  (Test-ProjectFieldKnown -Project $project -Path 'package.sourceDirectory')

$afterSelection = @(Get-PendingPrompt -Project $project -Operation 'BuildPackage').Path
Test-Case 'installer never re-asked'  ('installer.path' -notin $afterSelection)
Test-Case 'name never re-asked'       ('application.name' -notin $afterSelection)
Test-Case 'version never re-asked'    ('application.version' -notin $afterSelection)

# 6-12. Capture publishes what it observed.
$delta = New-FakeDelta -Files @(
    'C:\Program Files\Contoso\Reader\Reader.exe'
    'C:\Program Files\Contoso\Reader\lib\core.dll'
    'C:\Program Files\Contoso\Reader\unins000.exe'
) -PathAdded @('C:\Program Files\Contoso\Reader\bin') `
  -Shortcuts @('C:\Users\Public\Desktop\Contoso Reader.lnk') `
  -Applications @('Contoso Reader|4.2.1|{11111111-2222-3333-4444-555555555555}')

$capture = Import-CaptureResult -Project $project -Delta $delta

Test-Case 'install location captured' ((Get-ProjectFieldValue -Project $project -Path 'installation.installLocation') -eq 'C:/Program Files/Contoso/Reader')
Test-Case 'executable captured'       ((Get-ProjectFieldValue -Project $project -Path 'installation.executable') -eq 'C:/Program Files/Contoso/Reader/Reader.exe')
Test-Case 'uninstall name captured'   ((Get-ProjectFieldValue -Project $project -Path 'installation.uninstallDisplayName') -eq 'Contoso Reader')
Test-Case 'product code captured'     ((Get-ProjectFieldValue -Project $project -Path 'installer.productCode') -match '^\{1{8}')
Test-Case 'PATH change captured'      (@(Get-ProjectFieldValue -Project $project -Path 'installation.machinePath').Count -eq 1)

# 13-14. Only policy is left outstanding; captured values are never re-asked.
$capturePrompts = @(Get-CaptureDecisionPrompt -Project $project)
$capturePaths   = @($capturePrompts.Path)

Test-Case 'capture raises policy decisions' ($capturePrompts.Count -eq 2)
Test-Case 'PATH policy asked'               ('decision.applyMachinePath' -in $capturePaths)
Test-Case 'shortcut policy asked'           ('decision.createDesktopShortcut' -in $capturePaths)
Test-Case 'install location not asked'      ('installation.installLocation' -notin $capturePaths)
Test-Case 'executable not asked'            ('installation.executable' -notin $capturePaths)
Test-Case 'policy prompt shows evidence'    (@($capturePrompts | Where-Object { $_.Path -eq 'decision.applyMachinePath' })[0].Observed.Count -eq 1)

# 15. Each decision is answered once.
foreach ($prompt in $capturePrompts) {
    Resolve-InformationPrompt -Project $project -Path $prompt.Path -Value $false -Method 'Choice' -Rationale 'deployment policy' | Out-Null
}

Test-Case 'decisions are remembered'   (@(Get-CaptureDecisionPrompt -Project $project).Count -eq 0)
Test-Case 'observed fact still intact'  (@(Get-ProjectFieldValue -Project $project -Path 'installation.machinePath').Count -eq 1)
Test-Case 'decision differs from fact'  ((Get-Decision -Store $project.Evidence -Key 'decision.applyMachinePath').Value -eq $false)

# 16-17. Commands are generated, not typed.
$blueprint = New-DeploymentBlueprint -Project $project -UseWrapperScripts
Test-Case 'install command generated'   ($blueprint.Install.Rendered -match 'Install\.ps1')
Test-Case 'uninstall command generated' ($blueprint.Uninstall.Rendered -match 'Uninstall\.ps1')
Test-Case 'generated command is valid'  (Test-StructuredCommand -Command $blueprint.Install.Structured).IsValid

# UI mode: detected silent switches make Silent the default and are carried.
# Read-only against the acceptance project, so it is left in the detected state
# the manifest section below depends on.
Test-Case 'ui mode defaults to Silent'      ((Get-ProjectFieldValue -Project $project -Path 'installer.uiMode') -eq 'Silent')
Test-Case 'silent command carries the mode' ($blueprint.Install.Rendered -match '-UiMode Silent')
Test-Case 'silent command carries switches' ($blueprint.Install.Rendered -match '(?<!\S)/S(?!\S)')

# Remaining questions are genuine policy, asked once and in priority order.
$remaining = @(Get-PendingPrompt -Project $project -Operation 'BuildPackage')
$remainingPaths = @($remaining.Path)

Test-Case 'install context still needed' ('installation.context' -in $remainingPaths)
Test-Case 'nothing discovered is asked'  (@($remainingPaths | Where-Object { $_ -in @(
    'installer.path', 'installer.type', 'installer.fileName', 'application.name'
    'application.version', 'application.architecture', 'installation.installLocation'
    'installation.executable', 'deployment.installCommand', 'deployment.uninstallCommand'
)}).Count -eq 0)

$contextPrompt = @($remaining | Where-Object { $_.Path -eq 'installation.context' })[0]
Test-Case 'prompt explains why'          ($contextPrompt.Why -match 'SYSTEM')
Test-Case 'prompt offers choices'        ($contextPrompt.Choices -contains 'System')
Test-Case 'prompt marked as decision'    ($contextPrompt.IsDecision)

foreach ($prompt in $remaining) {
    $value = switch ($prompt.Path) {
        'installation.context'          { 'System' }
        'deployment.rebootBehavior'     { 'BasedOnReturnCode' }
        'deployment.packageVersion'     { '1.0.0' }
        'package.intuneWinAppUtilPath'  { New-FakeInstaller -Path (Join-Path $projectRoot 'tools/IntuneWinAppUtil.exe') }
        'deployment.detectionMethod'    { 'Script' }
        default                         { 'System' }
    }
    Resolve-InformationPrompt -Project $project -Path $prompt.Path -Value $value -Method 'Choice' | Out-Null
}

$afterAnswers = @(Get-PendingPrompt -Project $project -Operation 'BuildPackage')
Test-Case 'nothing is asked twice'      ($afterAnswers.Count -eq 0)
Test-Case 'build is now ready'          (Test-OperationReady -Project $project -Operation 'BuildPackage')

$completeness = Get-ProjectCompleteness -Project $project -Operation 'BuildPackage'
Test-Case 'readiness reaches ninety'    ($completeness.Readiness -ge 90)
Test-Case 'no blockers remain'          ($completeness.BlockerCount -eq 0)

# 18-20. The manifest the build consumes comes from the same information.
$manifest = Export-ProjectManifest -Project $project
Test-Case 'manifest is valid'           (Test-PackageManifest -Manifest $manifest).IsValid
Test-Case 'manifest reuses the name'    ($manifest.ApplicationName -eq 'Contoso Reader')
Test-Case 'manifest reuses the command' ($manifest.InstallCommand -eq $blueprint.Install.Rendered)
Test-Case 'manifest reuses the context' ($manifest.InstallBehavior -eq 'System')

# 21. Reopening the project asks nothing.
Save-ProjectState -Project $project | Out-Null
$reopened = Initialize-InformationProject -Root $projectRoot

Test-Case 'reopened project keeps fields' ($reopened.Fields.Count -eq $project.Fields.Count)

# A project written before the canonical separator changed must repair itself
# on load, and must touch only values the catalog declares to be paths.
$legacyRoot = Join-Path $WorkPath 'legacy'
New-FakeInstaller -Path (Join-Path $legacyRoot 'source/Setup.exe') | Out-Null

$legacyProject = New-ProjectState -Root $legacyRoot
Set-ProjectField -Project $legacyProject -Path 'installer.path' -Value 'source\Setup.exe' -Source 'USER_SELECTED' | Out-Null
Set-ProjectField -Project $legacyProject -Path 'installation.installLocation' -Value 'C:\Program Files\Contoso' -Source 'CAPTURED' | Out-Null
Set-ProjectField -Project $legacyProject -Path 'installation.registryKeys' -Value @('HKLM:\SOFTWARE\Contoso') -Source 'CAPTURED' | Out-Null
Set-ProjectField -Project $legacyProject -Path 'deployment.installCommand' -Value 'powershell.exe -File .\Install.ps1' -Source 'PREVIOUS_BUILD' | Out-Null
$legacyProject.Resources['installer.primary'] = [PSCustomObject]@{ StoredPath = 'source\Setup.exe' }

$rewrittenPaths = @(Update-ProjectPathFormat -Project $legacyProject)

Test-Case 'legacy path field normalized'   ((Get-ProjectFieldValue -Project $legacyProject -Path 'installer.path') -eq 'source/Setup.exe')
Test-Case 'legacy directory normalized'    ((Get-ProjectFieldValue -Project $legacyProject -Path 'installation.installLocation') -eq 'C:/Program Files/Contoso')
Test-Case 'legacy resource normalized'     ($legacyProject.Resources['installer.primary'].StoredPath -eq 'source/Setup.exe')
Test-Case 'migration reports what changed' ($rewrittenPaths.Count -eq 3) ($rewrittenPaths -join ', ')

# Backslashes are legitimate in these, and rewriting them would corrupt the
# value. Neither is declared a Path or a Directory, so neither is touched.
Test-Case 'registry key left alone' (
    @(Get-ProjectFieldValue -Project $legacyProject -Path 'installation.registryKeys')[0] -eq 'HKLM:\SOFTWARE\Contoso'
)
Test-Case 'command left alone' (
    (Get-ProjectFieldValue -Project $legacyProject -Path 'deployment.installCommand') -eq 'powershell.exe -File .\Install.ps1'
)
Test-Case 'second migration is a no-op' (@(Update-ProjectPathFormat -Project $legacyProject).Count -eq 0)
Test-Case 'reopened project asks nothing' (@(Get-PendingPrompt -Project $reopened -Operation 'BuildPackage').Count -eq 0)
Test-Case 'reopened project keeps decisions' ((Get-Decision -Store $reopened.Evidence -Key 'decision.applyMachinePath').Value -eq $false)
Test-Case 'reopened project keeps evidence'  (@(Get-Fact -Store $reopened.Evidence -Key 'application.name').Count -ge 1)

# --- UI mode overrides (isolated project) ------------------------------------
# The administrator can override the detected UI behaviour before building, and
# the install and uninstall UI modes are configured independently. Run on a
# throwaway project so the acceptance state above is untouched.
Write-Host "`nUI mode overrides"

$modeRoot = Join-Path $WorkPath 'ui-mode'
New-FakeInstaller -Path (Join-Path $modeRoot 'source/ContosoReader-4.2.1-x64.exe') | Out-Null
$modeProject = Initialize-InformationProject -Root $modeRoot -Name 'Contoso Reader'
Select-ProjectInstaller -Project $modeProject -Path (Join-Path $modeRoot 'source/ContosoReader-4.2.1-x64.exe') | Out-Null

# Detected default carries the switches and the mode.
$silentBp = New-DeploymentBlueprint -Project $modeProject -UseWrapperScripts
Test-Case 'default mode is Silent'          ((Get-ProjectFieldValue -Project $modeProject -Path 'installer.uiMode') -eq 'Silent')
Test-Case 'silent carries switches'         ($silentBp.Install.Rendered -match '(?<!\S)/S(?!\S)')

# Administrator override to NormalUI: the same installer is packaged to show
# its UI, and its silent switches are deliberately not passed.
Set-ProjectField -Project $modeProject -Path 'installer.uiMode' -Value 'NormalUI' `
    -Source 'USER_SELECTED' -Evidence 'Administrator chose an interactive install' | Out-Null
$normalBp = New-DeploymentBlueprint -Project $modeProject -UseWrapperScripts
Test-Case 'NormalUI carries the mode'       ($normalBp.Install.Rendered -match '-UiMode NormalUI')
Test-Case 'NormalUI drops silent switches'  ($normalBp.Install.Rendered -notmatch '(?<!\S)/S(?!\S)')
Test-Case 'NormalUI install still valid'    (Test-StructuredCommand -Command $normalBp.Install.Structured).IsValid

# Uninstall UI mode is independent of the install mode.
Set-ProjectField -Project $modeProject -Path 'installer.uninstallUiMode' -Value 'Silent' `
    -Source 'USER_SELECTED' -Evidence 'Uninstall stays silent regardless of install UI' | Out-Null
$mixedBp = New-DeploymentBlueprint -Project $modeProject -UseWrapperScripts
Test-Case 'uninstall mode independent'      ($mixedBp.Uninstall.Rendered -match '-UiMode Silent')

# The mode round-trips through the manifest. Satisfy the remaining build
# prerequisites on the throwaway project so the export can run.
New-FakeInstaller -Path (Join-Path $modeRoot 'tools/IntuneWinAppUtil.exe') | Out-Null
foreach ($prompt in @(Get-PendingPrompt -Project $modeProject -Operation 'BuildPackage')) {
    $value = switch ($prompt.Path) {
        'installation.context'         { 'System' }
        'deployment.rebootBehavior'    { 'BasedOnReturnCode' }
        'deployment.packageVersion'    { '1.0.0' }
        'deployment.detectionMethod'   { 'Script' }
        'package.intuneWinAppUtilPath' { Join-Path $modeRoot 'tools/IntuneWinAppUtil.exe' }
        default                        { 'System' }
    }
    Resolve-InformationPrompt -Project $modeProject -Path $prompt.Path -Value $value -Method 'Choice' | Out-Null
}
$modeManifest = Export-ProjectManifest -Project $modeProject
Test-Case 'manifest records UiMode'          ($modeManifest.UiMode -eq 'NormalUI')
Test-Case 'manifest records UninstallUiMode' ($modeManifest.UninstallUiMode -eq 'Silent')
Test-Case 'manifest with modes is valid'     (Test-PackageManifest -Manifest $modeManifest).IsValid

# 22-23. A new version reuses the previous build and asks only about changes.
$manifestPath = Join-Path $WorkPath 'previous-manifest.json'
Save-PackageManifest -Manifest $manifest -Path $manifestPath | Out-Null

$nextRoot = Join-Path $WorkPath 'next-version'
New-FakeInstaller -Path (Join-Path $nextRoot 'source/ContosoReader-4.2.2-x64.exe') | Out-Null

$nextProject = Initialize-InformationProject -Root $nextRoot -Name 'Contoso Reader'
Select-ProjectInstaller -Project $nextProject -Path (Join-Path $nextRoot 'source/ContosoReader-4.2.2-x64.exe') | Out-Null
$reuse = Import-PreviousBuild -Project $nextProject -ManifestPath $manifestPath

Test-Case 'previous build imported'      ($reuse.FieldsImported.Count -ge 6)
Test-Case 'identity not overwritten'     ('application.version' -notin $reuse.FieldsImported)
Test-Case 'previous context reused'      ((Get-ProjectFieldValue -Project $nextProject -Path 'installation.context') -eq 'System')
Test-Case 'previous commands reused'     ((Get-ProjectFieldValue -Project $nextProject -Path 'deployment.installCommand') -eq $blueprint.Install.Rendered)
Test-Case 'new version keeps its own'    ((Get-ProjectFieldValue -Project $nextProject -Path 'application.version') -eq '4.2.2')
Test-Case 'version change reported'      (@($reuse.Changes | Where-Object { $_.Path -eq 'application.version' }).Count -eq 1)

$nextPending = @(Get-PendingPrompt -Project $nextProject -Operation 'BuildPackage').Path
Test-Case 'reuse removes settled questions' ('installation.context' -notin $nextPending)
Test-Case 'unmet needs still surface'       ('package.intuneWinAppUtilPath' -in $nextPending)

# --- Inventory and review ----------------------------------------------------
Write-Host "`nInventory and review"

$inventory = Get-InformationInventory -Project $project
Test-Case 'inventory lists known fields' ($inventory.Count -gt 10)
Test-Case 'inventory reports sources'    (@($inventory | Where-Object { $_.Source }).Count -gt 0)
Test-Case 'inventory offers actions'     (@($inventory | Where-Object { 'ViewEvidence' -in $_.Actions }).Count -gt 0)

$overridden = @($inventory | Where-Object { $_.Path -eq 'installation.context' })[0]
Test-Case 'confirmed value shows source' ($overridden.Confidence -eq 'CONFIRMED')

$review = New-InformationReview -Project $project
Test-Case 'review reports ready'         ($review.IsReady)
Test-Case 'review summarises the package' ($review.Summary.Count -ge 8)
Test-Case 'review shows observed changes' ($review.Observed.Count -ge 2)
Test-Case 'review pairs fact and decision' ($review.Observed['Machine PATH Addition'].Decision -eq $false)
Test-Case 'nothing required is outstanding' (@($review.Outstanding | Where-Object { $_.IsRequired }).Count -eq 0)
# Recommended gaps are reported rather than hidden, but they do not block.
Test-Case 'recommended gaps still surface'  (@($review.Outstanding | Where-Object { -not $_.IsRequired }).Count -gt 0)

$blockedReview = New-InformationReview -Project $empty
Test-Case 'incomplete project is not ready' (-not $blockedReview.IsReady)
Test-Case 'incomplete project lists gaps'   ($blockedReview.Outstanding.Count -gt 0)

# --- Result ------------------------------------------------------------------
Remove-Item -LiteralPath $WorkPath -Recurse -Force -ErrorAction SilentlyContinue

Write-Host ""
if ($script:failures -eq 0) {
    Write-Host "ALL TESTS PASSED" -ForegroundColor Green
    exit 0
}

Write-Host "$($script:failures) TEST(S) FAILED" -ForegroundColor Red
exit 1
