#Requires -Version 5.1
<#
    Analyzer.ps1

    Read-only inspection of an .exe or .msi installer.

    IMPORTANT: this file never installs, never writes to the registry, never
    touches PATH and never launches the installer. It only reads metadata from
    the file on disk. Everything it produces is a *recommendation* that the
    technician reviews before anything executes.

    Headless: no UI dependencies.
#>

Set-StrictMode -Version Latest

# --- Installer technology fingerprints -------------------------------------
# Ordered most-specific first; the first match wins.
$script:InstallerSignatures = @(
    @{
        Name       = 'Inno Setup'
        Markers    = @('Inno Setup', 'JR.Inno.Setup')
        Silent     = '/VERYSILENT /SUPPRESSMSGBOXES /NORESTART /SP-'
        BasicUI    = '/SILENT /SUPPRESSMSGBOXES /NORESTART /SP-'
        Uninstall  = '/VERYSILENT /SUPPRESSMSGBOXES /NORESTART'
        Confidence = 'High'
    }
    @{
        Name       = 'NSIS'
        Markers    = @('Nullsoft.NSIS', 'Nullsoft Install System', 'NullsoftInst')
        Silent     = '/S'
        BasicUI    = '/S'
        Uninstall  = '/S'
        Confidence = 'High'
    }
    @{
        Name       = 'WiX Burn'
        Markers    = @('WixBundle', 'wixburn', 'Wix.Bootstrapper')
        Silent     = '/quiet /norestart'
        BasicUI    = '/passive /norestart'
        Uninstall  = '/uninstall /quiet /norestart'
        Confidence = 'High'
    }
    @{
        Name       = 'InstallShield'
        Markers    = @('InstallShield', 'IsSetupHlp', 'ISSetupPrerequisite')
        Silent     = '/s /v"/qn REBOOT=ReallySuppress"'
        BasicUI    = '/s /v"/qb REBOOT=ReallySuppress"'
        Uninstall  = '/s /x /v"/qn"'
        Confidence = 'Medium'
    }
    @{
        Name       = 'Squirrel'
        Markers    = @('Squirrel.Windows', 'SquirrelSetup')
        Silent     = '--silent'
        BasicUI    = '--silent'
        Uninstall  = '--uninstall --silent'
        Confidence = 'Medium'
    }
    @{
        Name       = 'InstallAware'
        Markers    = @('InstallAware')
        Silent     = '/s'
        BasicUI    = '/s'
        Uninstall  = '/s /x'
        Confidence = 'Low'
    }
    @{
        Name       = 'Wise Installer'
        Markers    = @('Wise Installation', 'WiseMain')
        Silent     = '/s'
        BasicUI    = '/s'
        Uninstall  = '/s'
        Confidence = 'Low'
    }
    @{
        Name       = '7-Zip SFX'
        Markers    = @('7-Zip', '7zSFX')
        Silent     = '-y'
        BasicUI    = '-y'
        Uninstall  = ''
        Confidence = 'Low'
    }
    @{
        Name       = 'Embedded MSI'
        Markers    = @('msiexec', 'Windows Installer XML')
        Silent     = '/quiet /norestart'
        BasicUI    = '/passive /norestart'
        Uninstall  = '/uninstall /quiet /norestart'
        Confidence = 'Low'
    }
)

