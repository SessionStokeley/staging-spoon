#Requires -Version 5.1
<#
    Test-Detection.ps1

    Regression tests for Detection.ps1, the script Intune runs to decide
    whether the application is installed.

    Two things are being protected here:

      1. The exit-code contract. Intune treats exit 0 with output on stdout as
         "installed" and anything else as "not installed". Detection must never
         report success for an application that is not there, and must never
         report failure for one that is.

      2. Diagnosability. A broken configuration still has to exit non-zero, but
         it must say why on stderr. Previously the catch block exited silently,
         so a bad configuration looked exactly like "not installed" and Intune
         reinstalled in a loop with nothing to diagnose.

    Run:
        pwsh -File Tests/Test-Detection.ps1
        powershell.exe -ExecutionPolicy Bypass -File Tests\Test-Detection.ps1
#>

param()

$ErrorActionPreference = 'Stop'
$AppRoot = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Definition)
$DetectionScript = Join-Path $AppRoot 'Detection.ps1'

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

function Test-Group { param([string]$Name) Write-Host ''; Write-Host $Name -ForegroundColor White }

# Resolve the host that will run the detection script as a child process.
$PwshPath = (Get-Process -Id $PID).Path
if (-not $PwshPath) { $PwshPath = 'powershell.exe' }

function Invoke-Detection {
    <#
        Runs Detection.ps1 against a configuration in an isolated directory and
        captures its exit code, stdout and stderr separately - the three things
        the Intune contract depends on.
    #>
    param([Parameter(Mandatory)][string]$ConfigText)

    $dir = Join-Path ([System.IO.Path]::GetTempPath()) ("det_" + [Guid]::NewGuid().ToString('N').Substring(0, 8))
    New-Item -Path $dir -ItemType Directory -Force | Out-Null

    try {
        Copy-Item $DetectionScript (Join-Path $dir 'Detection.ps1')
        # Helpers\ ships in every package. Install.ps1 and Files\ deliberately
        # do not, so the standalone assertion below stays meaningful.
        Copy-Item (Join-Path $AppRoot 'Helpers') (Join-Path $dir 'Helpers') -Recurse -Force
        Set-Content -Path (Join-Path $dir 'Configuration.psd1') -Value $ConfigText -Encoding UTF8

        $outFile = Join-Path $dir 'out.txt'
        $errFile = Join-Path $dir 'err.txt'

        $proc = Start-Process -FilePath $PwshPath `
            -ArgumentList @('-NoProfile', '-File', (Join-Path $dir 'Detection.ps1')) `
            -Wait -PassThru -NoNewWindow `
            -RedirectStandardOutput $outFile -RedirectStandardError $errFile

        return [pscustomobject]@{
            ExitCode = $proc.ExitCode
            StdOut   = (Get-Content $outFile -Raw -ErrorAction SilentlyContinue)
            StdErr   = (Get-Content $errFile -Raw -ErrorAction SilentlyContinue)
        }
    }
    finally { Remove-Item $dir -Recurse -Force -ErrorAction SilentlyContinue }
}

Write-Host ''
Write-Host '========================================' -ForegroundColor Cyan
Write-Host 'Detection Contract Tests' -ForegroundColor Cyan
Write-Host '========================================' -ForegroundColor Cyan

# A real file to detect, so the positive case is genuine.
$fixture = Join-Path ([System.IO.Path]::GetTempPath()) ("detfix_" + [Guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -Path $fixture -ItemType Directory -Force | Out-Null
Set-Content -Path (Join-Path $fixture 'Installed.txt') -Value 'present'
$fixtureEscaped = $fixture.Replace("'", "''")

try {
    Test-Group 'Exit-code contract'

    $r = Invoke-Detection "@{ Detection = @{ Type = 'File'; Path = '$fixtureEscaped'; FileName = 'Installed.txt' } }"
    Test-Assert 'Present file exits 0' ($r.ExitCode -eq 0) "exit $($r.ExitCode)"
    Test-Assert 'Present file writes to stdout' (-not [string]::IsNullOrWhiteSpace($r.StdOut))
    Test-Assert 'Present file writes nothing to stderr' ([string]::IsNullOrWhiteSpace($r.StdErr)) $r.StdErr

    $r = Invoke-Detection "@{ Detection = @{ Type = 'File'; Path = '$fixtureEscaped'; FileName = 'NotThere.txt' } }"
    Test-Assert 'Absent file exits non-zero' ($r.ExitCode -ne 0)
    Test-Assert 'Absent file writes nothing to stdout' ([string]::IsNullOrWhiteSpace($r.StdOut)) $r.StdOut
    # A genuinely absent application is a normal outcome, not an error.
    Test-Assert 'Absent file is not reported as an error' ([string]::IsNullOrWhiteSpace($r.StdErr)) $r.StdErr

    Test-Group 'Version comparison'

    $r = Invoke-Detection "@{ Detection = @{ Type = 'File'; Path = '$fixtureEscaped'; FileName = 'Installed.txt'; MinimumVersion = '9.9.9.9' } }"
    Test-Assert 'File below the minimum version is not detected' ($r.ExitCode -ne 0)

    Test-Group 'Broken configuration is diagnosable'

    # Each of these used to exit 1 silently, indistinguishable from "not installed".
    $r = Invoke-Detection "@{ Detection = @{ Type = 'File'  "
    Test-Assert 'Unparseable psd1 exits non-zero' ($r.ExitCode -ne 0)
    Test-Assert 'Unparseable psd1 explains itself on stderr' ($r.StdErr -match 'Detection could not run') $r.StdErr
    Test-Assert 'Unparseable psd1 writes nothing to stdout' ([string]::IsNullOrWhiteSpace($r.StdOut))

    $r = Invoke-Detection "@{ ApplicationName = 'NoDetectionSection' }"
    Test-Assert 'Missing Detection section exits non-zero' ($r.ExitCode -ne 0)
    Test-Assert 'Missing Detection section is named in the error' ($r.StdErr -match 'no Detection section') $r.StdErr

    $r = Invoke-Detection "@{ Detection = @{ Path = 'C:\x' } }"
    Test-Assert 'Missing Detection.Type is named in the error' ($r.StdErr -match 'no Detection.Type') $r.StdErr

    $r = Invoke-Detection "@{ Detection = @{ Type = 'Banana' } }"
    Test-Assert 'Unknown detection type exits non-zero' ($r.ExitCode -ne 0)
    Test-Assert 'Unknown detection type reports the type' ($r.StdErr -match 'Banana') $r.StdErr

    $r = Invoke-Detection "@{ Detection = @{ Type = 'Custom' } }"
    Test-Assert 'Custom without a ScriptBlock exits non-zero' ($r.ExitCode -ne 0)
    Test-Assert 'Custom without a ScriptBlock says so' ($r.StdErr -match 'ScriptBlock') $r.StdErr

    Test-Group 'Detection is independent of the installer'

    # Detection must not depend on the package or the installer being present:
    # Intune runs it on machines that have neither.
    $r = Invoke-Detection "@{ Detection = @{ Type = 'File'; Path = '$fixtureEscaped'; FileName = 'Installed.txt' } }"
    Test-Assert 'Detects without Install.ps1 or Files\ present' ($r.ExitCode -eq 0) `
        'Detection.ps1 must run standalone.'
}
finally {
    Remove-Item $fixture -Recurse -Force -ErrorAction SilentlyContinue
}

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
