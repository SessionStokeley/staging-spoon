<#
.SYNOPSIS
    Runs one of a package's exact commands and shows everything it produced.
.DESCRIPTION
    The full validation cycle proves a package; this proves one command. Use it
    to get an install or a detection script working before spending a whole
    install-detect-uninstall-detect cycle on it, and to see why one stage of a
    failed cycle behaved as it did.

    The command run is the same string the cycle runs and the same string
    entered into Intune, read from the manifest. Both streams and the exit code
    are shown in full: a stage that reports only "exit code 1" leaves nothing
    to work from.

    Nothing is installed or removed that the command itself does not do, and no
    package is produced. This never writes a .intunewin.
.PARAMETER SourcePath
    The deployment source directory.
.PARAMETER Command
    Install, Uninstall or Detection.
.PARAMETER ManifestPath
    PackageManifest.json. Defaults to the one in the source directory.
.PARAMETER SystemContext
    Run as NT AUTHORITY\SYSTEM, the way Intune will. Requires elevation.
.PARAMETER Staged
    Copy the package to a temporary directory first, as the full cycle does, so
    a dependency on the source location surfaces here.
.EXAMPLE
    .\src\Testing\Invoke-PackageCommand.ps1 -SourcePath .\source -Command Detection
.EXAMPLE
    .\src\Testing\Invoke-PackageCommand.ps1 -SourcePath .\source -Command Install -SystemContext
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$SourcePath,
    [Parameter(Mandatory)][ValidateSet('Install', 'Uninstall', 'Detection')][string]$Command,
    [string]$ManifestPath = '',
    [switch]$SystemContext,
    [switch]$Staged,
    [int]$TimeoutSeconds = 1800,
    [string]$CancelSignalPath = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$coreRoot = Join-Path (Split-Path $PSScriptRoot -Parent) 'Core'
. (Join-Path $coreRoot 'PackageManifest.ps1')
. (Join-Path $coreRoot 'ProcessRunner.ps1')
. (Join-Path $coreRoot 'DetectionContract.ps1')
. (Join-Path $coreRoot 'FailureClassifier.ps1')
. (Join-Path $PSScriptRoot 'SystemContext.ps1')

function Write-Line {
    param([string]$Message = '', [ValidateSet('Info', 'Pass', 'Fail', 'Detail')][string]$Status = 'Info')

    $color = switch ($Status) {
        'Pass'   { 'Green' }
        'Fail'   { 'Red' }
        'Detail' { 'DarkGray' }
        default  { 'Cyan' }
    }
    Write-Host $Message -ForegroundColor $color
}

$resolvedSource = (Resolve-Path -LiteralPath $SourcePath).ProviderPath

if (-not $ManifestPath) {
    $ManifestPath = Join-Path $resolvedSource 'PackageManifest.json'
}
if (-not (Test-Path -LiteralPath $ManifestPath)) {
    throw "Manifest not found: $ManifestPath. Build once, or pass -ManifestPath."
}

$manifest = Import-PackageManifest -Path $ManifestPath

$commandLine = switch ($Command) {
    'Install'   { $manifest.InstallCommand }
    'Uninstall' { $manifest.UninstallCommand }
    'Detection' { Get-DetectionCommand -Manifest $manifest }
}

if (-not $commandLine) {
    throw "The manifest defines no $Command command."
}

$identity = Get-ExecutionContextIdentity
if ($SystemContext -and -not $identity.IsElevated) {
    throw 'SYSTEM-context execution requires an elevated session'
}

# Staging is optional here on purpose. The full cycle always stages, because a
# package that only works where it was built is a package that fails on a
# device; while a command is still being got working, running it in place keeps
# the edit-run loop short.
$workingDirectory = $resolvedSource
$stagedRoot = ''

if ($Staged) {
    $stagedRoot = Join-Path $env:SystemRoot ("Temp\IntuneCmd-" + [guid]::NewGuid().ToString('N').Substring(0, 12))
    New-Item -Path $stagedRoot -ItemType Directory -Force | Out-Null
    Copy-Item -Path (Join-Path $resolvedSource '*') -Destination $stagedRoot -Recurse -Force
    $workingDirectory = $stagedRoot
}

