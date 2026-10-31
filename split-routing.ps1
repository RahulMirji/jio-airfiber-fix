<#
.SYNOPSIS
    Split routing: game traffic over the phone hotspot, OBS stream over Jio AirFiber (Ethernet).

.DESCRIPTION
    Windows uses the default route with the lowest total metric (route metric + interface metric).
    This script gives the phone-hotspot adapter (USB tethering or Wi-Fi) a low interface metric
    (default 5) and the Ethernet adapter a higher one (default 50). All normal traffic, including
    BlueStacks / Free Fire, then goes out through the hotspot. Ethernet stays connected as a backup
    route and for anything bound to its IP.

    AFTER RUNNING: bind OBS to the Ethernet IP so the stream uses AirFiber:
        OBS > Settings > Advanced > Network > Bind to IP  ->  pick the Ethernet IP (e.g. 192.168.31.141)
        Click Apply, then restart OBS.
    Windows picks the outgoing interface from the source address for bound sockets, so OBS
    traffic goes out through Ethernet even though Ethernet is no longer the preferred route.

    Run from an elevated (Administrator) PowerShell. Works in Windows PowerShell 5.1 and PowerShell 7.

.PARAMETER Revert
    Turn automatic metrics back on for the adapters changed earlier (read from the saved state file),
    or for adapters you pick if no state file exists.

.PARAMETER HotspotAlias
    Optional. Adapter name (as shown by Get-NetAdapter) of the phone hotspot. Skips the prompt.

.PARAMETER EthernetAlias
    Optional. Adapter name of the Ethernet connection to the AirFiber router. Skips the prompt.

.PARAMETER HotspotMetric
    Interface metric for the hotspot (default 5). Must be lower than EthernetMetric.

.PARAMETER EthernetMetric
    Interface metric for Ethernet (default 50).

.EXAMPLE
    .\split-routing.ps1
.EXAMPLE
    .\split-routing.ps1 -HotspotAlias "Ethernet 3" -EthernetAlias "Ethernet"
.EXAMPLE
    .\split-routing.ps1 -Revert

.NOTES
    Persistent-route alternative (advanced, usually not needed):
    Instead of changing metrics you can add a persistent route, e.g. send one known IP range
    over a specific gateway:
        route -p add <dest-network> mask <netmask> <gateway> metric 1 if <ifIndex>
    or in PowerShell:
        New-NetRoute -DestinationPrefix "x.x.x.x/24" -InterfaceIndex <ifIndex> -NextHop <gateway> -RouteMetric 1
    This is fragile here: Free Fire and YouTube ingest servers change IPs, and Android often gives
    the USB-tether network a new subnet/gateway each time you connect. The metric method plus
    OBS "Bind to IP" is simpler and survives those changes. Remove such routes with
    "route delete <dest-network>" or Remove-NetRoute.
#>
[CmdletBinding()]
param(
    [switch]$Revert,
    [string]$HotspotAlias,
    [string]$EthernetAlias,
    [ValidateRange(1, 9999)][int]$HotspotMetric = 5,
    [ValidateRange(1, 9999)][int]$EthernetMetric = 50
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$StateDir  = Join-Path $env:ProgramData 'jio-fix'
$StateFile = Join-Path $StateDir 'split-routing-state.json'

function Write-Step([string]$Text) { Write-Host "`n== $Text" -ForegroundColor Cyan }
function Write-Ok([string]$Text)   { Write-Host "[OK]   $Text" -ForegroundColor Green }
function Write-Warn([string]$Text) { Write-Host "[WARN] $Text" -ForegroundColor Yellow }
function Write-Fail([string]$Text) { Write-Host "[FAIL] $Text" -ForegroundColor Red }

# ---------- Safety checks ----------
$isWindowsOs = ($env:OS -eq 'Windows_NT')
if (-not $isWindowsOs) { Write-Fail 'This script only runs on Windows.'; exit 1 }

$principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Fail 'Run this from an Administrator PowerShell (right-click PowerShell > Run as administrator).'
    exit 1
}

if (-not (Get-Command Set-NetIPInterface -ErrorAction SilentlyContinue)) {
    Write-Fail 'The NetTCPIP module (Set-NetIPInterface) is not available on this system.'
    exit 1
}

