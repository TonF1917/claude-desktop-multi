# Settings sync (pins, starred, MCP servers) and the "same session in two instances" guard. Dot-sourced by Core.ps1.
Add-Type -AssemblyName System.Web.Extensions
$script:SetSnapFile = Join-Path $HomeRoot 'settings-snap.txt'
$script:PendingDir = Join-Path $HomeRoot 'pending-settings'   # <id>.json = canonical subset waiting for that (running) instance to restart
$script:Cpu2 = @{}
$script:Warned = @{}

function New-Js { $s = New-Object Web.Script.Serialization.JavaScriptSerializer; $s.MaxJsonLength = [int]::MaxValue; $s.RecursionLimit = 200; $s }
function Get-CfgPath($i) { Join-Path (Get-DataDir $i) 'claude_desktop_config.json' }
function Read-CfgDict($path) {
  if (-not (Test-Path $path)) { return $null }
  try { (New-Js).DeserializeObject([IO.File]::ReadAllText($path)) } catch { $null }
}
function New-Dict { New-Object 'Collections.Generic.Dictionary[string,object]' }

# the part of claude_desktop_config.json that makes two windows "feel the same": MCP servers, starred sessions, pin order
function Get-SyncSubset($d) {
  $o = New-Dict
  if (-not $d) { return $o }
  if ($d.ContainsKey('mcpServers')) { $o['mcpServers'] = $d['mcpServers'] }
  $e = $null
  if ($d.ContainsKey('preferences') -and $d['preferences'].ContainsKey('epitaxyPrefs')) { $e = $d['preferences']['epitaxyPrefs'] }
  if ($e) {
    foreach ($k in @($e.Keys)) { if ($k -like 'starred-*') { $o[$k] = $e[$k] } }
    if ($e.ContainsKey('dframe-local-slice')) {
      $sl = $e['dframe-local-slice']
      foreach ($k in 'pinnedOrder', 'homeProjectsPinnedOrder') { if ($sl.ContainsKey($k)) { $o["slice:$k"] = $sl[$k] } }
    }
  }
  $o
}
function Get-SubsetHash($subset) {
  $keys = @($subset.Keys | Sort-Object); $sorted = New-Dict; foreach ($k in $keys) { $sorted[$k] = $subset[$k] }
  $json = (New-Js).Serialize($sorted)
  $sha = [Security.Cryptography.SHA1]::Create()
  ([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($json)))) -replace '-', ''
}
function Set-SyncSubset($path, $subset) {
  $d = Read-CfgDict $path; if (-not $d) { return }
  if (-not (Get-ChildItem (Split-Path $path) -Filter 'claude_desktop_config.json.bak-multi-*' -ErrorAction SilentlyContinue)) {
    Copy-Item $path ($path + '.bak-multi-' + (Get-Date -Format yyyyMMddHHmmss))
  }
  if ($subset.ContainsKey('mcpServers')) { $d['mcpServers'] = $subset['mcpServers'] }
  if (-not $d.ContainsKey('preferences')) { $d['preferences'] = New-Dict }
  if (-not $d['preferences'].ContainsKey('epitaxyPrefs')) { $d['preferences']['epitaxyPrefs'] = New-Dict }
  $e = $d['preferences']['epitaxyPrefs']
  foreach ($k in @($subset.Keys)) {
    if ($k -like 'starred-*') { $e[$k] = $subset[$k] }
    elseif ($k -like 'slice:*') {
      if (-not $e.ContainsKey('dframe-local-slice')) { $e['dframe-local-slice'] = New-Dict }
      $e['dframe-local-slice'][$k.Substring(6)] = $subset[$k]
    }
  }
  $tmp = $path + '.tmp'
  [IO.File]::WriteAllText($tmp, (New-Js).Serialize($d), (New-Object Text.UTF8Encoding $false))
  Move-Item $tmp $path -Force
}
function Test-PendingSettings($id) { Test-Path (Join-Path $PendingDir "$id.json") }
function Save-PendingSettings($id, $subset) { New-Item -ItemType Directory -Force $PendingDir | Out-Null; Write-Utf8 (Join-Path $PendingDir "$id.json") ((New-Js).Serialize($subset)) }
function Apply-PendingSettings($i) {
  $f = Join-Path $PendingDir "$($i.id).json"; if (-not (Test-Path $f)) { return }
  $p = (New-Js).DeserializeObject([IO.File]::ReadAllText($f))
  Set-SyncSubset (Get-CfgPath $i) $p; Remove-Item $f -Force
}

