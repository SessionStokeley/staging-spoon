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

function ConvertTo-PowerShellLiteral {
    <#
    .SYNOPSIS
        Wraps a value as a PowerShell single-quoted literal.
    .DESCRIPTION
        Generated script text must embed paths and command lines that can
        themselves contain quotes. A single-quoted literal with doubled
        apostrophes is the only form PowerShell does not reinterpret.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Value)

    "'" + ($Value -replace "'", "''") + "'"
}

function Split-ExecutableCommandLine {
    <#
    .SYNOPSIS
        Splits a command line into its executable and the rest, verbatim.
    .DESCRIPTION
        The remainder is returned exactly as written rather than re-quoted from
        parsed tokens, because re-quoting is what turns a working command into
        a broken one.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowEmptyString()][string]$CommandLine)

    $trimmed = $CommandLine.Trim()

    if (-not $trimmed) {
        return [PSCustomObject]@{ Executable = ''; Arguments = '' }
    }

    if ($trimmed.StartsWith('"')) {
        $closing = $trimmed.IndexOf('"', 1)
        if ($closing -gt 0) {
            return [PSCustomObject]@{
                Executable = $trimmed.Substring(1, $closing - 1)
                Arguments  = $trimmed.Substring($closing + 1).Trim()
            }
        }
    }

    $space = $trimmed.IndexOf(' ')
    if ($space -lt 0) {
        return [PSCustomObject]@{ Executable = $trimmed; Arguments = '' }
    }

    [PSCustomObject]@{
        Executable = $trimmed.Substring(0, $space)
        Arguments  = $trimmed.Substring($space + 1).Trim()
    }
}

function New-SystemContextShim {
    <#
    .SYNOPSIS
        Builds the script a scheduled task runs to execute one command as SYSTEM.
    .DESCRIPTION
        A scheduled task has nowhere to write a console, so the shim redirects
        both streams to files and records the wrapped command's real exit code.

        The command is started through ProcessStartInfo rather than through
        cmd.exe. Handing a command line to cmd means quoting it for cmd, inside
        a PowerShell string, inside generated script text - three layers of
        escaping over one string, and getting any of them wrong silently
        produces a command that never runs. Passing the executable and its
        argument string as separate fields removes all three layers.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$CommandLine,
        [Parameter(Mandatory)][string]$WorkingDirectory,
        [Parameter(Mandatory)][string]$StdOutPath,
        [Parameter(Mandatory)][string]$StdErrPath,
        [Parameter(Mandatory)][string]$ExitCodePath,
        [int]$TimeoutSeconds = 1800
    )

    $command = Split-ExecutableCommandLine -CommandLine $CommandLine

    if (-not $command.Executable) {
        throw "Cannot run an empty command line as SYSTEM"
    }

    $executableLiteral = ConvertTo-PowerShellLiteral -Value $command.Executable
    $argumentLiteral   = ConvertTo-PowerShellLiteral -Value $command.Arguments
    $workingLiteral    = ConvertTo-PowerShellLiteral -Value $WorkingDirectory
    $stdOutLiteral     = ConvertTo-PowerShellLiteral -Value $StdOutPath
    $stdErrLiteral     = ConvertTo-PowerShellLiteral -Value $StdErrPath
    $exitCodeLiteral   = ConvertTo-PowerShellLiteral -Value $ExitCodePath
    $timeoutMs         = [int]$TimeoutSeconds * 1000

    @"
`$ErrorActionPreference = 'Stop'
`$exitCode = 1
`$stdOut = ''
`$stdErr = ''

try {
    `$startInfo = [System.Diagnostics.ProcessStartInfo]::new()
    `$startInfo.FileName               = $executableLiteral
    `$startInfo.Arguments              = $argumentLiteral
    `$startInfo.WorkingDirectory       = $workingLiteral
    `$startInfo.UseShellExecute        = `$false
    `$startInfo.CreateNoWindow         = `$true
    `$startInfo.RedirectStandardOutput = `$true
    `$startInfo.RedirectStandardError  = `$true

    `$process = [System.Diagnostics.Process]::Start(`$startInfo)

    # Both pipes are drained concurrently. Reading one to the end before the
    # other deadlocks as soon as the process fills the pipe it is not reading.
    `$outTask = `$process.StandardOutput.ReadToEndAsync()
    `$errTask = `$process.StandardError.ReadToEndAsync()

    if (`$process.WaitForExit($timeoutMs)) {
        `$exitCode = `$process.ExitCode
    } else {
        try { `$process.Kill() } catch { }
        `$process.WaitForExit(30000) | Out-Null
        `$exitCode = 1460
    }

    `$stdOut = `$outTask.GetAwaiter().GetResult()
    `$stdErr = `$errTask.GetAwaiter().GetResult()
} catch {
    `$stdErr = `$_.Exception.Message
    `$exitCode = 1
}

Set-Content -LiteralPath $stdOutLiteral -Value `$stdOut -Encoding UTF8
Set-Content -LiteralPath $stdErrLiteral -Value `$stdErr -Encoding UTF8
Set-Content -LiteralPath $exitCodeLiteral -Value `$exitCode -Encoding UTF8
"@
}

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

    $shim = New-SystemContextShim -CommandLine $CommandLine `
                                  -WorkingDirectory $WorkingDirectory `
                                  -StdOutPath $stdOutPath `
                                  -StdErrPath $stdErrPath `
                                  -ExitCodePath $exitCodePath `
                                  -TimeoutSeconds $TimeoutSeconds

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
