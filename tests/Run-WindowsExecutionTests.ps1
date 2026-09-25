<#
.SYNOPSIS
    End-to-end execution tests that run a real installer process. Windows only.
.DESCRIPTION
    These are the tests that genuinely launch a process through the deployment
    wrapper, so they need a real executable to stand in for a vendor installer.
    One is compiled here with Add-Type: a console program that prints back the
    exact argv it received and spawns a lingering child, which is how a real
    installer that leaves a helper or updater resident behaves.

    With that fake installer the suite proves, on the platform the packager
    actually runs on:
      - the wrapper returns as soon as the installer exits and does not wait for
        the resident child (a wait on descendants would hang the deployment);
      - the vendor exit code is preserved;
      - the installer name and its silent switches reach the installer exactly
        as configured - one argument each, spaces and quotes intact, no
        duplication - through both the ordinary and the SYSTEM-context paths.

    Run it on Windows (Windows PowerShell 5.1 or PowerShell 7). It compiles and
    launches native executables, so it does not run on other platforms.
.EXAMPLE
    pwsh -NoProfile -File .\tests\Run-WindowsExecutionTests.ps1
#>

[CmdletBinding()]
param([string]$WorkPath = (Join-Path ([System.IO.Path]::GetTempPath()) 'staging-spoon-winexec-tests'))

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repo = Split-Path $PSScriptRoot -Parent
. (Join-Path $repo 'src/Core/Platform.ps1')
. (Join-Path $repo 'src/Core/ProcessRunner.ps1')
. (Join-Path $repo 'src/Information/CommandModel.ps1')
. (Join-Path $repo 'src/Testing/SystemContext.ps1')

$installTemplate = Join-Path $repo 'templates/Install.ps1'
$shellPath = (Get-Command powershell.exe -ErrorAction SilentlyContinue).Source
if (-not $shellPath) { $shellPath = (Get-Process -Id $PID).Path }

$script:failures = 0
function Test-Case {
    param([Parameter(Mandatory)][string]$Name, [Parameter(Mandatory)][AllowNull()]$Condition, [string]$Detail = '')
    if ($Condition) { Write-Host "  PASS $Name" }
    else { Write-Host "  FAIL $Name $Detail" -ForegroundColor Red; $script:failures++ }
}

if (Test-Path -LiteralPath $WorkPath) { Remove-Item -LiteralPath $WorkPath -Recurse -Force -ErrorAction SilentlyContinue }
New-Item -Path $WorkPath -ItemType Directory -Force | Out-Null

# --- The fake installer ------------------------------------------------------
# Prints the argv it was handed (so boundaries can be asserted), then starts a
# child that lingers ~10s before writing a marker file. The wrapper should
# return before that marker appears, proving it did not wait on the descendant.
$fakeSource = @'
using System;
using System.Diagnostics;
class FakeInstaller {
    static int Main(string[] args) {
        Console.WriteLine("ARGCOUNT=" + args.Length);
        for (int i = 0; i < args.Length; i++) { Console.WriteLine("GOTARG" + i + "=[" + args[i] + "]"); }
        string marker = Environment.GetEnvironmentVariable("STAGING_SPOON_MARKER");
        if (!string.IsNullOrEmpty(marker)) {
            var psi = new ProcessStartInfo("cmd.exe", "/c ping -n 11 127.0.0.1 >NUL & echo done>\"" + marker + "\"");
            psi.UseShellExecute = false;
            psi.CreateNoWindow = true;
            try { Process.Start(psi); } catch { }
        }
        Console.WriteLine("vendor installer finished");
        return 0;
    }
}
'@

$fakeExe = Join-Path $WorkPath 'Setup.exe'
Add-Type -TypeDefinition $fakeSource -OutputAssembly $fakeExe -OutputType ConsoleApplication

# Stage the real Install.ps1 wrapper beside the fake installer.
$wrapperDir = Join-Path $WorkPath 'package'
New-Item -Path $wrapperDir -ItemType Directory -Force | Out-Null
Copy-Item -LiteralPath $fakeExe -Destination (Join-Path $wrapperDir 'Setup.exe') -Force
Copy-Item -LiteralPath $installTemplate -Destination (Join-Path $wrapperDir 'Install.ps1') -Force

