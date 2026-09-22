<#
.SYNOPSIS
    Process execution with child-process awareness and exit-code preservation.
.DESCRIPTION
    A vendor installer frequently bootstraps a child process that performs the
    real installation. The first process exiting does not mean the install is
    complete, and the vendor's exit code must never be silently replaced with 0.
#>

Set-StrictMode -Version Latest

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
