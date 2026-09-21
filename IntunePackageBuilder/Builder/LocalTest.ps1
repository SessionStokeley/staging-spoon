#Requires -Version 5.1

<#
    LocalTest.ps1

    Runs the generated package the way Intune runs it: as SYSTEM.

    Why this exists
    ---------------
    Testing as an administrator and deploying as SYSTEM are not the same test,
    and the difference is the usual explanation for "it worked locally but
    failed through Company Portal":

      HKCU              the admin's hive        vs  .DEFAULT, no real user
      %USERPROFILE%     the admin's profile     vs  systemprofile
      Desktop           the admin's desktop     vs  the system profile's
      Start Menu        the admin's             vs  the system profile's
      Mapped drives     present                 vs  absent
      User PATH         the admin's             vs  the system profile's

    A package that writes a shortcut to "the user's desktop" passes as an
    administrator and lands somewhere nobody can see as SYSTEM.

    How
    ---
    Task Scheduler, not PsExec. A scheduled task principal of
    NT AUTHORITY\SYSTEM is the route that needs nothing installed, and the
    task is registered, run, read and unregistered within one call. The wrapper
    writes its exit code and output to files, so a result is available even
    when the task host reports nothing useful.

    Safety
    ------
    This installs real software on the machine it runs on. It requires
    administrator rights, it refuses to run without explicit confirmation, and
    it removes its scheduled task in a finally block whatever happens.
#>

$script:TaskFolder = '\IntunePackageBuilder'

function Test-IsWindowsHost {
    if ($PSVersionTable.PSEdition -ne 'Core') { return $true }
    return [bool](Get-Variable -Name IsWindows -ValueOnly -ErrorAction SilentlyContinue)
}

function Test-AdministratorRights {
    try {
        $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
        $principal = [Security.Principal.WindowsPrincipal]$identity
        if ($principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) { return $true }
        return ($identity.Name -eq 'NT AUTHORITY\SYSTEM')
    }
    catch { return $false }
}

function Get-PackageFingerprint {
    <#
        .SYNOPSIS
        A hash of everything that decides what the package does.

        .DESCRIPTION
        Covers the configuration, the three scripts, and the installer's name
        and length. Editing any of them changes the fingerprint, which is how a
        test result is known to be stale: section 23 forbids packaging a
        configuration that has changed since it last passed.

        The installer is hashed by name and length rather than contents,
        because hashing a 200 MB installer on every build costs more than it
        tells you - a replaced installer almost always differs in length, and
        a same-length replacement still changes the configuration around it.
    #>
    param([Parameter(Mandatory)][string]$PackagePath)

    $parts = @()

    foreach ($name in @('Configuration.psd1', 'Install.ps1', 'Uninstall.ps1', 'Detection.ps1')) {
        $path = Join-Path $PackagePath $name
        if (Test-Path -LiteralPath $path) {
            $text = Get-Content -LiteralPath $path -Raw
            $parts += "$name=$text"
        }
        else { $parts += "$name=<missing>" }
    }

    foreach ($file in @(Get-ChildItem -LiteralPath $PackagePath -File -ErrorAction SilentlyContinue |
                        Sort-Object Name)) {
        if ($file.Name -in @('Configuration.psd1', 'Install.ps1', 'Uninstall.ps1', 'Detection.ps1')) { continue }
        $parts += "$($file.Name)=$($file.Length)"
    }

    $bytes = [System.Text.Encoding]::UTF8.GetBytes($parts -join "`n")
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try { return ([BitConverter]::ToString($sha.ComputeHash($bytes))).Replace('-', '') }
    finally { $sha.Dispose() }
}