# --- Wrapper: returns without waiting on the resident child ------------------
Write-Host "`nWrapper execution"

$marker = Join-Path $WorkPath 'helper-finished.marker'
Remove-Item -LiteralPath $marker -Force -ErrorAction SilentlyContinue
$env:STAGING_SPOON_MARKER = $marker

$watch = [System.Diagnostics.Stopwatch]::StartNew()
$wrapperResult = Invoke-ProcessWithTimeout -FilePath $shellPath `
    -Arguments ("-NoProfile -NonInteractive -File `"{0}`" -InstallerName Setup.exe /S /norestart" -f (Join-Path $wrapperDir 'Install.ps1')) `
    -WorkingDirectory $wrapperDir -TimeoutSeconds 120
$watch.Stop()

Remove-Item Env:\STAGING_SPOON_MARKER -ErrorAction SilentlyContinue

Test-Case 'wrapper returns before the resident child finishes' ($watch.Elapsed.TotalSeconds -lt 8) ("{0:n1}s" -f $watch.Elapsed.TotalSeconds)
Test-Case 'resident child was still running on return' (-not (Test-Path -LiteralPath $marker))
Test-Case 'wrapper preserves the vendor exit code' ($wrapperResult.ExitCode -eq 0) $wrapperResult.ExitCode
Test-Case 'installer output reaches the log' ($wrapperResult.StdOut -match 'vendor installer finished')
Test-Case 'wrapper passes the installer name and switches through' ($wrapperResult.StdOut -match 'Setup\.exe /S /norestart')

# --- UI mode honoured by the wrapper -----------------------------------------
Write-Host "`nUI mode"

$wrapperScript = Join-Path $wrapperDir 'Install.ps1'

# NormalUI with no arguments: the installer runs and receives none. The wrapper
# runs it exactly once and preserves its exit code.
$normal = Invoke-ProcessWithTimeout -FilePath $shellPath `
    -Arguments ("-NoProfile -NonInteractive -File `"{0}`" -UiMode NormalUI -InstallerName Setup.exe" -f $wrapperScript) `
    -WorkingDirectory $wrapperDir -TimeoutSeconds 60
Test-Case 'NormalUI runs the installer'        ($normal.StdOut -match 'vendor installer finished')
Test-Case 'NormalUI passes no arguments'       ($normal.StdOut -match 'ARGCOUNT=0')
Test-Case 'NormalUI logs the mode'             ($normal.StdOut -match 'Install UI mode: NormalUI')

# Silent with no arguments is the misconfiguration that would hang session 0.
# The wrapper must refuse it before starting the installer, not run it.
$silentEmpty = Invoke-ProcessWithTimeout -FilePath $shellPath `
    -Arguments ("-NoProfile -NonInteractive -File `"{0}`" -UiMode Silent -InstallerName Setup.exe" -f $wrapperScript) `
    -WorkingDirectory $wrapperDir -TimeoutSeconds 60
Test-Case 'Silent without switches fails'      ($silentEmpty.ExitCode -ne 0) $silentEmpty.ExitCode
Test-Case 'Silent without switches never runs' (-not ($silentEmpty.StdOut -match 'vendor installer finished'))

# --- Argument flow: package.json -> command -> Install.ps1 -> installer ------
Write-Host "`nInstaller argument flow (through a real installer)"

