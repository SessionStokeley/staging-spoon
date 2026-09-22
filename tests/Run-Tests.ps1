<#
.SYNOPSIS
    Tests for the platform-independent validation modules.
.DESCRIPTION
    Covers path classification, command parsing, manifest validation, failure
    classification, the pre-build gate, config export and report rendering.
    Runs on Linux or Windows; deployment validation itself requires Windows.
.EXAMPLE
    pwsh -NoProfile -File .\tests\Run-Tests.ps1
#>

[CmdletBinding()]
param([string]$WorkPath = (Join-Path ([System.IO.Path]::GetTempPath()) 'staging-spoon-tests'))

$ErrorActionPreference = 'Stop'

$repo = Split-Path $PSScriptRoot -Parent
. (Join-Path $repo 'src/Core/PreBuildValidator.ps1')
. (Join-Path $repo 'src/Testing/SystemContext.ps1')
. (Join-Path $repo 'src/Core/FailureClassifier.ps1')
. (Join-Path $repo 'src/Reporting/Export-IntuneConfiguration.ps1')
. (Join-Path $repo 'src/Reporting/New-ValidationReport.ps1')

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

Remove-Item -LiteralPath $WorkPath -Recurse -Force -ErrorAction SilentlyContinue
New-Item -Path $WorkPath -ItemType Directory -Force | Out-Null

# --- Command parsing ---------------------------------------------------------
Write-Host "`nCommand parsing"

$parsed = ConvertFrom-CommandLine -CommandLine 'powershell.exe -NoProfile -ExecutionPolicy Bypass -File ".\Install.ps1"'
Test-Case 'executable extracted' ($parsed.Executable -eq 'powershell.exe') $parsed.Executable
Test-Case 'quoted argument unwrapped' ($parsed.Arguments[-1] -eq '.\Install.ps1') $parsed.Arguments[-1]

Test-Case 'flags msiexec /qb'  (@(Find-InteractiveArgument -CommandLine 'msiexec /i a.msi /qb').Count -eq 1)
Test-Case 'allows msiexec /qn' (@(Find-InteractiveArgument -CommandLine 'msiexec /i a.msi /qn').Count -eq 0)
Test-Case 'flags /passive'     (@(Find-InteractiveArgument -CommandLine 'setup.exe /passive').Count -eq 1)

Test-Case 'finds duplicate switch' (@(Find-DuplicateArgument -CommandLine 'setup.exe /S /norestart /S').Count -eq 1)
Test-Case 'no false duplicate'     (@(Find-DuplicateArgument -CommandLine 'msiexec /i a.msi /qn /norestart').Count -eq 0)

Test-Case 'comparison ignores whitespace' (Compare-IntuneCommand -TestedCommand 'a.exe  /S' -IntuneCommand 'a.exe /S' -CommandType 'Install').Matches
Test-Case 'comparison detects drift' (-not (Compare-IntuneCommand -TestedCommand 'a.exe /S' -IntuneCommand 'a.exe /quiet' -CommandType 'Install').Matches)

# --- Path classification -----------------------------------------------------
Write-Host "`nPath classification"

Test-Case 'Program Files is valid'      ((Get-PathClassification -Path 'C:\Program Files\Vendor\App').Classification -eq 'VALID')
Test-Case 'ProgramData is valid'        ((Get-PathClassification -Path 'C:\ProgramData\Vendor\cfg.xml').Classification -eq 'VALID')
Test-Case 'developer profile invalid'   ((Get-PathClassification -Path 'C:\Users\Developer\Desktop\App\Installer.exe').Classification -eq 'INVALID')
Test-Case 'build directory invalid'     ((Get-PathClassification -Path 'C:\Build\App\Installer.exe').Classification -eq 'INVALID')
Test-Case 'UNC path invalid'            ((Get-PathClassification -Path '\\server\share\app.msi').Classification -eq 'INVALID')
Test-Case 'non-system drive invalid'    ((Get-PathClassification -Path 'D:\Apps\thing.exe').Classification -eq 'INVALID')
# An all-users shortcut legitimately lives under the Public profile.
Test-Case 'Public profile not flagged'  ((Get-PathClassification -Path 'C:\Users\Public\Desktop\a.lnk').Classification -ne 'INVALID')