function Invoke-AsSystem {
    <#
        .SYNOPSIS
        Runs a PowerShell script as NT AUTHORITY\SYSTEM and returns what it did.

        .OUTPUTS
        @{ Ran; ExitCode; Output; TimedOut; Error }

        Ran is $false when the task could not be registered or started at all,
        which is different from the script running and failing.
    #>
    param(
        [Parameter(Mandatory)][string]$ScriptPath,
        # Passed through to the script. Detection.ps1 needs -Report, and a
        # wrapper that could only run a script bare would have forced the test
        # to re-implement detection instead of reading the package's own
        # account of itself.
        [string[]]$Arguments = @(),
        [int]$TimeoutSeconds = 1800
    )

    $result = @{ Ran = $false; ExitCode = -1; Output = ''; TimedOut = $false; Error = '' }

    if (-not (Test-IsWindowsHost)) {
        $result.Error = 'SYSTEM-context execution needs Windows Task Scheduler.'
        return $result
    }
    if (-not (Test-AdministratorRights)) {
        $result.Error = 'Registering a scheduled task that runs as SYSTEM needs administrator rights.'
        return $result
    }

    $runId = [Guid]::NewGuid().ToString('N').Substring(0, 12)
    $taskName = "LocalTest_$runId"
    $workDirectory = Join-Path ([System.IO.Path]::GetTempPath()) "ipb_$runId"
    New-Item -Path $workDirectory -ItemType Directory -Force | Out-Null

    $exitCodeFile = Join-Path $workDirectory 'exitcode.txt'
    $outputFile = Join-Path $workDirectory 'output.txt'
    $wrapperPath = Join-Path $workDirectory 'wrapper.ps1'

    # The wrapper writes the exit code itself. Task Scheduler's LastTaskResult
    # is unreliable for this: it reports the task host's result, which is 0 for
    # a task that started successfully even when the script inside it failed.
    # Each argument is single-quoted and its own quotes doubled, so a value
    # carrying a quote or a space cannot break out of the literal.
    $argumentText = ''
    foreach ($argument in @($Arguments)) {
        $argumentText += " '" + ([string]$argument).Replace("'", "''") + "'"
    }

    $wrapper = @"
`$ErrorActionPreference = 'Continue'
try {
    & '$($ScriptPath.Replace("'", "''"))'$argumentText *>&1 | Out-File -FilePath '$($outputFile.Replace("'", "''"))' -Encoding utf8
    `$code = `$LASTEXITCODE
    if (`$null -eq `$code) { `$code = 0 }
}
catch {
    `$_ | Out-File -FilePath '$($outputFile.Replace("'", "''"))' -Append -Encoding utf8
    `$code = 1
}
Set-Content -LiteralPath '$($exitCodeFile.Replace("'", "''"))' -Value `$code -Encoding ascii
"@
    [System.IO.File]::WriteAllText($wrapperPath, $wrapper, (New-Object System.Text.UTF8Encoding($false)))

    $registered = $false
    try {
        $action = New-ScheduledTaskAction -Execute 'powershell.exe' `
            -Argument "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$wrapperPath`""

        # ServiceAccount logon type is what makes SYSTEM work without a
        # password. RunLevel Highest matters on a machine with UAC.
        $principal = New-ScheduledTaskPrincipal -UserId 'NT AUTHORITY\SYSTEM' `
            -LogonType ServiceAccount -RunLevel Highest

        $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries `
            -DontStopIfGoingOnBatteries -ExecutionTimeLimit ([TimeSpan]::FromSeconds($TimeoutSeconds + 60))

        Register-ScheduledTask -TaskName $taskName -TaskPath $script:TaskFolder `
            -Action $action -Principal $principal -Settings $settings -Force -ErrorAction Stop | Out-Null
        $registered = $true

        Start-ScheduledTask -TaskName $taskName -TaskPath $script:TaskFolder -ErrorAction Stop
        $result.Ran = $true

        $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
        while ((Get-Date) -lt $deadline) {
            Start-Sleep -Seconds 2
            $task = Get-ScheduledTask -TaskName $taskName -TaskPath $script:TaskFolder -ErrorAction SilentlyContinue
            if (-not $task) { break }
            if ($task.State -ne 'Running') { break }
        }

        $task = Get-ScheduledTask -TaskName $taskName -TaskPath $script:TaskFolder -ErrorAction SilentlyContinue
        if ($task -and $task.State -eq 'Running') {
            $result.TimedOut = $true
            $result.Error = "The package did not finish within $TimeoutSeconds seconds. A non-silent installer waiting for a dialog is the usual cause - nobody can answer it as SYSTEM."
            Stop-ScheduledTask -TaskName $taskName -TaskPath $script:TaskFolder -ErrorAction SilentlyContinue
        }

        # The wrapper writes the file after the script returns, so give a
        # moment for the write to land after the task leaves Running.
        for ($attempt = 0; $attempt -lt 10; $attempt++) {
            if (Test-Path -LiteralPath $exitCodeFile) { break }
            Start-Sleep -Milliseconds 300
        }

        if (Test-Path -LiteralPath $exitCodeFile) {
            $raw = (Get-Content -LiteralPath $exitCodeFile -Raw).Trim()
            $parsed = 0
            if ([int]::TryParse($raw, [ref]$parsed)) { $result.ExitCode = $parsed }
        }
        elseif (-not $result.TimedOut) {
            $result.Error = 'The task ran but wrote no exit code, so what it did is unknown.'
        }

        if (Test-Path -LiteralPath $outputFile) {
            $result.Output = Get-Content -LiteralPath $outputFile -Raw
        }
    }
    catch {
        $result.Error = $_.Exception.Message
    }
    finally {
        if ($registered) {
            Unregister-ScheduledTask -TaskName $taskName -TaskPath $script:TaskFolder `
                -Confirm:$false -ErrorAction SilentlyContinue
        }
        Remove-Item -LiteralPath $workDirectory -Recurse -Force -ErrorAction SilentlyContinue
    }

    return $result
}

