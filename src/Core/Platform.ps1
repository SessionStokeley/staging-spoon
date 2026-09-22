<#
.SYNOPSIS
    Host platform detection that works on both PowerShell editions.
.DESCRIPTION
    The automatic variables $IsWindows, $IsLinux and $IsMacOS were introduced in
    PowerShell 6. On Windows PowerShell 5.1 they do not exist at all, and under
    Set-StrictMode reading one throws rather than returning false. Guarding with
    a version check does not help, because the variable reference is evaluated
    before the guard. The variable has to be probed instead of referenced.
#>

Set-StrictMode -Version Latest

function Test-WindowsPlatform {
    <#
    .SYNOPSIS
        True when the current host is Windows.
    #>
    [CmdletBinding()]
    param()

    $variable = Get-Variable -Name 'IsWindows' -ErrorAction SilentlyContinue

    # Windows PowerShell 5.1 and earlier shipped only on Windows, so its absence
    # is itself the answer.
    if ($null -eq $variable) { return $true }

    [bool]$variable.Value
}

function Get-Latin1Encoding {
    <#
    .SYNOPSIS
        A single-byte encoding for scanning binaries for ASCII markers.
    .DESCRIPTION
        [System.Text.Encoding]::Latin1 is .NET 5 and later, so it is missing on
        Windows PowerShell 5.1. Code page 28591 is ISO-8859-1 on both runtimes
        and maps every byte to one character, which keeps offsets aligned and
        cannot fail on bytes that are not valid UTF-8.
    #>
    [CmdletBinding()]
    param()

    [System.Text.Encoding]::GetEncoding(28591)
}
