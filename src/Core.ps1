# Shared logic for claude-multi (dot-sourced by claude-multi.ps1). Requires $Root to be set.
$ErrorActionPreference = 'Stop'
$script:RealLocal     = $env:LOCALAPPDATA                        # captured before any per-instance override
$script:ConfigPath    = Join-Path $Root 'instances.json'
$script:HomeRoot      = Join-Path $env:USERPROFILE '.claude-multi'   # state, icons and one private fake %LOCALAPPDATA% per extra instance
$script:StateDir      = $HomeRoot                                  # NB: not under AppData\*\ClaudeMulti - Explorer cannot load icons from there
$script:IconDir       = Join-Path $StateDir 'icons'
$script:StatePath     = Join-Path $StateDir 'state.json'
$script:SourceDir     = Join-Path $RealLocal 'Claude-3p'         # where the app (and cc-switch) keep the 3P config library
$script:OfficialDir   = Join-Path $env:APPDATA 'Claude'
$script:OfficialAumid = 'AnthropicPBC.Claude_fnn82j28hfe8t!Claude'
$script:PinDir        = Join-Path $env:APPDATA 'Microsoft\Internet Explorer\Quick Launch\User Pinned\TaskBar'
$script:Wscript       = Join-Path $env:WINDIR 'System32\wscript.exe'

. (Join-Path $Root 'src\Icon.ps1')
. (Join-Path $Root 'src\CcSwitch.ps1')
if (-not ('ShellProp' -as [type])) { Add-Type -TypeDefinition (Get-Content (Join-Path $Root 'src\ShellProp.cs') -Raw) -Language CSharp }

# ---------------------------------------------------------------- config / state
function Write-Utf8($path, $text) { [IO.File]::WriteAllText($path, $text, (New-Object Text.UTF8Encoding $false)) }
function Read-Config {
  $c = Get-Content $ConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json
  if (-not $c.PSObject.Properties['settings']) { $c | Add-Member settings ([pscustomobject]@{}) }
  if (-not $c.settings.PSObject.Properties['syncSessions']) { $c.settings | Add-Member syncSessions $true }
  if (-not $c.settings.PSObject.Properties['protocol'])     { $c.settings | Add-Member protocol 'last' }
  if (-not $c.settings.PSObject.Properties['liveRefresh'])    { $c.settings | Add-Member liveRefresh $true }
  if (-not $c.settings.PSObject.Properties['refreshOfficial']) { $c.settings | Add-Member refreshOfficial $false }
  $c
}
function Save-Config($cfg) { Write-Utf8 $ConfigPath ($cfg | ConvertTo-Json -Depth 8) }
function Set-Prop($obj, $name, $value) {
  if ($obj.PSObject.Properties[$name]) { $obj.$name = $value } else { $obj | Add-Member $name $value }
}
function Get-Palettes { Get-Content (Join-Path $Root 'palettes.json') -Raw -Encoding UTF8 | ConvertFrom-Json }
function Get-Instance($id) {
  $i = (Read-Config).instances | Where-Object id -eq $id
  if (-not $i) { throw "No instance '$id' in instances.json" }
  $i
}
function Read-State { try { Get-Content $StatePath -Raw | ConvertFrom-Json } catch { [pscustomobject]@{ lastActive = '' } } }
function Save-State($s) { New-Item -ItemType Directory -Force $StateDir | Out-Null; Write-Utf8 $StatePath ($s | ConvertTo-Json) }