function ConvertFrom-DetectionReport {
    <#
        Turns Detection.ps1 -Report output into a lookup.

        The report is the package's own account of itself, so the test reads
        what the package reports rather than re-implementing the same checks
        and risking the two disagreeing.
    #>
    param([string]$Text)

    $map = @{}
    if (-not $Text) { return $map }

    foreach ($line in ($Text -split "`r?`n")) {
        $trimmed = $line.Trim()
        if (-not $trimmed) { continue }
        $separator = $trimmed.IndexOf(':')
        if ($separator -lt 1) { continue }
        $key = $trimmed.Substring(0, $separator).Trim()
        $value = $trimmed.Substring($separator + 1).Trim()
        if ($key) { $map[$key] = $value }
    }
    return $map
}

function New-TestStage {
    param([string]$Name, [string]$Result, [string]$Detail = '')
    return [pscustomobject]@{ Name = $Name; Result = $Result; Detail = $Detail }
}

function Invoke-LocalPackageTest {
    <#
        .SYNOPSIS
        Installs, verifies, uninstalls and re-verifies the package as SYSTEM.

        .DESCRIPTION
        Runs the real generated Install.ps1 - not a simulation of it - in the
        context Intune uses. Section 21.

        .PARAMETER SkipUninstall
        Leave the application installed. Useful when investigating a failure,
        but it means the machine is left changed.

        .PARAMETER Force
        Skip the confirmation prompt. This installs software; automation that
        passes -Force is asserting it already has approval.

        .OUTPUTS
        @{ Overall; Stages; Fingerprint; InstallOutput; UninstallOutput; Failure }
    #>
    param(
        [Parameter(Mandatory)][string]$PackagePath,
        [switch]$SkipUninstall,
        [switch]$Force,
        [int]$TimeoutSeconds = 1800
    )

    $stages = @()
    $failure = ''
    $installOutput = ''
    $uninstallOutput = ''

    $installScript = Join-Path $PackagePath 'Install.ps1'
    $uninstallScript = Join-Path $PackagePath 'Uninstall.ps1'
    $detectionScript = Join-Path $PackagePath 'Detection.ps1'

    foreach ($required in @($installScript, $uninstallScript, $detectionScript)) {
        if (-not (Test-Path -LiteralPath $required)) {
            throw "The package is incomplete: $required is missing. Generate it before testing."
        }
    }

    if (-not (Test-IsWindowsHost)) {
        return @{
            Overall = 'SKIPPED'
            Stages = @(New-TestStage 'SYSTEM-context test' 'SKIP' 'Not running on Windows, so there is no Task Scheduler to run the package as SYSTEM.')
            Fingerprint = (Get-PackageFingerprint -PackagePath $PackagePath)
            InstallOutput = ''; UninstallOutput = ''; Failure = ''
        }
    }

    if (-not (Test-AdministratorRights)) {
        return @{
            Overall = 'SKIPPED'
            Stages = @(New-TestStage 'SYSTEM-context test' 'SKIP' 'Administrator rights are needed to register a task that runs as SYSTEM. Re-run elevated.')
            Fingerprint = (Get-PackageFingerprint -PackagePath $PackagePath)
            InstallOutput = ''; UninstallOutput = ''; Failure = ''
        }
    }

    if (-not $Force) {
        Write-Host ''
        Write-Host 'This installs the packaged application on THIS machine, as SYSTEM.' -ForegroundColor Yellow
        Write-Host "Package: $PackagePath" -ForegroundColor Yellow
        if (-not $SkipUninstall) { Write-Host 'It will then be uninstalled again.' -ForegroundColor Yellow }
        else { Write-Host 'It will be LEFT INSTALLED (-SkipUninstall).' -ForegroundColor Yellow }
        Write-Host ''
        $answer = Read-Host 'Type "test" to continue'
        if ($answer -ne 'test') {
            return @{
                Overall = 'CANCELLED'
                Stages = @(New-TestStage 'Confirmation' 'CANCELLED' 'Nothing was run.')
                Fingerprint = (Get-PackageFingerprint -PackagePath $PackagePath)
                InstallOutput = ''; UninstallOutput = ''; Failure = ''
            }
        }
    }

    # Checked, not assumed. An unconditional PASS here would report a package
    # with no installer in it as sound right up until the install stage failed
    # for a reason the table did not name.
    $installerFile = ''
    try {
        $config = Import-PackageConfig -Path (Join-Path $PackagePath 'Configuration.psd1')
        $installerFile = [string]$config.InstallerFile
    }
    catch {
        return @{
            Overall = 'FAILED'
            Stages = @(New-TestStage 'Configuration' 'FAIL' $_.Exception.Message)
            Fingerprint = (Get-PackageFingerprint -PackagePath $PackagePath)
            InstallOutput = ''; UninstallOutput = ''
            Failure = "Configuration.psd1 could not be read: $($_.Exception.Message)"
        }
    }

    $installerPath = Join-Path $PackagePath $installerFile
    if (-not $installerFile -or -not (Test-Path -LiteralPath $installerPath)) {
        $detail = if ($installerFile) { "$installerFile is not in the package." }
                  else { 'The configuration names no InstallerFile.' }
        return @{
            Overall = 'FAILED'
            Stages = @(New-TestStage 'Installer' 'FAIL' $detail)
            Fingerprint = (Get-PackageFingerprint -PackagePath $PackagePath)
            InstallOutput = ''; UninstallOutput = ''
            Failure = $detail
        }
    }
    $stages += New-TestStage 'Installer' 'PASS' $installerFile

    # ------------------------------------------------------------- install
    $install = Invoke-AsSystem -ScriptPath $installScript -TimeoutSeconds $TimeoutSeconds
    $installOutput = $install.Output

    if (-not $install.Ran) {
        $stages += New-TestStage 'Silent Installation' 'FAIL' $install.Error
        return @{
            Overall = 'FAILED'; Stages = $stages
            Fingerprint = (Get-PackageFingerprint -PackagePath $PackagePath)
            InstallOutput = $installOutput; UninstallOutput = ''
            Failure = $install.Error
        }
    }

    if ($install.TimedOut) {
        $stages += New-TestStage 'Silent Installation' 'FAIL' $install.Error
        $failure = $install.Error
    }
    elseif ($install.ExitCode -eq 0 -or $install.ExitCode -eq 3010) {
        $stages += New-TestStage 'Silent Installation' 'PASS' ''
    }
    else {
        $stages += New-TestStage 'Silent Installation' 'FAIL' "The package reported exit code $($install.ExitCode)."
        $failure = "Install.ps1 exited $($install.ExitCode)."
    }

    $stages += New-TestStage 'Exit Code' ([string]$install.ExitCode) ''

    # ------------------------------------------- detection and the extras
    # -Report, not the bare verdict. Verdict mode prints one "Detected:" line
    # and carries everything else in its exit code; the report prints the
    # per-feature lines this table needs, and its "Installed:" line comes from
    # the same Get-DetectionResult call the verdict does, so the two cannot
    # disagree.
    $report = Invoke-AsSystem -ScriptPath $detectionScript -Arguments @('-Report') -TimeoutSeconds 300
    $reportMap = ConvertFrom-DetectionReport -Text $report.Output
    $installed = $false
    if ($reportMap.ContainsKey('Installed')) { $installed = ($reportMap['Installed'] -eq 'True') }
    $stages += New-TestStage 'Application Detection' $(if ($installed) { 'PASS' } else { 'FAIL' }) `
        $(if ($installed) { '' } else { [string]$reportMap['Executable'] })
    if (-not $installed -and -not $failure) { $failure = 'The application was not detected after installing.' }

    foreach ($pair in @(
        @{ Key = 'PATH';                Label = 'PATH' },
        @{ Key = 'Associations';        Label = 'File Associations' },
        @{ Key = 'Context Menu';        Label = 'Context Menu' },
        @{ Key = 'Desktop Shortcut';    Label = 'Desktop Shortcut' },
        @{ Key = 'Start Menu Shortcut'; Label = 'Start Menu Shortcut' }
    )) {
        if (-not $reportMap.ContainsKey($pair.Key)) { continue }
        $value = [string]$reportMap[$pair.Key]

        if ($value -eq 'not configured') {
            $stages += New-TestStage $pair.Label 'N/A' ''
        }
        elseif ($value -like 'PASS*') {
            $stages += New-TestStage $pair.Label 'PASS' ''
        }
        else {
            $stages += New-TestStage $pair.Label 'FAIL' $value
            if (-not $failure) { $failure = "$($pair.Label): $value" }
        }
    }

    # ----------------------------------------------------------- uninstall
    if ($SkipUninstall) {
        $stages += New-TestStage 'Uninstall' 'SKIPPED' 'The application is still installed on this machine.'
    }
    else {
        $uninstall = Invoke-AsSystem -ScriptPath $uninstallScript -TimeoutSeconds $TimeoutSeconds
        $uninstallOutput = $uninstall.Output

        if (-not $uninstall.Ran) {
            $stages += New-TestStage 'Uninstall' 'FAIL' $uninstall.Error
            if (-not $failure) { $failure = $uninstall.Error }
        }
        elseif ($uninstall.TimedOut) {
            $stages += New-TestStage 'Uninstall' 'FAIL' $uninstall.Error
            if (-not $failure) { $failure = $uninstall.Error }
        }
        elseif ($uninstall.ExitCode -eq 0 -or $uninstall.ExitCode -eq 3010) {
            $stages += New-TestStage 'Uninstall' 'PASS' ''
        }
        else {
            $stages += New-TestStage 'Uninstall' 'FAIL' "Uninstall.ps1 exited $($uninstall.ExitCode)."
            if (-not $failure) { $failure = "Uninstall.ps1 exited $($uninstall.ExitCode)." }
        }

        $after = Invoke-AsSystem -ScriptPath $detectionScript -Arguments @('-Report') -TimeoutSeconds 300
        $afterMap = ConvertFrom-DetectionReport -Text $after.Output
        $stillInstalled = $false
        if ($afterMap.ContainsKey('Installed')) { $stillInstalled = ($afterMap['Installed'] -eq 'True') }

        $stages += New-TestStage 'Post-Uninstall Detection' `
            $(if ($stillInstalled) { 'STILL INSTALLED' } else { 'NOT INSTALLED' }) ''
        if ($stillInstalled -and -not $failure) {
            $failure = 'The application is still detected after uninstalling.'
        }
    }

    $failed = @($stages | Where-Object { $_.Result -eq 'FAIL' -or $_.Result -eq 'STILL INSTALLED' })
    $overall = if ($failed.Count -eq 0) { 'PASS' } else { 'FAILED' }

    return @{
        Overall = $overall
        Stages = $stages
        Fingerprint = (Get-PackageFingerprint -PackagePath $PackagePath)
        InstallOutput = $installOutput
        UninstallOutput = $uninstallOutput
        Failure = $failure
    }
}

