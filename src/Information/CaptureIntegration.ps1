<#
.SYNOPSIS
    Turns an installation capture into answers instead of questions.
.DESCRIPTION
    Capture already knows where the application landed, what it runs, what it
    added to the PATH and what it registered. None of that is ever asked for
    again. What capture cannot know is policy: whether the deployment should
    reproduce a PATH change or create a shortcut. Those become decisions, and
    they are the only thing the user is asked about after a capture.
#>

Set-StrictMode -Version Latest

# An observed change, the fact it records, and the policy decision it raises.
$script:CapturePolicyMap = @(
    @{
        DeltaPath   = 'Path.Added'
        FactField   = 'installation.machinePath'
        Decision    = 'decision.applyMachinePath'
        Description = 'machine PATH modification'
    }
    @{
        DeltaPath   = 'EnvironmentVariables.Added'
        FactField   = 'installation.environmentVariables'
        Decision    = 'decision.applyEnvironmentVariables'
        Description = 'environment variable'
    }
    @{
        DeltaPath   = 'Shortcuts.Added'
        FactField   = 'installation.shortcuts'
        Decision    = 'decision.createDesktopShortcut'
        Description = 'shortcut'
    }
)

function Get-DeltaSection {
    <#
    .SYNOPSIS
        Reads a dotted path out of a delta without tripping StrictMode on a
        section the snapshot did not produce.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][PSCustomObject]$Delta,
        [Parameter(Mandatory)][string]$Path
    )

    $current = $Delta

    foreach ($segment in $Path.Split('.')) {
        if ($null -eq $current) { return @() }
        if ($current.PSObject.Properties.Name -notcontains $segment) { return @() }
        $current = $current.$segment
    }

    @($current)
}