function Get-FileMarkerMatches {
    <#
        Scans the head and tail of a binary for ASCII and UTF-16LE marker
        strings. Installers are often very large, so only bounded regions are
        read rather than the whole file.
    #>
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string[]]$Markers,
        [int]$HeadBytes = 8MB,
        [int]$TailBytes = 1MB
    )

    $found = @()
    try {
        $fs = [System.IO.File]::Open($Path, 'Open', 'Read', 'ReadWrite')
        try {
            $length = $fs.Length

            $headLen = [Math]::Min($HeadBytes, $length)
            $head = New-Object byte[] $headLen
            [void]$fs.Read($head, 0, $headLen)

            $tail = @()
            if ($length -gt $HeadBytes) {
                $tailLen = [int][Math]::Min($TailBytes, $length - $HeadBytes)
                $fs.Seek(-$tailLen, [System.IO.SeekOrigin]::End) | Out-Null
                $tail = New-Object byte[] $tailLen
                [void]$fs.Read($tail, 0, $tailLen)
            }

            $ascii = [System.Text.Encoding]::ASCII
            $uni = [System.Text.Encoding]::Unicode

            $haystacks = @()
            $haystacks += $ascii.GetString($head)
            $haystacks += $uni.GetString($head)
            if ($tail.Count -gt 0) {
                $haystacks += $ascii.GetString($tail)
                $haystacks += $uni.GetString($tail)
            }

            foreach ($marker in $Markers) {
                foreach ($hay in $haystacks) {
                    if ($hay.IndexOf($marker, [StringComparison]::OrdinalIgnoreCase) -ge 0) {
                        $found += $marker
                        break
                    }
                }
            }
        }
        finally { $fs.Dispose() }
    }
    catch {
        # Unreadable file is not fatal to analysis; caller reports lower confidence.
    }

    # Emitted to the pipeline (not 'return ,$found', which would wrap an empty
    # result into a one-element array and make every signature appear to match).
    # Callers wrap in @() to get a reliable count.
    $found
}

function Get-InstallerTechnology {
    param([Parameter(Mandatory)][string]$Path)

    foreach ($sig in $script:InstallerSignatures) {
        $hits = @(Get-FileMarkerMatches -Path $Path -Markers $sig.Markers)
        if ($hits.Count -gt 0) {
            return [pscustomobject]@{
                Name              = $sig.Name
                Confidence        = $sig.Confidence
                SilentArguments   = $sig.Silent
                BasicUIArguments  = $sig.BasicUI
                UninstallArguments = $sig.Uninstall
                MatchedMarkers    = $hits
            }
        }
    }

    return [pscustomobject]@{
        Name               = 'Unknown'
        Confidence         = 'Low'
        SilentArguments    = '/S'
        BasicUIArguments   = ''
        UninstallArguments = ''
        MatchedMarkers     = @()
    }
}

function Get-MsiProperties {
    <#
        Reads the MSI Property table via the Windows Installer COM API.
        Returns an empty hashtable off-Windows or when the MSI cannot be read.
    #>
    param([Parameter(Mandatory)][string]$Path)

    $props = @{}
    $installer = $null
    $database = $null
    $view = $null

    try {
        $installer = New-Object -ComObject WindowsInstaller.Installer -ErrorAction Stop

        # 0 = read-only
        $database = $installer.GetType().InvokeMember(
            'OpenDatabase', 'InvokeMethod', $null, $installer, @($Path, 0))

        $view = $database.GetType().InvokeMember(
            'OpenView', 'InvokeMethod', $null, $database,
            @('SELECT `Property`,`Value` FROM `Property`'))

        $view.GetType().InvokeMember('Execute', 'InvokeMethod', $null, $view, $null) | Out-Null

        while ($true) {
            $record = $view.GetType().InvokeMember('Fetch', 'InvokeMethod', $null, $view, $null)
            if ($null -eq $record) { break }

            $name = $record.GetType().InvokeMember('StringData', 'GetProperty', $null, $record, @(1))
            $value = $record.GetType().InvokeMember('StringData', 'GetProperty', $null, $record, @(2))
            $props[$name] = $value
        }
    }
    catch {
        # Not on Windows, or the file is not a readable MSI.
    }
    finally {
        foreach ($obj in @($view, $database, $installer)) {
            if ($obj) {
                try { [void][System.Runtime.InteropServices.Marshal]::ReleaseComObject($obj) } catch { }
            }
        }
    }

    return $props
}

function Get-FileHashSafe {
    param([Parameter(Mandatory)][string]$Path, [string]$Algorithm = 'SHA256')
    try { return (Get-FileHash -LiteralPath $Path -Algorithm $Algorithm -ErrorAction Stop).Hash }
    catch { return $null }
}