# Paths with spaces must survive extraction intact. Truncating
# "C:\Program Files\Vendor\App" at the space leaves "C:\Program", which matches
# no known-good location and warns on essentially every real package.
$spacedSource = Join-Path $WorkPath 'spaced'
New-Item -Path $spacedSource -ItemType Directory -Force | Out-Null
@'
$ExpectedFile = "C:\Program Files\JetBrains\IntelliJ IDEA\bin\idea64.exe"
$Legacy       = "C:\Program Files (x86)\Vendor\App.exe"
$Bad          = "C:\Users\jsmith\Desktop\Setup.exe"
if (Test-Path HKLM:\SOFTWARE\Contoso) { }
'@ | Set-Content -LiteralPath (Join-Path $spacedSource 'Detection.ps1')

$spacedFindings = @(Find-AbsolutePath -PackagePath $spacedSource)

Test-Case 'Program Files path not truncated' (
    @($spacedFindings | Where-Object { $_.Path -eq 'C:\Program Files\JetBrains\IntelliJ IDEA\bin\idea64.exe' }).Count -eq 1
) (($spacedFindings | ForEach-Object { $_.Path }) -join ' | ')

Test-Case 'Program Files path is valid' (
    @($spacedFindings | Where-Object { $_.Path -like 'C:\Program Files\*' -and $_.Classification -ne 'VALID' }).Count -eq 0
)
Test-Case 'x86 Program Files is valid' (
    @($spacedFindings | Where-Object { $_.Path -like '*(x86)*' -and $_.Classification -eq 'VALID' }).Count -eq 1
)
Test-Case 'developer path still flagged' (
    @($spacedFindings | Where-Object { $_.Path -like '*jsmith*' -and $_.Classification -eq 'INVALID' }).Count -eq 1
)
Test-Case 'registry path still ignored' (
    @($spacedFindings | Where-Object { $_.Path -like '*SOFTWARE*' }).Count -eq 0
)

# --- SYSTEM-context shim -----------------------------------------------------
# The scheduled task itself needs Windows, but the shim it runs is an ordinary
# script. Generating and executing one here covers the quoting that previously
# made every SYSTEM-context stage fail with exit 1 and no output.
Write-Host "`nSYSTEM-context shim"

Test-Case 'literal escapes apostrophes' ((ConvertTo-PowerShellLiteral -Value "it's") -eq "'it''s'")

$bareCommand = Split-ExecutableCommandLine -CommandLine 'powershell.exe -NoProfile -File ".\Install.ps1"'
Test-Case 'executable split from arguments' ($bareCommand.Executable -eq 'powershell.exe')
Test-Case 'arguments kept verbatim'         ($bareCommand.Arguments -eq '-NoProfile -File ".\Install.ps1"')

$quotedCommand = Split-ExecutableCommandLine -CommandLine '"C:\Program Files\App\run.exe" /S /norestart'
Test-Case 'quoted executable with spaces'   ($quotedCommand.Executable -eq 'C:\Program Files\App\run.exe')
Test-Case 'arguments after quoted exe'      ($quotedCommand.Arguments -eq '/S /norestart')

$shimWork = Join-Path $WorkPath 'shim'
New-Item -Path $shimWork -ItemType Directory -Force | Out-Null

$payloadPath = Join-Path $shimWork 'Payload.ps1'
'Write-Output "ran in $PWD"; exit 3' | Set-Content -LiteralPath $payloadPath -Encoding UTF8

# The running host's own executable: present on both editions, and on Windows
# its path contains a space, which is the case that used to break.
$shellPath = [System.Diagnostics.Process]::GetCurrentProcess().MainModule.FileName
$shimCommand = '"{0}" -NoProfile -NonInteractive -File "{1}"' -f $shellPath, $payloadPath

$stdOutPath   = Join-Path $shimWork 'stdout.log'
$stdErrPath   = Join-Path $shimWork 'stderr.log'
$exitCodePath = Join-Path $shimWork 'exitcode.txt'
$shimPath     = Join-Path $shimWork 'shim.ps1'

$shimText = New-SystemContextShim -CommandLine $shimCommand -WorkingDirectory $shimWork `
                                  -StdOutPath $stdOutPath -StdErrPath $stdErrPath `
                                  -ExitCodePath $exitCodePath -TimeoutSeconds 120

# The original defect was a generated script that PowerShell mis-parsed, so the
# shim must be checked as code rather than only as text.
$shimTokens = $null
$shimErrors = $null
[System.Management.Automation.Language.Parser]::ParseInput($shimText, [ref]$shimTokens, [ref]$shimErrors) | Out-Null
Test-Case 'generated shim parses'    ($shimErrors.Count -eq 0) ($shimErrors | Select-Object -First 1)
Test-Case 'shim does not shell out'  ($shimText -notmatch 'cmd\.exe')

