<#
.SYNOPSIS
    Evaluation of an installer into a reviewable configuration proposal.
.DESCRIPTION
    One pass over an installer that populates everything the platform can
    establish from evidence, and marks everything else as needing the
    administrator.

    The rule the whole file is built around: a value is populated only when
    something was actually read - file metadata, an MSI property, a line of a
    wrapper script, a registry entry, an observed installation. Nothing is
    inferred from what installers usually do. A silent switch that was not
    found stays empty and is reported as not detected, because a guessed switch
    produces a package that installs interactively on every device.

    Discovery is kept separate from generation. This writes facts into the
    project's existing field model, with the source and confidence that go with
    each; the script generator turns approved facts into Install.ps1,
    Uninstall.ps1 and Detection.ps1 afterwards.
#>

Set-StrictMode -Version Latest

$script:InstallerKindByExtension = @{
    '.msi'        = 'MSI'
    '.msp'        = 'MSI'
    '.exe'        = 'EXE'
    '.msix'       = 'MSIX'
    '.msixbundle' = 'MSIX'
    '.appx'       = 'APPX'
    '.appxbundle' = 'APPX'
    '.ps1'        = 'PS1'
    '.cmd'        = 'CMD'
    '.bat'        = 'BAT'
    '.vbs'        = 'VBS'
}

function Get-InstallerKind {
    <#
    .SYNOPSIS
        Classifies a source file by extension.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)

    $extension = (Get-CanonicalExtension -Path $Path).ToLowerInvariant()
    if ($script:InstallerKindByExtension.ContainsKey($extension)) {
        return $script:InstallerKindByExtension[$extension]
    }

    'Unknown'
}

function Test-ScriptInstallerKind {
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Kind)

    $Kind -in @('PS1', 'CMD', 'BAT')
}

function ConvertFrom-ScriptArgumentList {
    <#
    .SYNOPSIS
        Flattens a PowerShell -ArgumentList expression into a command string.
    .DESCRIPTION
        Only literal elements are kept. An argument built from a variable is
        not evidence of anything, so it is dropped rather than guessed at.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Expression)

    $text = $Expression.Trim().TrimStart('@').Trim('(', ')')
    if (-not $text) { return '' }

    $parts = foreach ($element in ($text -split ',')) {
        $value = $element.Trim()
        if (-not $value) { continue }
        if ($value.StartsWith('$')) { continue }

        $value.Trim("'", '"')
    }

    (@($parts) -join ' ').Trim()
}

