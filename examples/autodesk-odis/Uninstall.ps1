<#
.SYNOPSIS
    Deployment wrapper - uninstall (Autodesk ODIS offline deployment).
.DESCRIPTION
    Removes Revit 2027 with the ODIS installer's own uninstall verb, driven by
    the product manifests inside the deployment image, exactly as the vendor
    .bat documents:

        Installer.exe -i uninstall -q
            --manifest           <image>\RVT_2027_en-US\setup.xml
            --extension_manifest <image>\RVT_2027_en-US\setup_ext.xml

    It prefers the staged image at the deployment path (where install put it and
    where the product's symlinks point), and falls back to the copy shipped in
    the package if the staged one is gone. -q is true silent, safe under SYSTEM.

    After a successful uninstall the staged image is removed to reclaim the
    ~14 GB it occupies. This is safe only once the product is gone, because the
    symlink deployment references files inside it while installed.

    Contracts kept from the template: the vendor exit code is preserved; the
    process is waited on alone (never -Wait); the log path cannot throw; nothing
    to remove is treated as a successful uninstall, not a failure.
#>

[CmdletBinding()]
param(
    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]]$IgnoredArguments = @()
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# --- Package configuration ---------------------------------------------------
$PackageRoot = $PSScriptRoot
$ImageFolderName = 'image'
$DeploymentImagePath = 'C:\Program Files\Autodesk\image'
$BundleFolder = 'RVT_2027_en-US'

# Reclaim the staged image after the product is removed. Set to $false to keep
# the image staged (e.g. if you redeploy frequently and want to skip re-copying).
$RemoveImageOnUninstall = $true

$SuccessExitCodes = @(0, 1605)   # 1605: already absent
$RebootExitCodes  = @(1641, 3010)
$UninstallTimeoutSeconds = 3600

$LogParent = if ($env:ProgramData) { $env:ProgramData } elseif ($env:TEMP) { $env:TEMP } else { [System.IO.Path]::GetTempPath() }
$LogRoot = Join-Path $LogParent 'IntuneDeployment\Logs'
$LogFile = Join-Path $LogRoot ('Uninstall-Revit2027.3-{0}.log' -f (Get-Date -Format 'yyyyMMdd-HHmmss'))

function Write-Log {
    param(
        [Parameter(Mandatory)][string]$Message,
        [ValidateSet('INFO', 'WARN', 'ERROR')][string]$Level = 'INFO'
    )

    $line = '{0} [{1}] {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level, $Message
    Write-Host $line

    try {
        if (-not (Test-Path -LiteralPath $LogRoot)) {
            New-Item -Path $LogRoot -ItemType Directory -Force | Out-Null
        }
        Add-Content -LiteralPath $LogFile -Value $line -Encoding UTF8
    } catch { }
}

function Invoke-NativeProcess {
    param(
        [Parameter(Mandatory)][string]$FilePath,
        [string[]]$Arguments = @(),
        [Parameter(Mandatory)][int]$TimeoutSeconds,
        [string]$WorkingDirectory = $PackageRoot
    )

    $argumentLine = (
        $Arguments | ForEach-Object {
            if ([string]::IsNullOrEmpty($_)) { return }
            if ($_ -match '"') { $_ }
            elseif ($_ -match '\s') { '"' + $_ + '"' }
            else { $_ }
        }
    ) -join ' '

    Write-Log "Running: $FilePath $argumentLine"

    $startInfo = [System.Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName         = $FilePath
    $startInfo.Arguments        = $argumentLine
    $startInfo.WorkingDirectory = $WorkingDirectory
    $startInfo.UseShellExecute  = $false

    $process = [System.Diagnostics.Process]::Start($startInfo)
    Write-Log "Process running as PID $($process.Id)"

    if (-not $process.WaitForExit($TimeoutSeconds * 1000)) {
        Write-Log "Process did not exit within $TimeoutSeconds seconds" -Level ERROR
        try { $process.Kill() } catch { }
        return 1460
    }

    $process.ExitCode
}

$exitCode = 1

try {
    $identity = [System.Security.Principal.WindowsIdentity]::GetCurrent()
    Write-Log "Package root: $PackageRoot"
    Write-Log "Running as: $($identity.Name) (System=$($identity.IsSystem))"

    # Prefer the staged image; fall back to the copy in the package.
    $imageRoot = if (Test-Path -LiteralPath (Join-Path $DeploymentImagePath 'Installer.exe') -PathType Leaf) {
        $DeploymentImagePath
    } else {
        Join-Path $PackageRoot $ImageFolderName
    }
    Write-Log "Using image at: $imageRoot"

    $installer        = Join-Path $imageRoot 'Installer.exe'
    $manifest         = Join-Path $imageRoot "$BundleFolder\setup.xml"
    $extensionManifest = Join-Path $imageRoot "$BundleFolder\setup_ext.xml"

    if (-not (Test-Path -LiteralPath $installer -PathType Leaf)) {
        Write-Log "Installer.exe not found at $installer; nothing to uninstall from. Treating as already removed."
        exit 0
    }
    if (-not (Test-Path -LiteralPath $manifest -PathType Leaf)) {
        throw "Uninstall manifest not found: $manifest"
    }

    $uninstallArguments = @(
        '-i', 'uninstall'
        '-q'
        '--manifest', $manifest
        '--extension_manifest', $extensionManifest
    )

    $vendorExitCode = Invoke-NativeProcess -FilePath $installer `
        -Arguments $uninstallArguments -TimeoutSeconds $UninstallTimeoutSeconds `
        -WorkingDirectory $imageRoot

    Write-Log "Uninstaller exited with code $vendorExitCode"

    $requiresReboot = $vendorExitCode -in $RebootExitCodes
    $isSuccess      = ($vendorExitCode -in $SuccessExitCodes) -or $requiresReboot

    if (-not $isSuccess) {
        Write-Log "Uninstallation failed. Vendor exit code: $vendorExitCode" -Level ERROR
        exit $vendorExitCode
    }

    Write-Log "Uninstallation succeeded with exit code $vendorExitCode"

    # Reclaim the staged image now that the product (and its symlinks) are gone.
    if ($RemoveImageOnUninstall -and (Test-Path -LiteralPath $DeploymentImagePath)) {
        Write-Log "Removing staged image at $DeploymentImagePath"
        try {
            Remove-Item -LiteralPath $DeploymentImagePath -Recurse -Force -ErrorAction Stop
            Write-Log "Staged image removed"
        } catch {
            # A leftover image does not make the uninstall a failure.
            Write-Log "Could not fully remove staged image: $($_.Exception.Message)" -Level WARN
        }
    }

    $exitCode = $vendorExitCode
} catch {
    Write-Log "Unhandled failure: $($_.Exception.Message)" -Level ERROR
    Write-Log $_.ScriptStackTrace -Level ERROR
    exit 1
}

exit $exitCode