function Get-SignatureInfo {
    param([Parameter(Mandatory)][string]$Path)

    $result = [ordered]@{
        Status  = 'Unknown'
        Signer  = $null
        Signed  = $false
    }

    if (-not (Get-Command Get-AuthenticodeSignature -ErrorAction SilentlyContinue)) {
        $result.Status = 'Unavailable (non-Windows)'
        return [pscustomobject]$result
    }

    try {
        $sig = Get-AuthenticodeSignature -LiteralPath $Path -ErrorAction Stop
        $result.Status = [string]$sig.Status
        $result.Signed = ($sig.Status -eq 'Valid')
        if ($sig.SignerCertificate) {
            $result.Signer = $sig.SignerCertificate.Subject
        }
    }
    catch {
        $result.Status = 'Unavailable'
    }

    return [pscustomobject]$result
}

function Get-PeArchitecture {
    <#
        Reads the PE COFF machine field to determine the target architecture.
    #>
    param([Parameter(Mandatory)][string]$Path)

    try {
        $fs = [System.IO.File]::Open($Path, 'Open', 'Read', 'ReadWrite')
        try {
            $br = New-Object System.IO.BinaryReader($fs)

            $fs.Seek(0, 'Begin') | Out-Null
            if ($br.ReadUInt16() -ne 0x5A4D) { return 'Unknown' }   # 'MZ'

            $fs.Seek(0x3C, 'Begin') | Out-Null
            $peOffset = $br.ReadInt32()
            if ($peOffset -le 0 -or $peOffset -gt ($fs.Length - 6)) { return 'Unknown' }

            $fs.Seek($peOffset, 'Begin') | Out-Null
            if ($br.ReadUInt32() -ne 0x00004550) { return 'Unknown' }  # 'PE\0\0'

            switch ($br.ReadUInt16()) {
                0x8664  { return 'x64' }
                0x014c  { return 'x86' }
                0xAA64  { return 'ARM64' }
                0x01c4  { return 'ARM' }
                default { return 'Unknown' }
            }
        }
        finally { $fs.Dispose() }
    }
    catch { return 'Unknown' }
}

