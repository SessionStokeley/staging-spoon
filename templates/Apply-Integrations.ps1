<#
.SYNOPSIS
    Establishes and verifies the package's Windows integrations after install.
.DESCRIPTION
    Ships inside the package beside Install.ps1 and Integrations.ps1. Reads the
    integrations the package declared, applies the ones it manages, verifies the
    ones the vendor installer was expected to create, and records what it now
    owns so uninstall can remove exactly that and nothing else.

    Exit 0 when every integration that was not DISABLED succeeded; non-zero
    otherwise, so a caller (Install.ps1, or the validation harness) can fail the
    deployment rather than ship an application whose PATH entry, shortcut,
    context-menu action or association is missing.
#>

[CmdletBinding()]
param(
    [string]$ConfigPath = '',
    [string]$ApplicationKey = '',
    [string]$StatePath = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$here = $PSScriptRoot
. (Join-Path $here 'Integrations.ps1')

if (-not $ConfigPath) { $ConfigPath = Join-Path $here 'integrations.json' }
if (-not (Test-Path -LiteralPath $ConfigPath)) {
    Write-Host "No integrations to apply ($ConfigPath not found)."
    exit 0
}

$config = Get-Content -LiteralPath $ConfigPath -Raw | ConvertFrom-Json
if (-not $ApplicationKey) {
    $ApplicationKey = if ($config.PSObject.Properties.Name -contains 'ApplicationKey' -and $config.ApplicationKey) { [string]$config.ApplicationKey } else { 'Application' }
}
if (-not $StatePath) { $StatePath = Get-IntegrationStatePath -ApplicationKey $ApplicationKey }

$definitions = ConvertTo-IntegrationConfig -Integrations $(if ($config.PSObject.Properties.Name -contains 'Integrations') { $config.Integrations } else { $config })

$runningAsSystem = $false
try { $runningAsSystem = [System.Security.Principal.WindowsIdentity]::GetCurrent().IsSystem } catch { }

# Reuse any state from a prior run so re-applying does not lose earlier
# ownership, then apply and record.
$state = Get-IntegrationState -Path $StatePath
if ($null -eq $state) { $state = New-IntegrationState -ApplicationKey $ApplicationKey }

$applyResults = Invoke-IntegrationSet -Phase 'Apply' -Definitions $definitions -RunningAsSystem $runningAsSystem -State $state
Save-IntegrationState -State $state -Path $StatePath

$failed = 0
foreach ($result in $applyResults) {
    $status = if ($result.Skipped) { 'SKIP' } elseif ($result.Success) { 'OK' } else { 'FAIL' }
    Write-Host ("  [{0}] {1} {2} ({3}): {4}" -f $status, $result.Kind, $result.Id, $result.Mode, $result.Reason)
    if (-not $result.Success -and -not $result.Skipped) { $failed++ }
}

Write-Host "Integration state recorded at $StatePath"
if ($failed -gt 0) { Write-Host "$failed integration(s) failed."; exit 1 }
exit 0
