<#
.SYNOPSIS
    Process execution with child-process awareness and exit-code preservation.
.DESCRIPTION
    A vendor installer frequently bootstraps a child process that performs the
    real installation. The first process exiting does not mean the install is
    complete, and the vendor's exit code must never be silently replaced with 0.
#>

Set-StrictMode -Version Latest

function Stop-ProcessTree {
    <#
    .SYNOPSIS
        Terminates a process and the descendants it started.
    .DESCRIPTION
        Process.Kill(bool) arrived in .NET Core and does not exist on Windows
        PowerShell 5.1, so the tree kill falls back to taskkill there. Only the
        named process and its own descendants are touched; nothing is matched
        by name.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][System.Diagnostics.Process]$Process,
        [int]$GraceMilliseconds = 30000
    )

    if ($Process.HasExited) { return $true }

    $processId = $Process.Id

    try {
        $Process.Kill($true)
    } catch {
        # Either the overload is missing (5.1) or the tree kill failed.
        if (Test-WindowsPlatform) {
            try {
                Start-Process -FilePath 'taskkill.exe' `
                              -ArgumentList '/PID', $processId, '/T', '/F' `
                              -Wait -NoNewWindow -ErrorAction Stop | Out-Null
            } catch {
                try { $Process.Kill() } catch { }
            }
        } else {
            try { $Process.Kill() } catch { }
        }
    }

    $Process.WaitForExit($GraceMilliseconds)
}