function Get-InstallerAnalysis {
    <#
        .SYNOPSIS
        Inspects an installer and returns everything known about it.

        .DESCRIPTION
        Purely read-only. The result feeds the wizard's recommendations; it
        does not itself change anything on the machine.

        .PARAMETER Path
        Path to the .exe or .msi to inspect.
    #>
    param(
        [Parameter(Mandatory)][string]$Path
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "Installer not found: $Path"
    }

    $item = Get-Item -LiteralPath $Path
    $extension = $item.Extension.ToLowerInvariant()

    if ($extension -notin @('.exe', '.msi')) {
        throw "Unsupported installer type '$extension'. Expected .exe or .msi."
    }

    $type = if ($extension -eq '.msi') { 'MSI' } else { 'EXE' }

    $analysis = [ordered]@{
        # File
        FilePath        = $item.FullName
        FileName        = $item.Name
        FileSizeBytes   = $item.Length
        FileSizeText    = '{0:N1} MB' -f ($item.Length / 1MB)
        LastModified    = $item.LastWriteTime
        Sha256          = Get-FileHashSafe -Path $item.FullName
        Signature       = Get-SignatureInfo -Path $item.FullName

        # Application
        InstallerType   = $type
        ApplicationName = [System.IO.Path]::GetFileNameWithoutExtension($item.Name)
        Publisher       = ''
        Version         = ''
        FileVersion     = ''
        ProductVersion  = ''
        Architecture    = 'Unknown'

        # Installer behavior
        Technology         = 'Unknown'
        TechnologyConfidence = 'Low'
        SilentArguments    = ''
        BasicUIArguments   = ''
        SupportsSilent     = $false

        # Uninstall
        ProductCode        = $null
        UninstallArguments = ''

        # Integration candidates (populated only when an install dir is supplied)
        PathCandidates     = @()

        # Recommendations
        Recommendations = [ordered]@{}
        Notes           = @()
    }

    # --- Version resource (EXE) ---
    if ($type -eq 'EXE') {
        try {
            $vi = $item.VersionInfo
            if ($vi.ProductName)    { $analysis.ApplicationName = $vi.ProductName.Trim() }
            if ($vi.CompanyName)    { $analysis.Publisher       = $vi.CompanyName.Trim() }
            if ($vi.FileVersion)    { $analysis.FileVersion     = $vi.FileVersion.Trim() }
            if ($vi.ProductVersion) { $analysis.ProductVersion  = $vi.ProductVersion.Trim() }
            $analysis.Version = if ($vi.ProductVersion) { $vi.ProductVersion.Trim() }
                                elseif ($vi.FileVersion) { $vi.FileVersion.Trim() }
                                else { '' }
        }
        catch {
            $analysis.Notes += 'Version resource could not be read from the installer.'
        }

        $analysis.Architecture = Get-PeArchitecture -Path $item.FullName

        $tech = Get-InstallerTechnology -Path $item.FullName
        $analysis.Technology           = $tech.Name
        $analysis.TechnologyConfidence = $tech.Confidence
        $analysis.SilentArguments      = $tech.SilentArguments
        $analysis.BasicUIArguments     = $tech.BasicUIArguments
        $analysis.UninstallArguments   = $tech.UninstallArguments
        $analysis.SupportsSilent       = [bool]$tech.SilentArguments

        if ($tech.Name -eq 'Unknown') {
            $analysis.Notes += 'Installer technology could not be identified. Silent switches are a guess - confirm them against vendor documentation before deploying.'
        }
    }

    # --- MSI property table ---
    if ($type -eq 'MSI') {
        $analysis.Technology           = 'Windows Installer (MSI)'
        $analysis.TechnologyConfidence = 'High'
        $analysis.SilentArguments      = '/qn /norestart'
        $analysis.BasicUIArguments     = '/qb /norestart'
        $analysis.UninstallArguments   = '/qn /norestart'
        $analysis.SupportsSilent       = $true

        $props = Get-MsiProperties -Path $item.FullName
        if ($props.Count -gt 0) {
            if ($props['ProductName'])    { $analysis.ApplicationName = $props['ProductName'] }
            if ($props['Manufacturer'])   { $analysis.Publisher       = $props['Manufacturer'] }
            if ($props['ProductVersion']) {
                $analysis.Version        = $props['ProductVersion']
                $analysis.ProductVersion = $props['ProductVersion']
            }
            if ($props['ProductCode'])    { $analysis.ProductCode     = $props['ProductCode'] }

            $template = $props['Template']
            if ($template -and $template -match 'x64|Intel64|Arm64') {
                $analysis.Architecture = if ($template -match 'Arm64') { 'ARM64' } else { 'x64' }
            }
            elseif ($template) {
                $analysis.Architecture = 'x86'
            }
        }
        else {
            $analysis.Notes += 'MSI property table could not be read (Windows Installer COM is unavailable here). ProductCode must be supplied manually.'
        }
    }

    # --- Recommendations -------------------------------------------------
    $analysis.Recommendations = Get-AnalysisRecommendations -Analysis $analysis

    return [pscustomobject]$analysis
}