function Get-ScriptInstallerReference {
    <#
    .SYNOPSIS
        Finds the installer a wrapper script actually runs, and what it passes.
    .DESCRIPTION
        A .cmd or .ps1 in a package is usually a thin wrapper around a real
        installer. What the wrapper invokes, and with which switches, is
        written down in the script - so it is evidence, not inference, and the
        switches it uses are the ones the vendor's installer is known to
        accept in this environment.

        Comment lines are skipped, and an invocation whose target or arguments
        come from a variable is reported without them rather than resolved.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)

    $native = ConvertTo-NativePath -Path $Path

    if (-not (Test-Path -LiteralPath $native -PathType Leaf)) {
        throw "Script not found: $Path"
    }

    $kind = Get-InstallerKind -Path $Path
    $lines = @(Get-Content -LiteralPath $native)

    $invocations  = [System.Collections.Generic.List[PSCustomObject]]::new()
    $registryOps  = [System.Collections.Generic.List[PSCustomObject]]::new()
    $environment  = [System.Collections.Generic.List[PSCustomObject]]::new()
    $fileOps      = [System.Collections.Generic.List[PSCustomObject]]::new()

    $lineNumber = 0

    foreach ($rawLine in $lines) {
        $lineNumber++
        $line = $rawLine.Trim()
        if (-not $line) { continue }

        # Comments in either dialect.
        if ($line.StartsWith('#')) { continue }
        if ($line -match '^(?i)(rem\b|::)') { continue }

        # --- PowerShell Start-Process ---------------------------------------
        # Checked before the bare-msiexec pattern below: in a PowerShell script
        # the executable is a -FilePath value and the switches are a separate
        # -ArgumentList, so matching msiexec by name first would swallow the
        # rest of the line as if it were arguments.
        if ($kind -eq 'PS1' -and $line -match '(?i)\bStart-Process\b') {
            $file = [regex]::Match($line, '(?i)-FilePath\s+(?<v>"[^"]+"|''[^'']+''|\$?[^\s]+)')
            $argumentMatch = [regex]::Match($line, '(?i)-ArgumentList\s+(?<v>@?\([^)]*\)|"[^"]*"|''[^'']*''|[^\s].*?)(?=\s+-[A-Za-z]|$)')

            $target = if ($file.Success) { $file.Groups['v'].Value.Trim('"', "'") } else { '' }
            $arguments = if ($argumentMatch.Success) {
                ConvertFrom-ScriptArgumentList -Expression $argumentMatch.Groups['v'].Value
            } else {
                ''
            }

            # A target that is a variable is not a discovered installer.
            if ($target -and -not $target.StartsWith('$')) {
                $invocations.Add([PSCustomObject]@{
                    Kind       = if ($target -match '(?i)(\.msi"?$|^"?msiexec)') { 'MSI' } else { 'EXE' }
                    Executable = $target
                    Target     = $target
                    Arguments  = $arguments
                    Line       = $lineNumber
                    Raw        = $line
                })
            }
            continue
        }

        # --- msiexec invoked directly ---------------------------------------
        $msi = [regex]::Match($line, '(?i)\bmsiexec(?:\.exe)?\b(?<args>[^&|]*)')
        if ($msi.Success -and $msi.Groups['args'].Value -match '(?i)/i\b|/package\b') {
            $arguments = $msi.Groups['args'].Value.Trim()
            $package = [regex]::Match($arguments, '(?i)(?:/i|/package)\s+"?(?<file>[^"\s]+\.msi)"?')

            $invocations.Add([PSCustomObject]@{
                Kind       = 'MSI'
                Executable = 'msiexec.exe'
                Target     = if ($package.Success) { $package.Groups['file'].Value } else { '' }
                Arguments  = $arguments
                Line       = $lineNumber
                Raw        = $line
            })
            continue
        }

        # --- Call operator, or a bare executable in a batch file ------------
        # Two spellings of the target: quoted (may contain spaces, e.g. a path
        # under "C:\Program Files\...") or bare (no spaces). The quoted branch is
        # tried first so a spaced path is captured whole instead of truncating at
        # the first space.
        $executable = [regex]::Match($line,
            '(?i)(?:^|\bstart\b[^"]*?\s|&\s*)(?:"(?<exe>(?:[A-Za-z]:[\\/]|\.[\\/]|%~dp0|\$PSScriptRoot[\\/])?[^"]*\.(?:exe|msi))"|(?<exe>(?:[A-Za-z]:[\\/]|\.[\\/]|%~dp0|\$PSScriptRoot[\\/])?[^"\s|&]*\.(?:exe|msi)))(?<args>[^&|]*)')

        if ($executable.Success) {
            $target = $executable.Groups['exe'].Value
            if ($target -match '(?i)^msiexec') { continue }

            $invocations.Add([PSCustomObject]@{
                Kind       = if ($target -match '(?i)\.msi$') { 'MSI' } else { 'EXE' }
                Executable = $target
                Target     = $target
                Arguments  = $executable.Groups['args'].Value.Trim()
                Line       = $lineNumber
                Raw        = $line
            })
            continue
        }

        # --- Side effects worth reporting, never acted on automatically -----
        if ($line -match '(?i)\breg(\.exe)?\s+add\b|\bNew-ItemProperty\b|\bSet-ItemProperty\b|\bNew-Item\b.*(?i)HK(LM|CU)') {
            $registryOps.Add([PSCustomObject]@{ Line = $lineNumber; Raw = $line })
        }

        if ($line -match '(?i)\bsetx\b|\[Environment\]::SetEnvironmentVariable') {
            $environment.Add([PSCustomObject]@{ Line = $lineNumber; Raw = $line })
        }

        if ($line -match '(?i)\b(xcopy|robocopy|copy-item|copy)\b') {
            $fileOps.Add([PSCustomObject]@{ Line = $lineNumber; Raw = $line })
        }
    }

    [PSCustomObject]@{
        ScriptPath            = $Path
        ScriptKind            = $kind
        Invocations           = @($invocations)
        RegistryOperations    = @($registryOps)
        EnvironmentOperations = @($environment)
        FileOperations        = @($fileOps)
    }
}