Set-Content -LiteralPath $shimPath -Value $shimText -Encoding UTF8
& $shellPath -NoProfile -File $shimPath | Out-Null

Test-Case 'shim recorded an exit code' (Test-Path -LiteralPath $exitCodePath)

if (Test-Path -LiteralPath $exitCodePath) {
    $shimExit   = (Get-Content -LiteralPath $exitCodePath -Raw).Trim()
    $shimOutput = if (Test-Path -LiteralPath $stdOutPath) { Get-Content -LiteralPath $stdOutPath -Raw } else { '' }

    Test-Case 'wrapped exit code preserved' ($shimExit -eq '3') $shimExit
    Test-Case 'wrapped command produced output' ($shimOutput -match 'ran in') $shimOutput
    Test-Case 'command ran in the package directory' ($shimOutput -match ([regex]::Escape($shimWork))) $shimOutput
}

# --- Manifest ----------------------------------------------------------------
Write-Host "`nManifest"

$manifest = New-PackageManifest -ApplicationName 'Contoso Reader' -ApplicationVersion '4.2.1' `
    -PackageVersion '1.0.0' -InstallerType 'EXE' -SourceInstaller 'Setup.exe' `
    -InstallCommand 'powershell.exe -NoProfile -ExecutionPolicy Bypass -File ".\Install.ps1"' `
    -UninstallCommand 'powershell.exe -NoProfile -ExecutionPolicy Bypass -File ".\Uninstall.ps1"' `
    -DetectionMethod 'Script' -DetectionScript 'Detection.ps1' -ContentDirectory $WorkPath

Test-Case 'complete manifest is valid' (Test-PackageManifest -Manifest $manifest).IsValid

$noScript = $manifest.PSObject.Copy(); $noScript.DetectionScript = ''
Test-Case 'script detection needs a script' (-not (Test-PackageManifest -Manifest $noScript).IsValid)

$noName = $manifest.PSObject.Copy(); $noName.ApplicationName = ''
Test-Case 'empty required field rejected' (-not (Test-PackageManifest -Manifest $noName).IsValid)

# --- Failure classification --------------------------------------------------
Write-Host "`nFailure classification"

Test-Case 'pre-build -> PACKAGING'        ((Get-FailureClassification -Stage 'PreBuild').Classification -eq 'PACKAGING_FAILURE')
Test-Case '1603 -> INSTALLER'             ((Get-FailureClassification -Stage 'Install' -ExitCode 1603).Classification -eq 'INSTALLER_FAILURE')
Test-Case '5 -> PERMISSION'               ((Get-FailureClassification -Stage 'Install' -ExitCode 5).Classification -eq 'PERMISSION_FAILURE')
Test-Case '1633 -> CONTEXT'               ((Get-FailureClassification -Stage 'Install' -ExitCode 1633).Classification -eq 'CONTEXT_FAILURE')
Test-Case 'install ok but not detected'   ((Get-FailureClassification -Stage 'Detection' -ExitCode 0 -DetectionResult $false -ExpectedExitCodes @(0)).Classification -eq 'DETECTION_FAILURE')
Test-Case 'detected after uninstall'      ((Get-FailureClassification -Stage 'DetectionRemoval' -DetectionResult $true).Classification -eq 'DETECTION_FAILURE')
Test-Case 'no desktop -> SYSTEM_CONTEXT'  ((Get-FailureClassification -Stage 'Install' -Output 'error: no interactive desktop available' -ExecutionContextName 'System').Classification -eq 'SYSTEM_CONTEXT_FAILURE')
Test-Case 'undeclared code -> RETURN_CODE' ((Get-FailureClassification -Stage 'Install' -ExitCode 4242 -ExpectedExitCodes @(0)).Classification -eq 'RETURN_CODE_FAILURE')
Test-Case 'no evidence -> UNKNOWN'        ((Get-FailureClassification -Stage 'Install').Classification -eq 'UNKNOWN')

# --- Pre-build gate: clean package -------------------------------------------
Write-Host "`nPre-build gate (clean package)"

$clean = Join-Path $WorkPath 'clean'
New-Item -Path $clean -ItemType Directory -Force | Out-Null
'binary' | Set-Content -LiteralPath (Join-Path $clean 'Setup.exe')
foreach ($name in @('Install.ps1', 'Uninstall.ps1', 'Detection.ps1')) {
    Copy-Item -LiteralPath (Join-Path $repo "templates/$name") -Destination (Join-Path $clean $name)
}

$manifest.ContentDirectory = $clean
$cleanResult = Invoke-PreBuildValidation -SourcePath $clean -Manifest $manifest
Test-Case 'clean package can build' $cleanResult.CanBuild ($cleanResult.Errors -join ' | ')