function Invoke-ProcessWithTimeout {
    <#
    .SYNOPSIS
        Runs one command and always comes back: completed, timed out or cancelled.
    .DESCRIPTION
        The shared execution layer. Install, detection and uninstall all run
        through this, so a reliability fix applies to every stage rather than
        one of them.

        Output is captured through events rather than by reading the redirected
        streams to their end. Reading to the end waits for EOF, and EOF arrives
        only when every handle to the pipe's write end is closed - including
        the copies an installer passes to a helper or updater that deliberately
        outlives it. That wait is not covered by any process timeout, so a
        successful install whose updater stays resident blocks the caller
        permanently. Here the process wait is what is bounded, and trailing
        output gets a short grace period it can never exceed.
    .PARAMETER CancelSignalPath
        A file whose appearance cancels the run. Polled while waiting, so a
        stuck operation can be released without terminating the session.
    .OUTPUTS
        State is COMPLETED, TIMED_OUT, CANCELLED, or FAILED when the process
        could not be started at all.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$FilePath,
        [string]$Arguments = '',
        [Parameter(Mandatory)][string]$WorkingDirectory,
        [int]$TimeoutSeconds = 1800,
        [int]$StreamDrainSeconds = 5,
        [int]$PollMilliseconds = 250,
        [string]$CancelSignalPath = ''
    )

    $startInfo = [System.Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName               = $FilePath
    $startInfo.Arguments              = $Arguments
    $startInfo.WorkingDirectory       = $WorkingDirectory
    $startInfo.UseShellExecute        = $false
    $startInfo.CreateNoWindow         = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError  = $true

    $stdOutBuilder = [System.Text.StringBuilder]::new()
    $stdErrBuilder = [System.Text.StringBuilder]::new()

    $process   = [System.Diagnostics.Process]::new()
    $process.StartInfo = $startInfo

    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    $startedAt = Get-Date
    $outEvent  = $null
    $errEvent  = $null

    $state     = 'COMPLETED'
    $exitCode  = 1
    $processId = 0

    try {
        $outEvent = Register-ObjectEvent -InputObject $process -EventName OutputDataReceived -MessageData $stdOutBuilder -Action {
            if ($null -ne $EventArgs.Data) { $Event.MessageData.AppendLine($EventArgs.Data) | Out-Null }
        }
        $errEvent = Register-ObjectEvent -InputObject $process -EventName ErrorDataReceived -MessageData $stdErrBuilder -Action {
            if ($null -ne $EventArgs.Data) { $Event.MessageData.AppendLine($EventArgs.Data) | Out-Null }
        }

        try {
            $process.Start() | Out-Null
        } catch {
            $stopwatch.Stop()
            return [PSCustomObject]@{
                FilePath    = $FilePath
                Arguments   = $Arguments
                CommandLine = "$FilePath $Arguments".Trim()
                ProcessId   = 0
                StartedAt   = $startedAt.ToString('o')
                ExitCode    = 1
                StdOut      = ''
                StdErr      = $_.Exception.Message
                Duration    = $stopwatch.Elapsed
                TimedOut    = $false
                Cancelled   = $false
                State       = 'FAILED'
            }
        }

        $processId = $process.Id
        $process.BeginOutputReadLine()
        $process.BeginErrorReadLine()

        $deadline = $startedAt.AddSeconds($TimeoutSeconds)

        # Polled rather than waited on in one call: a short slice keeps the
        # deadline and the cancel signal responsive, and lets the output events
        # be serviced while the process runs.
        while ($true) {
            if ($process.WaitForExit($PollMilliseconds)) {
                $exitCode = $process.ExitCode
                break
            }

            if ($CancelSignalPath -and (Test-Path -LiteralPath $CancelSignalPath)) {
                $state = 'CANCELLED'
                Stop-ProcessTree -Process $process | Out-Null
                $exitCode = 1223
                break
            }

            if ((Get-Date) -ge $deadline) {
                $state = 'TIMED_OUT'
                Stop-ProcessTree -Process $process | Out-Null
                $exitCode = 1460
                break
            }
        }

        # Trailing output gets a bounded grace period. It is allowed to stop
        # early once the buffers settle, and can never hold the caller: a
        # descendant still holding the pipe is expected, not exceptional.
        $drainDeadline = (Get-Date).AddSeconds($StreamDrainSeconds)
        $lastLength = -1

        while ((Get-Date) -lt $drainDeadline) {
            $currentLength = $stdOutBuilder.Length + $stdErrBuilder.Length
            if ($currentLength -eq $lastLength) { break }
            $lastLength = $currentLength
            Start-Sleep -Milliseconds 100
        }
    } finally {
        $stopwatch.Stop()

        # Cancel the readers before disposing; a pipe an outliving descendant
        # still holds would otherwise keep the reader thread attached.
        try { $process.CancelOutputRead() } catch { }
        try { $process.CancelErrorRead() } catch { }

        foreach ($subscription in @($outEvent, $errEvent)) {
            if ($null -ne $subscription) {
                Unregister-Event -SourceIdentifier $subscription.Name -ErrorAction SilentlyContinue
            }
        }

        try { $process.Dispose() } catch { }
    }

    [PSCustomObject]@{
        FilePath    = $FilePath
        Arguments   = $Arguments
        CommandLine = "$FilePath $Arguments".Trim()
        ProcessId   = $processId
        StartedAt   = $startedAt.ToString('o')
        ExitCode    = $exitCode
        StdOut      = $stdOutBuilder.ToString()
        StdErr      = $stdErrBuilder.ToString()
        Duration    = $stopwatch.Elapsed
        TimedOut    = $state -eq 'TIMED_OUT'
        Cancelled   = $state -eq 'CANCELLED'
        State       = $state
    }
}

function Get-InstallerChildProcess {
    <#
    .SYNOPSIS
        Processes that look like a continuation of a specific installation.
    .DESCRIPTION
        Matching on process name alone is not a completion condition. msiexec
        runs as the long-lived Windows Installer service, and "setup" or
        "install" are common names, so a machine-wide name match never goes
        quiet and anything waiting on it blocks until its deadline.

        A process counts only when it was not already running before the
        installation began and did not start before it.
    .PARAMETER BaselineProcessId
        Process ids captured before the installer started. These belong to the
        machine, not to this installation.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string[]]$ProcessName,
        [int[]]$BaselineProcessId = @(),
        [AllowNull()][Nullable[datetime]]$StartedAfter = $null,
        [int[]]$ExcludeProcessId = @()
    )

    $matched = foreach ($name in $ProcessName) {
        foreach ($candidate in (Get-Process -Name $name -ErrorAction SilentlyContinue)) {
            if ($candidate.Id -in $ExcludeProcessId)  { continue }
            if ($candidate.Id -in $BaselineProcessId) { continue }
            if ($candidate.HasExited)                 { continue }

            if ($null -ne $StartedAfter) {
                # StartTime is unreadable for some processes even when
                # elevated. Those are judged by the baseline alone rather than
                # being assumed to belong to this installation.
                $candidateStart = $null
                try { $candidateStart = $candidate.StartTime } catch { }
                if ($null -ne $candidateStart -and $candidateStart -lt $StartedAfter) { continue }
            }

            $candidate
        }
    }

    @($matched)
}

