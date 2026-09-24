<#
.SYNOPSIS
    The entry point every feature uses to ask what is known.
.DESCRIPTION
    Discovery, capture, script generation, packaging and validation all go
    through this one facade, so none of them holds its own copy of the
    application name or re-implements its own prompting. The order it enforces
    is always the same: discover, resolve, reuse, ask only what is left,
    confirm, persist.
#>

Set-StrictMode -Version Latest

function Initialize-InformationProject {
    <#
    .SYNOPSIS
        Opens an existing project or starts a new one.
    .DESCRIPTION
        Reopening a project loads every answer it already holds, which is what
        makes the second run of a build ask nothing.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Root,
        [string]$Name = '',
        [switch]$Force
    )

    if ((Test-ProjectExists -Root $Root) -and -not $Force) {
        $project = Import-ProjectState -Root $Root
        Add-AuditEntry -Store $project.Evidence -Category 'Operation' -Key 'OpenProject' `
                       -Detail "Reopened with $($project.Fields.Count) known fields" -Value $null | Out-Null
        return $project
    }

    $projectArgs = @{ Root = $Root }
    if ($Name) { $projectArgs['Name'] = $Name }

    $project = New-ProjectState @projectArgs

    foreach ($anchor in @(
        @{ Name = 'SourceDirectory';    SubPath = 'source' }
        @{ Name = 'OutputDirectory';    SubPath = 'build' }
        @{ Name = 'CaptureDirectory';   SubPath = '.project/captures' }
    )) {
        Set-ProjectAnchor -Project $project -Name $anchor.Name -Path (Join-Path $Root $anchor.SubPath) | Out-Null
    }

    # Conventional locations and a first package version follow from creating
    # the project, so none of them is worth a question. All three are ordinary
    # derived values that any later source or the user can replace.
    Set-ProjectField -Project $project -Path 'package.outputDirectory' `
        -Value (ConvertTo-CanonicalPath -Path (Join-Path $Root 'build')) `
        -Source 'DERIVED' -Evidence 'Conventional build output directory for a project' | Out-Null

    Set-ProjectField -Project $project -Path 'deployment.packageVersion' -Value '1.0.0' `
        -Source 'DERIVED' -Evidence 'First package of this application; raise it on a rebuild' | Out-Null

    Add-AuditEntry -Store $project.Evidence -Category 'Operation' -Key 'CreateProject' `
                   -Detail "Created at $Root" -Value $null | Out-Null

    $project
}

function Select-ProjectInstaller {
    <#
    .SYNOPSIS
        Registers the chosen installer and runs everything that follows from it.
    .DESCRIPTION
        One selection settles the installer path, file name, type, size, hash,
        source directory and package source, and populates the application
        name, version, publisher and architecture from its metadata. None of
        those is asked for separately afterwards.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][PSCustomObject]$Project,
        [Parameter(Mandatory)][string]$Path,
        [string]$Method = 'BrowseFile'
    )

    $canonical = ConvertTo-CanonicalPath -Path $Path

    if (-not (Test-Path -LiteralPath $canonical -PathType Leaf)) {
        throw "Installer not found: $Path"
    }

    $validation = Test-PathCharacterValid -Path $canonical
    if (-not $validation.IsValid) {
        throw "Installer path is not usable: $($validation.Problems -join '; ')"
    }

    $reference = Register-ProjectResource -Project $Project -Id 'installer.primary' `
                                          -Path $canonical -Type 'installer' -Source 'USER_SELECTED'

    Set-ProjectField -Project $Project -Path 'installer.path' -Value $reference.StoredPath `
        -Source 'USER_SELECTED' -Evidence "Selected via $Method" -State 'CONFIRMED' | Out-Null

    $field = Get-ProjectField -Project $Project -Path 'installer.path'
    $field.ConfirmedByUser = $true
    $field.Confidence      = 'CONFIRMED'

    # The directory holding the installer is the package payload unless the
    # user has already said otherwise.
    $directory = Split-CanonicalPath -Path $canonical
    Set-ProjectAnchor -Project $Project -Name 'InstallerDirectory' -Path $directory | Out-Null

    if (-not (Test-ProjectFieldKnown -Project $Project -Path 'package.sourceDirectory')) {
        Set-ProjectField -Project $Project -Path 'package.sourceDirectory' -Value $directory `
            -Source 'DERIVED' -Evidence 'Directory containing the selected installer' | Out-Null
    }

    $discovery = Invoke-InstallerDiscovery -Project $Project -InstallerPath $canonical

    [PSCustomObject]@{
        Reference   = $reference
        Family      = $discovery.Family
        FieldsFound = $discovery.FieldsFound
    }
}