function Get-UninstallRegistration {
    <#
    .SYNOPSIS
        Uninstall entries matching a display name, from all three hives.
    .DESCRIPTION
        Extends the basic lookup with QuietUninstallString, which is the only
        string a vendor has actually promised will run without a user.
    #>
    [CmdletBinding()]
    param([string]$NameLike = '*')

    $roots = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall'
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall'
        'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall'
    )

    $found = foreach ($root in $roots) {
        if (-not (Test-Path -LiteralPath $root)) { continue }

        foreach ($key in (Get-ChildItem -LiteralPath $root -ErrorAction SilentlyContinue)) {
            $properties = Get-ItemProperty -LiteralPath $key.PSPath -ErrorAction SilentlyContinue
            if (-not $properties) { continue }

            $names = $properties.PSObject.Properties.Name
            if ('DisplayName' -notin $names -or -not $properties.DisplayName) { continue }
            if ($properties.DisplayName -notlike $NameLike) { continue }

            $read = {
                param($propertyName)
                if ($propertyName -in $names -and $properties.$propertyName) { $properties.$propertyName } else { '' }
            }

            [PSCustomObject]@{
                DisplayName          = $properties.DisplayName
                DisplayVersion       = & $read 'DisplayVersion'
                Publisher            = & $read 'Publisher'
                InstallLocation      = & $read 'InstallLocation'
                UninstallString      = & $read 'UninstallString'
                QuietUninstallString = & $read 'QuietUninstallString'
                WindowsInstaller     = & $read 'WindowsInstaller'
                ProductCode          = $key.PSChildName
                RegistryView         = if ($root -match 'WOW6432Node') { 'x86' } else { 'x64' }
                RegistryHive         = if ($root -match '^HKCU') { 'HKCU' } else { 'HKLM' }
                RegistryPath         = $key.PSPath
            }
        }
    }

    @($found)
}

function New-UninstallProposal {
    <#
    .SYNOPSIS
        Proposes an uninstall command from a registry entry, or explains why it
        cannot.
    .DESCRIPTION
        QuietUninstallString is preferred because it is the vendor stating what
        runs unattended. An MSI product code gives an exact silent command. A
        bare UninstallString is reported as needing review rather than silently
        assumed to accept a silent switch - adding one that the vendor does not
        support produces an uninstall that stops for a user who is not there.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][PSCustomObject]$Registration)

    $names = $Registration.PSObject.Properties.Name

    $quiet = if ('QuietUninstallString' -in $names) { $Registration.QuietUninstallString } else { '' }
    if ($quiet) {
        return [PSCustomObject]@{
            Command        = $quiet
            Source         = 'REGISTRY'
            Confidence     = 'HIGH'
            RequiresReview = $false
            Reason         = 'QuietUninstallString registered by the vendor'
        }
    }

    $productCode = if ('ProductCode' -in $names) { $Registration.ProductCode } else { '' }
    if ($productCode -match '^\{[0-9A-Fa-f-]{36}\}$') {
        return [PSCustomObject]@{
            Command        = "msiexec.exe /x $productCode /qn /norestart"
            Source         = 'REGISTRY'
            Confidence     = 'HIGH'
            RequiresReview = $false
            Reason         = 'Windows Installer product code; /qn is defined by Windows Installer'
        }
    }

    $uninstallString = if ('UninstallString' -in $names) { $Registration.UninstallString } else { '' }
    if ($uninstallString) {
        return [PSCustomObject]@{
            Command        = $uninstallString
            Source         = 'REGISTRY'
            Confidence     = 'MEDIUM'
            RequiresReview = $true
            Reason         = 'UninstallString only; it is not known to run without a user. Add the vendor''s silent switch and confirm.'
        }
    }

    [PSCustomObject]@{
        Command        = ''
        Source         = ''
        Confidence     = ''
        RequiresReview = $true
        Reason         = 'No uninstall string registered'
    }
}