# One pass: find the instance whose subset changed since the last agreed state and spread it to the others.
function Invoke-SettingsSync($cfg, $mains) {
  $all = @($cfg.instances); $running = @{}
  foreach ($m in $mains) { $x = Find-InstanceOf $m $all; if ($x) { $running[$x.id] = $true } }
  $info = @{}
  foreach ($i in $all) {
    $path = Get-CfgPath $i; if (-not (Test-Path $path)) { continue }
    $sub = Get-SyncSubset (Read-CfgDict $path)
    $info[$i.id] = @{ i = $i; sub = $sub; h = (Get-SubsetHash $sub); t = (Get-Item $path).LastWriteTimeUtc }
  }
  if ($info.Count -lt 2) { return }
  $snap = if (Test-Path $SetSnapFile) { (Get-Content $SetSnapFile -Raw).Trim() } else { $null }
  $winner = $null
  if (-not $snap) {                                           # first run: the official instance is the source of truth
    $distinct = @($info.Values | ForEach-Object { $_.h } | Sort-Object -Unique)
    if ($distinct.Count -le 1) { Write-Utf8 $SetSnapFile $distinct[0]; return }
    $winner = if ($info.ContainsKey('official')) { $info['official'] } else { $info.Values | Sort-Object { $_.t } -Descending | Select-Object -First 1 }
  } else {
    $changed = @($info.Values | Where-Object { $_.h -ne $snap -and -not (Test-PendingSettings $_.i.id) })
    if ($changed.Count -eq 0) { return }
    $winner = $changed | Sort-Object { $_.t } -Descending | Select-Object -First 1
  }
  foreach ($e in $info.Values) {
    if ($e.i.id -eq $winner.i.id -or $e.h -eq $winner.h) { continue }
    if ($running.ContainsKey($e.i.id)) { Save-PendingSettings $e.i.id $winner.sub; $script:StaleSince[$e.i.id] = Get-Date }
    else { Set-SyncSubset (Get-CfgPath $e.i) $winner.sub }
  }
  Write-Utf8 $SetSnapFile $winner.h
}

# ---------------------------------------------------------------- same session in two instances
function Show-Toast([string]$title, [string]$text) {
  try {
    [void][Windows.UI.Notifications.ToastNotificationManager, Windows.UI.Notifications, ContentType = WindowsRuntime]
    [void][Windows.Data.Xml.Dom.XmlDocument, Windows.Data.Xml.Dom.XmlDocument, ContentType = WindowsRuntime]
    $xml = New-Object Windows.Data.Xml.Dom.XmlDocument
    $xml.LoadXml("<toast><visual><binding template='ToastGeneric'><text>$([Security.SecurityElement]::Escape($title))</text><text>$([Security.SecurityElement]::Escape($text))</text></binding></visual></toast>")
    $appId = '{1AC14E77-02E7-4E5D-B744-2EB1AE5198B7}\WindowsPowerShell\v1.0\powershell.exe'
    [Windows.UI.Notifications.ToastNotificationManager]::CreateToastNotifier($appId).Show([Windows.UI.Notifications.ToastNotification]::new($xml))
  } catch { Add-Content (Join-Path $StateDir 'agent.log') ("{0} toast failed: {1}" -f (Get-Date -Format s), $_) }
}
function Get-SessionTitle([string]$cliId) {
  foreach ($f in Get-SessionFolders) {
    foreach ($p in [IO.Directory]::EnumerateFiles($f.Path, 'local_*.json')) {
      $txt = [IO.File]::ReadAllText($p)
      if ($txt.Contains($cliId) -and $txt -match '"title":"((?:[^"\\]|\\.)*)"') { return $Matches[1] }
    }
    break
  }
  $cliId
}
# Two Claude Code processes resuming one session id append to the same transcript and each keeps its own context.
# Warn when a session is live in two instances and one of them is busy.
function Invoke-ConcurrencyGuard($cfg, $mains) {
  $all = @($cfg.instances); $procs = @(Get-CimInstance Win32_Process); $by = @{}
  foreach ($m in $mains) {
    $inst = Find-InstanceOf $m $all; if (-not $inst) { continue }
    foreach ($c in (Get-Descendants $m.ProcessId $procs)) {
      if ($c.CommandLine -notmatch '--resume=([0-9a-f]{8}-[0-9a-f-]{27})') { continue }
      $id = $Matches[1]; $busy = $false
      try {
        $cpu = [Diagnostics.Process]::GetProcessById([int]$c.ProcessId).TotalProcessorTime.TotalSeconds
        $prev = $script:Cpu2[[int]$c.ProcessId]; $script:Cpu2[[int]$c.ProcessId] = $cpu
        $busy = ($null -ne $prev -and ($cpu - $prev) -gt 0.4)
      } catch { }
      if (-not $by.ContainsKey($id)) { $by[$id] = @() }
      $by[$id] += [pscustomobject]@{ inst = $inst.name; busy = $busy }
    }
  }
  foreach ($id in $by.Keys) {
    $uses = @($by[$id]); $names = @($uses | ForEach-Object inst | Sort-Object -Unique)
    if ($names.Count -lt 2 -or -not (@($uses | Where-Object busy).Count)) { continue }
    $w = $script:Warned[$id]; if ($w -and ((Get-Date) - $w).TotalMinutes -lt 30) { continue }
    $script:Warned[$id] = Get-Date
    Show-Toast 'Claude Multi: same session open in two windows' ("'{0}' is live in {1}. Sending in both interleaves one transcript with two separate contexts - keep it active in one window only." -f (Get-SessionTitle $id), ($names -join ' and '))
  }
}
