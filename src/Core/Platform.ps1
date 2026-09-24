<#
.SYNOPSIS
    Helpers that smooth over differences between Windows PowerShell editions.
.DESCRIPTION
    Windows PowerShell 5.1 (the .NET Framework edition that ships in the box)
    and PowerShell 7 (the .NET edition) differ in a few APIs the packager uses.
    This keeps those differences in one place so the rest of the code does not
    branch on the runtime.
#>

Set-StrictMode -Version Latest

function Get-Latin1Encoding {
    <#
    .SYNOPSIS
        A single-byte encoding for scanning binaries for ASCII markers.
    .DESCRIPTION
        [System.Text.Encoding]::Latin1 is .NET 5 and later, so it is missing on
        Windows PowerShell 5.1. Code page 28591 is ISO-8859-1 on both editions
        and maps every byte to one character, which keeps offsets aligned and
        cannot fail on bytes that are not valid UTF-8.
    #>
    [CmdletBinding()]
    param()

    [System.Text.Encoding]::GetEncoding(28591)
}