if ($HotspotMetric -ge $EthernetMetric) {
    Write-Fail "HotspotMetric ($HotspotMetric) must be lower than EthernetMetric ($EthernetMetric)."
    exit 1
}

# ---------- Helpers ----------
function Get-AdapterInfo {
    $list = @()
    foreach ($a in (Get-NetAdapter | Where-Object { $_.Status -eq 'Up' } | Sort-Object ifIndex)) {
        $ipv4 = $null; $gw = $null; $metric = $null; $auto = $null
        $addr = Get-NetIPAddress -InterfaceIndex $a.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue |
                Where-Object { $_.IPAddress -notlike '169.254.*' } | Select-Object -First 1
        if ($addr) { $ipv4 = $addr.IPAddress }
        $route = Get-NetRoute -InterfaceIndex $a.ifIndex -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue |
                 Select-Object -First 1
        if ($route) { $gw = $route.NextHop }
        $ipif = Get-NetIPInterface -InterfaceIndex $a.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue
        if ($ipif) { $metric = $ipif.InterfaceMetric; $auto = [string]$ipif.AutomaticMetric }
        $list += [PSCustomObject]@{
            No          = $list.Count + 1
            Name        = $a.Name
            ifIndex     = $a.ifIndex
            Description = $a.InterfaceDescription
            IPv4        = $ipv4
            Gateway     = $gw
            Metric      = $metric
            AutoMetric  = $auto
        }
    }
    return ,$list
}

function Show-Adapters($List) {
    $List | Format-Table No, Name, ifIndex, IPv4, Gateway, Metric, AutoMetric, Description -AutoSize |
        Out-String -Width 220 | Write-Host
}

function Select-Adapter($List, [string]$Prompt, [int]$ExcludeIndex = -1) {
    while ($true) {
        $answer = Read-Host $Prompt
        if ($answer -match '^[qQ]$') { Write-Host 'Cancelled.'; exit 0 }
        $n = 0
        if ([int]::TryParse($answer, [ref]$n) -and $n -ge 1 -and $n -le $List.Count) {
            $pick = $List[$n - 1]
            if ($pick.ifIndex -eq $ExcludeIndex) { Write-Warn 'You already picked that adapter. Choose a different one.'; continue }
            return $pick
        }
        Write-Warn "Enter a number between 1 and $($List.Count), or q to quit."
    }
}

function Find-ByAlias($List, [string]$Alias) {
    $m = @($List | Where-Object { $_.Name -eq $Alias })
    if ($m.Count -ne 1) { Write-Fail "No connected adapter named '$Alias'. Check the names with Get-NetAdapter."; exit 1 }
    return $m[0]
}

function Set-Metric([int]$IfIndex, [int]$Metric) {
    foreach ($family in 'IPv4', 'IPv6') {
        $ipif = Get-NetIPInterface -InterfaceIndex $IfIndex -AddressFamily $family -ErrorAction SilentlyContinue
        if ($ipif) {
            # Setting InterfaceMetric turns AutomaticMetric off for that interface/family.
            Set-NetIPInterface -InterfaceIndex $IfIndex -AddressFamily $family -InterfaceMetric $Metric
        }
    }
}

function Enable-AutoMetric([int]$IfIndex) {
    $ifs = Get-NetIPInterface -InterfaceIndex $IfIndex -ErrorAction SilentlyContinue
    if (-not $ifs) { Write-Warn "Interface index $IfIndex not found (adapter unplugged?). Skipping."; return }
    $ifs | Set-NetIPInterface -AutomaticMetric Enabled
    Write-Ok "Automatic metric enabled on ifIndex $IfIndex ($(@($ifs)[0].InterfaceAlias))."
}