function Get-AnalysisRecommendations {
    <#
        Turns raw analysis into recommended install / detection / uninstall
        settings, each carrying a confidence the technician can weigh.
    #>
    param([Parameter(Mandatory)]$Analysis)

    $rec = [ordered]@{}

    # Install
    $rec['Install'] = [ordered]@{
        Type       = $Analysis.InstallerType
        File       = $Analysis.FileName
        Arguments  = $Analysis.SilentArguments
        Confidence = $Analysis.TechnologyConfidence
        Reason     = "Detected installer technology: $($Analysis.Technology)"
    }

    # Detection
    if ($Analysis.InstallerType -eq 'MSI' -and $Analysis.ProductCode) {
        $rec['Detection'] = [ordered]@{
            Type        = 'MSI'
            ProductCode = $Analysis.ProductCode
            Confidence  = 'High'
            Reason      = 'MSI ProductCode read directly from the package.'
        }
    }
    else {
        $guessDir = if ($Analysis.Publisher -and $Analysis.ApplicationName) {
            "C:\Program Files\$($Analysis.Publisher)\$($Analysis.ApplicationName)"
        }
        elseif ($Analysis.ApplicationName) {
            "C:\Program Files\$($Analysis.ApplicationName)"
        }
        else { 'C:\Program Files\<Application>' }

        $rec['Detection'] = [ordered]@{
            Type           = 'File'
            Path           = $guessDir
            FileName       = ''
            MinimumVersion = $Analysis.Version
            Confidence     = 'Low'
            Reason         = 'Install directory inferred from installer metadata. Confirm the real path after a test install.'
        }
    }

    # Uninstall
    if ($Analysis.InstallerType -eq 'MSI' -and $Analysis.ProductCode) {
        $rec['Uninstall'] = [ordered]@{
            Type        = 'MSI'
            ProductCode = $Analysis.ProductCode
            Confidence  = 'High'
            Reason      = 'msiexec /x with the package ProductCode.'
        }
    }
    elseif ($Analysis.InstallerType -eq 'MSI') {
        # MSI with no readable ProductCode: uninstall still goes through
        # msiexec, but the code has to come from the technician.
        $rec['Uninstall'] = [ordered]@{
            Type        = 'MSI'
            ProductCode = $null
            Confidence  = 'Low'
            Reason      = 'MSI ProductCode could not be read from the package. Supply it before deploying - uninstall cannot work without it.'
        }
    }
    elseif ($Analysis.UninstallArguments) {
        $rec['Uninstall'] = [ordered]@{
            Type       = 'EXE'
            File       = ''
            Arguments  = $Analysis.UninstallArguments
            Confidence = $Analysis.TechnologyConfidence
            Reason     = "Typical uninstall switches for $($Analysis.Technology). The uninstaller path must be confirmed after a test install."
        }
    }
    else {
        $rec['Uninstall'] = [ordered]@{
            Type       = 'EXE'
            File       = ''
            Arguments  = ''
            Confidence = 'Low'
            Reason     = 'No uninstall convention known for this installer. Supply the command from the Windows uninstall registry key after a test install.'
        }
    }

    return $rec
}

function Get-InstalledIntegrationCandidates {
    <#
        .SYNOPSIS
        Inspects an already-installed application directory for integration
        candidates (CLI directories, shortcuts, services).

        .DESCRIPTION
        Read-only. Intended to run after a test install so the wizard can offer
        concrete, real paths rather than guesses. Reuses the CLI discovery
        helper from Helpers/Environment.ps1 when it is available.
    #>
    param(
        [Parameter(Mandatory)][string]$InstallPath
    )

    $result = [ordered]@{
        InstallPath    = $InstallPath
        Exists         = (Test-Path -LiteralPath $InstallPath)
        PathCandidates = @()
        Executables    = @()
    }

    if (-not $result.Exists) { return [pscustomobject]$result }

    if (Get-Command Find-CliDirectories -ErrorAction SilentlyContinue) {
        $result.PathCandidates = @(Find-CliDirectories -InstallPath $InstallPath)
    }

    $result.Executables = @(
        Get-ChildItem -LiteralPath $InstallPath -Filter '*.exe' -File -Recurse -Depth 2 -ErrorAction SilentlyContinue |
            Select-Object -First 50 |
            ForEach-Object {
                [ordered]@{
                    Name     = $_.Name
                    FullName = $_.FullName
                    Version  = $_.VersionInfo.FileVersion
                }
            }
    )

    return [pscustomobject]$result
}