# A detection script inspects the installed application, not the package, so it
# has no payload to resolve and must not be reported for lacking $PSScriptRoot.
$cleanWarnings = @($cleanResult.Checks | Where-Object { -not $_.Passed } | ForEach-Object { $_.Name })
Test-Case 'clean package warns about nothing' ($cleanWarnings.Count -eq 0) ($cleanWarnings -join ', ')

# An install wrapper left pointing at a different file throws before the vendor
# installer starts, and reports only a bare exit 1 after a full cycle has run.
Test-Case 'wrapper installer name read' (
    (Get-WrapperInstallerReference -ScriptPath (Join-Path $clean 'Install.ps1')).InstallerName -eq 'Setup.exe'
)
Test-Case 'computed installer name not guessed' (
    -not (Get-WrapperInstallerReference -ScriptPath (Join-Path $clean 'Detection.ps1')).Declared
)

$mismatchManifest = $manifest.PSObject.Copy()
$mismatchManifest.SourceInstaller = 'ideaIU-262.9437.185.exe'
'binary' | Set-Content -LiteralPath (Join-Path $clean 'ideaIU-262.9437.185.exe')

$mismatchResult = Invoke-PreBuildValidation -SourcePath $clean -Manifest $mismatchManifest
$mismatchCheck = @($mismatchResult.Checks | Where-Object { $_.Name -eq 'Install.ps1 targets the packaged installer' })
Test-Case 'installer name mismatch blocks build' (-not $mismatchCheck[0].Passed) $mismatchCheck[0].Detail
Test-Case 'mismatch stops the build'             (-not $mismatchResult.CanBuild)

Remove-Item -LiteralPath (Join-Path $clean 'ideaIU-262.9437.185.exe') -Force

'$DisplayName = "Contoso"; exit 0' | Set-Content -LiteralPath (Join-Path $clean 'Detection.ps1')
$detectionOnly = Invoke-PreBuildValidation -SourcePath $clean -Manifest $manifest
$scriptRootCheck = @($detectionOnly.Checks | Where-Object { $_.Name -eq 'Scripts resolve content from $PSScriptRoot' })
Test-Case 'detection script exempt from $PSScriptRoot' ($scriptRootCheck[0].Passed) $scriptRootCheck[0].Detail

# --- Pre-build gate: dirty package -------------------------------------------
Write-Host "`nPre-build gate (dirty package)"

$dirty = Join-Path $WorkPath 'dirty'
New-Item -Path $dirty -ItemType Directory -Force | Out-Null
'binary' | Set-Content -LiteralPath (Join-Path $dirty 'Setup.exe')
Copy-Item -LiteralPath (Join-Path $repo 'templates/Uninstall.ps1') -Destination (Join-Path $dirty 'Uninstall.ps1')
Copy-Item -LiteralPath (Join-Path $repo 'templates/Detection.ps1') -Destination (Join-Path $dirty 'Detection.ps1')

@'
$src = "C:\Users\jsmith\Desktop\Build\Setup.exe"
$cfg = "\\fileserver\share\config.xml"
Start-Process .\Setup.exe -Wait
$here = Get-Location
'@ | Set-Content -LiteralPath (Join-Path $dirty 'Install.ps1')

'stale' | Set-Content -LiteralPath (Join-Path $dirty 'previous.intunewin')
'log'   | Set-Content -LiteralPath (Join-Path $dirty 'install.log')

$dirtyManifest = New-PackageManifest -ApplicationName 'Bad App' -ApplicationVersion '1.0' `
    -PackageVersion '1.0.0' -InstallerType 'EXE' -SourceInstaller 'Setup.exe' `
    -InstallCommand 'msiexec /i Setup.msi /qb /qb' `
    -UninstallCommand 'powershell.exe -NoProfile -ExecutionPolicy Bypass -File ".\Uninstall.ps1"' `
    -DetectionMethod 'Script' -DetectionScript 'Detection.ps1' -ContentDirectory $dirty

$dirtyResult = Invoke-PreBuildValidation -SourcePath $dirty -Manifest $dirtyManifest
Test-Case 'dirty package is blocked' (-not $dirtyResult.CanBuild)

$failedChecks = @($dirtyResult.Checks | Where-Object { -not $_.Passed } | ForEach-Object { $_.Name })
foreach ($expected in @(
    'No invalid absolute paths'
    'No working-directory assumptions'
    'No nested .intunewin files'
    'No stale build artifacts in source'
    'Install command has no interactive arguments'
    'Install command has no duplicate arguments'
    'Install command resolves to an existing file'
)) {
    Test-Case "flags: $expected" ($failedChecks -contains $expected)
}

