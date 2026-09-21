<#
.SYNOPSIS
    Generates IntuneValidationReport.html from a validation result.
#>

Set-StrictMode -Version Latest

function ConvertTo-HtmlText {
    param([AllowNull()][AllowEmptyString()]$Value)

    if ($null -eq $Value) { return '' }
    [System.Net.WebUtility]::HtmlEncode([string]$Value)
}

function New-ValidationReport {
    <#
    .SYNOPSIS
        Renders the validation result as a self-contained HTML report.
    .PARAMETER Result
        The object returned by Test-IntunePackage.ps1.
    .PARAMETER CommandComparison
        Optional results from Compare-IntuneCommand.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][PSCustomObject]$Result,
        [Parameter(Mandatory)][string]$Path,
        [PSCustomObject[]]$CommandComparison = @(),
        [PSCustomObject]$PreBuildResult = $null
    )

    $isReady = $Result.IsProductionReady
    $statusText = if ($isReady) { 'PRODUCTION READY' } else { 'FAILED VALIDATION' }
    $statusClass = if ($isReady) { 'ready' } else { 'failed' }

    $stageRows = foreach ($stage in $Result.Stages) {
        $class = switch ($stage.Result) {
            'PASS' { 'pass' }
            'FAIL' { 'fail' }
            default { 'skip' }
        }
        $duration = if ($stage.Duration -and $stage.Duration.TotalSeconds -gt 0) {
            '{0:n1}s' -f $stage.Duration.TotalSeconds
        } else { '-' }

        @"
<tr>
  <td>$(ConvertTo-HtmlText $stage.Name)</td>
  <td><span class="badge $class">$(ConvertTo-HtmlText $stage.Result)</span></td>
  <td class="mono">$(if ($null -ne $stage.ExitCode) { ConvertTo-HtmlText $stage.ExitCode } else { '-' })</td>
  <td>$duration</td>
  <td>$(ConvertTo-HtmlText $stage.Detail)</td>
</tr>
"@
    }

    $commandBlocks = foreach ($stage in ($Result.Stages | Where-Object { $_.Command })) {
        @"
<div class="command">
  <h4>$(ConvertTo-HtmlText $stage.Name)</h4>
  <pre>$(ConvertTo-HtmlText $stage.Command)</pre>
  $(if ($stage.Output) { "<details><summary>Output</summary><pre>$(ConvertTo-HtmlText $stage.Output)</pre></details>" })
</div>
"@
    }

    $comparisonRows = foreach ($comparison in $CommandComparison) {
        $class = if ($comparison.Matches) { 'pass' } else { 'fail' }
        @"
<tr>
  <td>$(ConvertTo-HtmlText $comparison.CommandType)</td>
  <td><span class="badge $class">$(if ($comparison.Matches) { 'MATCH' } else { 'MISMATCH' })</span></td>
  <td class="mono">$(ConvertTo-HtmlText $comparison.TestedCommand)</td>
  <td class="mono">$(ConvertTo-HtmlText $comparison.IntuneCommand)</td>
</tr>
"@
    }

    $deltaSection = if ($Result.InstallDelta) {
        $delta = $Result.InstallDelta
        $items = @(
            @{ Label = 'Applications'; Added = $delta.Applications.Added; Removed = $delta.Applications.Removed }
            @{ Label = 'Files';        Added = $delta.Files.Added;        Removed = $delta.Files.Removed }
            @{ Label = 'Registry';     Added = $delta.Registry.Added;     Removed = $delta.Registry.Removed }
            @{ Label = 'Services';     Added = $delta.Services.Added;     Removed = $delta.Services.Removed }
            @{ Label = 'Shortcuts';    Added = $delta.Shortcuts.Added;    Removed = $delta.Shortcuts.Removed }
            @{ Label = 'PATH';         Added = $delta.Path.Added;         Removed = $delta.Path.Removed }
        )

        $rows = foreach ($item in $items) {
            "<tr><td>$(ConvertTo-HtmlText $item.Label)</td><td class='mono'>+$($item.Added.Count)</td><td class='mono'>-$($item.Removed.Count)</td></tr>"
        }

        @"
<h2>Observed State Change</h2>
<table>
  <thead><tr><th>Category</th><th>Added</th><th>Removed</th></tr></thead>
  <tbody>$($rows -join "`n")</tbody>
</table>
"@
    } else { '' }

    $classificationSection = if ($Result.Classification) {
        @"
<h2>Failure Classification</h2>
<div class="classification">
  <pre>$(ConvertTo-HtmlText $Result.Classification.Classification)</pre>
  <p><strong>Reason:</strong> $(ConvertTo-HtmlText $Result.Classification.Reason)</p>
  <p><strong>Confidence:</strong> $(ConvertTo-HtmlText $Result.Classification.Confidence)</p>
</div>
"@
    } else { '' }

    $preBuildSection = if ($PreBuildResult) {
        $rows = foreach ($check in $PreBuildResult.Checks) {
            $class = if ($check.Passed) { 'pass' } elseif ($check.Severity -eq 'Warning') { 'skip' } else { 'fail' }
            $label = if ($check.Passed) { 'PASS' } elseif ($check.Severity -eq 'Warning') { 'WARN' } else { 'FAIL' }
            "<tr><td>$(ConvertTo-HtmlText $check.Name)</td><td><span class='badge $class'>$label</span></td><td>$(ConvertTo-HtmlText $check.Detail)</td></tr>"
        }
        @"
<h2>Pre-Build Validation</h2>
<table>
  <thead><tr><th>Check</th><th>Result</th><th>Detail</th></tr></thead>
  <tbody>$($rows -join "`n")</tbody>
</table>
"@
    } else { '' }

    $html = @"
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Intune Validation Report</title>
<style>
  :root {
    --bg: #ffffff; --fg: #1a1a1a; --muted: #666; --border: #e0e0e0;
    --pass: #0a7a3d; --fail: #c62828; --skip: #b26a00; --surface: #f7f7f8;
  }
  @media (prefers-color-scheme: dark) {
    :root:not([data-theme="light"]) {
      --bg: #16181c; --fg: #e8e8e8; --muted: #9aa0a6; --border: #2c3036;
      --pass: #4caf72; --fail: #ef5350; --skip: #ffb74d; --surface: #1e2126;
    }
  }
  * { box-sizing: border-box; }
  body {
    margin: 0; padding: 32px 16px; background: var(--bg); color: var(--fg);
    font: 15px/1.6 -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif;
  }
  .wrap { max-width: 1000px; margin: 0 auto; }
  h1 { font-size: 26px; margin: 0 0 4px; }
  h2 { font-size: 19px; margin: 36px 0 12px; padding-bottom: 6px; border-bottom: 1px solid var(--border); }
  h4 { font-size: 14px; margin: 16px 0 6px; color: var(--muted); }
  .sub { color: var(--muted); margin: 0 0 24px; }
  .status { padding: 18px 22px; border-radius: 8px; font-size: 20px; font-weight: 700; letter-spacing: .04em; margin-bottom: 28px; }
  .status.ready { background: rgba(10,122,61,.12); color: var(--pass); border: 1px solid var(--pass); }
  .status.failed { background: rgba(198,40,40,.12); color: var(--fail); border: 1px solid var(--fail); }
  table { width: 100%; border-collapse: collapse; margin-bottom: 16px; font-size: 14px; }
  th, td { text-align: left; padding: 9px 10px; border-bottom: 1px solid var(--border); vertical-align: top; }
  th { color: var(--muted); font-weight: 600; font-size: 12px; text-transform: uppercase; letter-spacing: .05em; }
  .badge { display: inline-block; padding: 2px 9px; border-radius: 11px; font-size: 11px; font-weight: 700; letter-spacing: .04em; }
  .badge.pass { background: rgba(10,122,61,.15); color: var(--pass); }
  .badge.fail { background: rgba(198,40,40,.15); color: var(--fail); }
  .badge.skip { background: rgba(178,106,0,.15); color: var(--skip); }
  .mono, pre { font-family: ui-monospace, SFMono-Regular, Menlo, Consolas, monospace; }
  pre { background: var(--surface); border: 1px solid var(--border); border-radius: 6px; padding: 11px 13px; overflow-x: auto; font-size: 13px; margin: 0; }
  .command { margin-bottom: 14px; }
  details { margin-top: 7px; }
  summary { cursor: pointer; color: var(--muted); font-size: 13px; }
  .classification pre { color: var(--fail); font-weight: 700; font-size: 15px; }
  .grid { display: grid; grid-template-columns: repeat(auto-fit, minmax(210px, 1fr)); gap: 12px; }
  .card { background: var(--surface); border: 1px solid var(--border); border-radius: 6px; padding: 12px 14px; }
  .card .label { color: var(--muted); font-size: 11px; text-transform: uppercase; letter-spacing: .05em; }
  .card .value { font-size: 15px; font-weight: 600; margin-top: 3px; word-break: break-word; }