function New-DetectionProposal {
    <#
    .SYNOPSIS
        Proposes how Intune should decide the application is installed.
    .DESCRIPTION
        Strongest available evidence wins, in this order: an MSI product code,
        the primary executable and its version, a registered uninstall entry,
        then the install folder. Folder existence is last on purpose - a folder
        commonly survives an uninstall, so a package detected that way can
        never be reinstalled or reported correctly.
    #>
    [CmdletBinding()]
    param(
        [string]$ProductCode = '',
        [string]$PrimaryExecutable = '',
        [string]$ExpectedVersion = '',
        [string]$UninstallDisplayName = '',
        [string]$InstallLocation = ''
    )

    if ($ProductCode -match '^\{[0-9A-Fa-f-]{36}\}$') {
        return [PSCustomObject]@{
            Type       = 'MsiProductCode'
            Path       = ''
            Value      = $ProductCode
            Version    = $ExpectedVersion
            Confidence = 'HIGH'
            Reason     = 'Windows Installer product code identifies the product exactly'
            IsReliable = $true
        }
    }

    if ($PrimaryExecutable) {
        return [PSCustomObject]@{
            Type       = 'File'
            Path       = Split-CanonicalPath -Path $PrimaryExecutable
            Value      = Get-CanonicalLeaf -Path $PrimaryExecutable
            Version    = $ExpectedVersion
            Confidence = 'HIGH'
            Reason     = if ($ExpectedVersion) {
                'The application executable and its version'
            } else {
                'The application executable. No version was discovered, so this detects presence only.'
            }
            IsReliable = $true
        }
    }

    if ($UninstallDisplayName) {
        return [PSCustomObject]@{
            Type       = 'Registry'
            Path       = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall'
            Value      = $UninstallDisplayName
            Version    = $ExpectedVersion
            Confidence = 'MEDIUM'
            Reason     = 'Uninstall registration. Removed on uninstall, but does not prove the files are present.'
            IsReliable = $true
        }
    }

    if ($InstallLocation) {
        return [PSCustomObject]@{
            Type       = 'Folder'
            Path       = $InstallLocation
            Value      = ''
            Version    = ''
            Confidence = 'LOW'
            Reason     = 'Install folder only. Folders commonly survive an uninstall, so this cannot prove removal.'
            IsReliable = $false
        }
    }

    [PSCustomObject]@{
        Type       = ''
        Path       = ''
        Value      = ''
        Version    = ''
        Confidence = ''
        Reason     = 'No evidence strong enough to identify the application'
        IsReliable = $false
    }
}