$invalidPaths = @($dirtyResult.PathValidation.InvalidPaths)
Test-Case 'developer path found' (@($invalidPaths | Where-Object { $_.Path -like '*jsmith*' }).Count -ge 1)
Test-Case 'UNC path found'       (@($invalidPaths | Where-Object { $_.Path -like '\\fileserver*' }).Count -ge 1)

# --- Intune configuration export ---------------------------------------------
Write-Host "`nIntune configuration export"

$validated = @{
    Install   = $manifest.InstallCommand
    Uninstall = $manifest.UninstallCommand
    Detection = 'powershell.exe -NoProfile -ExecutionPolicy Bypass -File ".\Detection.ps1"'
}

$export = Export-IntuneConfiguration -Manifest $manifest -OutputPath (Join-Path $WorkPath 'out') `
                                     -ValidatedCommands $validated -ValidationPassed $true
Test-Case 'json written'        (Test-Path -LiteralPath $export.JsonPath)
Test-Case 'markdown written'    (Test-Path -LiteralPath $export.MarkdownPath)
Test-Case 'commands consistent' $export.IsConsistent
Test-Case 'production ready'    $export.IsProductionReady

$drifted = $validated.Clone()
$drifted['Install'] = 'powershell.exe -File ".\Install.ps1"'
$driftExport = Export-IntuneConfiguration -Manifest $manifest -OutputPath (Join-Path $WorkPath 'out-drift') `
                                          -ValidatedCommands $drifted -ValidationPassed $true
Test-Case 'drift detected'          (-not $driftExport.IsConsistent)
Test-Case 'drift blocks ready'      (-not $driftExport.IsProductionReady)
Test-Case 'drift warning in markdown' ((Get-Content -LiteralPath $driftExport.MarkdownPath -Raw) -match 'DOES NOT MATCH VALIDATED')

$unvalidated = Export-IntuneConfiguration -Manifest $manifest -OutputPath (Join-Path $WorkPath 'out-unvalidated') `
                                          -ValidatedCommands $validated -ValidationPassed $false
Test-Case 'failed validation blocks ready' (-not $unvalidated.IsProductionReady)

# --- HTML report -------------------------------------------------------------
Write-Host "`nHTML report"

$result = [PSCustomObject]@{
    ApplicationName = 'Contoso Reader'; ApplicationVersion = '4.2.1'; PackageVersion = '1.0.0'
    PackageHash = 'ABC123'; TestedAt = (Get-Date).ToString('o'); Duration = [timespan]::FromMinutes(3)
    ExecutionContext = 'NT AUTHORITY\SYSTEM'
    Environment = [PSCustomObject]@{
        ComputerName = 'PKG01'; OSVersion = 'Windows 10.0.19045'; Architecture = 'x64'
        PowerShellVersion = '5.1'; Is64BitProcess = $true
    }
    Stages = @(
        [PSCustomObject]@{ Name = 'Install'; Result = 'PASS'; Command = 'powershell.exe -File ".\Install.ps1"'
                           ExitCode = 0; Output = '<script>alert(1)</script>'; Detail = 'Success'
                           Duration = [timespan]::FromSeconds(42) }
        [PSCustomObject]@{ Name = 'Detection after install'; Result = 'PASS'; Command = 'detect'
                           ExitCode = 0; Output = 'Detected'; Detail = 'ok'; Duration = [timespan]::Zero }
    )
    InstallDelta = $null; Classification = $null; IsProductionReady = $true
}

$reportPath = New-ValidationReport -Result $result -Path (Join-Path $WorkPath 'report.html') `
                                   -CommandComparison $export.Comparisons
$html = Get-Content -LiteralPath $reportPath -Raw
Test-Case 'report written'       (Test-Path -LiteralPath $reportPath)
Test-Case 'reports ready status' ($html -match 'PRODUCTION READY')
# Installer output reaches the report verbatim, so it must be encoded.
Test-Case 'encodes html in output' (($html -notmatch '<script>alert') -and ($html -match '&lt;script&gt;'))

# --- Result ------------------------------------------------------------------
Remove-Item -LiteralPath $WorkPath -Recurse -Force -ErrorAction SilentlyContinue

Write-Host ""
if ($script:failures -eq 0) {
    Write-Host "ALL TESTS PASSED" -ForegroundColor Green
    exit 0
}

Write-Host "$($script:failures) TEST(S) FAILED" -ForegroundColor Red
exit 1
