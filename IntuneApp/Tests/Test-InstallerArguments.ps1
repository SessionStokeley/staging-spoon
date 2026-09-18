#Requires -Version 5.1
<#
    Test-InstallerArguments.ps1

    The deployment argument model: which installer arguments are authoritative,
    and what the final command line actually is.

    These tests assert the EFFECTIVE COMMAND rather than the individual
    variables that feed it. A test that only checked "Installer.Arguments is
    still /quiet" would pass while the command that runs says
    "/quiet /norestart /quiet /norestart" - which is exactly the failure this
    model exists to prevent, and exactly the one that is invisible until an
    installer rejects its own switches on a real machine.

    Part A runs the resolver and the command builder directly.
    Part B drives Install.ps1 end to end for all six type/source combinations,
    so the wiring is covered and not just the helper.

    Run:
        pwsh -File Tests/Test-InstallerArguments.ps1
        powershell.exe -ExecutionPolicy Bypass -File Tests\Test-InstallerArguments.ps1
#>

param()

$ErrorActionPreference = 'Stop'
$AppRoot = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Definition)

. (Join-Path $AppRoot 'Helpers\InstallerArguments.ps1')

$script:pass = 0
$script:fail = 0
$script:failures = [System.Collections.Generic.List[string]]::new()

function Test-Assert {
    param([string]$Name, [bool]$Condition, [string]$Detail = '')
    if ($Condition) {
        Write-Host "  PASS  $Name" -ForegroundColor Green
        $script:pass++
    }
    else {
        Write-Host "  FAIL  $Name" -ForegroundColor Red
        if ($Detail) { Write-Host "        $Detail" -ForegroundColor DarkRed }
        $script:fail++
        $script:failures.Add($Name)
    }
}

function Test-Throws {
    param([string]$Name, [scriptblock]$Action, [string]$Match = '')
    try {
        & $Action | Out-Null
        Test-Assert $Name $false 'expected an exception, none was thrown'
    }
    catch {
        if ($Match -and $_.Exception.Message -notmatch $Match) {
            Test-Assert $Name $false "message did not match '$Match': $($_.Exception.Message)"
        }
        else { Test-Assert $Name $true }
    }
}

function Test-Group { param([string]$Name) Write-Host ''; Write-Host $Name -ForegroundColor White }

function New-Config {
    param([string]$Type = 'EXE', [string]$File = 'Setup.exe', [string]$Arguments = '', $Source = $null)
    $installer = @{ Type = $Type; File = $File; Arguments = $Arguments }
    if ($null -ne $Source) { $installer['ArgumentSource'] = $Source }
    return @{ ApplicationName = 'ArgTest'; Installer = $installer }
}