function Show-RoutingResult {
    Write-Step 'Default routes (lower total = preferred)'
    $rows = foreach ($r in (Get-NetRoute -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue)) {
        $ipif = Get-NetIPInterface -InterfaceIndex $r.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue
        $ifm = 0; if ($ipif) { $ifm = [int]$ipif.InterfaceMetric }
        [PSCustomObject]@{
            Interface       = $r.InterfaceAlias
            ifIndex         = $r.ifIndex
            NextHop         = $r.NextHop
            RouteMetric     = $r.RouteMetric
            InterfaceMetric = $ifm
            Total           = [int]$r.RouteMetric + $ifm
        }
    }
    $rows | Sort-Object Total | Format-Table -AutoSize | Out-String | Write-Host

    try {
        $best = Find-NetRoute -RemoteIPAddress '1.1.1.1' -ErrorAction Stop | Select-Object -First 1
        Write-Host ("Internet traffic (test: 1.1.1.1) now leaves via: {0}  (source IP {1})" -f $best.InterfaceAlias, $best.IPAddress) -ForegroundColor Green
    } catch {
        Write-Warn 'Find-NetRoute could not resolve a route to 1.1.1.1.'
    }
}

# ---------- Revert ----------
if ($Revert) {
    Write-Step 'Reverting split routing (automatic metrics)'
    $indexes = @()
    if (Test-Path $StateFile) {
        $state = Get-Content $StateFile -Raw | ConvertFrom-Json
        foreach ($entry in @($state.Adapters)) { $indexes += [int]$entry.ifIndex }
        Write-Host "Using saved state from $StateFile"
    } else {
        Write-Warn 'No saved state found. Pick the adapters to reset.'
        $list = Get-AdapterInfo
        if ($list.Count -eq 0) { Write-Fail 'No connected adapters found.'; exit 1 }
        Show-Adapters $list
        $first = Select-Adapter $list 'Adapter number to reset (q to quit)'
        $indexes += $first.ifIndex
        $more = Read-Host 'Reset another adapter too? Enter its number, or press Enter to skip'
        $n = 0
        if ([int]::TryParse($more, [ref]$n) -and $n -ge 1 -and $n -le $list.Count) { $indexes += $list[$n - 1].ifIndex }
    }
    foreach ($i in ($indexes | Select-Object -Unique)) { Enable-AutoMetric $i }
    if (Test-Path $StateFile) { Remove-Item $StateFile -Force }
    Show-RoutingResult
    Write-Host "`nDone. You can set OBS > Settings > Advanced > Network > Bind to IP back to 'Default'." -ForegroundColor Cyan
    exit 0
}

# ---------- Apply ----------
Write-Step 'Connected network adapters'
$list = Get-AdapterInfo
if ($list.Count -lt 2) {
    Show-Adapters $list
    Write-Fail 'Need at least two connected adapters (Ethernet + phone hotspot). Connect the phone by USB tethering or Wi-Fi hotspot and try again.'
    exit 1
}
Show-Adapters $list
Write-Host 'Hints: USB tethering usually shows as "Remote NDIS based Internet Sharing Device". Wi-Fi hotspot shows as your Wi-Fi card.' -ForegroundColor DarkGray

if ($HotspotAlias) { $hot = Find-ByAlias $list $HotspotAlias } else { $hot = Select-Adapter $list 'Number of the PHONE HOTSPOT adapter (q to quit)' }
if ($EthernetAlias) { $eth = Find-ByAlias $list $EthernetAlias } else { $eth = Select-Adapter $list 'Number of the ETHERNET (AirFiber) adapter (q to quit)' $hot.ifIndex }

if ($hot.ifIndex -eq $eth.ifIndex) { Write-Fail 'Hotspot and Ethernet must be different adapters.'; exit 1 }

# Sanity checks on the selection
$problems = 0
if (-not $hot.IPv4)    { Write-Fail "Hotspot adapter '$($hot.Name)' has no IPv4 address."; $problems++ }
if (-not $hot.Gateway) { Write-Fail "Hotspot adapter '$($hot.Name)' has no default gateway, so it cannot reach the internet."; $problems++ }
if (-not $eth.IPv4)    { Write-Fail "Ethernet adapter '$($eth.Name)' has no IPv4 address."; $problems++ }
if (-not $eth.Gateway) { Write-Warn "Ethernet adapter '$($eth.Name)' has no default gateway. OBS bound to it will not reach the internet." }
if ($problems -gt 0) { exit 1 }