</style>
</head>
<body>
<div class="wrap">
  <h1>Intune Validation Report</h1>
  <p class="sub">$(ConvertTo-HtmlText $Result.ApplicationName) $(ConvertTo-HtmlText $Result.ApplicationVersion) &middot; generated $(ConvertTo-HtmlText $Result.TestedAt)</p>

  <div class="status $statusClass">$statusText</div>

  <h2>Package</h2>
  <div class="grid">
    <div class="card"><div class="label">Application</div><div class="value">$(ConvertTo-HtmlText $Result.ApplicationName)</div></div>
    <div class="card"><div class="label">Version</div><div class="value">$(ConvertTo-HtmlText $Result.ApplicationVersion)</div></div>
    <div class="card"><div class="label">Package version</div><div class="value">$(ConvertTo-HtmlText $Result.PackageVersion)</div></div>
    <div class="card"><div class="label">SHA256</div><div class="value mono" style="font-size:11px">$(ConvertTo-HtmlText $Result.PackageHash)</div></div>
  </div>

  <h2>Environment</h2>
  <div class="grid">
    <div class="card"><div class="label">Computer</div><div class="value">$(ConvertTo-HtmlText $Result.Environment.ComputerName)</div></div>
    <div class="card"><div class="label">OS</div><div class="value">$(ConvertTo-HtmlText $Result.Environment.OSVersion)</div></div>
    <div class="card"><div class="label">Architecture</div><div class="value">$(ConvertTo-HtmlText $Result.Environment.Architecture)</div></div>
    <div class="card"><div class="label">PowerShell</div><div class="value">$(ConvertTo-HtmlText $Result.Environment.PowerShellVersion)</div></div>
    <div class="card"><div class="label">Execution context</div><div class="value">$(ConvertTo-HtmlText $Result.ExecutionContext)</div></div>
    <div class="card"><div class="label">64-bit process</div><div class="value">$(ConvertTo-HtmlText $Result.Environment.Is64BitProcess)</div></div>
  </div>

  $preBuildSection

  <h2>Validation Stages</h2>
  <table>
    <thead><tr><th>Stage</th><th>Result</th><th>Exit code</th><th>Duration</th><th>Detail</th></tr></thead>
    <tbody>$($stageRows -join "`n")</tbody>
  </table>

  <h2>Exact Commands Executed</h2>
  $($commandBlocks -join "`n")

  $(if ($comparisonRows) {
@"
<h2>Intune Command Sanity Check</h2>
<table>
  <thead><tr><th>Command</th><th>Result</th><th>Tested</th><th>Intune</th></tr></thead>
  <tbody>$($comparisonRows -join "`n")</tbody>
</table>
"@
  })

  $deltaSection
  $classificationSection
</div>
</body>
</html>
"@

    $directory = Split-Path -Path $Path -Parent
    if ($directory -and -not (Test-Path -LiteralPath $directory)) {
        New-Item -Path $directory -ItemType Directory -Force | Out-Null
    }

    $html | Set-Content -LiteralPath $Path -Encoding UTF8
    $Path
}