# The command a configuration actually produces, end to end through the two
# functions the engine uses. This is what the assertions below compare.
function Get-EffectiveCommand {
    param(
        $Config,
        [string]$Override = '',
        [string]$IntuneArguments = '',
        [string]$IntuneArgumentsBase64 = '',
        [string]$InstallerPath = 'C:\Pkg\Files\Setup.exe'
    )
    $provided = [bool]$IntuneArguments -or [bool]$IntuneArgumentsBase64
    $resolved = Resolve-InstallerArguments -Config $Config -Override $Override `
        -IntuneArguments $IntuneArguments -IntuneArgumentsBase64 $IntuneArgumentsBase64 `
        -IntuneArgumentsProvided $provided
    $command = New-InstallerCommandLine -Type $Config.Installer.Type -InstallerPath $InstallerPath `
        -Arguments $resolved.Arguments -DisplayArguments $resolved.Display
    return @{ Resolved = $resolved; Command = $command }
}

Write-Host ''
Write-Host '========================================' -ForegroundColor Cyan
Write-Host 'Installer Argument Model' -ForegroundColor Cyan
Write-Host '========================================' -ForegroundColor Cyan

$msiPath = 'C:\Pkg\Files\app.msi'
$exePath = 'C:\Pkg\Files\Setup.exe'

# ===================================================== A. the six combinations
Test-Group 'A. EXE'

$r = Get-EffectiveCommand -Config (New-Config -Arguments '/quiet /norestart' -Source 'Configuration') -InstallerPath $exePath
Test-Assert '1. EXE + Configuration arguments' `
    ($r.Command.FilePath -eq $exePath -and $r.Command.Arguments -eq '/quiet /norestart') $r.Command.Display
Test-Assert '   ...and the source is reported as Configuration' ($r.Resolved.Source -eq 'Configuration')

$r = Get-EffectiveCommand -Config (New-Config -Arguments '' -Source 'Intune') -IntuneArguments '/S /v/qn' -InstallerPath $exePath
Test-Assert '2. EXE + Intune arguments' `
    ($r.Command.FilePath -eq $exePath -and $r.Command.Arguments -eq '/S /v/qn') $r.Command.Display

$r = Get-EffectiveCommand -Config (New-Config -Arguments '/quiet' -Source 'None') -InstallerPath $exePath
Test-Assert '3. EXE + no arguments' ($r.Command.FilePath -eq $exePath -and $null -eq $r.Command.Arguments) `
    "Arguments was [$($r.Command.Arguments)]"
Test-Assert '   ...Arguments is $null, not empty' ($null -eq $r.Command.Arguments) `
    'Start-Process rejects an empty -ArgumentList on Windows PowerShell 5.1, so the parameter has to be omitted'

Test-Group 'A. MSI'

$r = Get-EffectiveCommand -Config (New-Config -Type 'MSI' -File 'app.msi' -Arguments '/qn /norestart' -Source 'Configuration') -InstallerPath $msiPath
Test-Assert '4. MSI + Configuration arguments' `
    ($r.Command.FilePath -eq 'msiexec.exe' -and $r.Command.Arguments -eq "/i `"$msiPath`" /qn /norestart") $r.Command.Arguments

$r = Get-EffectiveCommand -Config (New-Config -Type 'MSI' -File 'app.msi' -Source 'Intune') -IntuneArguments '/qn REBOOT=ReallySuppress' -InstallerPath $msiPath
Test-Assert '5. MSI + Intune arguments' `
    ($r.Command.Arguments -eq "/i `"$msiPath`" /qn REBOOT=ReallySuppress") $r.Command.Arguments

$r = Get-EffectiveCommand -Config (New-Config -Type 'MSI' -File 'app.msi' -Arguments '/qn' -Source 'None') -InstallerPath $msiPath
Test-Assert '6. MSI + no arguments still gets /i and the path' `
    ($r.Command.Arguments -eq "/i `"$msiPath`"") $r.Command.Arguments
Test-Assert '   ...and the configured /qn is absent' ($r.Command.Arguments -notmatch '/qn') $r.Command.Arguments

# ============================================== the invariant: never combined
Test-Group 'The arguments are never combined'

# The failure this whole model exists to prevent.
$r = Get-EffectiveCommand -Config (New-Config -Arguments '/quiet /norestart' -Source 'Intune') `
    -IntuneArguments '/quiet /norestart' -InstallerPath $exePath
Test-Assert '7. Identical arguments on both sides are not duplicated' `
    ($r.Command.Arguments -eq '/quiet /norestart') $r.Command.Arguments
Test-Assert '   ...the switch appears exactly once' `
    (([regex]::Matches($r.Command.Arguments, '/quiet')).Count -eq 1) $r.Command.Arguments

$r = Get-EffectiveCommand -Config (New-Config -Arguments '/CONFIGARGS' -Source 'Intune') `
    -IntuneArguments '/INTUNEARGS' -InstallerPath $exePath
Test-Assert '8. Configuration arguments are not appended when the source is Intune' `
    ($r.Command.Arguments -eq '/INTUNEARGS') $r.Command.Arguments
Test-Assert '   ...the configured value appears nowhere in the command' `
    ($r.Command.Display -notmatch 'CONFIGARGS') $r.Command.Display
Test-Assert '   ...and the unused configuration value is called out' `
    (@($r.Resolved.Warnings | Where-Object { $_ -match 'not used' }).Count -eq 1)

Test-Throws '9. Intune arguments are refused when the source is Configuration' `
    { Get-EffectiveCommand -Config (New-Config -Arguments '/CONFIGARGS' -Source 'Configuration') -IntuneArguments '/INTUNEARGS' } `
    'never combined'

Test-Throws '   Arguments are refused when the source is None' `
    { Get-EffectiveCommand -Config (New-Config -Source 'None') -IntuneArguments '/X' } 'no arguments'

Test-Throws '   The source Intune with nothing passed is refused, not silently filled in' `
    { Get-EffectiveCommand -Config (New-Config -Arguments '/quiet' -Source 'Intune') } 'no installer arguments were passed'

Test-Throws '   An unknown ArgumentSource is refused by name' `
    { Get-EffectiveCommand -Config (New-Config -Source 'Portal') } 'not valid'

# =============================================== quoting and complex arguments
Test-Group 'Quoted paths, MSI properties and spaces'

$complex = 'INSTALLDIR="C:\Program Files\Java\jdk-21" ALLUSERS=1 /qn'
$r = Get-EffectiveCommand -Config (New-Config -Type 'MSI' -File 'app.msi' -Arguments $complex -Source 'Configuration') -InstallerPath $msiPath
Test-Assert 'An MSI property with a quoted path survives intact' `
    ($r.Command.Arguments -eq "/i `"$msiPath`" $complex") $r.Command.Arguments
Test-Assert 'The quoted path is not re-quoted or split' `
    ($r.Command.Arguments -match 'INSTALLDIR="C:\\Program Files\\Java\\jdk-21"') $r.Command.Arguments

$spaced = '/D="C:\Program Files\App With Spaces"'
$r = Get-EffectiveCommand -Config (New-Config -Arguments $spaced -Source 'Configuration') -InstallerPath $exePath
Test-Assert 'An EXE argument containing spaces survives intact' ($r.Command.Arguments -eq $spaced) $r.Command.Arguments

$r = Get-EffectiveCommand -Config (New-Config -Type 'MSI' -File 'a b.msi' -Arguments '/qn' -Source 'Configuration') `
    -InstallerPath 'C:\Pkg\Files\a b.msi'
Test-Assert 'An installer path containing spaces is quoted for msiexec' `
    ($r.Command.Arguments -eq '/i "C:\Pkg\Files\a b.msi" /qn') $r.Command.Arguments

Test-Group 'Base64, for arguments the Windows command line cannot carry'

# Windows splits a command line with CommandLineToArgvW, where a backslash run
# before a quote is halved and \" is a literal quote. These two cases therefore
# do not survive being typed into the Intune Program command as a quoted value.
$risky = 'INSTALLDIR="C:\Program Files\App"'
$risk = Test-ArgumentQuotingRisk -Arguments $risky
Test-Assert 'A quoted value is reported as unsafe for the raw form' (-not $risk.Safe)
Test-Assert '   ...and the reason names the quote' (($risk.Reasons -join ' ') -match 'double quote')

$risk = Test-ArgumentQuotingRisk -Arguments 'TARGETDIR=C:\Program Files\App\'
Test-Assert 'A trailing backslash is reported as unsafe' (-not $risk.Safe)
Test-Assert '   ...and the reason names the escaped quote' (($risk.Reasons -join ' ') -match 'escapes the closing quote')

$risk = Test-ArgumentQuotingRisk -Arguments '/quiet /norestart'
Test-Assert 'A switch-only string is safe for the raw form' $risk.Safe ($risk.Reasons -join '; ')

$encoded = ConvertTo-Base64Argument -Arguments $risky
Test-Assert 'The encoded form contains nothing the command line treats specially' `
    ($encoded -notmatch '[" \\]') $encoded
Test-Assert 'Base64 round-trips the exact string' ((ConvertFrom-Base64Argument -Encoded $encoded) -eq $risky)

$r = Get-EffectiveCommand -Config (New-Config -Type 'MSI' -File 'app.msi' -Source 'Intune') `
    -IntuneArgumentsBase64 $encoded -InstallerPath $msiPath
Test-Assert 'Base64 arguments reach the command line decoded' `
    ($r.Command.Arguments -eq "/i `"$msiPath`" $risky") $r.Command.Arguments

Test-Throws 'Raw and base64 together are refused as ambiguous' `
    { Get-EffectiveCommand -Config (New-Config -Source 'Intune') -IntuneArguments '/a' -IntuneArgumentsBase64 $encoded } `
    'exactly one'

Test-Throws 'Invalid base64 is reported as such' `
    { ConvertFrom-Base64Argument -Encoded 'not!valid!base64' } 'not valid base64'

# ============================================================ backward compat
Test-Group 'Backward compatibility'

# The shape every existing package has: Arguments, and no ArgumentSource.
$legacy = New-Config -Arguments '/quiet /norestart'
$r = Get-EffectiveCommand -Config $legacy -InstallerPath $exePath
Test-Assert 'A configuration with no ArgumentSource defaults to Configuration' `
    ($r.Resolved.Source -eq 'Configuration') $r.Resolved.Source
Test-Assert '   ...and behaves exactly as it did before' ($r.Command.Arguments -eq '/quiet /norestart')

$emptyLegacy = New-Config -Arguments ''
$r = Get-EffectiveCommand -Config $emptyLegacy -InstallerPath $exePath
Test-Assert 'A legacy configuration with empty arguments still runs' ($null -eq $r.Command.Arguments)

Test-Assert 'Case is accepted and normalised' `
    ((Get-EffectiveCommand -Config (New-Config -Source 'intune') -IntuneArguments '/x').Resolved.Source -eq 'Intune')

Test-Group 'Override, for local testing'

# A package deployed with Intune arguments still has to be testable locally.
$intunePackage = New-Config -Arguments '/quiet /norestart' -Source 'Intune'
$r = Get-EffectiveCommand -Config $intunePackage -Override 'Configuration' -InstallerPath $exePath
Test-Assert 'An override tests the configured arguments without editing the file' `
    ($r.Command.Arguments -eq '/quiet /norestart' -and $r.Resolved.Source -eq 'Configuration') $r.Command.Display

# =================================================================== redaction
Test-Group 'Redaction'

$secret = '/qn LICENSEKEY=ABCD-1234-EFGH SERVICEPASSWORD=hunter2 INSTALLDIR="C:\App"'
$r = Get-EffectiveCommand -Config (New-Config -Type 'MSI' -File 'app.msi' -Arguments $secret -Source 'Configuration') -InstallerPath $msiPath

Test-Assert 'The password value is not in the display form' ($r.Command.Display -notmatch 'hunter2') $r.Command.Display
Test-Assert 'The licence key value is not in the display form' ($r.Command.Display -notmatch 'ABCD-1234-EFGH') $r.Command.Display
Test-Assert 'The argument names survive redaction' `
    ($r.Command.Display -match 'LICENSEKEY' -and $r.Command.Display -match 'SERVICEPASSWORD') $r.Command.Display
Test-Assert 'Non-sensitive arguments are left readable' ($r.Command.Display -match 'INSTALLDIR') $r.Command.Display
Test-Assert 'The command that RUNS is not redacted' `
    ($r.Command.Arguments -match 'hunter2') 'redaction is for display only; the installer must receive the real value'

# ======================================================= B. end to end
Test-Group 'B. Install.ps1 end to end, all six combinations'

$workDir = Join-Path ([System.IO.Path]::GetTempPath()) ("args_" + [Guid]::NewGuid().ToString('N').Substring(0, 8))

function New-TestPackage {
    param([string]$Path, [string]$ConfigText)
    New-Item -Path $Path -ItemType Directory -Force | Out-Null
    New-Item -Path (Join-Path $Path 'Files') -ItemType Directory -Force | Out-Null
    foreach ($file in @('Install.ps1', 'Uninstall.ps1', 'Detection.ps1')) {
        Copy-Item (Join-Path $AppRoot $file) (Join-Path $Path $file)
    }
    Copy-Item (Join-Path $AppRoot 'Helpers') (Join-Path $Path 'Helpers') -Recurse -Force
    Set-Content -LiteralPath (Join-Path $Path 'Files\Setup.exe') -Value 'stub' -Encoding UTF8
    Set-Content -LiteralPath (Join-Path $Path 'Files\app.msi') -Value 'stub' -Encoding UTF8
    Set-Content -LiteralPath (Join-Path $Path 'Configuration.psd1') -Value $ConfigText -Encoding UTF8
}

function Invoke-InstallDryRun {
    <#
        Runs the real Install.ps1 in dry-run mode and returns what it says it
        would run. The dry run and the real execution share one command
        builder, so this is the command that would actually be issued.
    #>
    param([string]$ConfigText, [string[]]$ExtraArgs = @())

    $dir = Join-Path $workDir ("pkg_" + [Guid]::NewGuid().ToString('N').Substring(0, 6))
    New-TestPackage -Path $dir -ConfigText $ConfigText

    $previous = $env:INTUNE_LOCAL_TEST
    $env:INTUNE_LOCAL_TEST = '1'
    try {
        $arguments = @('-NoProfile', '-File', (Join-Path $dir 'Install.ps1'), '-TestMode') + $ExtraArgs
        $output = & (Get-Process -Id $PID).Path @arguments 2>&1
        return @{ ExitCode = $LASTEXITCODE; Text = ($output -join "`n") }
    }
    finally { $env:INTUNE_LOCAL_TEST = $previous }
}

try {
    New-Item -Path $workDir -ItemType Directory -Force | Out-Null

    $exeConfig = @'
@{
    ApplicationName = 'ArgsEndToEnd'
    Installer   = @{ Type = 'EXE'; File = 'Setup.exe'; Arguments = '/CONFIGONLY'; ArgumentSource = '{0}' }
    Uninstaller = @{ Type = 'EXE'; File = 'Setup.exe'; Arguments = '/S' }
    Detection   = @{ Type = 'Custom'; Script = '$false' }
    Logging     = @{ Enabled = $false; Path = 'C:\Temp' }
}
'@
    $msiConfig = @'
@{
    ApplicationName = 'ArgsEndToEnd'
    Installer   = @{ Type = 'MSI'; File = 'app.msi'; Arguments = '/CONFIGONLY'; ArgumentSource = '{0}' }
    Uninstaller = @{ Type = 'MSI'; ProductCode = '{{11111111-2222-3333-4444-555555555555}}' }
    Detection   = @{ Type = 'Custom'; Script = '$false' }
    Logging     = @{ Enabled = $false; Path = 'C:\Temp' }
}
'@

    # --- EXE ---
    $r = Invoke-InstallDryRun -ConfigText ($exeConfig -replace '\{0\}', 'Configuration')
    Test-Assert 'E2E EXE + Configuration uses the configured arguments' `
        ($r.Text -match '/CONFIGONLY' -and $r.Text -match 'Argument source\s*:\s*Configuration') $r.Text

    $r = Invoke-InstallDryRun -ConfigText ($exeConfig -replace '\{0\}', 'Intune') `
        -ExtraArgs @('-InstallerArguments', '/FROMINTUNE')
    Test-Assert 'E2E EXE + Intune uses the passed arguments' ($r.Text -match '/FROMINTUNE') $r.Text
    Test-Assert 'E2E EXE + Intune does NOT also use the configured arguments' `
        ($r.Text -notmatch '/CONFIGONLY') $r.Text

    $r = Invoke-InstallDryRun -ConfigText ($exeConfig -replace '\{0\}', 'None')
    Test-Assert 'E2E EXE + None passes no arguments' `
        ($r.Text -notmatch '/CONFIGONLY' -and $r.Text -match 'Argument source\s*:\s*None') $r.Text

    # --- MSI ---
    $r = Invoke-InstallDryRun -ConfigText ($msiConfig -replace '\{0\}', 'Configuration')
    Test-Assert 'E2E MSI + Configuration builds msiexec /i with the configured arguments' `
        ($r.Text -match 'msiexec\.exe /i' -and $r.Text -match '/CONFIGONLY') $r.Text

    $r = Invoke-InstallDryRun -ConfigText ($msiConfig -replace '\{0\}', 'Intune') `
        -ExtraArgs @('-InstallerArguments', '/qn REBOOT=ReallySuppress')
    Test-Assert 'E2E MSI + Intune uses the passed arguments' ($r.Text -match 'REBOOT=ReallySuppress') $r.Text
    Test-Assert 'E2E MSI + Intune does NOT also use the configured arguments' `
        ($r.Text -notmatch '/CONFIGONLY') $r.Text

    $r = Invoke-InstallDryRun -ConfigText ($msiConfig -replace '\{0\}', 'None')
    Test-Assert 'E2E MSI + None still builds /i with the package path' `
        ($r.Text -match 'msiexec\.exe /i' -and $r.Text -notmatch '/CONFIGONLY') $r.Text

    # --- refusals reach the caller as a failure ---
    $r = Invoke-InstallDryRun -ConfigText ($exeConfig -replace '\{0\}', 'Configuration') `
        -ExtraArgs @('-InstallerArguments', '/FROMINTUNE')
    Test-Assert 'E2E passing arguments to a Configuration package fails the run' ($r.ExitCode -ne 0) $r.Text
    Test-Assert '   ...and says they are never combined' ($r.Text -match 'never combined') $r.Text

    $r = Invoke-InstallDryRun -ConfigText ($exeConfig -replace '\{0\}', 'Intune')
    Test-Assert 'E2E an Intune package with no arguments passed fails the run' ($r.ExitCode -ne 0) $r.Text

    # --- the override keeps a deployed package locally testable ---
    $r = Invoke-InstallDryRun -ConfigText ($exeConfig -replace '\{0\}', 'Intune') `
        -ExtraArgs @('-ArgumentSource', 'Configuration')
    Test-Assert 'E2E the override tests an Intune package with its configured arguments' `
        ($r.ExitCode -eq 0 -and $r.Text -match '/CONFIGONLY') $r.Text

    # --- base64 end to end ---
    $encoded = ConvertTo-Base64Argument -Arguments 'INSTALLDIR="C:\Program Files\App"'
    $r = Invoke-InstallDryRun -ConfigText ($msiConfig -replace '\{0\}', 'Intune') `
        -ExtraArgs @('-InstallerArgumentsBase64', $encoded)
    Test-Assert 'E2E base64 arguments arrive decoded' `
        ($r.Text -match 'INSTALLDIR="C:\\Program Files\\App"') $r.Text

    # --- a package that predates ArgumentSource ---
    $legacyConfig = @'
@{
    ApplicationName = 'LegacyPackage'
    Installer   = @{ Type = 'EXE'; File = 'Setup.exe'; Arguments = '/quiet /norestart' }
    Uninstaller = @{ Type = 'EXE'; File = 'Setup.exe'; Arguments = '/S' }
    Detection   = @{ Type = 'Custom'; Script = '$false' }
    Logging     = @{ Enabled = $false; Path = 'C:\Temp' }
}
'@
    $r = Invoke-InstallDryRun -ConfigText $legacyConfig
    Test-Assert 'E2E a configuration with no ArgumentSource behaves as before' `
        ($r.ExitCode -eq 0 -and $r.Text -match '/quiet /norestart' -and
         $r.Text -match 'Argument source\s*:\s*Configuration') $r.Text
}
finally {
    Remove-Item $workDir -Recurse -Force -ErrorAction SilentlyContinue
}

Test-Group 'Test-Local reports what it is about to run'

# Test-Local.ps1 declares [string]$Command. Assigning the command hashtable to
# $command there coerces it to a string, so $command.Display is $null and the
# Execution line prints empty - while also clobbering the -Command parameter.
# Nothing else catches this: the resolver is correct, and the banner is only
# reached by a real install.
$localSource = Get-Content (Join-Path $AppRoot 'Test-Local.ps1') -Raw

Test-Assert 'Test-Local does not assign the command line to $command' `
    ($localSource -notmatch '\$command\s*=\s*New-InstallerCommandLine') `
    'that variable is a [string] parameter, so the assignment silently coerces'
Test-Assert 'The Execution line reads from the command object' `
    ($localSource -match 'Execution[^\r\n]*\$installerCommand\.Display')
Test-Assert 'The banner reports the argument source' `
    ($localSource -match 'Argument source[^\r\n]*\$\(\$resolved\.Source\)')
Test-Assert 'The banner reports the effective arguments, redacted' `
    ($localSource -match 'Effective arguments' -and $localSource -match '\$resolved\.Display')
Test-Assert 'Test-Local accepts -ArgumentSource' ($localSource -match '\[string\]\$ArgumentSource')
Test-Assert 'Test-Local forwards -ArgumentSource to Install.ps1' `
    ($localSource -match '&\s*\$script\s+-ArgumentSource\s+\$ArgumentSource')

Write-Host ''
Write-Host '========================================' -ForegroundColor Cyan
$total = $script:pass + $script:fail
Write-Host "Total: $total   Pass: $($script:pass)   Fail: $($script:fail)" `
    -ForegroundColor $(if ($script:fail -eq 0) { 'Green' } else { 'Red' })
if ($script:fail -gt 0) {
    Write-Host ''
    Write-Host 'Failed:' -ForegroundColor Red
    foreach ($f in $script:failures) { Write-Host "  - $f" -ForegroundColor Red }
}
Write-Host '========================================' -ForegroundColor Cyan

if ($script:fail -gt 0) { exit 1 }
exit 0