if ($hot.IPv4 -like '192.168.31.*') {
    Write-Warn "The 'hotspot' adapter has a 192.168.31.x address. That looks like the AirFiber network, not the phone."
    if ((Read-Host 'Continue anyway? (y/N)') -notmatch '^[yY]') { exit 0 }
}
if ($eth.IPv4 -notlike '192.168.31.*') {
    Write-Warn "The Ethernet adapter's IP is $($eth.IPv4), not 192.168.31.x. Make sure this is the AirFiber connection."
}

Write-Step 'Testing hotspot internet before switching'
$pingOut = & ping.exe -n 2 -w 2000 -S $hot.IPv4 1.1.1.1
if ($LASTEXITCODE -eq 0 -and ($pingOut -match 'TTL=')) {
    Write-Ok "Hotspot reaches 1.1.1.1 from $($hot.IPv4)."
} else {
    Write-Warn 'Hotspot did not answer a ping to 1.1.1.1. Check mobile data on the phone.'
    if ((Read-Host 'Continue anyway? (y/N)') -notmatch '^[yY]') { exit 0 }
}

Write-Host ''
Write-Host "Planned change:" -ForegroundColor Cyan
Write-Host ("  Hotspot : {0} ({1})  metric {2} -> {3}" -f $hot.Name, $hot.IPv4, $hot.Metric, $HotspotMetric)
Write-Host ("  Ethernet: {0} ({1})  metric {2} -> {3}" -f $eth.Name, $eth.IPv4, $eth.Metric, $EthernetMetric)
if ((Read-Host 'Apply? (y/N)') -notmatch '^[yY]') { Write-Host 'Nothing changed.'; exit 0 }

# Save state so -Revert knows which adapters to reset
if (-not (Test-Path $StateDir)) { New-Item -ItemType Directory -Path $StateDir -Force | Out-Null }
$state = [PSCustomObject]@{
    Saved    = (Get-Date).ToString('s')
    Adapters = @(
        [PSCustomObject]@{ Role = 'Hotspot';  Name = $hot.Name; ifIndex = $hot.ifIndex; PreviousMetric = $hot.Metric; PreviousAuto = $hot.AutoMetric },
        [PSCustomObject]@{ Role = 'Ethernet'; Name = $eth.Name; ifIndex = $eth.ifIndex; PreviousMetric = $eth.Metric; PreviousAuto = $eth.AutoMetric }
    )
}
$state | ConvertTo-Json -Depth 4 | Set-Content -Path $StateFile -Encoding UTF8

try {
    Set-Metric $hot.ifIndex $HotspotMetric
    Write-Ok "Hotspot '$($hot.Name)' metric set to $HotspotMetric (IPv4 + IPv6 where present)."
    Set-Metric $eth.ifIndex $EthernetMetric
    Write-Ok "Ethernet '$($eth.Name)' metric set to $EthernetMetric (IPv4 + IPv6 where present)."
} catch {
    Write-Fail "Failed to set metrics: $($_.Exception.Message)"
    Write-Warn 'Rolling back to automatic metrics.'
    Enable-AutoMetric $hot.ifIndex
    Enable-AutoMetric $eth.ifIndex
    exit 1
}

Show-RoutingResult

Write-Step 'Next: bind OBS to Ethernet (AirFiber)'
Write-Host "  1. OBS > Settings > Advanced > Network > Bind to IP"
Write-Host ("  2. Choose: {0}   (this is '{1}')" -f $eth.IPv4, $eth.Name) -ForegroundColor Green
Write-Host "  3. Apply, then restart OBS."
Write-Host "  4. Go live and watch Docks > Stats: dropped frames should stay near 0%."
Write-Host ''
Write-Host 'Notes:' -ForegroundColor Cyan
Write-Host '  - Close and reopen BlueStacks so Free Fire opens new connections over the hotspot.'
Write-Host '  - If the phone is unplugged, Windows falls back to Ethernet automatically.'
Write-Host '  - If you reconnect the phone on another USB port it can appear as a new adapter: run this script again.'
Write-Host '  - Reserve 192.168.31.141 for this PC in the AirFiber router so the OBS binding stays valid.'
Write-Host '  - Undo everything with:  .\split-routing.ps1 -Revert'
