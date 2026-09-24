<#
.SYNOPSIS
    Tests for the validation modules.
.DESCRIPTION
    Covers path classification, command parsing, manifest validation, failure
    classification, the pre-build gate, config export and report rendering.
.EXAMPLE
    pwsh -NoProfile -File .\tests\Run-Tests.ps1
#>

[CmdletBinding()]
param([string]$WorkPath = (Join-Path ([System.IO.Path]::GetTempPath()) 'staging-spoon-tests'))

$ErrorActionPreference = 'Stop'

$repo = Split-Path $PSScriptRoot -Parent
. (Join-Path $repo 'src/Core/PreBuildValidator.ps1')
. (Join-Path $repo 'src/Core/Platform.ps1')
. (Join-Path $repo 'src/Core/ProcessRunner.ps1')
. (Join-Path $repo 'src/Core/DetectionContract.ps1')
. (Join-Path $repo 'src/Testing/SystemContext.ps1')
. (Join-Path $repo 'src/Core/FailureClassifier.ps1')
. (Join-Path $repo 'src/Reporting/Export-IntuneConfiguration.ps1')
. (Join-Path $repo 'src/Reporting/New-ValidationReport.ps1')

$script:failures = 0

function Test-Case {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][AllowNull()]$Condition,
        [string]$Detail = ''
    )

    if ($Condition) {
        Write-Host "  PASS $Name"
    } else {
        Write-Host "  FAIL $Name $Detail" -ForegroundColor Red
        $script:failures++
    }
}

Remove-Item -LiteralPath $WorkPath -Recurse -Force -ErrorAction SilentlyContinue
New-Item -Path $WorkPath -ItemType Directory -Force | Out-Null

# --- Command parsing ---------------------------------------------------------
Write-Host "`nCommand parsing"

$parsed = ConvertFrom-CommandLine -CommandLine 'powershell.exe -NoProfile -ExecutionPolicy Bypass -File ".\Install.ps1"'
Test-Case 'executable extracted' ($parsed.Executable -eq 'powershell.exe') $parsed.Executable
Test-Case 'quoted argument unwrapped' ($parsed.Arguments[-1] -eq '.\Install.ps1') $parsed.Arguments[-1]

Test-Case 'flags msiexec /qb'  (@(Find-InteractiveArgument -CommandLine 'msiexec /i a.msi /qb').Count -eq 1)
Test-Case 'allows msiexec /qn' (@(Find-InteractiveArgument -CommandLine 'msiexec /i a.msi /qn').Count -eq 0)
Test-Case 'flags /passive'     (@(Find-InteractiveArgument -CommandLine 'setup.exe /passive').Count -eq 1)

Test-Case 'finds duplicate switch' (@(Find-DuplicateArgument -CommandLine 'setup.exe /S /norestart /S').Count -eq 1)
Test-Case 'no false duplicate'     (@(Find-DuplicateArgument -CommandLine 'msiexec /i a.msi /qn /norestart').Count -eq 0)

Test-Case 'comparison ignores whitespace' (Compare-IntuneCommand -TestedCommand 'a.exe  /S' -IntuneCommand 'a.exe /S' -CommandType 'Install').Matches
Test-Case 'comparison detects drift' (-not (Compare-IntuneCommand -TestedCommand 'a.exe /S' -IntuneCommand 'a.exe /quiet' -CommandType 'Install').Matches)

# --- Path classification -----------------------------------------------------
Write-Host "`nPath classification"

Test-Case 'Program Files is valid'      ((Get-PathClassification -Path 'C:\Program Files\Vendor\App').Classification -eq 'VALID')
Test-Case 'ProgramData is valid'        ((Get-PathClassification -Path 'C:\ProgramData\Vendor\cfg.xml').Classification -eq 'VALID')
Test-Case 'developer profile invalid'   ((Get-PathClassification -Path 'C:\Users\Developer\Desktop\App\Installer.exe').Classification -eq 'INVALID')
Test-Case 'build directory invalid'     ((Get-PathClassification -Path 'C:\Build\App\Installer.exe').Classification -eq 'INVALID')
Test-Case 'UNC path invalid'            ((Get-PathClassification -Path '\\server\share\app.msi').Classification -eq 'INVALID')
Test-Case 'non-system drive invalid'    ((Get-PathClassification -Path 'D:\Apps\thing.exe').Classification -eq 'INVALID')
# An all-users shortcut legitimately lives under the Public profile.
Test-Case 'Public profile not flagged'  ((Get-PathClassification -Path 'C:\Users\Public\Desktop\a.lnk').Classification -ne 'INVALID')

# Paths with spaces must survive extraction intact. Truncating
# "C:\Program Files\Vendor\App" at the space leaves "C:\Program", which matches
# no known-good location and warns on essentially every real package.
$spacedSource = Join-Path $WorkPath 'spaced'
New-Item -Path $spacedSource -ItemType Directory -Force | Out-Null
@'
$ExpectedFile = "C:\Program Files\JetBrains\IntelliJ IDEA\bin\idea64.exe"
$Legacy       = "C:\Program Files (x86)\Vendor\App.exe"
$Bad          = "C:\Users\jsmith\Desktop\Setup.exe"
if (Test-Path HKLM:\SOFTWARE\Contoso) { }
'@ | Set-Content -LiteralPath (Join-Path $spacedSource 'Detection.ps1')

$spacedFindings = @(Find-AbsolutePath -PackagePath $spacedSource)

Test-Case 'Program Files path not truncated' (
    @($spacedFindings | Where-Object { $_.Path -eq 'C:\Program Files\JetBrains\IntelliJ IDEA\bin\idea64.exe' }).Count -eq 1
) (($spacedFindings | ForEach-Object { $_.Path }) -join ' | ')

Test-Case 'Program Files path is valid' (
    @($spacedFindings | Where-Object { $_.Path -like 'C:\Program Files\*' -and $_.Classification -ne 'VALID' }).Count -eq 0
)
Test-Case 'x86 Program Files is valid' (
    @($spacedFindings | Where-Object { $_.Path -like '*(x86)*' -and $_.Classification -eq 'VALID' }).Count -eq 1
)
Test-Case 'developer path still flagged' (
    @($spacedFindings | Where-Object { $_.Path -like '*jsmith*' -and $_.Classification -eq 'INVALID' }).Count -eq 1
)
Test-Case 'registry path still ignored' (
    @($spacedFindings | Where-Object { $_.Path -like '*SOFTWARE*' }).Count -eq 0
)