function Import-PreviousBuild {
    <#
    .SYNOPSIS
        Carries deployment knowledge forward from an earlier build.
    .DESCRIPTION
        Packaging a new version of a known application starts from what the
        last one used. Values are brought in at PREVIOUS_BUILD trust, so
        anything this version's installer actually reports will outrank them,
        and only the differences need attention.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][PSCustomObject]$Project,
        [Parameter(Mandatory)][string]$ManifestPath
    )

    if (-not (Test-Path -LiteralPath $ManifestPath -PathType Leaf)) {
        throw "Previous manifest not found: $ManifestPath"
    }

    $manifest = Get-Content -LiteralPath $ManifestPath -Raw | ConvertFrom-Json
    $names    = $manifest.PSObject.Properties.Name

    $mappings = @(
        @{ Property = 'ApplicationName';   Field = 'application.name' }
        @{ Property = 'ApplicationVersion';Field = 'application.version' }
        @{ Property = 'PackageVersion';    Field = 'deployment.packageVersion' }
        @{ Property = 'InstallerType';     Field = 'installer.type' }
        @{ Property = 'InstallCommand';    Field = 'deployment.installCommand' }
        @{ Property = 'UninstallCommand';  Field = 'deployment.uninstallCommand' }
        @{ Property = 'DetectionMethod';   Field = 'deployment.detectionMethod' }
        @{ Property = 'InstallBehavior';   Field = 'installation.context' }
        @{ Property = 'Architecture';      Field = 'application.architecture' }
        @{ Property = 'MinimumOS';         Field = 'deployment.minimumOS' }
        @{ Property = 'ExpectedExitCodes'; Field = 'deployment.expectedExitCodes' }
        @{ Property = 'RebootBehavior';    Field = 'deployment.rebootBehavior' }
    )

    $imported   = [System.Collections.Generic.List[string]]::new()
    $comparisons = [System.Collections.Generic.List[PSCustomObject]]::new()

    foreach ($mapping in $mappings) {
        if ($mapping.Property -notin $names) { continue }

        $value = $manifest.($mapping.Property)
        if (Test-FieldValueEmpty -Value $value) { continue }

        # The previous value is always kept as evidence, so a comparison is
        # possible even where it is not adopted.
        Add-Fact -Store $Project.Evidence -Key $mapping.Field -Value $value -Source 'PREVIOUS_BUILD' `
                 -Evidence "Used by package version $($manifest.PackageVersion)" | Out-Null

        $current = Get-ProjectFieldValue -Project $Project -Path $mapping.Field -Default $null

        if ($null -ne $current) {
            # This version's own installer outranks the last build's record of
            # it. Carrying the old value forward here is how a version update
            # silently ships the previous version's identity.
            $comparison = Compare-PreviousValue -Path $mapping.Field -PreviousValue $value -CurrentValue $current `
                                                -CurrentSource (Get-ProjectField -Project $Project -Path $mapping.Field).Source
            if ($comparison.HasChanged) { $comparisons.Add($comparison) }
            continue
        }

        Set-ProjectField -Project $Project -Path $mapping.Field -Value $value `
            -Source 'PREVIOUS_BUILD' -Evidence "Used by package version $($manifest.PackageVersion)" | Out-Null

        $imported.Add($mapping.Field)
    }

    Add-AuditEntry -Store $Project.Evidence -Category 'Operation' -Key 'ImportPreviousBuild' `
                   -Detail "Imported $($imported.Count) fields from $ManifestPath" -Value $null | Out-Null

    [PSCustomObject]@{
        FieldsImported = @($imported)
        Changes        = @($comparisons)
        ManifestPath   = $ManifestPath
    }
}