# Run a set of installer arguments through the real chain: the model renders the
# command, it is split exactly as the runner splits it, and executed. Returns
# what the fake installer actually received as argv.
function Invoke-ArgumentFlow {
    param([string[]]$InstallerArguments, [switch]$SystemPath)

    $command  = New-PowerShellScriptCommand -ScriptName 'Install.ps1' `
                    -InstallerName 'Setup.exe' -InstallerArguments $InstallerArguments
    $rendered = ConvertTo-CommandString -Command $command
    $split    = Split-ExecutableCommandLine -CommandLine $rendered
    # The rendered command names powershell.exe; run it with this host's shell.
    $arguments = $split.Arguments

    if ($SystemPath) {
        $shimStdOut = Join-Path $wrapperDir 'sys-stdout.log'
        $shimStdErr = Join-Path $wrapperDir 'sys-stderr.log'
        $shimExit   = Join-Path $wrapperDir 'sys-exit.txt'
        $shimState  = Join-Path $wrapperDir 'sys-state.txt'
        $shimPath   = Join-Path $wrapperDir 'shim.ps1'
        $moduleDir  = Join-Path $wrapperDir 'modules'
        New-Item -Path $moduleDir -ItemType Directory -Force | Out-Null
        foreach ($m in @('Platform.ps1', 'ProcessRunner.ps1')) {
            Copy-Item -LiteralPath (Join-Path $repo "src/Core/$m") -Destination $moduleDir -Force
        }
        Copy-Item -LiteralPath (Join-Path $repo 'src/Testing/SystemContext.ps1') -Destination $moduleDir -Force

        New-SystemContextShim -CommandLine "$shellPath $arguments" -WorkingDirectory $wrapperDir `
            -StdOutPath $shimStdOut -StdErrPath $shimStdErr -ExitCodePath $shimExit `
            -StatePath $shimState -ModuleDirectory $moduleDir |
            Set-Content -LiteralPath $shimPath -Encoding UTF8

        Invoke-ProcessWithTimeout -FilePath $shellPath `
            -Arguments "-NoProfile -NonInteractive -File `"$shimPath`"" `
            -WorkingDirectory $wrapperDir -TimeoutSeconds 60 | Out-Null
        return (Get-Content -LiteralPath $shimStdOut -Raw)
    }

    (Invoke-ProcessWithTimeout -FilePath $shellPath -Arguments $arguments `
        -WorkingDirectory $wrapperDir -TimeoutSeconds 60).StdOut
}

function Get-ReceivedArguments {
    param([string]$Output)
    @($Output -split "`r?`n" | Where-Object { $_ -match '^GOTARG\d+=\[' } |
        ForEach-Object { ($_ -replace '^GOTARG\d+=\[', '') -replace '\]$', '' })
}

function Test-ArgumentSet {
    param([string]$Name, [string[]]$Received, [string[]]$Expected)
    $ok = $Received.Count -eq $Expected.Count -and
          @($Expected | Where-Object { $Received -notcontains $_ }).Count -eq 0 -and
          @($Received | Where-Object { $Expected -notcontains $_ }).Count -eq 0
    Test-Case $Name $ok ("got: " + ($Received -join ' | '))
}

Test-ArgumentSet 'no arguments: installer gets none' `
    @(Get-ReceivedArguments -Output (Invoke-ArgumentFlow -InstallerArguments @())) @()
Test-ArgumentSet 'one argument survives' `
    @(Get-ReceivedArguments -Output (Invoke-ArgumentFlow -InstallerArguments @('/S'))) @('/S')
Test-ArgumentSet 'multiple arguments preserved' `
    @(Get-ReceivedArguments -Output (Invoke-ArgumentFlow -InstallerArguments @('/S', '/v/qn', '/norestart'))) `
    @('/S', '/v/qn', '/norestart')
Test-ArgumentSet 'space in a value is one argument' `
    @(Get-ReceivedArguments -Output (Invoke-ArgumentFlow -InstallerArguments @('INSTALLDIR=C:\Program Files\App', '/qn'))) `
    @('INSTALLDIR=C:\Program Files\App', '/qn')
Test-ArgumentSet 'quoted value survives' `
    @(Get-ReceivedArguments -Output (Invoke-ArgumentFlow -InstallerArguments @('TARGETDIR="C:\Program Files\App"', '/qn'))) `
    @('TARGETDIR=C:\Program Files\App', '/qn')
Test-ArgumentSet 'SYSTEM path preserves arguments identically' `
    @(Get-ReceivedArguments -Output (Invoke-ArgumentFlow -InstallerArguments @('/S', 'INSTALLDIR=C:\Program Files\App') -SystemPath)) `
    @('/S', 'INSTALLDIR=C:\Program Files\App')

# --- Cleanup -----------------------------------------------------------------
# Give the resident child time to exit on its own, then clear the work area.
Start-Sleep -Seconds 12
Remove-Item -LiteralPath $WorkPath -Recurse -Force -ErrorAction SilentlyContinue

Write-Host ''
if ($script:failures -eq 0) { Write-Host 'ALL TESTS PASSED' -ForegroundColor Green; exit 0 }
Write-Host "$($script:failures) TEST(S) FAILED" -ForegroundColor Red
exit 1
