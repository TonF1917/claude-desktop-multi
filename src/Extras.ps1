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
  if ($subset.ContainsKey('mcpServers')) { $d['mcpServers'] = $subset['mcpServers'].psobject.BaseObject }
  if (-not $d.ContainsKey('preferences')) { $d['preferences'] = New-Dict }
  if (-not $d['preferences'].ContainsKey('epitaxyPrefs')) { $d['preferences']['epitaxyPrefs'] = New-Dict }
  $e = $d['preferences']['epitaxyPrefs']
  foreach ($k in @($subset.Keys)) {
    if ($k -like 'starred-*') { $e[$k] = $subset[$k].psobject.BaseObject }
    elseif ($k -like 'slice:*') {
      if (-not $e.ContainsKey('dframe-local-slice')) { $e['dframe-local-slice'] = New-Dict }
      $e['dframe-local-slice'][$k.Substring(6)] = $subset[$k].psobject.BaseObject
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
  Set-SubsetKeep (Get-CfgPath $i) $p; Remove-Item $f -Force
}

# Membership of "pinned" is not decided by a config file: the app writes isStarred into each session file (mirrored between windows),
# so the pinned set is derived from those flags; only the ORDER and the other keys follow the "last changed window wins" rule.
$script:StarCache = @{}
function Get-FlaggedStars {
  $best = @{}
  foreach ($f in Get-SessionFolders) {
    foreach ($kv in ([ShellProp]::Index($f.Path)).GetEnumerator()) {
      if (-not $best.ContainsKey($kv.Key) -or $kv.Value -gt $best[$kv.Key].t) { $best[$kv.Key] = @{ p = [IO.Path]::Combine($f.Path, $kv.Key); t = $kv.Value } }
    }
  }
  $out = [Collections.ArrayList]::new()
  foreach ($k in ($best.Keys | Sort-Object)) {
    $e = $best[$k]; $c = $script:StarCache[$e.p]
    if (-not $c -or $c.t -ne $e.t) {
      $txt = [IO.File]::ReadAllText($e.p)
      $c = @{ t = $e.t; star = ($txt -match '"isStarred":true' -and $txt -notmatch '"isArchived":true') }; $script:StarCache[$e.p] = $c
    }
    if ($c.star) { [void]$out.Add([IO.Path]::GetFileNameWithoutExtension($k)) }
  }
  , $out
}
function Test-SubsetEmpty($sub) {
  (@($sub['starred-local-code-sessions']).Count -eq 0) -and (@($sub['slice:pinnedOrder']).Count -eq 0) -and (-not $sub.ContainsKey('mcpServers'))
}
function Update-SubsetFromFlags($sub, $flagged, $orderHint) {   # make starred list / pin order agree with the per-session flags
  if ($flagged.Count -eq 0) { return $sub }
  $set = New-Object 'Collections.Generic.HashSet[string]'; foreach ($x in $flagged) { [void]$set.Add($x) }
  $list = [Collections.ArrayList]::new(); $seen = New-Object 'Collections.Generic.HashSet[string]'
  foreach ($src in @($orderHint, @($sub['starred-local-code-sessions']), $flagged)) {
    foreach ($x in @($src)) { if ($x -and $set.Contains([string]$x) -and $seen.Add([string]$x)) { [void]$list.Add([string]$x) } }
  }
  $sub['starred-local-code-sessions'] = $list
  $po = [Collections.ArrayList]::new(); $inPo = New-Object 'Collections.Generic.HashSet[string]'
  foreach ($x in @($sub['slice:pinnedOrder'])) {
    $s = [string]$x
    if ($s.StartsWith('code:')) { if ($set.Contains($s.Substring(5)) -and $inPo.Add($s)) { [void]$po.Add($s) } } elseif ($s) { [void]$po.Add($s) }
  }
  foreach ($x in $list) { if ($inPo.Add("code:$x")) { [void]$po.Add("code:$x") } }
  $sub['slice:pinnedOrder'] = $po
  $sub
}
function Set-SubsetKeep($path, $subset) {   # never wipe: an empty list does not overwrite a non-empty one
  $cur = Get-SyncSubset (Read-CfgDict $path)
  foreach ($k in @($subset.Keys)) {
    if (($k -like 'starred-*' -or $k -like 'slice:*') -and @($subset[$k]).Count -eq 0 -and @($cur[$k]).Count -gt 0) { [void]$subset.Remove($k) }
  }
  Set-SyncSubset $path $subset
}

# One pass: find the window whose subset changed since the last agreed state and spread it to the others.
function Invoke-SettingsSync($cfg, $mains) {
  $all = @($cfg.instances); $running = @{}
  foreach ($m in $mains) { $x = Find-InstanceOf $m $all; if ($x) { $running[$x.id] = $true } }
  $flagged = Get-FlaggedStars
  $info = @{}
  foreach ($i in $all) {
    $path = Get-CfgPath $i; if (-not (Test-Path $path)) { continue }
    $raw = Get-SyncSubset (Read-CfgDict $path)
    $sub = Update-SubsetFromFlags $raw $flagged $null
    $info[$i.id] = @{ i = $i; sub = $sub; h = (Get-SubsetHash $sub); t = (Get-Item $path).LastWriteTimeUtc; empty = (Test-SubsetEmpty $raw) }
  }
  if ($info.Count -lt 2) { return }
  $snap = if (Test-Path $SetSnapFile) { (Get-Content $SetSnapFile -Raw).Trim() } else { $null }
  $cands = @($info.Values | Where-Object { -not $_.empty })           # a fresh/empty window must never win
  if ($cands.Count -eq 0) { return }
  $winner = $null
  if (-not $snap) {
    $distinct = @($info.Values | ForEach-Object { $_.h } | Sort-Object -Unique)
    if ($distinct.Count -le 1) { Write-Utf8 $SetSnapFile $distinct[0]; return }
    $winner = if ($info.ContainsKey('official') -and -not $info['official'].empty) { $info['official'] } else { $cands | Sort-Object { $_.t } -Descending | Select-Object -First 1 }
  } else {
    $changed = @($cands | Where-Object { $_.h -ne $snap -and -not (Test-PendingSettings $_.i.id) })
    if ($changed.Count -eq 0) {
      # nothing "changed" but some window may still lag behind the agreed state (e.g. a new window): bring it to the newest agreed subset
      $lag = @($info.Values | Where-Object { $_.h -ne $snap -and -not (Test-PendingSettings $_.i.id) })
      if ($lag.Count -eq 0) { return }
      $winner = $cands | Sort-Object { $_.t } -Descending | Select-Object -First 1
    } else { $winner = $changed | Sort-Object { $_.t } -Descending | Select-Object -First 1 }
  }
  $canon = Update-SubsetFromFlags $winner.sub $flagged $winner.sub['slice:pinnedOrder']
  $ch = Get-SubsetHash $canon
  foreach ($e in $info.Values) {
    if ($e.h -eq $ch) { continue }
    if ($running.ContainsKey($e.i.id)) { Save-PendingSettings $e.i.id $canon; $script:StaleSince[$e.i.id] = Get-Date }
    else { Set-SubsetKeep (Get-CfgPath $e.i) $canon }
  }
  Write-Utf8 $SetSnapFile $ch
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
function Show-ReloadToast($inst, [int]$count) {
  try {
    [void][Windows.UI.Notifications.ToastNotificationManager, Windows.UI.Notifications, ContentType = WindowsRuntime]
    [void][Windows.Data.Xml.Dom.XmlDocument, Windows.Data.Xml.Dom.XmlDocument, ContentType = WindowsRuntime]
    $uri = "claudemulti://restart/$($inst.id)"
    $title = [Security.SecurityElement]::Escape("$($inst.name): new sessions from your other windows")
    $body = [Security.SecurityElement]::Escape("$count session(s) are not loaded in this window yet. Reload restarts it (unsent drafts are lost).")
    $xml = New-Object Windows.Data.Xml.Dom.XmlDocument
    $xml.LoadXml("<toast launch='$uri' activationType='protocol'><visual><binding template='ToastGeneric'><text>$title</text><text>$body</text></binding></visual><actions><action content='Reload now' arguments='$uri' activationType='protocol'/></actions></toast>")
    $appId = '{1AC14E77-02E7-4E5D-B744-2EB1AE5198B7}\WindowsPowerShell\v1.0\powershell.exe'
    [Windows.UI.Notifications.ToastNotificationManager]::CreateToastNotifier($appId).Show([Windows.UI.Notifications.ToastNotification]::new($xml))
  } catch { Add-Content (Join-Path $StateDir 'agent.log') ("{0} reload toast failed: {1}" -f (Get-Date -Format s), $_) }
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