function Invoke-InstallerEvaluation {
    <#
    .SYNOPSIS
        Evaluates a source file and publishes everything it establishes.
    .DESCRIPTION
        Runs the discovery appropriate to the file's type, resolves a wrapper
        script to the installer it actually runs, then proposes uninstall and
        detection from whatever the evidence supports. Every value is written
        through the project's field model, so each carries the source it came
        from and can be reviewed, overridden or reset like any other.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][PSCustomObject]$Project,
        [Parameter(Mandatory)][string]$Path
    )

    $canonical = ConvertTo-CanonicalPath -Path $Path
    $native    = ConvertTo-NativePath -Path $canonical

    if (-not (Test-Path -LiteralPath $native -PathType Leaf)) {
        throw "Installer not found: $Path"
    }

    $kind = Get-InstallerKind -Path $canonical
    $notes = [System.Collections.Generic.List[string]]::new()
    $scriptAnalysis = $null
    $evaluatedPath = $canonical

    # A wrapper script is not the installer. What it runs is.
    if (Test-ScriptInstallerKind -Kind $kind) {
        $scriptAnalysis = Get-ScriptInstallerReference -Path $canonical
        $invocationList = @($scriptAnalysis.Invocations)
        $primary = if ($invocationList.Count -gt 0) { $invocationList[0] } else { $null }

        if ($null -eq $primary) {
            $notes.Add("$kind wrapper: no installer invocation found in the script")
        } else {
            $notes.Add("$kind wrapper runs $($primary.Executable) (line $($primary.Line))")

            if ($primary.Arguments) {
                # The switches are written in the script, so they are evidence
                # of what this installer is run with here - not a guess.
                Set-ProjectField -Project $Project -Path 'installer.silentArguments' -Value $primary.Arguments `
                    -Source 'CONFIGURATION' `
                    -Evidence "Arguments used on line $($primary.Line) of $(Get-CanonicalLeaf -Path $canonical)" | Out-Null
            }

            # Resolve the referenced installer beside the script when it exists,
            # so its own metadata can be read too.
            $referenced = $primary.Target -replace '(?i)%~dp0|\$PSScriptRoot[\\/]', ''
            if ($referenced) {
                $beside = Join-Path (Split-CanonicalPath -Path $canonical) (Get-CanonicalLeaf -Path $referenced)
                $besideNative = ConvertTo-NativePath -Path $beside

                if (Test-Path -LiteralPath $besideNative -PathType Leaf) {
                    $evaluatedPath = ConvertTo-CanonicalPath -Path $beside
                    $kind = Get-InstallerKind -Path $evaluatedPath
                    $notes.Add("Underlying installer found in the package: $(Get-CanonicalLeaf -Path $evaluatedPath)")
                } else {
                    $notes.Add("Referenced installer '$referenced' is not in the package; its metadata could not be read")
                }
            }
        }
    }

    # File metadata, MSI properties, name/version/architecture derivation and
    # toolkit detection all already live in the discovery engine.
    $discovery = Invoke-InstallerDiscovery -Project $Project -InstallerPath $evaluatedPath

    if (-not (Test-ProjectFieldKnown -Project $Project -Path 'installer.silentArguments')) {
        $notes.Add('Silent arguments not detected; administrator input required')
    }

    # What the machine already knows about this application.
    $installed = Invoke-InstalledApplicationDiscovery -Project $Project

    $uninstallProposal = $null
    $applicationName = Get-ProjectFieldValue -Project $Project -Path 'application.name' -Default ''

    if ($applicationName) {
        $registrations = @(Get-UninstallRegistration -NameLike "$applicationName*")

        if ($registrations.Count -eq 1) {
            $uninstallProposal = New-UninstallProposal -Registration $registrations[0]

            if ($uninstallProposal.Command) {
                Set-ProjectField -Project $Project -Path 'installation.uninstallString' -Value $uninstallProposal.Command `
                    -Source $uninstallProposal.Source -Evidence $uninstallProposal.Reason | Out-Null
            }
        } elseif ($registrations.Count -gt 1) {
            $notes.Add("$($registrations.Count) uninstall entries match '$applicationName'; administrator must choose")
        }
    }

    $detectionProposal = New-DetectionProposal `
        -ProductCode (Get-ProjectFieldValue -Project $Project -Path 'installer.productCode' -Default '') `
        -PrimaryExecutable (Get-ProjectFieldValue -Project $Project -Path 'installation.executable' -Default '') `
        -ExpectedVersion (Get-ProjectFieldValue -Project $Project -Path 'application.version' -Default '') `
        -UninstallDisplayName (Get-ProjectFieldValue -Project $Project -Path 'installation.uninstallDisplayName' -Default '') `
        -InstallLocation (Get-ProjectFieldValue -Project $Project -Path 'installation.installLocation' -Default '')

    if ($detectionProposal.Type) {
        $detectionSource = if ($detectionProposal.Confidence -eq 'HIGH') { 'REGISTRY' } else { 'DERIVED' }

        Set-ProjectField -Project $Project -Path 'detection.type' -Value $detectionProposal.Type `
            -Source $detectionSource -Evidence $detectionProposal.Reason | Out-Null

        foreach ($entry in @(
            @{ Field = 'detection.path';    Value = $detectionProposal.Path }
            @{ Field = 'detection.value';   Value = $detectionProposal.Value }
            @{ Field = 'detection.version'; Value = $detectionProposal.Version }
        )) {
            if ($entry.Value) {
                Set-ProjectField -Project $Project -Path $entry.Field -Value $entry.Value `
                    -Source $detectionSource -Evidence $detectionProposal.Reason | Out-Null
            }
        }
    } else {
        $notes.Add('Detection not determined; administrator input required')
    }

    Add-AuditEntry -Store $Project.Evidence -Category 'Operation' -Key 'EvaluateInstaller' `
                   -Detail "Evaluated $(Get-CanonicalLeaf -Path $canonical) as $kind" -Value $null | Out-Null

    [PSCustomObject]@{
        SourcePath        = $canonical
        EvaluatedPath     = $evaluatedPath
        InstallerKind     = $kind
        InstallerFamily   = $discovery.Family
        ScriptAnalysis    = $scriptAnalysis
        InstalledMatches  = @($installed.Matched)
        UninstallProposal = $uninstallProposal
        DetectionProposal = $detectionProposal
        FieldsPopulated   = @($discovery.FieldsFound)
        Notes             = @($notes)
    }
}

function Get-EvaluationSummary {
    <#
    .SYNOPSIS
        The evaluation as reviewable rows: value, where it came from, and how
        far it is to be trusted.
    .DESCRIPTION
        A field with no value is reported as requiring the administrator rather
        than omitted, so what is missing is as visible as what was found.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][PSCustomObject]$Project,
        [string[]]$Path = @(
            'application.name'
            'application.publisher'
            'application.version'
            'application.architecture'
            'installer.fileName'
            'installer.type'
            'installer.silentArguments'
            'installer.uiMode'
            'installer.uninstallUiMode'
            'installer.productCode'
            'installation.context'
            'installation.installLocation'
            'installation.executable'
            'installation.uninstallDisplayName'
            'installation.uninstallString'
            'detection.type'
            'detection.path'
            'detection.value'
            'detection.version'
        )
    )

    $rows = foreach ($fieldPath in $Path) {
        $definition = Get-FieldDefinition -Path $fieldPath
        if ($null -eq $definition) { continue }

        $field = Get-ProjectField -Project $Project -Path $fieldPath
        $resolved = Test-FieldResolved -Field $field

        [PSCustomObject]@{
            Path       = $fieldPath
            Label      = $definition.Label
            Value      = if ($resolved) { $field.Value } else { '' }
            Source     = if ($resolved) { $field.Source } else { '' }
            Confidence = if ($resolved) { $field.Confidence } else { '' }
            Evidence   = if ($resolved) { Format-FieldEvidence -Field $field } else { '' }
            Detected   = [bool]$resolved
            Required   = $fieldPath -in @(
                'application.name', 'application.version', 'installer.type',
                'installer.silentArguments', 'installation.context', 'detection.type'
            )
        }
    }

    @($rows)
}

function Test-EvaluationComplete {
    <#
    .SYNOPSIS
        Whether the evaluation produced enough to build from.
    .DESCRIPTION
        Auto-populated values are not automatically trusted. What is missing is
        named, so the administrator supplies it rather than the platform
        inventing it.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][PSCustomObject]$Project)

    $summary = @(Get-EvaluationSummary -Project $Project)
    $missing = @($summary | Where-Object { $_.Required -and -not $_.Detected })

    $weakDetection = @(
        $summary | Where-Object { $_.Path -eq 'detection.type' -and $_.Value -eq 'Folder' }
    )

    [PSCustomObject]@{
        IsComplete      = $missing.Count -eq 0
        Missing         = @($missing | ForEach-Object { $_.Label })
        MissingPaths    = @($missing | ForEach-Object { $_.Path })
        WeakDetection   = $weakDetection.Count -gt 0
        DetectedCount   = @($summary | Where-Object { $_.Detected }).Count
        TotalCount      = $summary.Count
    }
}
