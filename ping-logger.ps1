<#
.SYNOPSIS
    Pings the AirFiber router, the first Jio hop and 1.1.1.1 at the same time, logs to CSV,
    and prints min/avg/p95/max/loss when you press Ctrl+C or after -Minutes.

.DESCRIPTION
    Use it to collect evidence for Jio support and to compare times of day.
    Find the first Jio hop with:   tracert -d -h 6 1.1.1.1   (hop 2, the first after 192.168.31.1)

    Works in Windows PowerShell 5.1 and PowerShell 7. Does not need Administrator rights.

.PARAMETER JioHop
    IP of the first Jio hop (from tracert). If omitted you are asked for it. Enter nothing to skip it.

.PARAMETER Gateway
    AirFiber router IP. Default 192.168.31.1.

.PARAMETER Internet
    Internet target. Default 1.1.1.1.

.PARAMETER Minutes
    Stop automatically after this many minutes. 0 (default) = run until Ctrl+C.

.PARAMETER IntervalMs
    Time between ping rounds in ms. Default 1000.

.PARAMETER TimeoutMs
    Ping timeout in ms (a timeout counts as loss). Default 2000.

.PARAMETER OutDir
    Folder for the CSV and summary files. Default: a "logs" folder next to this script.

.EXAMPLE
    .\ping-logger.ps1 -JioHop 10.71.0.1 -Minutes 10
.EXAMPLE
    .\ping-logger.ps1            # asks for the Jio hop, runs until Ctrl+C