# --- SYSTEM-context shim -----------------------------------------------------
# The scheduled task itself needs Windows, but the shim it runs is an ordinary
# script. Generating and executing one here covers the quoting that previously
# made every SYSTEM-context stage fail with exit 1 and no output.
Write-Host "`nSYSTEM-context shim"

Test-Case 'literal escapes apostrophes' ((ConvertTo-PowerShellLiteral -Value "it's") -eq "'it''s'")

# Neither context may route through cmd.exe. "cmd /c" strips the outermost
# pair of quotes in its string, so a correctly quoted argument arrives
# unbalanced, and a command validated in one context would not be the command
# run in the other.
$systemContextSource = Get-Content -LiteralPath (Join-Path $repo 'src/Testing/SystemContext.ps1') -Raw
$systemContextCode = [regex]::Replace($systemContextSource, '(?s)<#.*?#>', '')
$systemContextCode = ($systemContextCode -split "`r?`n" |
                      Where-Object { -not $_.TrimStart().StartsWith('#') }) -join "`n"
Test-Case 'no context shells out to cmd' ($systemContextCode -notmatch 'cmd\.exe')

$bareCommand = Split-ExecutableCommandLine -CommandLine 'powershell.exe -NoProfile -File ".\Install.ps1"'
Test-Case 'executable split from arguments' ($bareCommand.Executable -eq 'powershell.exe')
Test-Case 'arguments kept verbatim'         ($bareCommand.Arguments -eq '-NoProfile -File ".\Install.ps1"')

$quotedCommand = Split-ExecutableCommandLine -CommandLine '"C:\Program Files\App\run.exe" /S /norestart'
Test-Case 'quoted executable with spaces'   ($quotedCommand.Executable -eq 'C:\Program Files\App\run.exe')
Test-Case 'arguments after quoted exe'      ($quotedCommand.Arguments -eq '/S /norestart')

$shimWork = Join-Path $WorkPath 'shim'
New-Item -Path $shimWork -ItemType Directory -Force | Out-Null

$payloadPath = Join-Path $shimWork 'Payload.ps1'
'Write-Output "ran in $PWD"; exit 3' | Set-Content -LiteralPath $payloadPath -Encoding UTF8

# The running host's own executable: present on both editions, and on Windows
# its path contains a space, which is the case that used to break.
$shellPath = [System.Diagnostics.Process]::GetCurrentProcess().MainModule.FileName
$shimCommand = '"{0}" -NoProfile -NonInteractive -File "{1}"' -f $shellPath, $payloadPath

$stdOutPath   = Join-Path $shimWork 'stdout.log'
$stdErrPath   = Join-Path $shimWork 'stderr.log'
$exitCodePath = Join-Path $shimWork 'exitcode.txt'
$statePath    = Join-Path $shimWork 'state.txt'
$shimPath     = Join-Path $shimWork 'shim.ps1'

# The shim runs as SYSTEM and cannot assume the repository is readable from
# there, so the execution layer is staged beside it.
$shimModules = Join-Path $shimWork 'modules'
New-Item -Path $shimModules -ItemType Directory -Force | Out-Null
foreach ($module in @('src/Core/Platform.ps1', 'src/Core/ProcessRunner.ps1', 'src/Testing/SystemContext.ps1')) {
    Copy-Item -LiteralPath (Join-Path $repo $module) -Destination $shimModules -Force
}

$shimText = New-SystemContextShim -CommandLine $shimCommand -WorkingDirectory $shimWork `
                                  -StdOutPath $stdOutPath -StdErrPath $stdErrPath `
                                  -ExitCodePath $exitCodePath -StatePath $statePath `
                                  -ModuleDirectory $shimModules -TimeoutSeconds 120

# The original defect was a generated script that PowerShell mis-parsed, so the
# shim must be checked as code rather than only as text.
$shimTokens = $null
$shimErrors = $null
[System.Management.Automation.Language.Parser]::ParseInput($shimText, [ref]$shimTokens, [ref]$shimErrors) | Out-Null
Test-Case 'generated shim parses'    ($shimErrors.Count -eq 0) ($shimErrors | Select-Object -First 1)
Test-Case 'shim does not shell out'  ($shimText -notmatch 'cmd\.exe')

Set-Content -LiteralPath $shimPath -Value $shimText -Encoding UTF8
& $shellPath -NoProfile -File $shimPath | Out-Null

Test-Case 'shim recorded an exit code' (Test-Path -LiteralPath $exitCodePath)

if (Test-Path -LiteralPath $exitCodePath) {
    $shimExit   = (Get-Content -LiteralPath $exitCodePath -Raw).Trim()
    $shimOutput = if (Test-Path -LiteralPath $stdOutPath) { Get-Content -LiteralPath $stdOutPath -Raw } else { '' }

    Test-Case 'wrapped exit code preserved' ($shimExit -eq '3') $shimExit
    Test-Case 'wrapped command produced output' ($shimOutput -match 'ran in') $shimOutput
    Test-Case 'command ran in the package directory' ($shimOutput -match ([regex]::Escape($shimWork))) $shimOutput
    Test-Case 'shim reports its state' ((Get-Content -LiteralPath $statePath -Raw).Trim() -eq 'COMPLETED')
}

# The user context runs the same command the SYSTEM context does. Validating
# one proves nothing about the other unless both execute it identically.
$userResult = Invoke-AsCurrentUser -CommandLine $shimCommand -WorkingDirectory $shimWork -TimeoutSeconds 120

Test-Case 'user context preserves exit code' ($userResult.ExitCode -eq 3) $userResult.ExitCode
Test-Case 'user context reports state'       ($userResult.State -eq 'COMPLETED') $userResult.State
Test-Case 'user context captures output'     ($userResult.StdOut -match 'ran in') $userResult.StdOut
Test-Case 'user context honours working dir' ($userResult.StdOut -match ([regex]::Escape($shimWork)))
Test-Case 'user context did not time out'    (-not $userResult.TimedOut)

# --- Execution layer ---------------------------------------------------------
# Install, detection and uninstall all run through Invoke-ProcessWithTimeout,
# so every state it can return is exercised here once.
Write-Host "`nExecution layer"