function New-DeploymentBlueprint {
    <#
    .SYNOPSIS
        Generates the install, uninstall and detection commands from what is
        known, so the user never assembles them by hand.
    .DESCRIPTION
        Commands are built as structure and rendered once. The rendered strings
        are what the build tests and what Intune receives, which is what keeps
        the tested command and the production command the same string.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][PSCustomObject]$Project,
        [switch]$UseWrapperScripts
    )

    $installerFileName = Get-ProjectFieldValue -Project $Project -Path 'installer.fileName' -Default ''
    $installerType     = Get-ProjectFieldValue -Project $Project -Path 'installer.type' -Default ''
    $silentArguments   = Get-ProjectFieldValue -Project $Project -Path 'installer.silentArguments' -Default ''
    $productCode       = Get-ProjectFieldValue -Project $Project -Path 'installer.productCode' -Default ''
    $uninstallString   = Get-ProjectFieldValue -Project $Project -Path 'installation.uninstallString' -Default ''

    # Silent arguments are authored as one string but travel as tokens, so an
    # argument whose value contains a space stays one argument.
    $argumentTokens = ConvertTo-ArgumentTokens -ArgumentString $silentArguments

    # A wrapper script is the default because it is what preserves the vendor
    # exit code and writes a log; a bare installer command does neither. The
    # wrapper is handed the installer name and its silent arguments from the
    # information model, so package.json is the single source of both and they
    # are never restated inside the template.
    $installCommand = if ($UseWrapperScripts -or -not $installerFileName) {
        if ($installerFileName) {
            New-PowerShellScriptCommand -ScriptName 'Install.ps1' `
                -InstallerName $installerFileName -InstallerArguments $argumentTokens
        } else {
            New-PowerShellScriptCommand -ScriptName 'Install.ps1'
        }
    } elseif ($installerType -eq 'MSI') {
        New-MsiInstallCommand -InstallerFileName $installerFileName
    } else {
        New-StructuredCommand -Executable ".\$installerFileName" -Arguments $argumentTokens
    }

    $uninstallCommand = if ($UseWrapperScripts -or (-not $productCode -and -not $uninstallString)) {
        New-PowerShellScriptCommand -ScriptName 'Uninstall.ps1'
    } elseif ($productCode) {
        New-MsiUninstallCommand -ProductCode $productCode
    } else {
        ConvertFrom-CommandString -CommandLine $uninstallString
    }

    $detectionCommand = New-PowerShellScriptCommand -ScriptName 'Detection.ps1'

    $installString   = ConvertTo-CommandString -Command $installCommand
    $uninstallString = ConvertTo-CommandString -Command $uninstallCommand
    $detectionString = ConvertTo-CommandString -Command $detectionCommand

    Set-ProjectField -Project $Project -Path 'deployment.installCommand' -Value $installString `
        -Source 'DERIVED' -Evidence 'Generated from the installer type and its silent switches' | Out-Null
    Set-ProjectField -Project $Project -Path 'deployment.uninstallCommand' -Value $uninstallString `
        -Source 'DERIVED' -Evidence 'Generated from the product code or registered uninstall string' | Out-Null

    if (-not (Test-ProjectFieldKnown -Project $Project -Path 'deployment.detectionMethod')) {
        Set-ProjectField -Project $Project -Path 'deployment.detectionMethod' -Value 'Script' `
            -Source 'DERIVED' -Evidence 'A detection script is the only method that can prove version as well as presence' | Out-Null
    }

    [PSCustomObject]@{
        Install   = [PSCustomObject]@{ Structured = $installCommand;   Rendered = $installString }
        Uninstall = [PSCustomObject]@{ Structured = $uninstallCommand; Rendered = $uninstallString }
        Detection = [PSCustomObject]@{ Structured = $detectionCommand; Rendered = $detectionString }
    }
}

function Get-InformationInventory {
    <#
    .SYNOPSIS
        Every value the project holds, with where it came from and what can be
        done about it.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][PSCustomObject]$Project,
        [switch]$IncludeUnknown
    )

    $catalog = Get-FieldCatalog

    $rows = foreach ($path in ($catalog.Keys)) {
        $definition = $catalog[$path]
        $field      = Get-ProjectField -Project $Project -Path $path

        if ($null -eq $field) {
            if (-not $IncludeUnknown) { continue }

            [PSCustomObject]@{
                Field       = $definition.Label
                Path        = $path
                Group       = $definition.Group
                Value       = $null
                Source      = ''
                Confidence  = ''
                Status      = 'UNKNOWN'
                LastUpdated = ''
                Actions     = @('Redetect') + $definition.InputMethods
            }
            continue
        }

        $actions = [System.Collections.Generic.List[string]]::new()
        $actions.Add('Edit')
        $actions.Add('ViewEvidence')
        if ($definition.Discoverers.Count -gt 0) { $actions.Add('Redetect') }
        if ($null -ne $field.OriginalSource) { $actions.Add('ResetToDetected') }
        $actions.Add('Replace')

        [PSCustomObject]@{
            Field       = $definition.Label
            Path        = $path
            Group       = $definition.Group
            Value       = $field.Value
            Source      = $field.Source
            Confidence  = $field.Confidence
            Status      = $field.State
            LastUpdated = $field.UpdatedAt
            Actions     = @($actions)
        }
    }

    @($rows | Sort-Object Group, Path)
}