function Write-LocalTestReport {
    <#
        The result table from section 22. A failure names the stage and the
        reason, because "FAILED" on its own sends someone back to the logs.
    #>
    param([Parameter(Mandatory)]$Result)

    Write-Host ''
    Write-Host 'LOCAL DEPLOYMENT TEST' -ForegroundColor Cyan
    Write-Host ('=' * 52) -ForegroundColor Cyan

    foreach ($stage in $Result.Stages) {
        $colour = switch ($stage.Result) {
            'PASS' { 'Green' }
            'FAIL' { 'Red' }
            'STILL INSTALLED' { 'Red' }
            'NOT INSTALLED' { 'Green' }
            'SKIP' { 'Yellow' }
            'SKIPPED' { 'Yellow' }
            'CANCELLED' { 'Yellow' }
            'N/A' { 'DarkGray' }
            default { 'Gray' }
        }
        Write-Host ('{0,-26}{1}' -f $stage.Name, $stage.Result) -ForegroundColor $colour
        if ($stage.Detail) { Write-Host "    $($stage.Detail)" -ForegroundColor DarkGray }
    }

    Write-Host ('=' * 52) -ForegroundColor Cyan

    $overallColour = switch ($Result.Overall) {
        'PASS' { 'Green' }
        'FAILED' { 'Red' }
        default { 'Yellow' }
    }
    Write-Host "OVERALL RESULT: $($Result.Overall)" -ForegroundColor $overallColour

    if ($Result.Failure) {
        Write-Host ''
        Write-Host 'Failure:' -ForegroundColor Red
        $firstFailure = @($Result.Stages | Where-Object { $_.Result -eq 'FAIL' -or $_.Result -eq 'STILL INSTALLED' })
        if ($firstFailure.Count -gt 0) { Write-Host "  $($firstFailure[0].Name)" -ForegroundColor Red }
        Write-Host ''
        Write-Host 'Reason:' -ForegroundColor Red
        Write-Host "  $($Result.Failure)" -ForegroundColor Red
    }
    Write-Host ''
}