# THE DEFECT THIS COVERS: a successful installer whose helper or updater keeps
# running inherits the redirected pipe, so reading the stream to its end waits
# for an EOF that never comes. The process wait had already returned with the
# exit code; the caller then blocked permanently on the stream, and no timeout
# covered it. This must return promptly with the output that was produced.
$survivorScript = Join-Path $shimWork 'Survivor.ps1'
@"
`$child = Start-Process -FilePath '$shellPath' ``
                       -ArgumentList '-NoProfile', '-NonInteractive', '-Command', 'Start-Sleep -Seconds 300' ``
                       -PassThru
Write-Output "installer-finished"
exit 0
"@ | Set-Content -LiteralPath $survivorScript -Encoding UTF8

$survivorWatch = [System.Diagnostics.Stopwatch]::StartNew()
$survivorResult = Invoke-ProcessWithTimeout -FilePath $shellPath `
                                            -Arguments "-NoProfile -NonInteractive -File `"$survivorScript`"" `
                                            -WorkingDirectory $shimWork -TimeoutSeconds 120
$survivorWatch.Stop()

Test-Case 'surviving child does not block' ($survivorWatch.Elapsed.TotalSeconds -lt 60) ("{0:n1}s" -f $survivorWatch.Elapsed.TotalSeconds)
Test-Case 'surviving child still completes' ($survivorResult.State -eq 'COMPLETED') $survivorResult.State
Test-Case 'output captured despite survivor' ($survivorResult.StdOut -match 'installer-finished') $survivorResult.StdOut
Test-Case 'exit code captured despite survivor' ($survivorResult.ExitCode -eq 0) $survivorResult.ExitCode

$failingScript = Join-Path $shimWork 'Failing.ps1'
'Write-Error "installer failed"; exit 13' | Set-Content -LiteralPath $failingScript -Encoding UTF8
$failingResult = Invoke-ProcessWithTimeout -FilePath $shellPath `
                                           -Arguments "-NoProfile -NonInteractive -File `"$failingScript`"" `
                                           -WorkingDirectory $shimWork -TimeoutSeconds 120

Test-Case 'failure keeps its exit code' ($failingResult.ExitCode -eq 13) $failingResult.ExitCode
Test-Case 'failure is still COMPLETED'  ($failingResult.State -eq 'COMPLETED') $failingResult.State
Test-Case 'stderr captured'             ($failingResult.StdErr -match 'installer failed') $failingResult.StdErr

$hangingScript = Join-Path $shimWork 'Hanging.ps1'
'Start-Sleep -Seconds 300' | Set-Content -LiteralPath $hangingScript -Encoding UTF8

$hangWatch = [System.Diagnostics.Stopwatch]::StartNew()
$hangResult = Invoke-ProcessWithTimeout -FilePath $shellPath `
                                        -Arguments "-NoProfile -NonInteractive -File `"$hangingScript`"" `
                                        -WorkingDirectory $shimWork -TimeoutSeconds 3
$hangWatch.Stop()

Test-Case 'hung process times out'       ($hangResult.State -eq 'TIMED_OUT') $hangResult.State
Test-Case 'timeout is actually enforced' ($hangWatch.Elapsed.TotalSeconds -lt 30) ("{0:n1}s" -f $hangWatch.Elapsed.TotalSeconds)
Test-Case 'timeout reports 1460'         ($hangResult.ExitCode -eq 1460) $hangResult.ExitCode
Test-Case 'timeout flag set'             ($hangResult.TimedOut)

# Cancellation must release a stuck stage without ending the session.
$cancelSignal = Join-Path $shimWork 'cancel.request'
Remove-Item -LiteralPath $cancelSignal -Force -ErrorAction SilentlyContinue
'requested' | Set-Content -LiteralPath $cancelSignal -Encoding UTF8

$cancelWatch = [System.Diagnostics.Stopwatch]::StartNew()
$cancelResult = Invoke-ProcessWithTimeout -FilePath $shellPath `
                                          -Arguments "-NoProfile -NonInteractive -File `"$hangingScript`"" `
                                          -WorkingDirectory $shimWork -TimeoutSeconds 300 `
                                          -CancelSignalPath $cancelSignal
$cancelWatch.Stop()

Test-Case 'cancellation is honoured'   ($cancelResult.State -eq 'CANCELLED') $cancelResult.State
Test-Case 'cancellation is prompt'     ($cancelWatch.Elapsed.TotalSeconds -lt 30) ("{0:n1}s" -f $cancelWatch.Elapsed.TotalSeconds)
Test-Case 'cancellation flag set'      ($cancelResult.Cancelled)
Remove-Item -LiteralPath $cancelSignal -Force -ErrorAction SilentlyContinue

$missingResult = Invoke-ProcessWithTimeout -FilePath (Join-Path $shimWork 'no-such-binary') `
                                           -Arguments '' -WorkingDirectory $shimWork -TimeoutSeconds 10
Test-Case 'unstartable process is FAILED' ($missingResult.State -eq 'FAILED') $missingResult.State
Test-Case 'unstartable process explains why' ($missingResult.StdErr.Length -gt 0)

Test-Case 'result carries diagnostics' (
    $survivorResult.ProcessId -gt 0 -and
    $survivorResult.StartedAt -and
    $survivorResult.Duration.TotalSeconds -ge 0 -and
    $survivorResult.CommandLine -match 'Survivor'
)

# --- Deployment wrappers -----------------------------------------------------
# The wrappers run the vendor installer. Nothing in them may wait on anything
# other than the installer process itself: leaving a helper or updater resident
# is normal behaviour, and waiting for one that never exits stalls the whole
# deployment until the timeout fires.
Write-Host "`nDeployment wrappers"

$installTemplate   = Join-Path $repo 'templates/Install.ps1'
$uninstallTemplate = Join-Path $repo 'templates/Uninstall.ps1'

foreach ($wrapper in @($installTemplate, $uninstallTemplate)) {
    $name = Split-Path $wrapper -Leaf
    $body = [regex]::Replace((Get-Content -LiteralPath $wrapper -Raw), '(?s)<#.*?#>', '')
    $code = ($body -split "`r?`n" | Where-Object { -not $_.TrimStart().StartsWith('#') }) -join "`n"

    # Start-Process -Wait waits for the process AND ITS DESCENDANTS on Windows,
    # so a resident updater keeps it from ever returning.
    Test-Case "$name does not use Start-Process -Wait" ($code -notmatch '(?s)Start-Process[^\r\n]*(\r?\n[^\r\n]*)*?-Wait')

    # Waiting for a process by name is never a completion condition: msiexec is
    # also the long-lived Windows Installer service.
    Test-Case "$name does not wait on processes by name" ($code -notmatch "Get-Process\s+-Name")
}

