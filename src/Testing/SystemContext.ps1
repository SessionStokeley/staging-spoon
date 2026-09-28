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
        [Parameter(Mandatory)][string]$StatePath,
        [Parameter(Mandatory)][string]$ModuleDirectory,
        [int]$TimeoutSeconds = 1800,
        [string]$CancelSignalPath = ''
    )

    $command = Split-ExecutableCommandLine -CommandLine $CommandLine

    if (-not $command.Executable) {
        throw "Cannot run an empty command line as SYSTEM"
    }

    $commandLiteral  = ConvertTo-PowerShellLiteral -Value $CommandLine
    $workingLiteral  = ConvertTo-PowerShellLiteral -Value $WorkingDirectory
    $stdOutLiteral   = ConvertTo-PowerShellLiteral -Value $StdOutPath
    $stdErrLiteral   = ConvertTo-PowerShellLiteral -Value $StdErrPath
    $exitCodeLiteral = ConvertTo-PowerShellLiteral -Value $ExitCodePath
    $stateLiteral    = ConvertTo-PowerShellLiteral -Value $StatePath
    $cancelLiteral   = ConvertTo-PowerShellLiteral -Value $CancelSignalPath
    $moduleLiteral   = ConvertTo-PowerShellLiteral -Value $ModuleDirectory

    # The shim runs the command through the same execution layer the current
    # user context uses. Two implementations of "run a process and wait" drift,
    # and the one that is harder to test is the one that breaks.
    @"