function Get-CommonDirectory {
    <#
    .SYNOPSIS
        The deepest directory that contains every one of the given files.
    .DESCRIPTION
        This is how an install location is derived from the files an installer
        produced, rather than asked for.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowEmptyCollection()][string[]]$Path)

    $paths = @($Path | Where-Object { $_ })
    if ($paths.Count -eq 0) { return '' }

    $splitPaths = @(
        foreach ($item in $paths) {
            $directory = Split-CanonicalPath -Path $item
            if ($directory) { , @($directory.TrimEnd('\').Split('\')) }
        }
    )

    if ($splitPaths.Count -eq 0) { return '' }

    $common = $splitPaths[0]

    foreach ($segments in $splitPaths) {
        $limit = [Math]::Min($common.Count, $segments.Count)
        $shared = [System.Collections.Generic.List[string]]::new()

        for ($index = 0; $index -lt $limit; $index++) {
            if ($common[$index] -ne $segments[$index]) { break }
            $shared.Add($common[$index])
        }

        $common = @($shared)
        if ($common.Count -eq 0) { break }
    }

    if ($common.Count -eq 0) { return '' }

    # A drive root alone is not an install location.
    if ($common.Count -eq 1 -and $common[0] -match '^[A-Za-z]:$') { return '' }

    $common -join '\'
}

function Select-PrimaryExecutable {
    <#
    .SYNOPSIS
        Picks the executable most likely to represent the application.
    .DESCRIPTION
        Prefers one whose name resembles the application, then one directly in
        the install root over one buried in a subdirectory, and skips the
        uninstallers and helper binaries that would make detection fragile.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$Path,
        [string]$ApplicationName = '',
        [string]$InstallLocation = ''
    )

    $executables = @($Path | Where-Object { $_ -and (Get-CanonicalExtension -Path $_).ToLowerInvariant() -eq '.exe' })
    if ($executables.Count -eq 0) { return '' }

    $skipPattern = '(unins|uninstall|setup|helper|updater|crashpad|vcredist|repair)'

    $candidates = @($executables | Where-Object {
        (Get-CanonicalBaseName -Path $_) -notmatch $skipPattern
    })

    if ($candidates.Count -eq 0) { $candidates = $executables }

    $nameToken = if ($ApplicationName) {
        ($ApplicationName -replace '[^A-Za-z0-9]', '').ToLowerInvariant()
    } else {
        ''
    }

    $scored = foreach ($candidate in $candidates) {
        $canonical = ConvertTo-CanonicalPath -Path $candidate
        $stem = ((Get-CanonicalBaseName -Path $canonical) -replace '[^A-Za-z0-9]', '').ToLowerInvariant()

        $score = 0
        if ($nameToken -and $stem -eq $nameToken)                { $score += 100 }
        elseif ($nameToken -and $stem.StartsWith($nameToken))    { $score += 60 }
        elseif ($nameToken -and $nameToken.StartsWith($stem))    { $score += 40 }

        if ($InstallLocation) {
            $directory = Split-CanonicalPath -Path $canonical
            if ($directory -eq (ConvertTo-CanonicalPath -Path $InstallLocation)) { $score += 25 }
        }

        # Shallower paths are more likely to be the entry point.
        $score -= ($canonical.Split('\').Count)

        [PSCustomObject]@{ Path = $canonical; Score = $score }
    }

    $best = @($scored | Sort-Object -Property Score -Descending)[0]
    $best.Path
}

function Import-CaptureResult {
    <#
    .SYNOPSIS
        Publishes an installation delta into the project as facts, resolved
        fields and outstanding policy decisions.
    .OUTPUTS
        What was learned and which decisions the capture raised.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][PSCustomObject]$Project,
        [Parameter(Mandatory)][PSCustomObject]$Delta
    )

    $learned   = [System.Collections.Generic.List[string]]::new()
    $decisions = [System.Collections.Generic.List[string]]::new()

    $addedFiles = @(Get-DeltaSection -Delta $Delta -Path 'Files.Added')

    # Install location and primary executable both follow from the files.
    $installLocation = Get-ProjectFieldValue -Project $Project -Path 'installation.installLocation' -Default ''

    if ($addedFiles.Count -gt 0) {
        $derivedLocation = Get-CommonDirectory -Path $addedFiles

        if ($derivedLocation) {
            Set-ProjectField -Project $Project -Path 'installation.installLocation' -Value $derivedLocation `
                -Source 'CAPTURED' -Evidence "Common root of $($addedFiles.Count) files created by the installer" | Out-Null
            $learned.Add('installation.installLocation')
            $installLocation = $derivedLocation
        }

        $applicationName = Get-ProjectFieldValue -Project $Project -Path 'application.name' -Default ''
        $executable = Select-PrimaryExecutable -Path $addedFiles -ApplicationName $applicationName -InstallLocation $installLocation

        if ($executable) {
            Set-ProjectField -Project $Project -Path 'installation.executable' -Value $executable `
                -Source 'CAPTURED' -Evidence 'Executable created by the installer' | Out-Null
            $learned.Add('installation.executable')
        }
    }

    # Uninstall registration, taken from what appeared in Add/Remove Programs.
    $addedApplications = @(Get-DeltaSection -Delta $Delta -Path 'Applications.Added')
    if ($addedApplications.Count -gt 0) {
        # Entries are recorded as "DisplayName|Version|ProductCode".
        $parts = $addedApplications[0] -split '\|'

        if ($parts[0]) {
            Set-ProjectField -Project $Project -Path 'installation.uninstallDisplayName' -Value $parts[0] `
                -Source 'CAPTURED' -Evidence 'Appeared in the uninstall registry during capture' | Out-Null
            $learned.Add('installation.uninstallDisplayName')
        }

        if ($parts.Count -gt 1 -and $parts[1]) {
            Set-ProjectField -Project $Project -Path 'application.version' -Value $parts[1] `
                -Source 'CAPTURED' -Evidence 'DisplayVersion registered by the installer' | Out-Null
            $learned.Add('application.version')
        }

        if ($parts.Count -gt 2 -and $parts[2] -match '^\{[0-9A-Fa-f-]+\}$') {
            Set-ProjectField -Project $Project -Path 'installer.productCode' -Value $parts[2] `
                -Source 'CAPTURED' -Evidence 'Product code registered by the installer' | Out-Null
            $learned.Add('installer.productCode')
        }
    }

    # Observations that are evidence, and detection material, but not policy.
    $observations = @(
        @{ DeltaPath = 'Registry.Added';       Field = 'installation.registryKeys'   }
        @{ DeltaPath = 'Services.Added';       Field = 'installation.services'       }
        @{ DeltaPath = 'ScheduledTasks.Added'; Field = 'installation.scheduledTasks' }
    )

    foreach ($observation in $observations) {
        $values = @(Get-DeltaSection -Delta $Delta -Path $observation.DeltaPath)
        if ($values.Count -eq 0) { continue }

        Set-ProjectField -Project $Project -Path $observation.Field -Value $values `
            -Source 'CAPTURED' -Evidence "$($values.Count) observed during installation capture" | Out-Null
        $learned.Add($observation.Field)
    }

    # Changes that carry a policy question. The value is recorded as a fact and
    # as a field; only the decision about it is left outstanding.
    foreach ($policy in $script:CapturePolicyMap) {
        $values = @(Get-DeltaSection -Delta $Delta -Path $policy.DeltaPath)
        if ($values.Count -eq 0) { continue }

        Set-ProjectField -Project $Project -Path $policy.FactField -Value $values `
            -Source 'CAPTURED' -Evidence "$($values.Count) $($policy.Description)(s) observed during capture" | Out-Null
        $learned.Add($policy.FactField)

        if (-not (Test-DecisionRecorded -Store $Project.Evidence -Key $policy.Decision)) {
            $decisions.Add($policy.Decision)
        }
    }

    Add-AuditEntry -Store $Project.Evidence -Category 'Operation' -Key 'CaptureInstallation' `
                   -Detail "Capture published $($learned.Count) fields and raised $($decisions.Count) decisions" `
                   -Value $null | Out-Null

    [PSCustomObject]@{
        FieldsLearned     = @($learned | Select-Object -Unique)
        DecisionsRequired = @($decisions | Select-Object -Unique)
        FilesAdded        = $addedFiles.Count
    }
}

function Get-CapturePolicyDecision {
    <#
    .SYNOPSIS
        The decision that belongs to an observed change, or empty when the
        observation raises no policy question.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$FactField)

    foreach ($policy in $script:CapturePolicyMap) {
        if ($policy.FactField -eq $FactField) { return $policy.Decision }
    }

    ''
}

function Get-CaptureDecisionPrompt {
    <#
    .SYNOPSIS
        The policy questions a capture raised, as one grouped set.
    .DESCRIPTION
        Each prompt states the change that was observed, so the user is
        deciding about something concrete rather than answering in the
        abstract.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][PSCustomObject]$Project)

    $prompts = foreach ($policy in $script:CapturePolicyMap) {
        if (Test-DecisionRecorded -Store $Project.Evidence -Key $policy.Decision) { continue }

        $observed = Get-ProjectFieldValue -Project $Project -Path $policy.FactField -Default @()
        if (@($observed).Count -eq 0) { continue }

        $definition = Get-FieldDefinition -Path $policy.Decision
        if ($null -eq $definition) { continue }

        [PSCustomObject]@{
            Path       = $policy.Decision
            Label      = $definition.Label
            Type       = 'Boolean'
            Group      = $definition.Group
            Priority   = $definition.Priority
            Rank       = $definition.PriorityRank
            IsRequired = $false
            IsDecision = $true
            Why        = $definition.Why
            Observed   = @($observed)
            Choices    = @('Yes', 'No')
            Options    = @(
                [PSCustomObject]@{ Method = 'Choice'; Label = 'Apply';         Value = $true;  Source = 'CAPTURED'; Evidence = '' }
                [PSCustomObject]@{ Method = 'Choice'; Label = 'Do not apply';  Value = $false; Source = 'CAPTURED'; Evidence = '' }
            )
        }
    }

    @($prompts | Sort-Object Rank, Path)
}