# --- Installer argument flow (end to end) ------------------------------------
# The whole point of the change: package.json -> CommandModel -> generated
# command -> Install.ps1 -> installer, with the silent arguments applied exactly
# once and every boundary preserved. Proven by running the generated command
# against a fake installer that prints back exactly the arguments it received.
. (Join-Path $repo 'src/Information/CommandModel.ps1')
Write-Host "`nInstaller argument flow"

# Generation half: the command the model produces from a name and arguments.
$genCommand = New-PowerShellScriptCommand -ScriptName 'Install.ps1' `
    -InstallerName 'Setup.exe' -InstallerArguments @('/S', '/v/qn')
$genRendered = ConvertTo-CommandString -Command $genCommand
Test-Case 'generated command names the installer once' (
    @([regex]::Matches($genRendered, '-InstallerName')).Count -eq 1
) $genRendered
Test-Case 'generated command carries the silent switches' ($genRendered -match '-InstallerName Setup\.exe /S /v/qn$')
Test-Case 'no installer name means no installer parameters' (
    (ConvertTo-CommandString -Command (New-PowerShellScriptCommand -ScriptName 'Install.ps1')) -notmatch 'InstallerName'
)

# The silent-argument string is tokenised on unquoted whitespace, so a value
# that contains a space stays one argument rather than splitting.
Test-Case 'plain switches tokenise'      (@(ConvertTo-ArgumentTokens -ArgumentString '/S /v/qn').Count -eq 2)
$spaced = @(ConvertTo-ArgumentTokens -ArgumentString 'INSTALLDIR="C:\Program Files\App" /qn')
Test-Case 'quoted span stays one token'  ($spaced.Count -eq 2 -and $spaced[0] -eq 'INSTALLDIR="C:\Program Files\App"')
# --- SYSTEM-context completion -----------------------------------------------
# Start-ScheduledTask only queues the launch, so the task is still 'Ready' for
# a moment afterwards. Reading that as "finished" ends the wait before the
# command has run and reports a Task Scheduler code as its exit code.
Write-Host "`nSYSTEM-context completion"

Test-Case 'queued but not yet running is not finished' (
    (Get-TaskWaitDecision -Reported $false -TaskState 'Ready' -ObservedRunning $false -StartDeadlinePassed $false) -eq 'WAITING'
)
Test-Case 'running is not finished' (
    (Get-TaskWaitDecision -Reported $false -TaskState 'Running' -ObservedRunning $true -StartDeadlinePassed $false) -eq 'WAITING'
)
Test-Case 'a reported result ends the wait' (
    (Get-TaskWaitDecision -Reported $true -TaskState 'Running' -ObservedRunning $true -StartDeadlinePassed $false) -eq 'REPORTED'
)
Test-Case 'ran then stopped without reporting' (
    (Get-TaskWaitDecision -Reported $false -TaskState 'Ready' -ObservedRunning $true -StartDeadlinePassed $false) -eq 'STOPPED'
)
Test-Case 'never started is distinguished' (
    (Get-TaskWaitDecision -Reported $false -TaskState 'Ready' -ObservedRunning $false -StartDeadlinePassed $true) -eq 'NEVER_STARTED'
)
Test-Case 'a vanished task ends the wait' (
    (Get-TaskWaitDecision -Reported $false -TaskState '' -ObservedRunning $true -StartDeadlinePassed $false) -eq 'VANISHED'
)
# A result written between two polls must still be read, whatever the task is
# doing by then.
Test-Case 'a result written late is still read' (
    (Get-TaskWaitDecision -Reported $true -TaskState '' -ObservedRunning $true -StartDeadlinePassed $true) -eq 'REPORTED'
)

# --- Detection contract ------------------------------------------------------
# Intune reads a non-zero exit as "not installed", so a detection script that
# fails for its own reasons is indistinguishable from an absent application and
# reinstalls forever. Nothing in the template may be able to exit non-zero.
Write-Host "`nDetection contract"

$detectionTemplate = Join-Path $repo 'templates/Detection.ps1'
$detectionSource = Get-Content -LiteralPath $detectionTemplate -Raw

# Everything ahead of the try block runs with no handler to catch it, so it may
# not touch anything that can fail: no environment variables, no path joining,
# no disk. Those belong inside the guard.
$beforeTry = ($detectionSource -split '(?m)^try\s*\{', 2)[0]
$beforeTryCode = ($beforeTry -split "`r?`n" |
    Where-Object { -not $_.TrimStart().StartsWith('#') }) -join "`n"
$beforeTryCode = [regex]::Replace($beforeTryCode, '(?s)<#.*?#>', '')
# Function bodies only run when called, which happens inside the guard.
$beforeTryCode = [regex]::Replace($beforeTryCode, '(?s)function\s+[\w-]+\s*\{.*', '')

Test-Case 'no environment access before the guard' ($beforeTryCode -notmatch '\$env:|GetEnvironmentVariable')
Test-Case 'no path building before the guard'      ($beforeTryCode -notmatch 'Join-Path')
Test-Case 'no disk access before the guard'        ($beforeTryCode -notmatch 'Test-Path|Get-Item|Get-ChildItem')

$detectionWork = Join-Path $WorkPath 'detection'
New-Item -Path $detectionWork -ItemType Directory -Force | Out-Null

function Invoke-DetectionScript {
    param([Parameter(Mandatory)][string]$Body, [Parameter(Mandatory)][string]$Name)

    $path = Join-Path $detectionWork $Name
    Set-Content -LiteralPath $path -Value $Body -Encoding UTF8
    Invoke-ProcessWithTimeout -FilePath $shellPath `
                              -Arguments "-NoProfile -NonInteractive -File `"$path`"" `
                              -WorkingDirectory $detectionWork -TimeoutSeconds 60
}

# The criteria block is what an administrator edits, so it is the most likely
# place for a value that cannot be resolved on the target machine.
$unresolvable = $detectionSource.Replace("`$ProgramFilesVariable  = 'ProgramFiles'",
                                         "`$ProgramFilesVariable  = 'NoSuchVariableAnywhere'")
$unresolvableResult = Invoke-DetectionScript -Body $unresolvable -Name 'Unresolvable.ps1'
Test-Case 'unresolvable file criterion still exits 0' ($unresolvableResult.ExitCode -eq 0) $unresolvableResult.StdErr
Test-Case 'unresolvable file criterion reports nothing detected' ([string]::IsNullOrWhiteSpace($unresolvableResult.StdOut))