`$ErrorActionPreference = 'Stop'
`$exitCode = 1
`$stdOut = ''
`$stdErr = ''
`$state = 'FAILED'

try {
    `$moduleRoot = $moduleLiteral
    . (Join-Path `$moduleRoot 'Platform.ps1')
    . (Join-Path `$moduleRoot 'ProcessRunner.ps1')
    . (Join-Path `$moduleRoot 'SystemContext.ps1')

    `$command = Split-ExecutableCommandLine -CommandLine $commandLiteral

    `$result = Invoke-ProcessWithTimeout -FilePath `$command.Executable ``
                                        -Arguments `$command.Arguments ``
                                        -WorkingDirectory $workingLiteral ``
                                        -TimeoutSeconds $TimeoutSeconds ``
                                        -CancelSignalPath $cancelLiteral

    `$exitCode = `$result.ExitCode
    `$stdOut   = `$result.StdOut
    `$stdErr   = `$result.StdErr
    `$state    = `$result.State
} catch {
    `$stdErr = `$_.Exception.Message
    `$exitCode = 1
    `$state = 'FAILED'
}

Set-Content -LiteralPath $stdOutLiteral -Value `$stdOut -Encoding UTF8
Set-Content -LiteralPath $stdErrLiteral -Value `$stdErr -Encoding UTF8
Set-Content -LiteralPath $exitCodeLiteral -Value `$exitCode -Encoding UTF8
Set-Content -LiteralPath $stateLiteral -Value `$state -Encoding UTF8
"@
}

function Get-TaskWaitDecision {
    <#
    .SYNOPSIS
        Decides whether a SYSTEM-context run has finished, from one poll.
    .DESCRIPTION
        Kept separate from the polling loop so the rule can be tested without
        a Task Scheduler. The rule that matters: a task that has not yet been
        seen Running has not finished, however un-Running it currently looks.
        Start-ScheduledTask only queues the request, so the state immediately
        afterwards is still 'Ready'.
    .PARAMETER Reported
        Whether the shim has written its exit code.
    .PARAMETER TaskState
        The task's current state, or an empty string if the task is gone.
    .OUTPUTS
        REPORTED, VANISHED, STOPPED, NEVER_STARTED or WAITING.
    #>
    [CmdletBinding()]
    param(
        [bool]$Reported,
        [AllowEmptyString()][string]$TaskState,
        [bool]$ObservedRunning,
        [bool]$StartDeadlinePassed
    )

    if ($Reported) { return 'REPORTED' }
    if (-not $TaskState) { return 'VANISHED' }
    if ($TaskState -eq 'Running') { return 'WAITING' }
    if ($ObservedRunning) { return 'STOPPED' }
    if ($StartDeadlinePassed) { return 'NEVER_STARTED' }
    'WAITING'
}

function Invoke-AsSystem {
    <#
    .SYNOPSIS
        Runs a command line as SYSTEM and returns its exit code and output.
    .DESCRIPTION
        The command is wrapped in a shim that redirects streams to files, since
        a scheduled task has nowhere to write a console. The shim records the
        wrapped command's real exit code so it is not lost.
    .PARAMETER TaskStartSeconds
        How long to allow for Task Scheduler to actually launch the task before
        concluding it never started. Registration and launch are asynchronous.
    .OUTPUTS
        PSCustomObject with ExitCode, StdOut, StdErr, Duration and TimedOut.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$CommandLine,
        [Parameter(Mandatory)][string]$WorkingDirectory,
        [int]$TimeoutSeconds = 1800,
        [string]$CancelSignalPath = '',
        [int]$TaskStartSeconds = 60
    )

    $identity = [System.Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [System.Security.Principal.WindowsPrincipal]::new($identity)
    if (-not $principal.IsInRole([System.Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw "SYSTEM-context testing requires an elevated session"
    }

    $taskName = "IntuneValidation-$([guid]::NewGuid().ToString('N').Substring(0, 12))"
    $shimRoot = Join-Path $env:SystemRoot "Temp\$taskName"
    $moduleRoot = Join-Path $shimRoot 'modules'
    New-Item -Path $moduleRoot -ItemType Directory -Force | Out-Null

    $stdOutPath   = Join-Path $shimRoot 'stdout.log'
    $stdErrPath   = Join-Path $shimRoot 'stderr.log'
    $exitCodePath = Join-Path $shimRoot 'exitcode.txt'
    $statePath    = Join-Path $shimRoot 'state.txt'
    $shimPath     = Join-Path $shimRoot 'shim.ps1'

    # The shim runs as SYSTEM and needs the execution layer. The modules are
    # copied beside it under %SystemRoot%\Temp rather than referenced where
    # they live, because the repository may sit somewhere SYSTEM cannot read.
    $coreDirectory = Join-Path (Split-Path $PSScriptRoot -Parent) 'Core'
    foreach ($module in @(
        (Join-Path $coreDirectory 'Platform.ps1')
        (Join-Path $coreDirectory 'ProcessRunner.ps1')
        (Join-Path $PSScriptRoot 'SystemContext.ps1')
    )) {
        Copy-Item -LiteralPath $module -Destination $moduleRoot -Force
    }

    $shim = New-SystemContextShim -CommandLine $CommandLine `
                                  -WorkingDirectory $WorkingDirectory `
                                  -StdOutPath $stdOutPath `
                                  -StdErrPath $stdErrPath `
                                  -ExitCodePath $exitCodePath `
                                  -StatePath $statePath `
                                  -ModuleDirectory $moduleRoot `
                                  -TimeoutSeconds $TimeoutSeconds `
                                  -CancelSignalPath $CancelSignalPath

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

        # Completion is the shim writing its result, never the task's state.
        # Start-ScheduledTask returns as soon as the request is queued, so the
        # task is still 'Ready' for a moment afterwards; treating "not Running"
        # as "finished" ends the wait before the command has even started, and
        # then reports a Task Scheduler code as though it were the command's
        # exit code. Task state is only the backstop for a task that never
        # starts or dies without reporting.
        $deadline      = (Get-Date).AddSeconds($TimeoutSeconds + 120)
        $startDeadline = (Get-Date).AddSeconds($TaskStartSeconds)
        $cancelled     = $false
        $observedRunning = $false
        $neverStarted  = $false

        do {
            Start-Sleep -Milliseconds 500

            if ($CancelSignalPath -and (Test-Path -LiteralPath $CancelSignalPath)) {
                $cancelled = $true
                Stop-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
                break
            }

            $task = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
            $taskState = if ($task) { [string]$task.State } else { '' }
            if ($taskState -eq 'Running') { $observedRunning = $true }

            # The shim's own report is authoritative and is checked first, so a
            # task that finishes between two polls is still read correctly.
            $decision = Get-TaskWaitDecision -Reported (Test-Path -LiteralPath $exitCodePath) `
                                             -TaskState $taskState `
                                             -ObservedRunning $observedRunning `
                                             -StartDeadlinePassed ((Get-Date) -ge $startDeadline)

            if ($decision -eq 'WAITING') { continue }

            if ($decision -eq 'NEVER_STARTED') { $neverStarted = $true }

            # A task that stopped without reporting gets a moment for its files
            # to appear before that is called a failure.
            if ($decision -in @('STOPPED', 'VANISHED')) { Start-Sleep -Milliseconds 500 }

            break
        } while ((Get-Date) -lt $deadline)

        if (-not $cancelled -and -not $neverStarted -and (Get-Date) -ge $deadline) {
            $timedOut = $true
            Stop-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
        }

        $reported = Test-Path -LiteralPath $exitCodePath

        # The shim writes these only after the wrapped command returns.
        $exitCode = if ($reported) {
            [int](Get-Content -LiteralPath $exitCodePath -Raw).Trim()
        } elseif ($cancelled) {
            1223
        } elseif ($timedOut) {
            1460
        } else {
            1
        }

        $state = if (Test-Path -LiteralPath $statePath) {
            (Get-Content -LiteralPath $statePath -Raw).Trim()
        } elseif ($cancelled) {
            'CANCELLED'
        } elseif ($timedOut) {
            'TIMED_OUT'
        } else {
            'FAILED'
        }

        $stdOut = if (Test-Path -LiteralPath $stdOutPath) { Get-Content -LiteralPath $stdOutPath -Raw } else { '' }
        $stdErr = if (Test-Path -LiteralPath $stdErrPath) { Get-Content -LiteralPath $stdErrPath -Raw } else { '' }

        # A run that produced no result of its own would otherwise come back as
        # a bare exit 1 with both streams empty, which reads exactly like a
        # command that ran and failed. Say which one it was.
        if (-not $reported -and -not $cancelled -and -not $timedOut) {
            $info = Get-ScheduledTaskInfo -TaskName $taskName -ErrorAction SilentlyContinue
            $launchResult = if ($info) { $info.LastTaskResult } else { $null }

            $explanation = if ($neverStarted) {
                "The scheduled task did not start within $TaskStartSeconds seconds, so the command never ran."
            } else {
                'The scheduled task ended without reporting a result, so the command did not run to completion.'
            }

            if ($null -ne $launchResult) {
                $explanation += " Task Scheduler last result: $launchResult."
            }

            $stdErr = ($stdErr, $explanation | Where-Object { $_ }) -join "`n"
        }
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
        TimedOut    = $state -eq 'TIMED_OUT'
        Cancelled   = $state -eq 'CANCELLED'
        State       = $state
        ProcessId   = 0
        StartedAt   = $stopwatch.Elapsed.ToString()
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
        [int]$TimeoutSeconds = 1800,
        [string]$CancelSignalPath = ''
    )

    # The command is started directly rather than through cmd.exe. Handing a
    # command line to "cmd /c" makes cmd strip the outermost pair of quotes in
    # the string, which turns a correctly quoted argument into an unbalanced
    # one. Both contexts run through the same execution layer, because
    # validating one proves nothing about the other unless they agree.
    $command = Split-ExecutableCommandLine -CommandLine $CommandLine

    $result = Invoke-ProcessWithTimeout -FilePath $command.Executable `
                                        -Arguments $command.Arguments `
                                        -WorkingDirectory $WorkingDirectory `
                                        -TimeoutSeconds $TimeoutSeconds `
                                        -CancelSignalPath $CancelSignalPath

    # The context label is reporting detail. Failing to read it must not
    # discard an execution result that was obtained successfully.
    $context = try {
        $identity  = [System.Security.Principal.WindowsIdentity]::GetCurrent()
        $principal = [System.Security.Principal.WindowsPrincipal]::new($identity)
        if ($principal.IsInRole([System.Security.Principal.WindowsBuiltInRole]::Administrator)) { 'Administrator' } else { 'User' }
    } catch {
        'Unknown'
    }

    [PSCustomObject]@{
        CommandLine = $CommandLine
        ExitCode    = $result.ExitCode
        StdOut      = $result.StdOut
        StdErr      = $result.StdErr
        Duration    = $result.Duration
        TimedOut    = $result.TimedOut
        Cancelled   = $result.Cancelled
        State       = $result.State
        ProcessId   = $result.ProcessId
        StartedAt   = $result.StartedAt
        Context     = $context
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
        [int]$TimeoutSeconds = 1800,
        [string]$CancelSignalPath = ''
    )

    if ($Context -eq 'System') {
        Invoke-AsSystem -CommandLine $CommandLine -WorkingDirectory $WorkingDirectory `
                        -TimeoutSeconds $TimeoutSeconds -CancelSignalPath $CancelSignalPath
    } else {
        Invoke-AsCurrentUser -CommandLine $CommandLine -WorkingDirectory $WorkingDirectory `
                             -TimeoutSeconds $TimeoutSeconds -CancelSignalPath $CancelSignalPath
    }
}
