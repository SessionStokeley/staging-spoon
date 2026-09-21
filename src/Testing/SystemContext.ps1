<#
.SYNOPSIS
    Execution of a command under NT AUTHORITY\SYSTEM.
.DESCRIPTION
    Works as Administrator does not mean works as SYSTEM. A scheduled task is
    used rather than an external tool so the test has no dependency beyond
    Windows itself. The task runs with no interactive desktop, no user profile
    and no mapped drives, matching how Intune invokes a System-context app.
#>

Set-StrictMode -Version Latest

function Invoke-AsSystem {
    <#
    .SYNOPSIS
        Runs a command line as SYSTEM and returns its exit code and output.
    .DESCRIPTION
        The command is wrapped in a shim that redirects streams to files, since
        a scheduled task has nowhere to write a console. The shim records the
        wrapped command's real exit code so it is not lost.
    .OUTPUTS
        PSCustomObject with ExitCode, StdOut, StdErr, Duration and TimedOut.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$CommandLine,
        [Parameter(Mandatory)][string]$WorkingDirectory,
        [int]$TimeoutSeconds = 1800
    )

    $identity = [System.Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [System.Security.Principal.WindowsPrincipal]::new($identity)
    if (-not $principal.IsInRole([System.Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw "SYSTEM-context testing requires an elevated session"
    }

    $taskName = "IntuneValidation-$([guid]::NewGuid().ToString('N').Substring(0, 12))"
    $shimRoot = Join-Path $env:SystemRoot "Temp\$taskName"
    New-Item -Path $shimRoot -ItemType Directory -Force | Out-Null

    $stdOutPath   = Join-Path $shimRoot 'stdout.log'
    $stdErrPath   = Join-Path $shimRoot 'stderr.log'
    $exitCodePath = Join-Path $shimRoot 'exitcode.txt'
    $shimPath     = Join-Path $shimRoot 'shim.ps1'

    # The shim runs as SYSTEM. It must capture the wrapped command's exit code
    # before anything else can overwrite $LASTEXITCODE.
    $shim = @"
Set-Location -LiteralPath '$WorkingDirectory'
`$exitCode = 1
try {
    & cmd.exe /c "$($CommandLine -replace '"', '""') > `"$stdOutPath`" 2> `"$stdErrPath`""
    `$exitCode = `$LASTEXITCODE
} catch {
    `$_.Exception.Message | Set-Content -LiteralPath '$stdErrPath' -Encoding UTF8
    `$exitCode = 1
}
Set-Content -LiteralPath '$exitCodePath' -Value `$exitCode -Encoding UTF8
"@

    Set-Content -LiteralPath $shimPath -Value $shim -Encoding UTF8

    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    $timedOut = $false

    try {
        $action = New-ScheduledTaskAction -Execute 'powershell.exe' `
                                          -Argument "-NoProfile -NonInteractive -ExecutionPolicy Bypass -File `"$shimPath`"" `
                                          -WorkingDirectory $WorkingDirectory

        $taskPrincipal = New-ScheduledTaskPrincipal -UserId 'NT AUTHORITY\SYSTEM' -LogonType ServiceAccount -RunLevel Highest
        $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries `
                                                 -DontStopIfGoingOnBatteries `
                                                 -ExecutionTimeLimit ([timespan]::FromSeconds($TimeoutSeconds))

        Register-ScheduledTask -TaskName $taskName `
                               -Action $action `
                               -Principal $taskPrincipal `
                               -Settings $settings | Out-Null

        Start-ScheduledTask -TaskName $taskName

        $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
        do {
            Start-Sleep -Seconds 2
            $task = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
            if (-not $task) { break }
            if ($task.State -ne 'Running') { break }
        } while ((Get-Date) -lt $deadline)

        if ((Get-Date) -ge $deadline) {
            $timedOut = $true
            Stop-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
        }

        # The shim writes the exit code only after the wrapped command returns.
        $exitCode = if (Test-Path -LiteralPath $exitCodePath) {
            [int](Get-Content -LiteralPath $exitCodePath -Raw).Trim()
        } elseif ($timedOut) {
            1460
        } else {
            $info = Get-ScheduledTaskInfo -TaskName $taskName -ErrorAction SilentlyContinue
            if ($info) { $info.LastTaskResult } else { 1 }
        }

        $stdOut = if (Test-Path -LiteralPath $stdOutPath) { Get-Content -LiteralPath $stdOutPath -Raw } else { '' }
        $stdErr = if (Test-Path -LiteralPath $stdErrPath) { Get-Content -LiteralPath $stdErrPath -Raw } else { '' }
    } finally {
        $stopwatch.Stop()
        Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $shimRoot -Recurse -Force -ErrorAction SilentlyContinue
    }

    [PSCustomObject]@{
        CommandLine = $CommandLine
        ExitCode    = $exitCode
        StdOut      = if ($stdOut) { $stdOut } else { '' }
        StdErr      = if ($stdErr) { $stdErr } else { '' }
        Duration    = $stopwatch.Elapsed
        TimedOut    = $timedOut
        Context     = 'System'
    }
}

function Invoke-AsCurrentUser {
    <#
    .SYNOPSIS
        Runs a command line in the current session, capturing output and exit code.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$CommandLine,
        [Parameter(Mandatory)][string]$WorkingDirectory,
        [int]$TimeoutSeconds = 1800
    )

    $workRoot   = Join-Path $env:TEMP "IntuneValidation-$([guid]::NewGuid().ToString('N').Substring(0, 12))"
    New-Item -Path $workRoot -ItemType Directory -Force | Out-Null
    $stdOutPath = Join-Path $workRoot 'stdout.log'
    $stdErrPath = Join-Path $workRoot 'stderr.log'

    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    $timedOut = $false
    $exitCode = 1

    try {
        $process = Start-Process -FilePath 'cmd.exe' `
                                 -ArgumentList '/c', $CommandLine `
                                 -WorkingDirectory $WorkingDirectory `
                                 -RedirectStandardOutput $stdOutPath `
                                 -RedirectStandardError $stdErrPath `
                                 -NoNewWindow `
                                 -PassThru

        if (-not $process.WaitForExit($TimeoutSeconds * 1000)) {
            $timedOut = $true
            try { $process.Kill($true) } catch { }
            $process.WaitForExit(30000) | Out-Null
            $exitCode = 1460
        } else {
            $exitCode = $process.ExitCode
        }

        $stdOut = if (Test-Path -LiteralPath $stdOutPath) { Get-Content -LiteralPath $stdOutPath -Raw } else { '' }
        $stdErr = if (Test-Path -LiteralPath $stdErrPath) { Get-Content -LiteralPath $stdErrPath -Raw } else { '' }
    } finally {
        $stopwatch.Stop()
        Remove-Item -LiteralPath $workRoot -Recurse -Force -ErrorAction SilentlyContinue
    }

    $identity = [System.Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [System.Security.Principal.WindowsPrincipal]::new($identity)

    [PSCustomObject]@{
        CommandLine = $CommandLine
        ExitCode    = $exitCode
        StdOut      = if ($stdOut) { $stdOut } else { '' }
        StdErr      = if ($stdErr) { $stdErr } else { '' }
        Duration    = $stopwatch.Elapsed
        TimedOut    = $timedOut
        Context     = if ($principal.IsInRole([System.Security.Principal.WindowsBuiltInRole]::Administrator)) { 'Administrator' } else { 'User' }
    }
}

function Invoke-InContext {
    <#
    .SYNOPSIS
        Dispatches a command to the requested execution context.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$CommandLine,
        [Parameter(Mandatory)][string]$WorkingDirectory,
        [ValidateSet('System', 'Current')][string]$Context = 'Current',
        [int]$TimeoutSeconds = 1800
    )

    if ($Context -eq 'System') {
        Invoke-AsSystem -CommandLine $CommandLine -WorkingDirectory $WorkingDirectory -TimeoutSeconds $TimeoutSeconds
    } else {
        Invoke-AsCurrentUser -CommandLine $CommandLine -WorkingDirectory $WorkingDirectory -TimeoutSeconds $TimeoutSeconds
    }
}