# The version rule is pure, so it is loaded out of the template and exercised
# directly rather than through a registry the test host does not have.
$templateAst = [System.Management.Automation.Language.Parser]::ParseFile(
    $detectionTemplate, [ref]$null, [ref]$null)
$versionRule = $templateAst.FindAll({
    param($node)
    $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
    $node.Name -eq 'Test-VersionSatisfied'
}, $true)[0]
. ([scriptblock]::Create($versionRule.Extent.Text))

Test-Case 'exact version satisfies'      (Test-VersionSatisfied -Installed '1.0.0' -Expected '1.0.0')
Test-Case 'newer version satisfies'      (Test-VersionSatisfied -Installed '5.2.1' -Expected '5.2.0')
Test-Case 'older version does not'       (-not (Test-VersionSatisfied -Installed '5.1.9' -Expected '5.2.0'))
# String comparison would put 5.2.10 below 5.2.9.
Test-Case 'version parts compare as numbers' (Test-VersionSatisfied -Installed '5.2.10' -Expected '5.2.9')
# A file stamped 1.0.0.0 satisfies an expected 1.0.0; string equality would not.
Test-Case 'four-part file version satisfies three-part' (Test-VersionSatisfied -Installed '1.0.0.0' -Expected '1.0.0')
# A vendor string with no ordering falls back to equality rather than guessing.
Test-Case 'unparsable version matches exactly'   (Test-VersionSatisfied -Installed '2024 R2' -Expected '2024 R2')
Test-Case 'unparsable version rejects mismatch'  (-not (Test-VersionSatisfied -Installed '2024 R1' -Expected '2024 R2'))
Test-Case 'nothing installed is never satisfied' (-not (Test-VersionSatisfied -Installed '' -Expected '1.0.0'))
Test-Case 'no expected version accepts any'      (Test-VersionSatisfied -Installed '1.0.0' -Expected '')

# "Not detected" must still say what it looked for. A detection script that
# reports absence with no reasoning is the reason these failures take days.
$absentResult = Invoke-DetectionScript -Body $detectionSource -Name 'Absent.ps1'
Test-Case 'absence exits 0'            ($absentResult.ExitCode -eq 0) $absentResult.StdErr
Test-Case 'absence writes no STDOUT'   ([string]::IsNullOrWhiteSpace($absentResult.StdOut))
Test-Case 'absence explains itself'    ($absentResult.StdErr -match 'Not detected. Criteria checked:')
Test-Case 'absence names the criterion' ($absentResult.StdErr -match "matched DisplayName 'Vendor Application'")

# An exception raised while the criteria are evaluated must not escape either.
$throwing = $detectionSource.Replace('function Resolve-ExpectedFile {',
                                     "function Resolve-ExpectedFile {`n    throw 'criteria could not be evaluated'")
$throwingResult = Invoke-DetectionScript -Body $throwing -Name 'Throwing.ps1'
Test-Case 'a throwing criterion still exits 0'  ($throwingResult.ExitCode -eq 0) $throwingResult.StdErr
Test-Case 'a throwing criterion says why'       ($throwingResult.StdErr -match 'criteria could not be evaluated')
Test-Case 'a throwing criterion writes no STDOUT' ([string]::IsNullOrWhiteSpace($throwingResult.StdOut))

function New-DetectionResult {
    param([int]$ExitCode = 0, [string]$StdOut = '', [string]$StdErr = '')
    [PSCustomObject]@{
        ExitCode = $ExitCode; StdOut = $StdOut; StdErr = $StdErr
        Duration = [timespan]::FromSeconds(1)
    }
}

$detectedContract = Test-DetectionContract -Result (New-DetectionResult -StdOut 'Detected Contoso 4.2.1')
Test-Case 'output with exit 0 is detected' ($detectedContract.Detected -and -not $detectedContract.Failed)

$absentContract = Test-DetectionContract -Result (New-DetectionResult)
Test-Case 'exit 0 with no output is absent'    (-not $absentContract.Detected)
Test-Case 'exit 0 with no output is not a failure' (-not $absentContract.Failed)

# The distinction that matters: a script that did not complete reports nothing
# about the application, so it can never stand in for a trustworthy "absent".
$brokenContract = Test-DetectionContract -Result (New-DetectionResult -ExitCode 1 -StdErr 'parse error')
Test-Case 'non-zero exit is not detected'   (-not $brokenContract.Detected)
Test-Case 'non-zero exit is a failure'      $brokenContract.Failed
Test-Case 'non-zero exit keeps its stderr'  ($brokenContract.Error -eq 'parse error')
Test-Case 'failed detection output carries stderr' (
    (Format-DetectionOutput -Detection $brokenContract) -match 'STDERR: parse error'
)

# --- Manifest ----------------------------------------------------------------
Write-Host "`nManifest"

$manifest = New-PackageManifest -ApplicationName 'Contoso Reader' -ApplicationVersion '4.2.1' `
    -PackageVersion '1.0.0' -InstallerType 'EXE' -SourceInstaller 'Setup.exe' `
    -InstallCommand 'powershell.exe -NoProfile -ExecutionPolicy Bypass -NonInteractive -File ./Install.ps1 -InstallerName Setup.exe /S' `
    -UninstallCommand 'powershell.exe -NoProfile -ExecutionPolicy Bypass -NonInteractive -File ./Uninstall.ps1' `
    -DetectionMethod 'Script' -DetectionScript 'Detection.ps1' -ContentDirectory $WorkPath

Test-Case 'complete manifest is valid' (Test-PackageManifest -Manifest $manifest).IsValid

$noScript = $manifest.PSObject.Copy(); $noScript.DetectionScript = ''
Test-Case 'script detection needs a script' (-not (Test-PackageManifest -Manifest $noScript).IsValid)

$noName = $manifest.PSObject.Copy(); $noName.ApplicationName = ''
Test-Case 'empty required field rejected' (-not (Test-PackageManifest -Manifest $noName).IsValid)

# The validated command and the deployed command come from one definition, so
# a package cannot be proven in one form and shipped in another.
Test-Case 'detection command built once' (
    (Get-DetectionCommand -Manifest $manifest) -eq 'powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Detection.ps1'
)

$spacedDetection = $manifest.PSObject.Copy(); $spacedDetection.DetectionScript = 'Detect App.ps1'
Test-Case 'detection command quotes only when needed' (
    (Get-DetectionCommand -Manifest $spacedDetection) -match '-File "\.\\Detect App\.ps1"$'
)

