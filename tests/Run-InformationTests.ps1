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
    [System.IO.File]::WriteAllBytes($Path, [System.Text.Encoding]::Latin1.GetBytes($content))
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

Test-Case 'forward slashes normalized'   ((ConvertTo-CanonicalPath -Path 'C:/Build/App') -eq 'C:\Build\App')
Test-Case 'trailing separator stripped'  ((ConvertTo-CanonicalPath -Path 'C:\Build\App\') -eq 'C:\Build\App')
Test-Case 'dot segments collapsed'       ((ConvertTo-CanonicalPath -Path 'C:\Build\.\A\..\B') -eq 'C:\Build\B')
Test-Case 'drive root keeps separator'   ((ConvertTo-CanonicalPath -Path 'C:\') -eq 'C:\')
Test-Case 'UNC prefix preserved'         ((ConvertTo-CanonicalPath -Path '\\srv\share\a.msi') -eq '\\srv\share\a.msi')
Test-Case 'relative prefix dropped'      ((ConvertTo-CanonicalPath -Path '.\Source\App') -eq 'Source\App')

# System.IO.Path only honours the running platform's separator, so canonical
# Windows paths have to be split here or they come back empty off Windows.
Test-Case 'parent of a nested path'      ((Split-CanonicalPath -Path 'C:\A\B\c.exe') -eq 'C:\A\B')
Test-Case 'parent at the drive root'     ((Split-CanonicalPath -Path 'C:\c.exe') -eq 'C:\')
Test-Case 'bare name has no parent'      ((Split-CanonicalPath -Path 'c.exe') -eq '')
Test-Case 'parent of a UNC path'         ((Split-CanonicalPath -Path '\\srv\share\dir\a.msi') -eq '\\srv\share\dir')
Test-Case 'UNC share has no parent'      ((Split-CanonicalPath -Path '\\srv\share') -eq '')
Test-Case 'leaf of a windows path'       ((Get-CanonicalLeaf -Path 'C:\A\B\c.exe') -eq 'c.exe')
Test-Case 'extension of a windows path'  ((Get-CanonicalExtension -Path 'C:\A\B\c.exe') -eq '.exe')
Test-Case 'dotted directory ignored'     ((Get-CanonicalExtension -Path 'C:\A.v2\readme') -eq '')
Test-Case 'base name drops extension'    ((Get-CanonicalBaseName -Path 'C:\A\B\c.tar.gz') -eq 'c.tar')

Test-Case 'absolute path detected'       (Test-AbsolutePath -Path 'C:\Build')
Test-Case 'relative path detected'       (-not (Test-AbsolutePath -Path 'Source\App'))

Test-Case 'inside project becomes relative' ((ConvertTo-RelativePath -Path 'C:\P\Source\a.exe' -BasePath 'C:\P') -eq 'Source\a.exe')
Test-Case 'outside project stays absolute'  ((ConvertTo-RelativePath -Path 'D:\X\a.exe' -BasePath 'C:\P') -eq '')

$storable = ConvertTo-StorablePath -Path 'C:\P\Source\a.exe' -ProjectRoot 'C:\P'
Test-Case 'storable path is relative'    ($storable.StoredPath -eq 'Source\a.exe' -and -not $storable.IsExternal)

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
Test-Case 'reference stores relative path' ($reference.StoredPath -eq 'source\Setup.exe')
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
Test-Case 'script command renders'       ($rendered -eq 'powershell.exe -NoProfile -ExecutionPolicy Bypass -NonInteractive -File ".\Install.ps1"')
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
)) -eq 'C:\Program Files\Contoso\Reader')

Test-Case 'unrelated files give no root' ((Get-CommonDirectory -Path @('C:\A\x.txt', 'D:\B\y.txt')) -eq '')

Test-Case 'primary executable preferred' ((Select-PrimaryExecutable -Path @(
    'C:\Program Files\Contoso\Reader\unins000.exe'
    'C:\Program Files\Contoso\Reader\Reader.exe'
    'C:\Program Files\Contoso\Reader\bin\helper.exe'
) -ApplicationName 'Contoso Reader' -InstallLocation 'C:\Program Files\Contoso\Reader') -eq 'C:\Program Files\Contoso\Reader\Reader.exe')

Test-Case 'uninstaller never chosen' ((Select-PrimaryExecutable -Path @(
    'C:\Program Files\App\unins000.exe'
    'C:\Program Files\App\App.exe'
)) -notmatch 'unins')

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

Test-Case 'install location captured' ((Get-ProjectFieldValue -Project $project -Path 'installation.installLocation') -eq 'C:\Program Files\Contoso\Reader')
Test-Case 'executable captured'       ((Get-ProjectFieldValue -Project $project -Path 'installation.executable') -eq 'C:\Program Files\Contoso\Reader\Reader.exe')
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
Test-Case 'reopened project asks nothing' (@(Get-PendingPrompt -Project $reopened -Operation 'BuildPackage').Count -eq 0)
Test-Case 'reopened project keeps decisions' ((Get-Decision -Store $reopened.Evidence -Key 'decision.applyMachinePath').Value -eq $false)
Test-Case 'reopened project keeps evidence'  (@(Get-Fact -Store $reopened.Evidence -Key 'application.name').Count -ge 1)

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
