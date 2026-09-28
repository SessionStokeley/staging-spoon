<#
.SYNOPSIS
    Intune's detection contract, in one place.
.DESCRIPTION
    Shared by the full validation cycle and by the single-command runner, so
    both reach the same verdict from the same evidence.
#>

Set-StrictMode -Version Latest

function Test-DetectionContract {
    <#
    .SYNOPSIS
        Evaluates an execution result against Intune's detection contract.
    .DESCRIPTION
        Intune treats a custom detection script as "detected" only when it
        exits 0 AND writes to STDOUT. Output with a non-zero exit does not
        count, and neither does a zero exit with no output.
    #>
    param([Parameter(Mandatory)][PSCustomObject]$Result)

    $hasOutput = -not [string]::IsNullOrWhiteSpace($Result.StdOut)
    $detected = ($Result.ExitCode -eq 0) -and $hasOutput

    # A non-zero exit is not the same answer as "exit 0, nothing found". The
    # first means the script did not complete, so it reports nothing about the
    # application either way; the second is a real, trustworthy "absent".
    # Collapsing them hides a broken script behind an expected result.
    [PSCustomObject]@{
        Detected  = $detected
        Failed    = $Result.ExitCode -ne 0
        ExitCode  = $Result.ExitCode
        HasOutput = $hasOutput
        Evidence  = $Result.StdOut.Trim()
        Error     = $Result.StdErr.Trim()
        Duration  = $Result.Duration
        Reason    = if ($detected) {
            'Exit code 0 with STDOUT output'
        } elseif ($Result.ExitCode -ne 0) {
            "The detection script did not complete: exit code $($Result.ExitCode). Intune reads any non-zero exit as not detected, so this reinstalls forever"
        } else {
            'Exit code 0 with no STDOUT output'
        }
    }
}

function Format-DetectionOutput {
    <#
    .SYNOPSIS
        Combines what a detection run wrote on both streams.
    .DESCRIPTION
        STDERR carries the reason a detection script failed. Recording only
        STDOUT keeps the one line that explains the failure out of the report,
        which leaves an exit code with nothing to attribute it to.
    #>
    param([Parameter(Mandatory)][PSCustomObject]$Detection)

    $parts = [System.Collections.Generic.List[string]]::new()
    if ($Detection.Evidence) { $parts.Add($Detection.Evidence) }
    if ($Detection.Error)    { $parts.Add("STDERR: $($Detection.Error)") }
    $parts -join "`n"
}
