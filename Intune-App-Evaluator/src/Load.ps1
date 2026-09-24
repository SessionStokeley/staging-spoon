<#
.SYNOPSIS
    Loads the evaluator modules in dependency order.
#>

Set-StrictMode -Version Latest

$here = $PSScriptRoot

# Self-contained: staging-spoon is not a dependency, only the consumer of the
# exported package.json.

. (Join-Path $here 'EvidenceModel.ps1')
. (Join-Path $here 'SystemInspector.ps1')
. (Join-Path $here 'Capture.ps1')
. (Join-Path $here 'Evaluator.ps1')
. (Join-Path $here 'PackageExport.ps1')