# ---------------------------------------------------------------- instance paths
function Get-DataDir($i) {          # the Claude userData directory of an instance
  if ($i.kind -eq 'official') { return $OfficialDir }
  if ($i.id -eq '3p') { return $SourceDir }                      # the primary 3P instance keeps the stock location
  Join-Path $HomeRoot "$($i.id)\Local\Claude-3p"
}
function Get-FakeLocal($i) { Join-Path $HomeRoot "$($i.id)\Local" }
function Get-Aumid($i) { if ($i.kind -eq 'official') { $OfficialAumid } else { "ClaudeMulti.$($i.id)" } }
function Get-IconPath($i) { Join-Path $IconDir "$($i.id).ico" }
function Get-DesktopLink($i) { Join-Path ([Environment]::GetFolderPath('Desktop')) ($i.name + '.lnk') }
function Get-Shim($i) { "`"$Wscript`" //B //Nologo `"$Root\run.vbs`" $($i.id)" }

# ---------------------------------------------------------------- processes
function Get-ClaudeMains {          # every Claude Desktop main process (not helpers, not the Claude Code CLI)
  Get-CimInstance Win32_Process -Filter "Name='Claude.exe'" | Where-Object {
    $_.ExecutablePath -and $_.ExecutablePath -like '*\AnthropicPBC.Claude_*' -and $_.CommandLine -and $_.CommandLine -notmatch '--type='
  }
}
function Find-InstanceOf($proc, $instances) {
  foreach ($i in $instances) {
    if ($i.kind -eq 'official') { continue }
    if ($proc.CommandLine.Contains('--user-data-dir="' + (Get-DataDir $i) + '"')) { return $i }
  }
  if ($proc.CommandLine -notmatch '--user-data-dir') { return ($instances | Where-Object kind -eq 'official' | Select-Object -First 1) }
}
function Get-Roots($i) {
  $all = @((Read-Config).instances)
  Get-ClaudeMains | Where-Object { $x = Find-InstanceOf $_ $all; $x -and $x.id -eq $i.id }
}

# ---------------------------------------------------------------- profiles (what makes an instance 3P)
function Get-NewestWrite($dir) {
  if (-not (Test-Path $dir)) { return [datetime]::MinValue }
  $f = Get-ChildItem $dir -File | Sort-Object LastWriteTime -Descending | Select-Object -First 1
  if ($f) { $f.LastWriteTime } else { [datetime]::MinValue }
}
function Write-Profile($dst, $id, $name, $profileObj) {
  New-Item -ItemType Directory -Force $dst | Out-Null
  Get-ChildItem $dst -File | Remove-Item -Force
  Write-Utf8 (Join-Path $dst "$id.json") ($profileObj | ConvertTo-Json -Depth 8)
  Write-Utf8 (Join-Path $dst '_meta.json') (@{ entries = @(@{ id = $id; name = $name }); appliedId = $id } | ConvertTo-Json -Depth 4)
}
function Sync-Profile($i, $data) {   # give a non-primary instance its own copy of its profile; returns the profile's timestamp
  $dst = Join-Path $data 'configLibrary'
  $uid = '00000000-0000-4000-8000-0000000000' + ('{0:D2}' -f ([Math]::Abs($i.id.GetHashCode()) % 100))
  if ($i.profile) {                  # hand-written profile JSON
    $src = [Environment]::ExpandEnvironmentVariables($i.profile)
    Write-Profile $dst $uid $i.name (Get-Content $src -Raw | ConvertFrom-Json)
    return (Get-Item $src).LastWriteTime
  }
  if ($i.provider) {                 # direct profile built from one cc-switch provider (own upstream, no shared gateway)
    $json = (New-DirectProfile $i.provider) | ConvertTo-Json -Depth 8
    $file = Join-Path $dst "$uid.json"
    if ((Test-Path $file) -and ((Get-Content $file -Raw) -eq $json)) { return (Get-Item $file).LastWriteTime }
    Write-Profile $dst $uid $i.name ($json | ConvertFrom-Json)
    return (Get-Date)
  }
  $src = Join-Path $SourceDir 'configLibrary'      # follow cc-switch's current selection
  if (-not (Test-Path $src)) { return [datetime]::MinValue }
  Get-ChildItem $dst -File -ErrorAction SilentlyContinue | Remove-Item -Force
  New-Item -ItemType Directory -Force $dst | Out-Null
  Copy-Item "$src\*" $dst -Force
  Get-NewestWrite $src
}

# the official app must never read a cc-switch profile: give it a private LOCALAPPDATA whose Claude-3p is empty
function Initialize-OfficialHome {
  $h = Join-Path $HomeRoot 'official\Local'
  New-Item -ItemType Directory -Force (Join-Path $h 'Claude-3p') | Out-Null
  foreach ($n in 'Claude', 'Packages') {
    $real = Join-Path $RealLocal $n; $link = Join-Path $h $n
    if ((Test-Path $real) -and -not (Test-Path $link)) { & cmd.exe /c mklink /J "`"$link`"" "`"$real`"" | Out-Null }
  }
  $h
}

# ---------------------------------------------------------------- launching
function Test-AgentRunning { $m = $null; if ([Threading.Mutex]::TryOpenExisting('Local\ClaudeMultiAgent', [ref]$m)) { $m.Dispose(); $true } else { $false } }
function Start-Agent {
  if (Test-AgentRunning) { return }
  Start-Process powershell.exe -WindowStyle Hidden -ArgumentList '-NoProfile', '-ExecutionPolicy', 'Bypass', '-WindowStyle', 'Hidden', '-File', "`"$Root\claude-multi.ps1`"", 'agent'
}

function Invoke-Launch($i, [string]$Url, [switch]$NoAgent) {
  $pkg = Get-ClaudePackage
  $exe = Join-Path $pkg.InstallLocation 'app\Claude.exe'
  $data = Get-DataDir $i
  $args_ = @()
  if ($Url) { $args_ += "`"$Url`"" }
  try {
    if ($i.kind -eq 'official') {
      if ($i.isolate -ne $false) { $env:LOCALAPPDATA = Initialize-OfficialHome }
    } else {
      $primary = ($data -eq $SourceDir)
      $profileTime = if ($primary) { Get-NewestWrite (Join-Path $SourceDir 'configLibrary') }
                     else { $env:LOCALAPPDATA = Get-FakeLocal $i; New-Item -ItemType Directory -Force $data | Out-Null; Sync-Profile $i $data }
      # a running instance read its profile at start-up: restart it when the profile changed since
      foreach ($r in Get-Roots $i) {
        if ($r.CreationDate -lt $profileTime) { & taskkill.exe /F /T /PID $r.ProcessId | Out-Null; Start-Sleep -Seconds 2 }
      }
      $args_ = @("--user-data-dir=`"$data`"") + $args_
    }
    if ($args_.Count) { Start-Process $exe -ArgumentList $args_ } else { Start-Process $exe }
  } finally { $env:LOCALAPPDATA = $RealLocal }
  if (-not $NoAgent) { Start-Agent }
}

# ---------------------------------------------------------------- icons & shortcuts
function Update-Icons($instances, [switch]$Force) {
  $pkg = Get-ClaudePackage; $pal = Get-Palettes; $base = $null
  foreach ($i in $instances) {
    $path = Get-IconPath $i
    if ((Test-Path $path) -and -not $Force) { continue }
    if (-not $base) { $base = Get-IconBase $pkg }
    if ($i.kind -eq 'official' -or $i.palette -eq 'official') { Save-Ico $base $path }
    else { Save-Ico (Convert-IconBase $base (Resolve-Palette $i.palette $pal)) $path }
    "icon: $path"
  }
}
function Set-Link($path, $i) {
  $s = (New-Object -ComObject WScript.Shell).CreateShortcut($path)
  $s.TargetPath = $Wscript; $s.Arguments = "//B //Nologo `"$Root\run.vbs`" $($i.id)"
  $s.IconLocation = (Get-IconPath $i) + ',0'; $s.WorkingDirectory = $Root; $s.Description = $i.name
  $s.Save(); [ShellProp]::SetLinkAumid($path, (Get-Aumid $i))
  "shortcut: $path"
}
function Get-LegacyNames($i) { if ($i.id -eq '3p') { @('Claude (3P)') } else { @() } }
function Update-PinnedLinks($i) {   # rewire already-pinned taskbar shortcuts so the pin and the windows share one button
  foreach ($n in @($i.name) + (Get-LegacyNames $i)) { $l = Join-Path $PinDir "$n.lnk"; if (Test-Path $l) { Set-Link $l $i } }
}
function Get-OfficialLinks {
  @((Join-Path $PinDir 'Claude.lnk'),
    (Join-Path ([Environment]::GetFolderPath('Desktop')) 'Claude.lnk'),
    "$env:APPDATA\Microsoft\Windows\Start Menu\Programs\Claude.lnk",
    "$env:APPDATA\Microsoft\Windows\Start Menu\Programs\Anthropic\Claude.lnk")
}
function Install-All([switch]$Force) {
  $inst = @((Read-Config).instances)
  Update-Icons $inst -Force:$Force
  foreach ($i in $inst) {
    if ($i.kind -eq 'official') {
      $links = @(Get-OfficialLinks | Where-Object { Test-Path $_ })
      if (-not $links) { $links = @(Join-Path ([Environment]::GetFolderPath('Desktop')) 'Claude.lnk') }
      foreach ($l in $links) { Set-Link $l $i }
    } else { Set-Link (Get-DesktopLink $i) $i; Update-PinnedLinks $i }
  }
  # manager (GUI) shortcut
  $mi = [pscustomobject]@{ id = 'manager'; name = 'Claude Multi Manager'; kind = 'tool'; palette = 'violet' }
  Update-Icons @($mi) -Force:$Force
  $ml = Join-Path ([Environment]::GetFolderPath('Desktop')) ($mi.name + '.lnk')
  $s = (New-Object -ComObject WScript.Shell).CreateShortcut($ml)
  $s.TargetPath = $Wscript; $s.Arguments = "//B //Nologo `"$Root\run.vbs`" --gui"
  $s.IconLocation = (Get-IconPath $mi) + ',0'; $s.WorkingDirectory = $Root; $s.Description = $mi.name; $s.Save()
  "shortcut: $ml"
  Register-Protocol
  & ie4uinit.exe -show 2>$null
}

# ---------------------------------------------------------------- claude:// routing
function Register-Protocol {
  foreach ($s in 'claude') {
    $k = "HKCU:\Software\Classes\$s"
    $cmd = "`"$Wscript`" //B //Nologo `"$Root\run.vbs`" --url `"%1`""
    $cur = try { (Get-ItemProperty "$k\shell\open\command" -ErrorAction Stop).'(default)' } catch { '' }
    if ($cur -eq $cmd) { continue }
    New-Item "$k\shell\open\command" -Force | Out-Null
    Set-ItemProperty $k -Name '(default)' -Value 'URL:Claude'
    Set-ItemProperty $k -Name 'URL Protocol' -Value ''
    Set-ItemProperty "$k\shell\open\command" -Name '(default)' -Value $cmd
  }
}
function Invoke-RouteUrl([string]$Url) {
  if ($Url -notmatch '^claude(-desktop)?://[^\s"]+$') { throw 'Refusing non-claude URL' }
  $cfg = Read-Config; $all = @($cfg.instances)
  $running = @(Get-ClaudeMains | ForEach-Object { Find-InstanceOf $_ $all } | Where-Object { $_ })
  $want = $cfg.settings.protocol
  if ($want -eq 'last') { $want = (Read-State).lastActive }
  $target = $all | Where-Object { $_.id -eq $want } | Select-Object -First 1
  if (-not $target) { $target = $running | Select-Object -First 1 }
  if (-not $target) { $target = $all | Where-Object kind -eq 'official' | Select-Object -First 1 }
  New-Item -ItemType Directory -Force $StateDir | Out-Null
  Add-Content (Join-Path $StateDir 'route.log') ('{0} -> {1} (want={2}, running={3})' -f (Get-Date -Format s), $target.id, $want, (($running | ForEach-Object id) -join ','))
  Invoke-Launch $target $Url
}

# ---------------------------------------------------------------- session sync
# The app reads its session list only at start-up (no file watcher, no reload hook), so keeping instances in sync takes two steps:
#  1) mirror every session file newest-wins into every instance's store (this section), and
#  2) silently restart a stale instance in the background when it is idle and not in use (Invoke-LiveRefresh below).
$script:CopiedStamp = @{}       # destination path -> mtime ticks we wrote (lets us tell our copies from the app's own writes)
$script:StaleSince  = @{}       # instance id -> time of the last file mirrored into its store
$script:LastRestart = @{}
$script:Cpu         = @{}

function Get-StoreRoot($i) { Get-DataDir $i }
function Get-SessionFolders {
  foreach ($i in (Read-Config).instances) {
    $cs = Join-Path (Get-StoreRoot $i) 'claude-code-sessions'
    if (-not (Test-Path $cs)) { continue }
    foreach ($a in [IO.Directory]::GetDirectories($cs)) { foreach ($o in [IO.Directory]::GetDirectories($a)) { if ($o -notmatch '-backup$') { [pscustomobject]@{ Path = $o; Id = $i.id } } } }
  }
}
function Backup-Sessions {
  $flag = Join-Path $StateDir 'sessions-backed-up'
  if (Test-Path $flag) { return }
  $dst = Join-Path $StateDir ('backup-sessions\' + (Get-Date -Format yyyyMMdd-HHmmss)); $n = 0
  foreach ($i in (Read-Config).instances) {
    $cs = Join-Path (Get-StoreRoot $i) 'claude-code-sessions'
    if (Test-Path $cs) { robocopy $cs (Join-Path $dst ('s' + $n++)) /E /NFL /NDL /NJH /NJS /NP | Out-Null }
  }
  New-Item -ItemType File -Force $flag | Out-Null
}
# Newest-wins mirror of every session file into every account/org folder of every instance (never deletes).
function Invoke-SessionSync {
  $folders = @(Get-SessionFolders)
  if ($folders.Count -lt 2) { return 0 }
  $best = @{}
  foreach ($f in $folders) {
    foreach ($p in [IO.Directory]::EnumerateFiles($f.Path, 'local_*.json')) {
      $fi = New-Object IO.FileInfo $p; $n = $fi.Name
      if (-not $best.ContainsKey($n) -or $fi.LastWriteTimeUtc -gt $best[$n].t) { $best[$n] = @{ p = $p; t = $fi.LastWriteTimeUtc } }
    }
  }
  $copied = 0
  foreach ($f in $folders) {
    foreach ($n in $best.Keys) {
      $dst = [IO.Path]::Combine($f.Path, $n); $b = $best[$n]
      $isNew = -not [IO.File]::Exists($dst)
      $need = $isNew -or ([IO.File]::GetLastWriteTimeUtc($dst) -lt $b.t.AddSeconds(-1))
      if ($need -and $dst -ne $b.p) {
        try {
          [IO.File]::Copy($b.p, $dst, $true); [IO.File]::SetLastWriteTimeUtc($dst, $b.t)
          $script:CopiedStamp[$dst] = [IO.File]::GetLastWriteTimeUtc($dst).Ticks
          if ($isNew) { $script:StaleSince[$f.Id] = Get-Date }     # only a session the instance has never seen makes it stale (updates to known ones do not)
          $copied++
        } catch { }
      }
    }
  }
  $copied
}
function Initialize-SessionStores {   # new instances start with the same session folders as the primary 3P store
  $src = Join-Path $SourceDir 'claude-code-sessions'
  if (-not (Test-Path $src)) { return }
  foreach ($i in (Read-Config).instances) {
    if ($i.kind -eq 'official' -or $i.id -eq '3p') { continue }
    $dst = Join-Path (Get-StoreRoot $i) 'claude-code-sessions'
    foreach ($a in [IO.Directory]::GetDirectories($src)) { foreach ($o in [IO.Directory]::GetDirectories($a)) {
      if ($o -notmatch '-backup$') { New-Item -ItemType Directory -Force (Join-Path (Join-Path $dst (Split-Path $a -Leaf)) (Split-Path $o -Leaf)) | Out-Null } } }
  }
}

# ---------------------------------------------------------------- live refresh (silent background restart of stale, idle instances)
function Get-Descendants([int]$rootPid, $procs) {
  $kids = @{}
  foreach ($p in $procs) { $k = [int]$p.ParentProcessId; if (-not $kids.ContainsKey($k)) { $kids[$k] = New-Object Collections.ArrayList }; [void]$kids[$k].Add($p) }
  $out = New-Object Collections.ArrayList; $q = New-Object Collections.Queue; $q.Enqueue($rootPid)
  while ($q.Count) { $x = $q.Dequeue(); if ($kids.ContainsKey($x)) { foreach ($c in $kids[$x]) { [void]$out.Add($c); $q.Enqueue([int]$c.ProcessId) } } }
  $out
}
function Test-InstanceBusy($i, $rootProc, $procs) {
  # 1) the app itself rewrote a session file in the last 45 s (a file we did not just mirror)
  $now = [datetime]::UtcNow
  $cs = Join-Path (Get-StoreRoot $i) 'claude-code-sessions'
  if (Test-Path $cs) {
    foreach ($f in [IO.Directory]::EnumerateFiles($cs, 'local_*.json', [IO.SearchOption]::AllDirectories)) {
      $t = [IO.File]::GetLastWriteTimeUtc($f)
      if (($now - $t).TotalSeconds -lt 45 -and $script:CopiedStamp[$f] -ne $t.Ticks) { return $true }
    }
  }
  # 2) a non-Electron child (agent CLI, build tool, ...) burned CPU since the previous check
  foreach ($c in (Get-Descendants $rootProc.ProcessId $procs)) {
    if ($c.ExecutablePath -and $c.ExecutablePath -like '*\AnthropicPBC.Claude_*') { continue }
    try {
      $cpu = [Diagnostics.Process]::GetProcessById([int]$c.ProcessId).TotalProcessorTime.TotalSeconds
      $prev = $script:Cpu[[int]$c.ProcessId]; $script:Cpu[[int]$c.ProcessId] = $cpu
      if ($null -ne $prev -and ($cpu - $prev) -gt 0.5) { return $true }
    } catch { }
  }
  $false
}
function Invoke-LiveRefresh($cfg, $mains, [uint32]$fgPid, $focusFix) {
  if (-not $cfg.settings.liveRefresh) { return }
  $all = @($cfg.instances); $procs = $null
  foreach ($m in $mains) {
    $i = Find-InstanceOf $m $all; if (-not $i) { continue }
    if ($i.kind -eq 'official' -and -not $cfg.settings.refreshOfficial) { continue }
    $since = $script:StaleSince[$i.id]; if (-not $since) { continue }
    if (((Get-Date) - $since).TotalSeconds -lt 8) { continue }                         # let the other instance finish writing
    if ($m.ProcessId -eq $fgPid) { continue }                                         # never touch the window in use
    $last = $script:LastRestart[$i.id]; if ($last -and ((Get-Date) - $last).TotalSeconds -lt 120) { continue }
    if (-not $procs) { $procs = @(Get-CimInstance Win32_Process) }
    if (Test-InstanceBusy $i $m $procs) { continue }
    $prev = [ShellProp]::ForegroundWindow()
    & taskkill.exe /F /T /PID $m.ProcessId | Out-Null; Start-Sleep -Seconds 2
    $script:StaleSince.Remove($i.id); $script:LastRestart[$i.id] = Get-Date
    Invoke-Launch $i -NoAgent
    $focusFix[$i.id] = @{ prev = $prev; until = (Get-Date).AddSeconds(90) }
    return                                                                            # one restart per cycle
  }
}

# ---------------------------------------------------------------- background agent
function Invoke-Agent {
  $created = $false
  $mutex = New-Object Threading.Mutex($true, 'Local\ClaudeMultiAgent', [ref]$created)
  if (-not $created) { return }
  try {
    $idleSince = $null; $tick = 0; $applied = @{}; $focusFix = @{}
    while ($true) {
      $cfg = Read-Config; $all = @($cfg.instances)
      $mains = @(Get-ClaudeMains)
      $fg = [ShellProp]::ForegroundPid()
      foreach ($m in $mains) {
        $i = Find-InstanceOf $m $all; if (-not $i) { continue }
        $p = Get-Process -Id $m.ProcessId -ErrorAction SilentlyContinue
        if (-not $p -or $p.MainWindowHandle -eq 0) { continue }
        if ($i.kind -ne 'official') {   # own taskbar button + icon (re-applied when the icon file changes)
          $ico = Get-IconPath $i; $stamp = if (Test-Path $ico) { (Get-Item $ico).LastWriteTimeUtc.Ticks } else { 0 }
          if ([ShellProp]::GetWindowAumid($p.MainWindowHandle) -ne (Get-Aumid $i) -or $applied[$m.ProcessId] -ne $stamp) {
            [void][ShellProp]::SetWindowIdentity($p.MainWindowHandle, (Get-Aumid $i), (Get-Shim $i), "$ico,0", $i.name)
            [ShellProp]::SetWindowIcon($p.MainWindowHandle, $ico); $applied[$m.ProcessId] = $stamp
          }
        }
        if ($focusFix.ContainsKey($i.id)) {   # a silently restarted instance must not steal focus
          $ff = $focusFix[$i.id]
          if ([ShellProp]::ForegroundPid() -eq $m.ProcessId -and $ff.prev -ne [IntPtr]::Zero) { [void][ShellProp]::Foreground($ff.prev); $focusFix.Remove($i.id) }
          elseif ((Get-Date) -gt $ff.until) { $focusFix.Remove($i.id) }
        }
        if ($m.ProcessId -eq $fg) { $s = Read-State; if ($s.lastActive -ne $i.id) { Save-State ([pscustomobject]@{ lastActive = $i.id }) } }
      }
      if ($tick % 3 -eq 0) {
        Register-Protocol
        if ($cfg.settings.syncSessions -and $mains.Count -gt 0) {
          try { Backup-Sessions; Initialize-SessionStores; [void](Invoke-SessionSync); Invoke-LiveRefresh $cfg $mains $fg $focusFix } catch { Add-Content (Join-Path $StateDir 'agent.log') ("{0} {1}" -f (Get-Date -Format s), $_) }
        }
      }
      if ($mains.Count -eq 0) { if (-not $idleSince) { $idleSince = Get-Date } elseif (((Get-Date) - $idleSince).TotalSeconds -gt 90) { break } } else { $idleSince = $null }
      $tick++; Start-Sleep -Seconds 2
    }
  } finally { $mutex.ReleaseMutex(); $mutex.Dispose() }
}
