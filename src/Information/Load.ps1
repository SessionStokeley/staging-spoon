<#
.SYNOPSIS
    Loads the information intelligence layer.
.DESCRIPTION
    Dot-source this file to bring the whole layer into the current scope:

        . .\src\Information\Load.ps1

    It is a script rather than a function on purpose. Dot-sourcing inside a
    function would scope every definition to that function and leave the caller
    with nothing.
#>

Set-StrictMode -Version Latest

# Platform probing lives in Core because the build orchestrator needs it too.
# Loading it twice is harmless; leaving it out breaks discovery on Windows
# PowerShell 5.1, where $IsWindows does not exist.
. (Join-Path (Split-Path $PSScriptRoot -Parent) 'Core/Platform.ps1')

foreach ($informationModule in @(
    'FieldModel'
    'PathResolver'
    'ResourceResolver'
    'FieldRegistry'
    'EvidenceStore'
    'ProjectState'
    'CommandModel'
    'DiscoveryEngine'
    'InstallerEvaluator'
    'ConflictResolver'
    'RequirementEngine'
    'PromptEngine'
    'CaptureIntegration'
    'InformationManager'
    'Show-InformationPrompt'
)) {
    . (Join-Path $PSScriptRoot "$informationModule.ps1")
}
