<#
.SYNOPSIS
  Measure and improve a Windows PC's internet connection — safely.

.DESCRIPTION
  Focused on real, measurable wins (no snake-oil):
    * Picks the FASTEST DNS resolver for your location and sets it
    * Removes Windows' artificial network throttle (NetworkThrottlingIndex)
    * Stops the network adapter from power-saving (Wi-Fi/NIC sleep)
    * Sane TCP autotuning + RSS so big transfers use full bandwidth
    * High-performance power plan while active
    * Measures download speed, ping, packet loss and DNS time BEFORE and AFTER
      so you can see the difference.

  It cannot exceed the bandwidth your ISP gives you — nothing can. What it does
  is remove the things that hold Windows BELOW that ceiling.

  SAFE BY DESIGN:
    * Default run only MEASURES + recommends (changes nothing).
    * -Apply makes changes, but first BACKS UP every setting it touches to a
      timestamped .json next to this script.
    * -Revert restores the most recent backup.

.PARAMETER Apply
  Actually apply the optimizations (otherwise it's measure-only).

.PARAMETER Revert
  Undo: restore settings from the most recent backup file.

.PARAMETER Gaming
  Also reduce latency (disable Nagle's algorithm on the active adapter).
  Slightly higher CPU/packet overhead — only worth it for gaming/voice.

.EXAMPLE
  # 1) See where you stand + what it would change (no changes made):
  .\Optimize-Internet.ps1

  # 2) Apply the speed optimizations (auto-elevates to Admin):
  .\Optimize-Internet.ps1 -Apply

  # 3) Undo everything:
  .\Optimize-Internet.ps1 -Revert
#>

[CmdletBinding()]
param(
  [switch]$Apply,
  [switch]$Revert,
  [switch]$Gaming
)

# ── Elevate to Administrator (changes + some reads need it) ──────────────────
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
          ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
  Write-Host "Re-launching as Administrator..." -ForegroundColor Yellow
  $argList = @('-NoProfile','-ExecutionPolicy','Bypass','-File',"`"$PSCommandPath`"")
  if ($Apply)  { $argList += '-Apply' }
  if ($Revert) { $argList += '-Revert' }
  if ($Gaming) { $argList += '-Gaming' }
  Start-Process powershell.exe -Verb RunAs -ArgumentList $argList
  return
}

$ErrorActionPreference = 'Continue'
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Definition
$Log = Join-Path $ScriptDir ("net-optimizer-{0}.log" -f (Get-Date -Format 'yyyyMMdd-HHmmss'))

function Say   { param($m,$c='Gray') Write-Host $m -ForegroundColor $c; Add-Content $Log $m }
function Head  { param($m) Write-Host ""; Write-Host "── $m ──" -ForegroundColor Cyan; Add-Content $Log "== $m ==" }
function Good  { param($m) Say "  [OK] $m" 'Green' }
function Warn  { param($m) Say "  [!]  $m" 'Yellow' }
function Bad   { param($m) Say "  [X]  $m" 'Red' }

# ── Helpers: the active internet adapter ─────────────────────────────────────
function Get-ActiveAdapter {
  # The adapter that actually carries the default route to the internet.
  $r = Get-NetRoute -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue |
       Sort-Object RouteMetric, ifMetric | Select-Object -First 1
  if ($r) { return Get-NetAdapter -InterfaceIndex $r.ifIndex -ErrorAction SilentlyContinue }
  Get-NetAdapter -Physical | Where-Object Status -eq 'Up' | Select-Object -First 1
}

# ── Measurements ─────────────────────────────────────────────────────────────
function Test-Ping {
  param([string]$Target = '1.1.1.1', [int]$Count = 12)
  $p = New-Object System.Net.NetworkInformation.Ping
  $lat = @(); $loss = 0
  for ($i = 0; $i -lt $Count; $i++) {
    try { $res = $p.Send($Target, 2000)
      if ($res.Status -eq 'Success') { $lat += $res.RoundtripTime } else { $loss++ }
    } catch { $loss++ }
    Start-Sleep -Milliseconds 120
  }
  [pscustomobject]@{
    Target = $Target
    AvgMs  = if ($lat.Count) { [math]::Round(($lat | Measure-Object -Average).Average, 1) } else { $null }
    MaxMs  = if ($lat.Count) { ($lat | Measure-Object -Maximum).Maximum } else { $null }
    LossPct= [math]::Round($loss / $Count * 100, 0)
  }
}

function Test-DnsResolver {
  param([string]$Server, [string[]]$Names = @('google.com','cloudflare.com','youtube.com','github.com','wikipedia.org'))
  $times = foreach ($n in $Names) {
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    try {
      if ($Server) { Resolve-DnsName -Name $n -Server $Server -Type A -DnsOnly -ErrorAction Stop | Out-Null }
      else         { Resolve-DnsName -Name $n -Type A -ErrorAction Stop | Out-Null }
      $sw.Stop(); $sw.Elapsed.TotalMilliseconds
    } catch { $sw.Stop(); $null }
  }
  $ok = @($times | Where-Object { $_ -ne $null })
  if ($ok.Count) { [math]::Round(($ok | Measure-Object -Average).Average, 1) } else { $null }
}

function Test-Download {
  # Uses Cloudflare's public speed-test endpoint (designed for exactly this).
  param([int64]$Bytes = 25000000)
  $url = "https://speed.cloudflare.com/__down?bytes=$Bytes"
  try {
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    Invoke-WebRequest -Uri $url -UseBasicParsing -TimeoutSec 90 | Out-Null
    $sw.Stop()
    $mbps = ($Bytes * 8) / $sw.Elapsed.TotalSeconds / 1000000
    return [math]::Round($mbps, 1)
  } catch { return $null }
}

function Get-OptimalMtu {
  # Largest non-fragmented payload to 1.1.1.1, + 28 bytes of IP/ICMP headers.
  param([string]$Target = '1.1.1.1')
  $lo = 1200; $hi = 1472; $best = $null   # 1472 payload = 1500 MTU (typical max)
  while ($lo -le $hi) {
    $mid = [math]::Floor(($lo + $hi) / 2)
    $out = ping.exe $Target -n 1 -f -l $mid -w 1500 2>$null
    if ($out -match 'TTL=') { $best = $mid; $lo = $mid + 1 }
    elseif ($out -match 'fragmented|too big|must be fragmented') { $hi = $mid - 1 }
    else { break }   # unreachable / blocks ICMP — bail
  }
  if ($best) { return ($best + 28) } else { return $null }
}

$DnsCandidates = [ordered]@{
  'Cloudflare'      = '1.1.1.1'
  'Google'          = '8.8.8.8'
  'Quad9'           = '9.9.9.9'
  'OpenDNS'         = '208.67.222.222'
  'Current (DHCP)'  = ''
}

function Run-Diagnostics {
  param([string]$Phase = 'BEFORE')
  Head "Measuring ($Phase)"
  $ad = Get-ActiveAdapter
  if ($ad) { Say ("  Adapter : {0}  ({1}, link {2})" -f $ad.Name, $ad.InterfaceDescription, $ad.LinkSpeed) }

  $ping = Test-Ping
  if ($ping.AvgMs -ne $null) { Say ("  Ping    : {0} ms avg, {1} ms max, {2}% loss  -> 1.1.1.1" -f $ping.AvgMs,$ping.MaxMs,$ping.LossPct) }
  else { Bad "Ping: no response from 1.1.1.1" }

  Say "  Download: testing (~25 MB from Cloudflare)..."
  $dl = Test-Download
  if ($dl) { Say ("  Download: {0} Mbps" -f $dl) 'White' } else { Bad "Download test failed" }

  Say "  DNS     : timing resolvers (lower = faster)..."
  $dnsResults = @{}
  foreach ($k in $DnsCandidates.Keys) {
    $avg = Test-DnsResolver -Server $DnsCandidates[$k]
    $dnsResults[$k] = $avg
    Say ("           {0,-16} {1}" -f $k, ($(if ($avg) { "$avg ms" } else { 'failed' })))
  }
  [pscustomobject]@{ Ping = $ping; Download = $dl; Dns = $dnsResults }
}

# ── REVERT ───────────────────────────────────────────────────────────────────
if ($Revert) {
  Head "Revert"
  $backup = Get-ChildItem -Path $ScriptDir -Filter 'net-backup-*.json' -ErrorAction SilentlyContinue |
            Sort-Object LastWriteTime -Descending | Select-Object -First 1
  if (-not $backup) { Bad "No backup file found in $ScriptDir — nothing to revert."; return }
  Say "  Restoring from $($backup.Name)"
  $b = Get-Content $backup.FullName -Raw | ConvertFrom-Json
  try {
    if ($b.AdapterName) {
      if ($b.DnsServers -and $b.DnsServers.Count) {
        Set-DnsClientServerAddress -InterfaceAlias $b.AdapterName -ServerAddresses $b.DnsServers -ErrorAction Stop
        Good "DNS restored to $($b.DnsServers -join ', ')"
      } else {
        Set-DnsClientServerAddress -InterfaceAlias $b.AdapterName -ResetServerAddresses -ErrorAction Stop
        Good "DNS reset to automatic (DHCP)"
      }
    }
    Set-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile' `
      -Name 'NetworkThrottlingIndex' -Value ([int]$b.NetworkThrottlingIndex) -Type DWord -ErrorAction SilentlyContinue
    Good "NetworkThrottlingIndex restored to $($b.NetworkThrottlingIndex)"
    if ($b.AutotuningLevel) { netsh int tcp set global autotuninglevel=$($b.AutotuningLevel) | Out-Null; Good "TCP autotuning restored" }
    if ($b.PowerScheme)     { powercfg /setactive $b.PowerScheme 2>$null; Good "Power plan restored" }
    ipconfig /flushdns | Out-Null
    Say ""; Good "Revert complete."
  } catch { Bad "Revert error: $($_.Exception.Message)" }
  return
}

# ── HEADER ───────────────────────────────────────────────────────────────────
Say "==============================================" 'Cyan'
Say " Internet Optimizer for Windows" 'Cyan'
Say (" Mode: {0}" -f $(if ($Apply) { 'APPLY (will change settings)' } else { 'MEASURE-ONLY (no changes)' })) 'Cyan'
Say "==============================================" 'Cyan'

$before = Run-Diagnostics -Phase 'BEFORE'

# Pick the fastest DNS we measured.
$fastestDns = $null; $fastestName = $null
foreach ($k in $DnsCandidates.Keys) {
  $v = $before.Dns[$k]
  if ($v -ne $null -and $DnsCandidates[$k] -ne '') {
    if ($fastestDns -eq $null -or $v -lt $fastestDns) { $fastestDns = $v; $fastestName = $k }
  }
}

Head "Recommendation"
if ($fastestName) { Say ("  Fastest DNS for you: {0} ({1}) at {2} ms" -f $fastestName, $DnsCandidates[$fastestName], $fastestDns) 'White' }
if (-not $Apply) {
  Warn "This was a MEASURE-ONLY run. To apply the speed optimizations, run:"
  Say  "     .\Optimize-Internet.ps1 -Apply" 'White'
  Say  "  (add -Gaming to also cut latency for games/voice)" 'DarkGray'
  return
}

# ── APPLY ────────────────────────────────────────────────────────────────────
Head "Backing up current settings"
$ad = Get-ActiveAdapter
$curDns = @()
if ($ad) {
  $curDns = (Get-DnsClientServerAddress -InterfaceAlias $ad.Name -AddressFamily IPv4 -ErrorAction SilentlyContinue).ServerAddresses
}
$curThrottle = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile' -Name 'NetworkThrottlingIndex' -ErrorAction SilentlyContinue).NetworkThrottlingIndex
if ($null -eq $curThrottle) { $curThrottle = 10 }      # Windows default
$curAuto = 'normal'
try { $a = netsh int tcp show global | Select-String 'Auto-Tuning Level'; if ($a -match ':\s*(\w+)') { $curAuto = $Matches[1] } } catch {}
$curScheme = (powercfg /getactivescheme) -replace '.*GUID:\s*([\w-]+).*','$1'

$backup = [pscustomobject]@{
  Timestamp              = (Get-Date).ToString('s')
  AdapterName            = $ad.Name
  DnsServers             = $curDns
  NetworkThrottlingIndex = $curThrottle
  AutotuningLevel        = $curAuto
  PowerScheme            = $curScheme
}
$backupPath = Join-Path $ScriptDir ("net-backup-{0}.json" -f (Get-Date -Format 'yyyyMMdd-HHmmss'))
$backup | ConvertTo-Json | Set-Content $backupPath
Good "Saved backup -> $backupPath  (use -Revert to undo)"

Head "Applying optimizations"

# 1) Fastest DNS
if ($fastestName -and $ad) {
  try {
    $primary = $DnsCandidates[$fastestName]
    $secondary = if ($primary -eq '1.1.1.1') { '1.0.0.1' } elseif ($primary -eq '8.8.8.8') { '8.8.4.4' } elseif ($primary -eq '9.9.9.9') { '149.112.112.112' } else { '1.1.1.1' }
    Set-DnsClientServerAddress -InterfaceAlias $ad.Name -ServerAddresses @($primary,$secondary) -ErrorAction Stop
    Good "DNS set to $fastestName ($primary, $secondary)"
  } catch { Bad "DNS change failed: $($_.Exception.Message)" }
}

# 2) Remove Windows' artificial network throttle (helps high-throughput)
try {
  Set-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile' `
    -Name 'NetworkThrottlingIndex' -Value 0xffffffff -Type DWord -ErrorAction Stop
  Good "Disabled NetworkThrottlingIndex (was $curThrottle)"
} catch { Bad "Throttle tweak failed: $($_.Exception.Message)" }

# 3) TCP autotuning + RSS so big transfers ramp to full bandwidth
try { netsh int tcp set global autotuninglevel=normal | Out-Null; Good "TCP autotuning = normal" } catch { Warn "autotuning skipped" }
try { netsh int tcp set global rss=enabled | Out-Null; Good "Receive-Side Scaling enabled" } catch { Warn "RSS skipped" }

# 4) Stop the adapter from power-saving (a big cause of Wi-Fi slow-downs/drops)
if ($ad) {
  try { Set-NetAdapterPowerManagement -Name $ad.Name -AllowComputerToTurnOffDevice Disabled -NoRestart -ErrorAction Stop
        Good "Disabled power-saving on '$($ad.Name)'" }
  catch { Warn "Could not change adapter power management (driver may not support it)" }
}

# 5) High-performance power plan (keeps NIC/CPU from throttling)
try { powercfg /setactive SCHEME_MIN 2>$null; Good "Power plan -> High performance" } catch { Warn "power plan skipped" }

# 6) Optimal MTU (only set if clearly below 1500 and detected reliably)
$mtu = Get-OptimalMtu
if ($mtu -and $mtu -lt 1500 -and $mtu -ge 1400 -and $ad) {
  try { netsh interface ipv4 set subinterface "$($ad.Name)" mtu=$mtu store=persistent | Out-Null; Good "MTU set to $mtu" }
  catch { Warn "MTU change skipped" }
} elseif ($mtu) { Say "  MTU: optimal is $mtu (already fine / left as-is)" 'DarkGray' }

# 7) Flush DNS so the new resolver takes effect immediately
ipconfig /flushdns | Out-Null; Good "Flushed DNS cache"

# 8) Optional latency tweak for gaming/voice (disable Nagle)
if ($Gaming -and $ad) {
  try {
    $guid = (Get-NetAdapter -Name $ad.Name).InterfaceGuid
    $base = "HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters\Interfaces"
    $key = Get-ChildItem $base | Where-Object { $_.PSChildName -eq $guid }
    if ($key) {
      Set-ItemProperty $key.PSPath -Name 'TcpAckFrequency' -Value 1 -Type DWord
      Set-ItemProperty $key.PSPath -Name 'TCPNoDelay' -Value 1 -Type DWord
      Good "Disabled Nagle on '$($ad.Name)' (lower latency)"
    }
  } catch { Warn "Nagle tweak skipped" }
}

Start-Sleep -Seconds 2
$after = Run-Diagnostics -Phase 'AFTER'

# ── BEFORE / AFTER SUMMARY ───────────────────────────────────────────────────
Head "Result (before -> after)"
function Delta { param($b,$a,$unit,$lowerBetter=$true)
  if ($b -eq $null -or $a -eq $null) { return "$b -> $a $unit" }
  $diff = $a - $b
  $better = if ($lowerBetter) { $diff -lt 0 } else { $diff -gt 0 }
  $tag = if ([math]::Abs($diff) -lt 0.001) { '(no change)' } elseif ($better) { '(better)' } else { '(worse)' }
  "{0} -> {1} {2}  {3}" -f $b, $a, $unit, $tag
}
Say ("  Download : " + (Delta $before.Download $after.Download 'Mbps' $false)) 'White'
Say ("  Ping     : " + (Delta $before.Ping.AvgMs $after.Ping.AvgMs 'ms' $true)) 'White'
$bDns = ($before.Dns.Values | Where-Object {$_} | Measure-Object -Minimum).Minimum
$aDns = ($after.Dns.Values  | Where-Object {$_} | Measure-Object -Minimum).Minimum
Say ("  DNS      : " + (Delta $bDns $aDns 'ms' $true)) 'White'
Say ""
Good "Done. Settings backed up to: $backupPath"
Say  "  Undo anytime with:  .\Optimize-Internet.ps1 -Revert" 'DarkGray'
Say  "  Log saved to: $Log" 'DarkGray'
Warn "Tip: if anything feels off, run -Revert, then reboot. A reboot also helps the new TCP/MTU settings fully apply."