Write-Line ''
Write-Line "Running the package's $($Command.ToLowerInvariant()) command"
Write-Line "  Command  : $commandLine" 'Detail'
Write-Line "  Directory: $workingDirectory" 'Detail'
Write-Line "  Context  : $(if ($SystemContext) { 'NT AUTHORITY\SYSTEM' } else { $identity.Context })" 'Detail'
Write-Line ''

try {
    $result = Invoke-InContext -CommandLine $commandLine `
                               -WorkingDirectory $workingDirectory `
                               -Context $(if ($SystemContext) { 'System' } else { 'Current' }) `
                               -TimeoutSeconds $TimeoutSeconds `
                               -CancelSignalPath $CancelSignalPath
} finally {
    if ($stagedRoot -and (Test-Path -LiteralPath $stagedRoot)) {
        Remove-Item -LiteralPath $stagedRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Write-Line ("Returned after {0:n1}s with exit code {1}" -f $result.Duration.TotalSeconds, $result.ExitCode)
Write-Line ''

# Both streams in full. Which one carried the answer is exactly what is in
# question when a command fails, so neither is summarised away.
foreach ($stream in @(
    @{ Label = 'STDOUT'; Text = $result.StdOut }
    @{ Label = 'STDERR'; Text = $result.StdErr }
)) {
    $text = [string]$stream.Text
    Write-Line "$($stream.Label):"
    if ([string]::IsNullOrWhiteSpace($text)) {
        Write-Line '  (nothing)' 'Detail'
    } else {
        foreach ($line in ($text -split "`r?`n")) {
            if ($line.Trim()) { Write-Host "  $line" }
        }
    }
    Write-Line ''
}

$succeeded = $false

if ($Command -eq 'Detection') {
    $detection = Test-DetectionContract -Result $result

    Write-Line 'Intune would conclude:'
    if ($detection.Detected) {
        Write-Line '  INSTALLED - exit 0 with STDOUT output' 'Pass'
    } elseif ($detection.Failed) {
        Write-Line '  NOT INSTALLED - and for the wrong reason' 'Fail'
        Write-Line "  $($detection.Reason)" 'Fail'
        if (-not $detection.Error -and -not $detection.Evidence) {
            Write-Line ''
            Write-Line '  The script exited non-zero without writing to either stream, so it' 'Fail'
            Write-Line '  failed before its own error handling ran: a parse error, or a' 'Fail'
            Write-Line '  statement outside the try block that threw. Run the script directly' 'Fail'
            Write-Line '  to see the parser message:' 'Fail'
            Write-Line "    powershell.exe -NoProfile -File `"$(Join-Path $resolvedSource $manifest.DetectionScript)`"" 'Detail'
        }
    } else {
        Write-Line '  NOT INSTALLED - exit 0 with no output' 'Detail'
        Write-Line '  That is a real answer. Expected before install, a failure after it.' 'Detail'
    }

    # Absence is a legitimate result for this command, so only a script that
    # did not complete counts as a failed run.
    $succeeded = -not $detection.Failed
} else {
    $exitCodeResult = Resolve-InstallerExitCode -VendorExitCode $result.ExitCode `
                                                -SuccessExitCodes @($manifest.ExpectedExitCodes | Where-Object { $_ -notin @(1641, 3010) }) `
                                                -RebootExitCodes @(1641, 3010)

    if ($exitCodeResult.IsSuccess) {
        Write-Line "  $($exitCodeResult.Interpretation)" 'Pass'
    } else {
        Write-Line "  $($exitCodeResult.Interpretation)" 'Fail'

        $classification = Get-FailureClassification -Stage $Command `
                                                    -ExitCode $result.ExitCode `
                                                    -Output (($result.StdOut + "`n" + $result.StdErr).Trim()) `
                                                    -ExpectedExitCodes $manifest.ExpectedExitCodes `
                                                    -ExecutionContextName $(if ($SystemContext) { 'System' } else { $identity.Context })
        Write-Line "  Classification: $($classification.Classification)" 'Fail'
        Write-Line "  $($classification.Reason)" 'Fail'
    }

    $succeeded = $exitCodeResult.IsSuccess
}

Write-Line ''
if ($succeeded) {
    Write-Line 'One command is not a validated package. When each behaves, run the full' 'Detail'
    Write-Line 'cycle with Build-IntunePackage.ps1, which packages only after it passes.' 'Detail'
    exit 0
}

exit 1