$fileDetection = $manifest.PSObject.Copy(); $fileDetection.DetectionMethod = 'File'
Test-Case 'no detection command without a script' ((Get-DetectionCommand -Manifest $fileDetection) -eq '')

# --- Failure classification --------------------------------------------------
Write-Host "`nFailure classification"

Test-Case 'pre-build -> PACKAGING'        ((Get-FailureClassification -Stage 'PreBuild').Classification -eq 'PACKAGING_FAILURE')
Test-Case '1603 -> INSTALLER'             ((Get-FailureClassification -Stage 'Install' -ExitCode 1603).Classification -eq 'INSTALLER_FAILURE')
Test-Case '5 -> PERMISSION'               ((Get-FailureClassification -Stage 'Install' -ExitCode 5).Classification -eq 'PERMISSION_FAILURE')
Test-Case '1633 -> CONTEXT'               ((Get-FailureClassification -Stage 'Install' -ExitCode 1633).Classification -eq 'CONTEXT_FAILURE')
Test-Case 'install ok but not detected'   ((Get-FailureClassification -Stage 'Detection' -ExitCode 0 -DetectionResult $false -ExpectedExitCodes @(0)).Classification -eq 'DETECTION_FAILURE')
Test-Case 'detected after uninstall'      ((Get-FailureClassification -Stage 'DetectionRemoval' -DetectionResult $true).Classification -eq 'DETECTION_FAILURE')
Test-Case 'no desktop -> SYSTEM_CONTEXT'  ((Get-FailureClassification -Stage 'Install' -Output 'error: no interactive desktop available' -ExecutionContextName 'System').Classification -eq 'SYSTEM_CONTEXT_FAILURE')
Test-Case 'undeclared code -> RETURN_CODE' ((Get-FailureClassification -Stage 'Install' -ExitCode 4242 -ExpectedExitCodes @(0)).Classification -eq 'RETURN_CODE_FAILURE')
Test-Case 'no evidence -> UNKNOWN'        ((Get-FailureClassification -Stage 'Install').Classification -eq 'UNKNOWN')

# --- Pre-build gate: clean package -------------------------------------------
Write-Host "`nPre-build gate (clean package)"

$clean = Join-Path $WorkPath 'clean'
New-Item -Path $clean -ItemType Directory -Force | Out-Null
'binary' | Set-Content -LiteralPath (Join-Path $clean 'Setup.exe')
foreach ($name in @('Install.ps1', 'Uninstall.ps1', 'Detection.ps1')) {
    Copy-Item -LiteralPath (Join-Path $repo "templates/$name") -Destination (Join-Path $clean $name)
}

# A real package has its criteria filled in. Leaving the template's example
# values in place is itself a finding, checked separately below.
function Set-PackageCriteria {
    param([Parameter(Mandatory)][string]$Directory)

    foreach ($name in @('Uninstall.ps1', 'Detection.ps1')) {
        $path = Join-Path $Directory $name
        if (-not (Test-Path -LiteralPath $path)) { continue }

        $body = (Get-Content -LiteralPath $path -Raw).
            Replace("'Vendor Application'", "'Contoso Reader'").
            Replace("'1.0.0'", "'4.2.1'").
            Replace("'Vendor\Application\App.exe'", "'Contoso\Reader\Reader.exe'")
        Set-Content -LiteralPath $path -Value $body -Encoding UTF8
    }
}

Set-PackageCriteria -Directory $clean

$manifest.ContentDirectory = $clean
$cleanResult = Invoke-PreBuildValidation -SourcePath $clean -Manifest $manifest
Test-Case 'clean package can build' $cleanResult.CanBuild ($cleanResult.Errors -join ' | ')

# A detection script inspects the installed application, not the package, so it
# has no payload to resolve and must not be reported for lacking $PSScriptRoot.
$cleanWarnings = @($cleanResult.Checks | Where-Object { -not $_.Passed } | ForEach-Object { $_.Name })
Test-Case 'clean package warns about nothing' ($cleanWarnings.Count -eq 0) ($cleanWarnings -join ', ')

# Criteria left at the template's example values match nothing on any machine.
# Caught here, that costs one line of output; caught later, it costs a full
# install/uninstall cycle, or an application that reinstalls forever.
$unedited = Join-Path $WorkPath 'unedited'
New-Item -Path $unedited -ItemType Directory -Force | Out-Null
'binary' | Set-Content -LiteralPath (Join-Path $unedited 'Setup.exe')
foreach ($name in @('Install.ps1', 'Uninstall.ps1', 'Detection.ps1')) {
    Copy-Item -LiteralPath (Join-Path $repo "templates/$name") -Destination (Join-Path $unedited $name)
}

$uneditedManifest = $manifest.PSObject.Copy()
$uneditedManifest.ContentDirectory = $unedited
$uneditedResult = Invoke-PreBuildValidation -SourcePath $unedited -Manifest $uneditedManifest
$uneditedFailed = @($uneditedResult.Checks | Where-Object { -not $_.Passed } | ForEach-Object { $_.Name })

Test-Case 'unedited detection criteria flagged' ($uneditedFailed -contains 'Detection criteria are filled in')
Test-Case 'unedited uninstall criteria flagged' ($uneditedFailed -contains 'Uninstall criteria are filled in')
Test-Case 'unedited criteria block the build'   (-not $uneditedResult.CanBuild)

# The gate holds the example values as data. If a template changes one and this
# list does not, the check silently stops finding anything, so the two are
# asserted to agree rather than assumed to.
foreach ($name in @('DisplayName', 'ExpectedVersion', 'ExpectedFile')) {
    $inTemplate = Get-ScriptLiteral -ScriptPath (Join-Path $repo 'templates/Detection.ps1') -Name $name
    Test-Case "template still uses the declared `$$name" (
        $inTemplate -eq $script:TemplatePlaceholders[$name]
    ) "template: '$inTemplate'"
}

$uneditedDetail = @($uneditedResult.Checks | Where-Object { $_.Name -eq 'Detection criteria are filled in' })[0].Detail
Test-Case 'flagged criteria are named' ($uneditedDetail -match '\$DisplayName' -and $uneditedDetail -match '\$ExpectedVersion')

# A product code identifies the application on its own, so an uninstall wrapper
# using one is not held to a display name it never reads.
$byProductCode = Join-Path $unedited 'Uninstall.ps1'
(Get-Content -LiteralPath $byProductCode -Raw).
    Replace("`$ProductCode   = ''", "`$ProductCode   = '{11111111-2222-3333-4444-555555555555}'") |
    Set-Content -LiteralPath $byProductCode -Encoding UTF8