#>
[CmdletBinding()]
param(
    [string]$JioHop,
    [string]$Gateway = '192.168.31.1',
    [string]$Internet = '1.1.1.1',
    [ValidateRange(0, 1440)][double]$Minutes = 0,
    [ValidateRange(200, 60000)][int]$IntervalMs = 1000,
    [ValidateRange(100, 10000)][int]$TimeoutMs = 2000,
    [string]$OutDir
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

function Test-IPv4([string]$Value) {
    $ip = $null
    return ([System.Net.IPAddress]::TryParse($Value, [ref]$ip) -and $ip.AddressFamily -eq [System.Net.Sockets.AddressFamily]::InterNetwork)
}

if (-not $PSBoundParameters.ContainsKey('JioHop')) {
    $JioHop = Read-Host 'First Jio hop IP from "tracert -d -h 6 1.1.1.1" (press Enter to skip)'
}
$JioHop = ("" + $JioHop).Trim()

$targets = New-Object System.Collections.Generic.List[object]
$targets.Add([PSCustomObject]@{ Label = 'AirFiber-Router'; Address = $Gateway })
if ($JioHop) { $targets.Add([PSCustomObject]@{ Label = 'Jio-FirstHop'; Address = $JioHop }) }
$targets.Add([PSCustomObject]@{ Label = 'Internet'; Address = $Internet })

foreach ($t in $targets) {
    if (-not (Test-IPv4 $t.Address)) { Write-Host "[FAIL] '$($t.Address)' is not a valid IPv4 address ($($t.Label))." -ForegroundColor Red; exit 1 }
}

if (-not $OutDir) {
    $base = $PSScriptRoot
    if (-not $base) { $base = (Get-Location).Path }
    $OutDir = Join-Path $base 'logs'
}
if (-not (Test-Path $OutDir)) { New-Item -ItemType Directory -Path $OutDir -Force | Out-Null }

$stamp       = Get-Date -Format 'yyyy-MM-dd_HH-mm-ss'
$csvPath     = Join-Path $OutDir "ping_$stamp.csv"
$summaryPath = Join-Path $OutDir "ping_${stamp}_summary.txt"

# Per-target results kept in memory for the summary
$results = @{}
foreach ($t in $targets) { $results[$t.Label] = New-Object System.Collections.Generic.List[double]; }
$sent = @{}; $lost = @{}
foreach ($t in $targets) { $sent[$t.Label] = 0; $lost[$t.Label] = 0 }

$writer = New-Object System.IO.StreamWriter($csvPath, $false, (New-Object System.Text.UTF8Encoding($false)))
$writer.AutoFlush = $true
$writer.WriteLine('Timestamp,Label,Target,Status,RTT_ms')

function Get-Percentile([double[]]$Sorted, [double]$P) {
    if ($Sorted.Length -eq 0) { return $null }
    $idx = [int][Math]::Ceiling($P / 100.0 * $Sorted.Length) - 1
    if ($idx -lt 0) { $idx = 0 }
    if ($idx -ge $Sorted.Length) { $idx = $Sorted.Length - 1 }
    return $Sorted[$idx]
}

function Write-Summary {
    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add("Ping summary  $startTime  ->  $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')")
    $lines.Add("Host: $env:COMPUTERNAME   Interval: $IntervalMs ms   Timeout: $TimeoutMs ms")
    $lines.Add("CSV: $csvPath")
    $lines.Add('')
    $lines.Add(('{0,-16} {1,-16} {2,6} {3,7} {4,8} {5,8} {6,8} {7,8} {8,8}' -f 'Label', 'Target', 'Sent', 'Loss%', 'Min', 'Avg', 'P95', 'Max', '>100ms'))
    foreach ($t in $targets) {
        $label = $t.Label
        $s = [int]$sent[$label]; $l = [int]$lost[$label]
        $vals = [double[]]($results[$label].ToArray())
        [Array]::Sort($vals)
        $lossPct = 0.0; if ($s -gt 0) { $lossPct = 100.0 * $l / $s }
        if ($vals.Length -gt 0) {
            $avg = ($vals | Measure-Object -Average).Average
            $over = @($vals | Where-Object { $_ -gt 100 }).Count
            $lines.Add(('{0,-16} {1,-16} {2,6} {3,7:N1} {4,8:N0} {5,8:N1} {6,8:N0} {7,8:N0} {8,8}' -f `
                $label, $t.Address, $s, $lossPct, $vals[0], $avg, (Get-Percentile $vals 95), $vals[$vals.Length - 1], $over))
        } else {
            $lines.Add(('{0,-16} {1,-16} {2,6} {3,7:N1} {4,8} {5,8} {6,8} {7,8} {8,8}' -f $label, $t.Address, $s, $lossPct, '-', '-', '-', '-', '-'))
        }
    }
    $lines.Add('')
    $lines.Add('Reading it: router low + Jio hop/Internet high = delay is in the AirFiber 5G uplink / Jio network.')
    $lines.Add('            router high too = check the cable, LAN port or NIC first.')
    $text = $lines -join [Environment]::NewLine
    Write-Host ''
    Write-Host $text -ForegroundColor Cyan
    Set-Content -Path $summaryPath -Value $text -Encoding UTF8
    Write-Host "`nSummary saved: $summaryPath" -ForegroundColor Green
}

$startTime = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
$deadline = $null
if ($Minutes -gt 0) { $deadline = (Get-Date).AddMinutes($Minutes) }

Write-Host "Logging to $csvPath" -ForegroundColor Green
Write-Host ("Targets: " + (($targets | ForEach-Object { "$($_.Label)=$($_.Address)" }) -join '  '))
if ($deadline) { Write-Host "Stops at $($deadline.ToString('HH:mm:ss')) or on Ctrl+C." } else { Write-Host 'Press Ctrl+C to stop and see the summary.' }
Write-Host ''
Write-Host ('{0,-8}  ' -f 'Time') -NoNewline
foreach ($t in $targets) { Write-Host ('{0,-18}' -f $t.Label) -NoNewline }
Write-Host ''

try {
    while ($true) {
        if ($deadline -and (Get-Date) -ge $deadline) { break }
        $roundStart = Get-Date
        $ts = $roundStart.ToString('yyyy-MM-dd HH:mm:ss.fff')

        # Fire all pings at once
        $pingers = @(); $tasks = @()
        foreach ($t in $targets) {
            $p = New-Object System.Net.NetworkInformation.Ping
            $pingers += $p
            $tasks += $p.SendPingAsync($t.Address, $TimeoutMs)
        }
        try { [void][System.Threading.Tasks.Task]::WaitAll([System.Threading.Tasks.Task[]]$tasks, ($TimeoutMs + 1000)) } catch { }

        Write-Host ('{0,-8}  ' -f $roundStart.ToString('HH:mm:ss')) -NoNewline
        for ($i = 0; $i -lt $targets.Count; $i++) {
            $t = $targets[$i]; $task = $tasks[$i]
            $status = 'Error'; $rtt = ''; $ok = $false
            if ($task.IsCompleted -and -not $task.IsFaulted -and -not $task.IsCanceled) {
                $reply = $task.Result
                $status = [string]$reply.Status
                if ($reply.Status -eq [System.Net.NetworkInformation.IPStatus]::Success) { $rtt = [double]$reply.RoundtripTime; $ok = $true }
            } elseif (-not $task.IsCompleted) {
                $status = 'TimedOut'
            }
            $sent[$t.Label]++
            if ($ok) {
                $results[$t.Label].Add($rtt)
                $color = 'Green'; if ($rtt -gt 100) { $color = 'Yellow' }; if ($rtt -gt 300) { $color = 'Red' }
                Write-Host ('{0,-18}' -f ("$rtt ms")) -NoNewline -ForegroundColor $color
            } else {
                $lost[$t.Label]++
                Write-Host ('{0,-18}' -f $status) -NoNewline -ForegroundColor Red
            }
            $writer.WriteLine(('{0},{1},{2},{3},{4}' -f $ts, $t.Label, $t.Address, $status, $rtt))
        }
        Write-Host ''
        foreach ($p in $pingers) { $p.Dispose() }

        $elapsed = ((Get-Date) - $roundStart).TotalMilliseconds
        $wait = [int]($IntervalMs - $elapsed)
        if ($wait -gt 0) { Start-Sleep -Milliseconds $wait }
    }
}
finally {
    # Runs on normal exit and on Ctrl+C
    if ($writer) { $writer.Dispose() }
    Write-Summary
}