function Get-ProcessBaseline {
    <#
    .SYNOPSIS
        Ids of processes matching the watch names that are already running.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string[]]$ProcessName)

    $ids = foreach ($name in $ProcessName) {
        Get-Process -Name $name -ErrorAction SilentlyContinue | ForEach-Object { $_.Id }
    }

    @($ids)
}

function Invoke-TrackedProcess {
    <#
    .SYNOPSIS
        Starts a process, waits for it, then waits for any installer children.
    .PARAMETER SettleSeconds
        Time to allow asynchronous installer components to finish after the
        tracked process tree exits.
    .OUTPUTS
        PSCustomObject with ExitCode, StdOut, StdErr, Duration and ChildProcesses.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$FilePath,
        [string[]]$ArgumentList = @(),
        [string]$WorkingDirectory = $PWD.Path,
        [int]$TimeoutSeconds = 1800,
        [int]$SettleSeconds = 5,
        [int]$ChildWaitSeconds = 120,
        [string[]]$ChildProcessName = @()
    )

    $watchBaselineNames = if ($ChildProcessName.Count -gt 0) {
        $ChildProcessName
    } else {
        @('msiexec', 'setup', 'install', 'installer')
    }

    # Captured before the process starts: anything already running belongs to
    # the machine and must never be waited on.
    $baselineIds = @(Get-ProcessBaseline -ProcessName $watchBaselineNames)
    $startedAt   = Get-Date

    $startInfo = [System.Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName               = $FilePath
    $startInfo.WorkingDirectory       = $WorkingDirectory
    $startInfo.UseShellExecute        = $false
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError  = $true
    $startInfo.CreateNoWindow         = $true

    foreach ($argument in $ArgumentList) {
        $startInfo.ArgumentList.Add($argument)
    }

    $process = [System.Diagnostics.Process]::new()
    $process.StartInfo = $startInfo

    $stdOutBuilder = [System.Text.StringBuilder]::new()
    $stdErrBuilder = [System.Text.StringBuilder]::new()

    # Async reads prevent a full pipe buffer from deadlocking a chatty installer.
    $outEvent = Register-ObjectEvent -InputObject $process -EventName OutputDataReceived -MessageData $stdOutBuilder -Action {
        if ($null -ne $EventArgs.Data) { $Event.MessageData.AppendLine($EventArgs.Data) | Out-Null }
    }
    $errEvent = Register-ObjectEvent -InputObject $process -EventName ErrorDataReceived -MessageData $stdErrBuilder -Action {
        if ($null -ne $EventArgs.Data) { $Event.MessageData.AppendLine($EventArgs.Data) | Out-Null }
    }

    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    $timedOut = $false
    $observedChildren = [System.Collections.Generic.List[string]]::new()

    try {
        $process.Start() | Out-Null
        $processId = $process.Id
        $process.BeginOutputReadLine()
        $process.BeginErrorReadLine()

        if (-not $process.WaitForExit($TimeoutSeconds * 1000)) {
            $timedOut = $true
            try { $process.Kill($true) } catch { }
            $process.WaitForExit(30000) | Out-Null
        }

        $exitCode = $process.ExitCode

        # Flush any output still buffered after exit.
        $process.WaitForExit()

        if (-not $timedOut) {
            # Waiting for a handover is a courtesy, not a completion condition,
            # so it gets its own short budget rather than the installer's.
            $deadline = (Get-Date).AddSeconds($ChildWaitSeconds)

            $watchNames = if ($ChildProcessName.Count -gt 0) {
                $ChildProcessName
            } else {
                @('msiexec', 'setup', 'install', 'installer')
            }

            do {
                $active = @(Get-InstallerChildProcess -ProcessName $watchNames `
                                                      -BaselineProcessId $baselineIds `
                                                      -StartedAfter $startedAt `
                                                      -ExcludeProcessId @($processId))

                foreach ($child in $active) {
                    $entry = "$($child.ProcessName) (PID $($child.Id))"
                    if ($entry -notin $observedChildren) { $observedChildren.Add($entry) }
                }

                if ($active.Count -eq 0) { break }
                Start-Sleep -Seconds 2
            } while ((Get-Date) -lt $deadline)

            if ((Get-Date) -ge $deadline) {
                Write-Verbose "Installer children still running after ${ChildWaitSeconds}s; continuing"
            }

            if ($SettleSeconds -gt 0) {
                Start-Sleep -Seconds $SettleSeconds
            }
        }
    } finally {
        $stopwatch.Stop()
        Unregister-Event -SourceIdentifier $outEvent.Name -ErrorAction SilentlyContinue
        Unregister-Event -SourceIdentifier $errEvent.Name -ErrorAction SilentlyContinue
        $process.Dispose()
    }

    [PSCustomObject]@{
        FilePath       = $FilePath
        Arguments      = $ArgumentList -join ' '
        ExitCode       = if ($timedOut) { 1460 } else { $exitCode }
        StdOut         = $stdOutBuilder.ToString()
        StdErr         = $stdErrBuilder.ToString()
        Duration       = $stopwatch.Elapsed
        TimedOut       = $timedOut
        ChildProcesses = $observedChildren.ToArray()
    }
}

function Resolve-InstallerExitCode {
    <#
    .SYNOPSIS
        Maps a vendor exit code onto the code the wrapper should return.
    .DESCRIPTION
        Meaningful installer codes are preserved, not flattened to 0 because
        the PowerShell wrapper happened to finish. Reboot codes are preserved
        or translated according to the configured strategy.
    .PARAMETER RebootStrategy
        Preserve  - return the reboot code unchanged so Intune sees it.
        Translate - map reboot codes to 0 (only when reboot is suppressed and
                    the application is fully usable without one).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][int]$VendorExitCode,
        [int[]]$SuccessExitCodes = @(0),
        [int[]]$RebootExitCodes = @(1641, 3010),
        [ValidateSet('Preserve', 'Translate')][string]$RebootStrategy = 'Preserve'
    )

    $isReboot  = $VendorExitCode -in $RebootExitCodes
    $isSuccess = $VendorExitCode -in $SuccessExitCodes -or $isReboot

    $wrapperExitCode = if ($isReboot -and $RebootStrategy -eq 'Translate') {
        0
    } else {
        $VendorExitCode
    }

    [PSCustomObject]@{
        VendorExitCode  = $VendorExitCode
        WrapperExitCode = $wrapperExitCode
        IsSuccess       = $isSuccess
        RequiresReboot  = $isReboot
        Translated      = $wrapperExitCode -ne $VendorExitCode
        Interpretation  = if ($isReboot) {
            "Success; reboot required (vendor returned $VendorExitCode)"
        } elseif ($isSuccess) {
            "Success (vendor returned $VendorExitCode)"
        } else {
            "Failure (vendor returned $VendorExitCode)"
        }
    }
}

function Get-ExecutionContextIdentity {
    <#
    .SYNOPSIS
        Reports the identity and interactivity of the current session.
    #>
    [CmdletBinding()]
    param()

    $identity = [System.Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [System.Security.Principal.WindowsPrincipal]::new($identity)

    [PSCustomObject]@{
        UserName      = $identity.Name
        IsSystem      = $identity.IsSystem
        IsElevated    = $principal.IsInRole([System.Security.Principal.WindowsBuiltInRole]::Administrator)
        IsInteractive = [Environment]::UserInteractive
        Is64BitProcess = [Environment]::Is64BitProcess
        Context       = if ($identity.IsSystem) {
            'System'
        } elseif ($principal.IsInRole([System.Security.Principal.WindowsBuiltInRole]::Administrator)) {
            'Administrator'
        } else {
            'User'
        }
    }
}