$codeResult = Invoke-PreBuildValidation -SourcePath $unedited -Manifest $uneditedManifest
$codeChecks = @($codeResult.Checks | Where-Object { $_.Name -eq 'Uninstall criteria are filled in' })
Test-Case 'product code exempts the display name' ($codeChecks.Count -eq 0)

# An install command pointing at a file the package does not ship throws before
# the vendor installer starts, and reports only a bare exit 1 after a full cycle
# has run. The name is read from the command, which is where it now lives.
Test-Case 'wrapper installer name read' (
    (Get-WrapperInstallerReference -CommandLine 'powershell.exe -File ./Install.ps1 -InstallerName Setup.exe /S').InstallerName -eq 'Setup.exe'
)
Test-Case 'quoted installer name read' (
    (Get-WrapperInstallerReference -CommandLine 'powershell.exe -File ./Install.ps1 -InstallerName "My Setup.exe" /S').InstallerName -eq 'My Setup.exe'
)
Test-Case 'no installer name not guessed' (
    -not (Get-WrapperInstallerReference -CommandLine 'powershell.exe -File ./Detection.ps1').Declared
)

$mismatchManifest = $manifest.PSObject.Copy()
$mismatchManifest.SourceInstaller = 'ideaIU-262.9437.185.exe'
'binary' | Set-Content -LiteralPath (Join-Path $clean 'ideaIU-262.9437.185.exe')

$mismatchResult = Invoke-PreBuildValidation -SourcePath $clean -Manifest $mismatchManifest
$mismatchCheck = @($mismatchResult.Checks | Where-Object { $_.Name -eq 'Install.ps1 targets the packaged installer' })
Test-Case 'installer name mismatch blocks build' (-not $mismatchCheck[0].Passed) $mismatchCheck[0].Detail
Test-Case 'mismatch stops the build'             (-not $mismatchResult.CanBuild)

Remove-Item -LiteralPath (Join-Path $clean 'ideaIU-262.9437.185.exe') -Force

'$DisplayName = "Contoso"; exit 0' | Set-Content -LiteralPath (Join-Path $clean 'Detection.ps1')
$detectionOnly = Invoke-PreBuildValidation -SourcePath $clean -Manifest $manifest
$scriptRootCheck = @($detectionOnly.Checks | Where-Object { $_.Name -eq 'Scripts resolve content from $PSScriptRoot' })
Test-Case 'detection script exempt from $PSScriptRoot' ($scriptRootCheck[0].Passed) $scriptRootCheck[0].Detail

# --- Pre-build gate: dirty package -------------------------------------------
Write-Host "`nPre-build gate (dirty package)"

$dirty = Join-Path $WorkPath 'dirty'
New-Item -Path $dirty -ItemType Directory -Force | Out-Null
'binary' | Set-Content -LiteralPath (Join-Path $dirty 'Setup.exe')
Copy-Item -LiteralPath (Join-Path $repo 'templates/Uninstall.ps1') -Destination (Join-Path $dirty 'Uninstall.ps1')
Copy-Item -LiteralPath (Join-Path $repo 'templates/Detection.ps1') -Destination (Join-Path $dirty 'Detection.ps1')

@'
$src = "C:\Users\jsmith\Desktop\Build\Setup.exe"
$cfg = "\\fileserver\share\config.xml"
Start-Process .\Setup.exe -Wait
$here = Get-Location
'@ | Set-Content -LiteralPath (Join-Path $dirty 'Install.ps1')

'stale' | Set-Content -LiteralPath (Join-Path $dirty 'previous.intunewin')
'log'   | Set-Content -LiteralPath (Join-Path $dirty 'install.log')

$dirtyManifest = New-PackageManifest -ApplicationName 'Bad App' -ApplicationVersion '1.0' `
    -PackageVersion '1.0.0' -InstallerType 'EXE' -SourceInstaller 'Setup.exe' `
    -InstallCommand 'msiexec /i Setup.msi /qb /qb' `
    -UninstallCommand 'powershell.exe -NoProfile -ExecutionPolicy Bypass -File ".\Uninstall.ps1"' `
    -DetectionMethod 'Script' -DetectionScript 'Detection.ps1' -ContentDirectory $dirty

$dirtyResult = Invoke-PreBuildValidation -SourcePath $dirty -Manifest $dirtyManifest
Test-Case 'dirty package is blocked' (-not $dirtyResult.CanBuild)

$failedChecks = @($dirtyResult.Checks | Where-Object { -not $_.Passed } | ForEach-Object { $_.Name })
foreach ($expected in @(
    'No invalid absolute paths'
    'No working-directory assumptions'
    'No nested .intunewin files'
    'No stale build artifacts in source'
    'Install command has no interactive arguments'
    'Install command has no duplicate arguments'
    'Install command resolves to an existing file'
)) {
    Test-Case "flags: $expected" ($failedChecks -contains $expected)
}

$invalidPaths = @($dirtyResult.PathValidation.InvalidPaths)
Test-Case 'developer path found' (@($invalidPaths | Where-Object { $_.Path -like '*jsmith*' }).Count -ge 1)
Test-Case 'UNC path found'       (@($invalidPaths | Where-Object { $_.Path -like '\\fileserver*' }).Count -ge 1)

# --- Stale-artifact matching: -like, not the provider -Filter ----------------
# On Windows the FileSystem provider's -Filter matches "*.log" against names
# like "ad.logconfig" (legacy short-name wildcard semantics), which flagged
# required vendor configuration files as stale logs. The scan now matches names
# with -like, which does not over-match. Asserted on the specific check so the
# result is independent of the other pre-build gates.
Write-Host "`nStale-artifact matching"

$staleWork = Join-Path $WorkPath 'stale-matching'
New-Item -Path $staleWork -ItemType Directory -Force | Out-Null
'binary' | Set-Content -LiteralPath (Join-Path $staleWork 'Setup.exe')
foreach ($name in @('Install.ps1', 'Uninstall.ps1', 'Detection.ps1')) {
    Copy-Item -LiteralPath (Join-Path $repo "templates/$name") -Destination (Join-Path $staleWork $name)
}
# Vendor configuration files (Autodesk / log4cplus) that must NOT be flagged.
'log4cplus' | Set-Content -LiteralPath (Join-Path $staleWork 'ad.logconfig')
'log4cplus' | Set-Content -LiteralPath (Join-Path $staleWork 'add.logconfig')