# ------------------------------------------------------ test state (s.23)

function Get-TestStatePath {
    param([Parameter(Mandatory)][string]$PackagePath)
    return (Join-Path $PackagePath '.testresult.json')
}

function Save-TestResult {
    <#
        Records the result against the fingerprint it was produced from. The
        fingerprint is what makes the record falsifiable: a configuration
        edited afterwards no longer matches, so the pass no longer counts.
    #>
    param(
        [Parameter(Mandatory)][string]$PackagePath,
        [Parameter(Mandatory)]$Result
    )

    # Assigned before the hashtable rather than inline: a try/catch used as an
    # expression parses on PowerShell 7 and not on 5.1, and 5.1 is the edition
    # this has to run on.
    $testedBy = '(unknown)'
    try { $testedBy = [Security.Principal.WindowsIdentity]::GetCurrent().Name } catch { $testedBy = '(unknown)' }

    $record = @{
        Overall     = $Result.Overall
        Fingerprint = $Result.Fingerprint
        TestedOn    = (Get-Date -Format 'o')
        TestedBy    = $testedBy
        Failure     = $Result.Failure
    }
    $path = Get-TestStatePath -PackagePath $PackagePath
    $record | ConvertTo-Json -Depth 4 | Out-File -FilePath $path -Encoding utf8 -Force
    return $path
}

