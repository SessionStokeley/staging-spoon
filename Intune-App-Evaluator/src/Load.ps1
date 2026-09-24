<#
.SYNOPSIS
    Loads the evaluator modules in dependency order.
#>

Set-StrictMode -Version Latest

$here = $PSScriptRoot

# A local platform probe so the tool is self-contained; staging-spoon is not a
# dependency, only the consumer of the exported package.json.
if (-not (Get-Command -Name 'Test-WindowsPlatform' -ErrorAction SilentlyContinue)) {
    function Test-WindowsPlatform {
        $variable = Get-Variable -Name 'IsWindows' -ErrorAction SilentlyContinue
        if ($null -eq $variable) { return $true }
        [bool]$variable.Value
    }
}

. (Join-Path $here 'EvidenceModel.ps1')
. (Join-Path $here 'SystemInspector.ps1')
. (Join-Path $here 'Capture.ps1')
. (Join-Path $here 'Evaluator.ps1')
. (Join-Path $here 'PackageExport.ps1')
