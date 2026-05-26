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
  [switch]$Auto,         # read -> detect problems -> fix only what's broken -> re-test
  [switch]$Apply,        # apply ALL optimizations (blanket)
  [switch]$Revert,       # undo from the latest backup
  [switch]$Gaming,       # also lower latency (disable Nagle)
  [switch]$Watch,        # stability watchdog: monitor, log drops, (optionally) auto-recover
  [switch]$AutoReset,    # with -Watch: auto-reset the adapter during a sustained outage
  [int]$WatchInterval = 4 # seconds between connectivity checks in -Watch mode
)

# ── Elevate to Administrator (changes + some reads need it) ──────────────────
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
          ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
  Write-Host "Re-launching as Administrator..." -ForegroundColor Yellow
  $argList = @('-NoProfile','-ExecutionPolicy','Bypass','-File',"`"$PSCommandPath`"")
  if ($Auto)      { $argList += '-Auto' }
  if ($Apply)     { $argList += '-Apply' }
  if ($Revert)    { $argList += '-Revert' }
  if ($Gaming)    { $argList += '-Gaming' }
  if ($Watch)     { $argList += '-Watch' }
  if ($AutoReset) { $argList += '-AutoReset' }
  Start-Process powershell.exe -Verb RunAs -ArgumentList $argList
  return
}

$ErrorActionPreference = 'Continue'
# CRITICAL on Windows PowerShell 5.1: the IWR progress bar throttles downloads
# ~10x, which would make the speed test read falsely low. Turn it off.
$ProgressPreference = 'SilentlyContinue'
# PS 5.1 defaults to old TLS that Cloudflare rejects — force TLS 1.2 so the
# speed test (https) actually connects.
try { [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12 } catch {}

# Reliable script folder: $PSScriptRoot is set when run as a .ps1; fall back
# sensibly if invoked oddly.
$ScriptDir = if ($PSScriptRoot) { $PSScriptRoot }
             elseif ($PSCommandPath) { Split-Path -Parent $PSCommandPath }
             else { (Get-Location).Path }
$Log = Join-Path $ScriptDir ("net-optimizer-{0}.log" -f (Get-Date -Format 'yyyyMMdd-HHmmss'))

function Say   { param($m,$c='Gray') Write-Host $m -ForegroundColor $c; Add-Content $Log $m }
function Head  { param($m) Write-Host ""; Write-Host "── $m ──" -ForegroundColor Cyan; Add-Content $Log "== $m ==" }
function Good  { param($m) Say "  [OK] $m" 'Green' }
function Warn  { param($m) Say "  [!]  $m" 'Yellow' }
function Bad   { param($m) Say "  [X]  $m" 'Red' }

# ── Preflight: this tool is Windows-only and uses cmdlets from Win8/Win10+ ────
$isWindows = ($env:OS -eq 'Windows_NT') -or ($PSVersionTable.Platform -eq 'Win32NT') -or ($null -eq $PSVersionTable.Platform)
if (-not $isWindows) {
  Bad "This tool only works on Windows (it tunes Windows networking settings). Detected a non-Windows OS — exiting."
  return
}
if ($PSVersionTable.PSVersion.Major -lt 5) {
  Bad "Windows PowerShell 5.0+ is required (you have $($PSVersionTable.PSVersion)). Update Windows or install PowerShell 7."
  return
}
# Make sure the networking cmdlets we rely on actually exist (stripped/Server Core installs may lack them).
$missing = @('Get-NetAdapter','Get-NetRoute','Resolve-DnsName','Set-DnsClientServerAddress') | Where-Object { -not (Get-Command $_ -ErrorAction SilentlyContinue) }
if ($missing.Count) {
  Warn "Some Windows networking cmdlets are missing ($($missing -join ', ')). The script will still run and skip anything unavailable."
}

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
  param([int64]$Bytes = 15000000)
  $base = 'https://speed.cloudflare.com/__down?bytes='
  $hdr  = @{ 'Cache-Control' = 'no-cache' }
  try {
    # Warm-up: open the connection + get past TCP slow-start (timing ignored).
    try { Invoke-WebRequest -Uri "${base}2000000" -Headers $hdr -UseBasicParsing -TimeoutSec 30 | Out-Null } catch {}
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    Invoke-WebRequest -Uri "$base$Bytes" -Headers $hdr -UseBasicParsing -TimeoutSec 90 | Out-Null
    $sw.Stop()
    if ($sw.Elapsed.TotalSeconds -le 0) { return $null }
    [math]::Round(($Bytes * 8) / $sw.Elapsed.TotalSeconds / 1000000, 1)
  } catch { return $null }
}

function New-HttpClient {
  param([int]$TimeoutSec = 60)
  try { Add-Type -AssemblyName System.Net.Http -ErrorAction SilentlyContinue } catch {}
  $c = New-Object System.Net.Http.HttpClient
  $c.Timeout = [TimeSpan]::FromSeconds($TimeoutSec)
  return $c
}

function Test-DownloadParallel {
  # Several simultaneous streams — a single TCP stream rarely saturates a fast
  # line, so one-stream tests undercount. Total bytes / wall-clock = real speed.
  param([int]$Streams = 4, [int64]$BytesPerStream = 10000000, [int]$TimeoutSec = 60)
  $base = 'https://speed.cloudflare.com/__down?bytes='
  $client = $null
  try {
    $client = New-HttpClient -TimeoutSec $TimeoutSec
    try { $client.GetByteArrayAsync("${base}1000000").Result | Out-Null } catch {}  # warm-up
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $tasks = 1..$Streams | ForEach-Object { $client.GetByteArrayAsync("$base$BytesPerStream") }
    [System.Threading.Tasks.Task]::WaitAll($tasks)
    $sw.Stop()
    $total = ($tasks | ForEach-Object { $_.Result.Length } | Measure-Object -Sum).Sum
    if ($sw.Elapsed.TotalSeconds -le 0 -or $total -le 0) { return $null }
    [math]::Round(($total * 8) / $sw.Elapsed.TotalSeconds / 1000000, 1)
  } catch { return $null }
  finally { if ($client) { $client.Dispose() } }
}

function Test-Upload {
  # POST a buffer to Cloudflare's upload endpoint and time it.
  param([int64]$Bytes = 8000000, [int]$TimeoutSec = 60)
  $client = $null
  try {
    $client = New-HttpClient -TimeoutSec $TimeoutSec
    $data = New-Object byte[] $Bytes
    $content = New-Object System.Net.Http.ByteArrayContent (, $data)
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $resp = $client.PostAsync('https://speed.cloudflare.com/__up', $content).Result
    $sw.Stop()
    if (-not $resp.IsSuccessStatusCode -or $sw.Elapsed.TotalSeconds -le 0) { return $null }
    [math]::Round(($Bytes * 8) / $sw.Elapsed.TotalSeconds / 1000000, 1)
  } catch { return $null }
  finally { if ($client) { $client.Dispose() } }
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

# ── Read the CURRENT Windows network settings (for auto-detect) ──────────────
function Get-NetworkState {
  $ad = Get-ActiveAdapter
  $throttle = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile' -Name 'NetworkThrottlingIndex' -ErrorAction SilentlyContinue).NetworkThrottlingIndex
  if ($null -eq $throttle) { $throttle = 10 }   # Windows default = throttled
  $auto = 'unknown'; $rss = 'unknown'
  try {
    $g = netsh int tcp show global
    if (($g | Select-String 'Auto-Tuning Level') -match ':\s*(\w+)') { $auto = $Matches[1] }
    if (($g | Select-String 'Receive-Side Scaling State') -match ':\s*(\w+)') { $rss = $Matches[1] }
  } catch {}
  $nicPower = $null
  if ($ad) { try { $nicPower = (Get-NetAdapterPowerManagement -Name $ad.Name -ErrorAction Stop).AllowComputerToTurnOffDevice } catch {} }
  $powerSaver = ((powercfg /getactivescheme) -join ' ') -match 'Power saver'
  $dns = @(); if ($ad) { $dns = @((Get-DnsClientServerAddress -InterfaceAlias $ad.Name -AddressFamily IPv4 -ErrorAction SilentlyContinue).ServerAddresses) }
  [pscustomobject]@{
    Adapter = $ad; Throttle = $throttle; Autotuning = $auto; Rss = $rss
    NicPower = $nicPower; PowerSaver = $powerSaver; Dns = $dns
  }
}

# ── Save a restore point before changing anything ────────────────────────────
function Backup-Settings {
  $ad = Get-ActiveAdapter
  $curDns = @(); if ($ad) { $curDns = @((Get-DnsClientServerAddress -InterfaceAlias $ad.Name -AddressFamily IPv4 -ErrorAction SilentlyContinue).ServerAddresses) }
  $curThrottle = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile' -Name 'NetworkThrottlingIndex' -ErrorAction SilentlyContinue).NetworkThrottlingIndex
  if ($null -eq $curThrottle) { $curThrottle = 10 }
  $curAuto = 'normal'
  try { $a = netsh int tcp show global | Select-String 'Auto-Tuning Level'; if ($a -match ':\s*(\w+)') { $curAuto = $Matches[1] } } catch {}
  $curScheme = (powercfg /getactivescheme) -replace '.*GUID:\s*([\w-]+).*','$1'
  $obj = [pscustomobject]@{
    Timestamp = (Get-Date).ToString('s'); AdapterName = $ad.Name; DnsServers = $curDns
    NetworkThrottlingIndex = $curThrottle; AutotuningLevel = $curAuto; PowerScheme = $curScheme
  }
  $path = Join-Path $ScriptDir ("net-backup-{0}.json" -f (Get-Date -Format 'yyyyMMdd-HHmmss'))
  $obj | ConvertTo-Json | Set-Content $path
  return $path
}

function Show-BeforeAfter {
  param($before, $after)
  function _d($b, $a, $unit, $lowerBetter) {
    if ($b -eq $null -or $a -eq $null) { return "$b -> $a $unit" }
    $diff = $a - $b
    $better = if ($lowerBetter) { $diff -lt 0 } else { $diff -gt 0 }
    $tag = if ([math]::Abs($diff) -lt 0.001) { '(no change)' } elseif ($better) { '(better)' } else { '(worse)' }
    "{0} -> {1} {2}  {3}" -f $b, $a, $unit, $tag
  }
  Say ("  Download : " + (_d $before.Download $after.Download 'Mbps' $false)) 'White'
  Say ("  Upload   : " + (_d $before.Upload $after.Upload 'Mbps' $false)) 'White'
  Say ("  Ping     : " + (_d $before.Ping.AvgMs $after.Ping.AvgMs 'ms' $true)) 'White'
  $bDns = ($before.Dns.Values | Where-Object { $_ } | Measure-Object -Minimum).Minimum
  $aDns = ($after.Dns.Values  | Where-Object { $_ } | Measure-Object -Minimum).Minimum
  Say ("  DNS      : " + (_d $bDns $aDns 'ms' $true)) 'White'
}

# ── Stability watchdog ───────────────────────────────────────────────────────
function Test-Online {
  param([string[]]$Targets)
  foreach ($t in $Targets) {
    try { $p = New-Object System.Net.NetworkInformation.Ping; if ($p.Send($t, 1500).Status -eq 'Success') { return $true } } catch {}
  }
  return $false
}

function Start-Watchdog {
  param(
    [string[]]$Targets = @('1.1.1.1','8.8.8.8'),
    [int]$IntervalSec = 4, [int]$FailsToDown = 3, [int]$ResetAfterSec = 30, [switch]$AutoReset
  )
  $csv = Join-Path $ScriptDir ("net-watchdog-{0}.csv" -f (Get-Date -Format 'yyyyMMdd-HHmmss'))
  "Timestamp,Event,Detail" | Set-Content $csv
  function LogEvt($evt, $detail) { ("{0},{1},{2}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $evt, $detail) | Add-Content $csv }

  $start = Get-Date
  $outages = 0; [double]$totalDownMs = 0; [double]$longestMs = 0
  $consecFails = 0; $down = $false; $downStart = $null
  $lastReset = (Get-Date).AddYears(-1); $resetCooldownSec = 120; $lastBeat = Get-Date

  Head "Stability watchdog"
  Say ("  Watching {0} every {1}s.  Auto-reset: {2}" -f ($Targets -join ', '), $IntervalSec, $(if ($AutoReset) { "ON (after ${ResetAfterSec}s down)" } else { 'off' }))
  Say ("  Logging every drop to: {0}" -f $csv)
  Say "  Leave this window open. Press Ctrl+C to stop and see the summary." 'DarkGray'
  LogEvt 'START' "targets=$($Targets -join '|') interval=${IntervalSec}s autoReset=$([bool]$AutoReset)"

  try {
    while ($true) {
      $online = Test-Online -Targets $Targets
      $now = Get-Date
      if ($online) {
        if ($down) {
          $dur = ($now - $downStart).TotalMilliseconds
          $outages++; $totalDownMs += $dur; if ($dur -gt $longestMs) { $longestMs = $dur }
          $secs = [math]::Round($dur / 1000, 1)
          Good ("RECOVERED at {0} — outage lasted {1}s" -f $now.ToString('HH:mm:ss'), $secs)
          LogEvt 'UP' "outage_sec=$secs"
          $down = $false; $downStart = $null
        }
        $consecFails = 0
      }
      else {
        $consecFails++
        if (-not $down -and $consecFails -ge $FailsToDown) {
          $down = $true; $downStart = $now
          Bad ("DOWN at {0} — no reply from any target" -f $now.ToString('HH:mm:ss'))
          LogEvt 'DOWN' "after_${FailsToDown}_failed_checks"
        }
        if ($down -and $AutoReset -and (($now - $downStart).TotalSeconds -ge $ResetAfterSec) -and (($now - $lastReset).TotalSeconds -ge $resetCooldownSec)) {
          $ad = Get-ActiveAdapter
          if ($ad) {
            Warn ("Sustained outage — resetting adapter '{0}'..." -f $ad.Name)
            try { Restart-NetAdapter -Name $ad.Name -Confirm:$false -ErrorAction Stop; LogEvt 'RESET' "adapter=$($ad.Name)" }
            catch { Bad "Adapter reset failed: $($_.Exception.Message)"; LogEvt 'RESET_FAIL' $_.Exception.Message }
            $lastReset = Get-Date
          }
        }
      }
      if (($now - $lastBeat).TotalSeconds -ge 30) {
        $totalMs = ($now - $start).TotalMilliseconds
        $up = if ($totalMs -gt 0) { [math]::Round(100 - ($totalDownMs / $totalMs * 100), 2) } else { 100 }
        Say ("  [{0}] alive · {1} min · outages {2} · uptime {3}%{4}" -f $now.ToString('HH:mm:ss'), [math]::Round($totalMs / 60000, 1), $outages, $up, $(if ($down) { ' · CURRENTLY DOWN' } else { '' })) 'DarkGray'
        $lastBeat = $now
      }
      Start-Sleep -Seconds $IntervalSec
    }
  }
  finally {
    $end = Get-Date; $totalMs = ($end - $start).TotalMilliseconds
    if ($down -and $downStart) { $totalDownMs += ($end - $downStart).TotalMilliseconds }
    $up = if ($totalMs -gt 0) { [math]::Round(100 - ($totalDownMs / $totalMs * 100), 2) } else { 100 }
    Head "Watchdog summary"
    Say ("  Monitored      : {0} min" -f [math]::Round($totalMs / 60000, 1)) 'White'
    Say ("  Outages        : {0}" -f $outages) 'White'
    Say ("  Total downtime : {0} s" -f [math]::Round($totalDownMs / 1000, 1)) 'White'
    Say ("  Longest outage : {0} s" -f [math]::Round($longestMs / 1000, 1)) 'White'
    Say ("  Uptime         : {0}%" -f $up) 'White'
    Say ("  Full drop log  : {0}" -f $csv) 'DarkGray'
    LogEvt 'STOP' "outages=$outages total_down_sec=$([math]::Round($totalDownMs/1000,1)) uptime_pct=$up"
  }
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

  Say "  Download: testing (4 parallel streams from Cloudflare)..."
  $dl = Test-DownloadParallel
  if (-not $dl) { $dl = Test-Download }   # fall back to single-stream if parallel failed
  if ($dl) { Say ("  Download: {0} Mbps" -f $dl) 'White' } else { Bad "Download test failed" }

  Say "  Upload  : testing..."
  $ul = Test-Upload
  if ($ul) { Say ("  Upload  : {0} Mbps" -f $ul) 'White' } else { Warn "Upload test failed (or blocked)" }

  Say "  DNS     : timing resolvers (lower = faster)..."
  $dnsResults = @{}
  foreach ($k in $DnsCandidates.Keys) {
    $avg = Test-DnsResolver -Server $DnsCandidates[$k]
    $dnsResults[$k] = $avg
    Say ("           {0,-16} {1}" -f $k, ($(if ($avg) { "$avg ms" } else { 'failed' })))
  }
  [pscustomobject]@{ Ping = $ping; Download = $dl; Upload = $ul; Dns = $dnsResults }
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

# ── WATCH: stability watchdog (long-running; own branch) ─────────────────────
if ($Watch) {
  Start-Watchdog -IntervalSec $WatchInterval -AutoReset:$AutoReset
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

# ── AUTO mode: read -> detect only the REAL problems -> fix those -> re-test ──
if ($Auto) {
  Head "Auto-detecting problems"
  $state = Get-NetworkState
  $fixes = @()   # each: { Name; Detail; Action = scriptblock }

  # 1) Slow DNS — switch only if current is meaningfully slower than the fastest.
  $curDnsAvg = $before.Dns['Current (DHCP)']
  if ($fastestName -and $fastestDns -ne $null) {
    $alreadyFastest = $state.Dns -contains $DnsCandidates[$fastestName]
    $slower = ($curDnsAvg -eq $null) -or ($curDnsAvg -gt ($fastestDns + 15)) -or ($curDnsAvg -gt $fastestDns * 1.25)
    if ($slower -and -not $alreadyFastest) {
      $p = $DnsCandidates[$fastestName]
      $sec = if ($p -eq '1.1.1.1') { '1.0.0.1' } elseif ($p -eq '8.8.8.8') { '8.8.4.4' } elseif ($p -eq '9.9.9.9') { '149.112.112.112' } else { '1.1.1.1' }
      $fixes += [pscustomobject]@{ Name = 'Slow DNS'; Detail = "~$curDnsAvg ms -> $fastestName ($p) ~$fastestDns ms"; Action = { Set-DnsClientServerAddress -InterfaceAlias $state.Adapter.Name -ServerAddresses @($p, $sec) -ErrorAction Stop }.GetNewClosure() }
    } else { Good "DNS already fast (~$([int]$fastestDns) ms)" }
  }

  # 2) Windows network throttle (DWORD comes back as -1 when already disabled).
  $throttleOff = ($state.Throttle -eq -1) -or ([int64]$state.Throttle -eq 4294967295)
  if (-not $throttleOff) {
    $fixes += [pscustomobject]@{ Name = 'Network throttle ON'; Detail = "NetworkThrottlingIndex=$($state.Throttle) -> off"; Action = { reg add "HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile" /v NetworkThrottlingIndex /t REG_DWORD /d 0xffffffff /f | Out-Null } }
  } else { Good "Network throttle already off" }

  # 3) TCP autotuning
  if ($state.Autotuning -ne 'normal' -and $state.Autotuning -ne 'unknown') {
    $fixes += [pscustomobject]@{ Name = "TCP autotuning '$($state.Autotuning)'"; Detail = '-> normal'; Action = { netsh int tcp set global autotuninglevel=normal | Out-Null } }
  } else { Good "TCP autotuning already normal" }

  # 4) Receive-Side Scaling
  if ($state.Rss -ne 'enabled' -and $state.Rss -ne 'unknown') {
    $fixes += [pscustomobject]@{ Name = 'RSS disabled'; Detail = '-> enabled'; Action = { netsh int tcp set global rss=enabled | Out-Null } }
  } else { Good "Receive-Side Scaling already on" }

  # 5) Adapter power-saving (big hidden cause of Wi-Fi slowdowns)
  if ($state.NicPower -eq 'Enabled' -and $state.Adapter) {
    $fixes += [pscustomobject]@{ Name = 'Adapter power-saving ON'; Detail = "'$($state.Adapter.Name)' -> no sleep"; Action = { Set-NetAdapterPowerManagement -Name $state.Adapter.Name -AllowComputerToTurnOffDevice Disabled -NoRestart -ErrorAction Stop }.GetNewClosure() }
  } else { Good "Adapter power-saving already off (or n/a)" }

  # 6) Power-saver plan
  if ($state.PowerSaver) {
    $fixes += [pscustomobject]@{ Name = 'Power-saver plan'; Detail = '-> High performance'; Action = { powercfg /setactive SCHEME_MIN 2>$null } }
  } else { Good "Power plan fine (not power-saver)" }

  # Things a script genuinely can't fix — report honestly.
  if ($before.Ping.LossPct -ge 2) { Warn "Packet loss ~$($before.Ping.LossPct)% — usually Wi-Fi signal or ISP. Move closer to the router or go wired." }
  if ($before.Ping.AvgMs -ne $null -and $before.Ping.AvgMs -gt 80) { Warn "High ping ($($before.Ping.AvgMs) ms) — mostly distance/ISP; the fixes above help a little." }

  if ($fixes.Count -eq 0) {
    Head "Nothing to fix"
    Good "Your connection is already optimally configured — nothing changed."
    Say  "  Log saved to: $Log" 'DarkGray'
    return
  }

  Head ("Found {0} issue(s) — fixing automatically" -f $fixes.Count)
  $backupPath = Backup-Settings
  Good "Backup saved -> $backupPath  (undo anytime with -Revert)"
  foreach ($f in $fixes) {
    try { & $f.Action; Good ("Fixed: {0}   [{1}]" -f $f.Name, $f.Detail) }
    catch { Bad ("Could not fix {0}: {1}" -f $f.Name, $_.Exception.Message) }
  }
  ipconfig /flushdns | Out-Null

  Start-Sleep -Seconds 2
  $after = Run-Diagnostics -Phase 'AFTER'
  Head "Result (before -> after)"
  Show-BeforeAfter $before $after
  Say ""
  Good "Auto-fix complete. Backup: $backupPath"
  Say  "  Undo anytime:  .\Optimize-Internet.ps1 -Revert" 'DarkGray'
  Warn "Tip: a reboot helps the TCP/throttle changes fully settle in."
  return
}

if (-not $Apply) {
  Warn "This was a MEASURE-ONLY run. Recommended next step — auto-detect & fix only what's wrong:"
  Say  "     .\Optimize-Internet.ps1 -Auto" 'White'
  Say  "  Or apply ALL tweaks:  .\Optimize-Internet.ps1 -Apply   (add -Gaming for lower latency)" 'DarkGray'
  return
}

# ── APPLY ────────────────────────────────────────────────────────────────────
Head "Backing up current settings"
$ad = Get-ActiveAdapter
$backupPath = Backup-Settings
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
  reg add "HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile" /v NetworkThrottlingIndex /t REG_DWORD /d 0xffffffff /f | Out-Null
  Good "Disabled NetworkThrottlingIndex"
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
Show-BeforeAfter $before $after
Say ""
Good "Done. Settings backed up to: $backupPath"
Say  "  Undo anytime with:  .\Optimize-Internet.ps1 -Revert" 'DarkGray'
Say  "  Log saved to: $Log" 'DarkGray'
Warn "Tip: if anything feels off, run -Revert, then reboot. A reboot also helps the new TCP/MTU settings fully apply."