function Get-TestResult {
    param([Parameter(Mandatory)][string]$PackagePath)
    $path = Get-TestStatePath -PackagePath $PackagePath
    if (-not (Test-Path -LiteralPath $path)) { return $null }
    try { return (Get-Content -LiteralPath $path -Raw | ConvertFrom-Json) }
    catch { return $null }
}

function Test-PackageTestCurrent {
    <#
        .SYNOPSIS
        Whether this package has a passing test that still applies.

        .OUTPUTS
        @{ Current; Reason }

        Section 23: a configuration changed after its last passing test is
        untested, and packaging it would ship something nobody ran.
    #>
    param([Parameter(Mandatory)][string]$PackagePath)

    $record = Get-TestResult -PackagePath $PackagePath
    if (-not $record) {
        return @{ Current = $false; Reason = 'This package has never been tested.' }
    }

    if ($record.Overall -ne 'PASS') {
        return @{ Current = $false; Reason = "The last local test result was $($record.Overall)." }
    }

    $fingerprint = Get-PackageFingerprint -PackagePath $PackagePath
    if ($record.Fingerprint -ne $fingerprint) {
        return @{ Current = $false
                  Reason = 'The configuration changed after the last successful test. Previous results no longer apply - run the local test again.' }
    }

    return @{ Current = $true; Reason = "Tested $($record.TestedOn) and unchanged since." }
}
