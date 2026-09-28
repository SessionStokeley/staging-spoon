<#
.SYNOPSIS
    Removes the Windows integrations the package created, and only those.
.DESCRIPTION
    Ships inside the package beside Uninstall.ps1 and Integrations.ps1. Reads the
    ownership the apply step recorded and removes exactly those resources - the
    PATH entry it added, the shortcut it created, the registry keys it created -
    leaving every pre-existing PATH entry, shortcut and key untouched. A
    VALIDATE integration was never recorded as owned, so a vendor-created
    association is never removed here.

    Always exits 0: nothing left to remove is a successful uninstall, and a
    missing state file means this package created no integrations.
#>

[CmdletBinding()]
param(
    [string]$ApplicationKey = '',
    [string]$StatePath = '',
    [string]$ConfigPath = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$here = $PSScriptRoot
. (Join-Path $here 'Integrations.ps1')

if (-not $ApplicationKey -and -not $StatePath) {
    if (-not $ConfigPath) { $ConfigPath = Join-Path $here 'integrations.json' }
    if (Test-Path -LiteralPath $ConfigPath) {
        $config = Get-Content -LiteralPath $ConfigPath -Raw | ConvertFrom-Json
        if ($config.PSObject.Properties.Name -contains 'ApplicationKey' -and $config.ApplicationKey) { $ApplicationKey = [string]$config.ApplicationKey }
    }
}
if (-not $ApplicationKey) { $ApplicationKey = 'Application' }
if (-not $StatePath) { $StatePath = Get-IntegrationStatePath -ApplicationKey $ApplicationKey }

$state = Get-IntegrationState -Path $StatePath
if ($null -eq $state) {
    Write-Host "No integration ownership recorded for '$ApplicationKey'; nothing to remove."
    exit 0
}

$runningAsSystem = $false
try { $runningAsSystem = [System.Security.Principal.WindowsIdentity]::GetCurrent().IsSystem } catch { }

$results = Remove-OwnedIntegrations -State $state -RunningAsSystem $runningAsSystem
foreach ($result in $results) {
    $status = if ($result.PSObject.Properties.Name -contains 'Skipped' -and $result.Skipped) { 'SKIP' } elseif ($result.Removed) { 'REMOVED' } else { 'ABSENT' }
    Write-Host ("  [{0}] {1} {2}" -f $status, $result.Kind, $result.Resource)
}

# The ownership record is consumed once acted on, so a second uninstall does not
# try to remove what is already gone.
Remove-Item -LiteralPath $StatePath -Force -ErrorAction SilentlyContinue
Write-Host "Integration ownership cleared."
exit 0