function New-InformationReview {
    <#
    .SYNOPSIS
        The consolidated review shown before a production build.
    .DESCRIPTION
        Anything still UNKNOWN, USER_REQUIRED, CONFLICT or INVALID is listed as
        outstanding, and the review refuses to call the project ready while any
        of them remain.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][PSCustomObject]$Project,
        [string]$Operation = 'BuildPackage'
    )

    $readiness    = Get-OperationReadiness -Project $Project -Operation $Operation
    $completeness = Get-ProjectCompleteness -Project $Project -Operation $Operation
    $conflicts    = @(Get-ProjectConflict -Project $Project)

    $outstanding = @(
        foreach ($entry in ($readiness.Required + $readiness.Recommended)) {
            if ($entry.IsSatisfied) { continue }
            [PSCustomObject]@{
                Path       = $entry.Path
                Label      = $entry.Label
                Status     = $entry.Status
                IsRequired = $entry.IsRequired
                BlockedBy  = $entry.BlockedBy
            }
        }
    )

    $summary = [ordered]@{}
    foreach ($path in @(
        'application.name', 'application.version', 'application.publisher', 'application.architecture'
        'installer.path', 'installer.type', 'installation.context', 'installation.installLocation'
        'installation.executable', 'deployment.installCommand', 'deployment.uninstallCommand'
        'deployment.detectionMethod', 'deployment.rebootBehavior'
    )) {
        $field = Get-ProjectField -Project $Project -Path $path
        if ($null -eq $field) { continue }
        if (-not (Test-FieldResolved -Field $field)) { continue }

        $definition = Get-FieldDefinition -Path $path
        $summary[$definition.Label] = [PSCustomObject]@{
            Value  = $field.Value
            Source = Format-FieldEvidence -Field $field
        }
    }

    $observed = [ordered]@{}
    foreach ($path in @(
        'installation.machinePath', 'installation.environmentVariables', 'installation.shortcuts'
        'installation.fileAssociations', 'installation.services', 'installation.scheduledTasks'
    )) {
        $value = Get-ProjectFieldValue -Project $Project -Path $path -Default $null
        if ($null -eq $value) { continue }

        $definition = Get-FieldDefinition -Path $path
        $decisionPath = Get-CapturePolicyDecision -FactField $path

        $decision = if ($decisionPath) {
            Get-Decision -Store $Project.Evidence -Key $decisionPath
        } else {
            $null
        }

        $observed[$definition.Label] = [PSCustomObject]@{
            Observed = @($value)
            Decision = if ($null -eq $decision) { 'Not decided' } else { $decision.Value }
        }
    }

    [PSCustomObject]@{
        ProjectName  = $Project.Name
        Operation    = $Operation
        Summary      = $summary
        Observed     = $observed
        Outstanding  = $outstanding
        Conflicts    = $conflicts
        Completeness = $completeness
        IsReady      = $readiness.CanProceed -and $conflicts.Count -eq 0
    }
}

function Export-ProjectManifest {
    <#
    .SYNOPSIS
        Produces the package manifest the build already understands, from the
        project's information rather than from a hand-written config file.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][PSCustomObject]$Project,
        [string]$ContentDirectory = ''
    )

    $readiness = Get-OperationReadiness -Project $Project -Operation 'BuildPackage'
    if (-not $readiness.CanProceed) {
        $missing = @($readiness.Blockers | ForEach-Object { $_.Label })
        throw "Cannot build a manifest while information is missing: $($missing -join ', ')"
    }

    if (-not $ContentDirectory) {
        $ContentDirectory = Get-ProjectFieldValue -Project $Project -Path 'package.sourceDirectory' -Default $Project.Root
    }

    $detectionMethod = Get-ProjectFieldValue -Project $Project -Path 'deployment.detectionMethod' -Default 'Script'

    $manifestArgs = @{
        ApplicationName    = Get-ProjectFieldValue -Project $Project -Path 'application.name'
        ApplicationVersion = Get-ProjectFieldValue -Project $Project -Path 'application.version'
        PackageVersion     = Get-ProjectFieldValue -Project $Project -Path 'deployment.packageVersion' -Default '1.0.0'
        InstallerType      = Get-ProjectFieldValue -Project $Project -Path 'installer.type'
        SourceInstaller    = Get-ProjectFieldValue -Project $Project -Path 'installer.fileName'
        InstallCommand     = Get-ProjectFieldValue -Project $Project -Path 'deployment.installCommand'
        UninstallCommand   = Get-ProjectFieldValue -Project $Project -Path 'deployment.uninstallCommand'
        DetectionMethod    = $detectionMethod
        ContentDirectory   = $ContentDirectory
        InstallBehavior    = Get-ProjectFieldValue -Project $Project -Path 'installation.context' -Default 'System'
        Architecture       = Get-ProjectFieldValue -Project $Project -Path 'application.architecture' -Default 'x64'
        MinimumOS          = Get-ProjectFieldValue -Project $Project -Path 'deployment.minimumOS' -Default 'W10_1809'
        ExpectedExitCodes  = @(Get-ProjectFieldValue -Project $Project -Path 'deployment.expectedExitCodes' -Default @(0, 1641, 3010))
        RebootBehavior     = Get-ProjectFieldValue -Project $Project -Path 'deployment.rebootBehavior' -Default 'BasedOnReturnCode'
    }

    if ($detectionMethod -eq 'Script') {
        $manifestArgs['DetectionScript'] = 'Detection.ps1'
    }

    New-PackageManifest @manifestArgs
}
