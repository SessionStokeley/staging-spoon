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

foreach ($informationModule in @(
    'FieldModel'
    'PathResolver'
    'ResourceResolver'
    'FieldRegistry'
    'EvidenceStore'
    'ProjectState'
    'CommandModel'
    'DiscoveryEngine'
    'ConflictResolver'
    'RequirementEngine'
    'PromptEngine'
    'CaptureIntegration'
    'InformationManager'
    'Show-InformationPrompt'
)) {
    . (Join-Path $PSScriptRoot "$informationModule.ps1")
}