$staleManifest = New-PackageManifest -ApplicationName 'Vendor App' -ApplicationVersion '1.0' `
    -PackageVersion '1.0.0' -InstallerType 'EXE' -SourceInstaller 'Setup.exe' `
    -InstallCommand 'powershell.exe -NoProfile -ExecutionPolicy Bypass -NonInteractive -File ./Install.ps1 -InstallerName Setup.exe /S' `
    -UninstallCommand 'powershell.exe -NoProfile -ExecutionPolicy Bypass -NonInteractive -File ./Uninstall.ps1' `
    -DetectionMethod 'Script' -DetectionScript 'Detection.ps1' -ContentDirectory $staleWork

function Get-StaleCheck {
    param([string]$Source, [PSCustomObject]$Manifest)
    $result = Invoke-PreBuildValidation -SourcePath $Source -Manifest $Manifest
    [PSCustomObject]@{
        Check    = @($result.Checks | Where-Object { $_.Name -eq 'No stale build artifacts in source' })[0]
        CanBuild = $result.CanBuild
    }
}

$noStale = Get-StaleCheck -Source $staleWork -Manifest $staleManifest
Test-Case 'ad.logconfig is not a stale artifact'  ($noStale.Check.Passed) $noStale.Check.Detail
Test-Case 'add.logconfig is not a stale artifact' ($noStale.Check.Detail -notmatch 'logconfig')

# A genuine stale log, plus a nested one, prove detection and recursion.
'log' | Set-Content -LiteralPath (Join-Path $staleWork 'foo.log')
$staleSub = Join-Path $staleWork 'resources'
New-Item -Path $staleSub -ItemType Directory -Force | Out-Null
'tmp' | Set-Content -LiteralPath (Join-Path $staleSub 'deep.tmp')

$withStale = Get-StaleCheck -Source $staleWork -Manifest $staleManifest
Test-Case 'foo.log is detected as stale'          ($withStale.Check.Detail -match 'foo\.log')
Test-Case 'existing patterns still match (.tmp)'   ($withStale.Check.Detail -match 'deep\.tmp')
Test-Case 'recursive scan finds nested stale file' ($withStale.Check.Detail -match 'deep\.tmp')
Test-Case 'stale artifact fails the check'         (-not $withStale.Check.Passed)
Test-Case 'stale artifact blocks the build'        (-not $withStale.CanBuild)
Test-Case '.logconfig not flagged beside real stale files' ($withStale.Check.Detail -notmatch 'logconfig')

# --- Intune configuration export ---------------------------------------------
Write-Host "`nIntune configuration export"

$validated = @{
    Install   = $manifest.InstallCommand
    Uninstall = $manifest.UninstallCommand
    Detection = Get-DetectionCommand -Manifest $manifest
}

$export = Export-IntuneConfiguration -Manifest $manifest -OutputPath (Join-Path $WorkPath 'out') `
                                     -ValidatedCommands $validated -ValidationPassed $true
Test-Case 'json written'        (Test-Path -LiteralPath $export.JsonPath)
Test-Case 'markdown written'    (Test-Path -LiteralPath $export.MarkdownPath)
Test-Case 'commands consistent' $export.IsConsistent
Test-Case 'production ready'    $export.IsProductionReady

$drifted = $validated.Clone()
$drifted['Install'] = 'powershell.exe -File ".\Install.ps1"'
$driftExport = Export-IntuneConfiguration -Manifest $manifest -OutputPath (Join-Path $WorkPath 'out-drift') `
                                          -ValidatedCommands $drifted -ValidationPassed $true
Test-Case 'drift detected'          (-not $driftExport.IsConsistent)
Test-Case 'drift blocks ready'      (-not $driftExport.IsProductionReady)
Test-Case 'drift warning in markdown' ((Get-Content -LiteralPath $driftExport.MarkdownPath -Raw) -match 'DOES NOT MATCH VALIDATED')

$unvalidated = Export-IntuneConfiguration -Manifest $manifest -OutputPath (Join-Path $WorkPath 'out-unvalidated') `
                                          -ValidatedCommands $validated -ValidationPassed $false
Test-Case 'failed validation blocks ready' (-not $unvalidated.IsProductionReady)

# --- HTML report -------------------------------------------------------------
Write-Host "`nHTML report"

$result = [PSCustomObject]@{
    ApplicationName = 'Contoso Reader'; ApplicationVersion = '4.2.1'; PackageVersion = '1.0.0'
    PackageHash = 'ABC123'; TestedAt = (Get-Date).ToString('o'); Duration = [timespan]::FromMinutes(3)
    ExecutionContext = 'NT AUTHORITY\SYSTEM'
    Environment = [PSCustomObject]@{
        ComputerName = 'PKG01'; OSVersion = 'Windows 10.0.19045'; Architecture = 'x64'
        PowerShellVersion = '5.1'; Is64BitProcess = $true
    }
    Stages = @(
        [PSCustomObject]@{ Name = 'Install'; Result = 'PASS'; Command = 'powershell.exe -File ".\Install.ps1"'
                           ExitCode = 0; Output = '<script>alert(1)</script>'; Detail = 'Success'
                           Duration = [timespan]::FromSeconds(42) }
        [PSCustomObject]@{ Name = 'Detection after install'; Result = 'PASS'; Command = 'detect'
                           ExitCode = 0; Output = 'Detected'; Detail = 'ok'; Duration = [timespan]::Zero }
    )
    InstallDelta = $null; Classification = $null; IsProductionReady = $true
}

$reportPath = New-ValidationReport -Result $result -Path (Join-Path $WorkPath 'report.html') `
                                   -CommandComparison $export.Comparisons
$html = Get-Content -LiteralPath $reportPath -Raw
Test-Case 'report written'       (Test-Path -LiteralPath $reportPath)
Test-Case 'reports ready status' ($html -match 'PRODUCTION READY')
# Installer output reaches the report verbatim, so it must be encoded.
Test-Case 'encodes html in output' (($html -notmatch '<script>alert') -and ($html -match '&lt;script&gt;'))

# --- Result ------------------------------------------------------------------
Remove-Item -LiteralPath $WorkPath -Recurse -Force -ErrorAction SilentlyContinue

Write-Host ""
if ($script:failures -eq 0) {
    Write-Host "ALL TESTS PASSED" -ForegroundColor Green
    exit 0
}

Write-Host "$($script:failures) TEST(S) FAILED" -ForegroundColor Red
exit 1
