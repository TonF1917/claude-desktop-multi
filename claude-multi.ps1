<#
.SYNOPSIS  Run the official Claude Desktop and any number of cc-switch-driven copies side by side (Windows).
.EXAMPLE   .\claude-multi.ps1 install
.EXAMPLE   .\claude-multi.ps1 add -Id gem -Name "Claude Gemini" -Palette gemini
.EXAMPLE   .\claude-multi.ps1 launch -Id 3p
#>
param(
  [Parameter(Position = 0)][ValidateSet('install', 'launch', 'list', 'add', 'remove', 'uninstall', 'icons')][string]$Command = 'list',
  [string]$Id, [string]$Name, [string]$Palette = 'violet', [string]$Profile,
  [switch]$Force
)
$ErrorActionPreference = 'Stop'
$Root          = $PSScriptRoot
$ConfigPath    = Join-Path $Root 'instances.json'
$IconDir       = Join-Path $env:LOCALAPPDATA 'ClaudeMulti\icons'
$OfficialAumid = 'AnthropicPBC.Claude_fnn82j28hfe8t!Claude'
$SourceDir     = Join-Path $env:LOCALAPPDATA 'Claude-3p'   # where the app (and cc-switch) keep the 3P config library
$OfficialDir   = Join-Path $env:APPDATA 'Claude'
$HomeRoot      = Join-Path $env:USERPROFILE '.claude-multi'  # one private fake %LOCALAPPDATA% per extra instance
$RealLocal     = $env:LOCALAPPDATA
. (Join-Path $Root 'src\Icon.ps1')
Add-Type -TypeDefinition (Get-Content (Join-Path $Root 'src\ShellProp.cs') -Raw) -Language CSharp

function Read-Config { Get-Content $ConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json }
function Write-Utf8($path, $text) { [IO.File]::WriteAllText($path, $text, (New-Object Text.UTF8Encoding $false)) }
function Save-Config($cfg) { Write-Utf8 $ConfigPath ($cfg | ConvertTo-Json -Depth 6) }
function Get-Palettes { Get-Content (Join-Path $Root 'palettes.json') -Raw -Encoding UTF8 | ConvertFrom-Json }
function Get-Instance($id) {
  $i = (Read-Config).instances | Where-Object id -eq $id
  if (-not $i) { throw "No instance '$id' in instances.json" }
  $i
}
function Get-DataDir($i) {
  if ($i.kind -eq 'official') { return $OfficialDir }
  if ($i.id -eq '3p') { return $SourceDir }                      # the primary 3P instance keeps the stock location
  Join-Path $HomeRoot "$($i.id)\Local\Claude-3p"
}
function Get-FakeLocal($i) { Join-Path $HomeRoot "$($i.id)\Local" }
function Get-Aumid($i) { if ($i.kind -eq 'official') { $OfficialAumid } else { "ClaudeMulti.$($i.id)" } }
function Get-Shim($i) { "`"$env:WINDIR\System32\wscript.exe`" //B //Nologo `"$Root\run.vbs`" $($i.id)" }
function Get-IconPath($i) { Join-Path $IconDir "$($i.id).ico" }
function Get-DesktopLink($i) { Join-Path ([Environment]::GetFolderPath('Desktop')) ($i.name + '.lnk') }

function Get-Roots($data) {   # main processes of the instance that owns $data
  $needle = '--user-data-dir="' + $data + '"'
  Get-CimInstance Win32_Process -Filter "Name='Claude.exe'" |
    Where-Object { $_.CommandLine -and $_.CommandLine.Contains($needle) -and $_.CommandLine -notmatch '--type=' }
}

# The app (production build) ignores CLAUDE_USER_DATA_DIR but resolves its 3P data dir from %LOCALAPPDATA%.
# Pointing LOCALAPPDATA at a private folder therefore gives an instance its own 3P data dir and config library.
function Initialize-OfficialHome {   # official: private LOCALAPPDATA whose Claude-3p is empty -> can never be forced into 3P
  $h = Join-Path $HomeRoot 'official\Local'
  New-Item -ItemType Directory -Force (Join-Path $h 'Claude-3p') | Out-Null
  foreach ($n in 'Claude', 'Packages') {
    $real = Join-Path $RealLocal $n; $link = Join-Path $h $n
    if ((Test-Path $real) -and -not (Test-Path $link)) { & cmd.exe /c mklink /J "`"$link`"" "`"$real`"" | Out-Null }
  }
  $h
}

function Get-NewestWrite($dir) {
  if (-not (Test-Path $dir)) { return [datetime]::MinValue }
  $f = Get-ChildItem $dir -File | Sort-Object LastWriteTime -Descending | Select-Object -First 1
  if ($f) { $f.LastWriteTime } else { [datetime]::MinValue }
}

function Sync-Profile($i, $data) {   # give a non-primary instance its own copy of the profile
  $dst = Join-Path $data 'configLibrary'      # $data = <fake Local>\Claude-3p
  New-Item -ItemType Directory -Force $dst | Out-Null
  if ($i.profile) {                  # hand-written profile JSON (own gateway / provider)
    $src = [Environment]::ExpandEnvironmentVariables($i.profile)
    $pid_ = '00000000-0000-4000-8000-0000000000' + ('{0:D2}' -f ([Math]::Abs($i.id.GetHashCode()) % 100))
    Get-ChildItem $dst -File | Remove-Item -Force
    Copy-Item $src (Join-Path $dst "$pid_.json") -Force
    Write-Utf8 (Join-Path $dst '_meta.json') (@{ entries = @(@{ id = $pid_; name = $i.name }); appliedId = $pid_ } | ConvertTo-Json -Depth 4)
    return (Get-Item $src).LastWriteTime
  }
  $src = Join-Path $SourceDir 'configLibrary'
  if (-not (Test-Path $src)) { return [datetime]::MinValue }
  Get-ChildItem $dst -File | Remove-Item -Force
  Copy-Item "$src\*" $dst -Force
  Get-NewestWrite $src
}

function Invoke-Launch($i) {
  $pkg = Get-ClaudePackage
  $exe = Join-Path $pkg.InstallLocation 'app\Claude.exe'
  $data = Get-DataDir $i
  if ($i.kind -eq 'official') {
    if ($i.isolate -ne $false) { $env:LOCALAPPDATA = Initialize-OfficialHome }
    Start-Process $exe
    return
  }
  $primary = ($data -eq $SourceDir)
  $profileTime = if ($primary) { Get-NewestWrite (Join-Path $SourceDir 'configLibrary') }
                 else { $env:LOCALAPPDATA = Get-FakeLocal $i; New-Item -ItemType Directory -Force $data | Out-Null; Sync-Profile $i $data }
  # a running instance read its profile at start-up: restart it when cc-switch changed the profile since
  foreach ($r in Get-Roots $data) {
    if ($r.CreationDate -lt $profileTime) { & taskkill.exe /F /T /PID $r.ProcessId | Out-Null; Start-Sleep -Seconds 2 }
  }
  Start-Process $exe -ArgumentList "--user-data-dir=`"$data`""
  # own taskbar button + palette icon for every window of this instance (~2 min, then exit)
  $aumid = Get-Aumid $i; $ico = Get-IconPath $i; $shim = Get-Shim $i
  $deadline = (Get-Date).AddSeconds(120)
  while ((Get-Date) -lt $deadline) {
    foreach ($r in Get-Roots $data) {
      $p = Get-Process -Id $r.ProcessId -ErrorAction SilentlyContinue
      if ($p -and $p.MainWindowHandle -ne 0 -and [ShellProp]::GetWindowAumid($p.MainWindowHandle) -ne $aumid) {
        [void][ShellProp]::SetWindowIdentity($p.MainWindowHandle, $aumid, $shim, $ico, $i.name)
        [ShellProp]::SetWindowIcon($p.MainWindowHandle, $ico)
      }
    }
    Start-Sleep -Seconds 2
  }
}

function Update-Icons($instances) {
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
  $s.TargetPath = "$env:WINDIR\System32\wscript.exe"; $s.Arguments = "//B //Nologo `"$Root\run.vbs`" $($i.id)"
  $s.IconLocation = (Get-IconPath $i) + ',0'; $s.WorkingDirectory = $Root; $s.Description = $i.name
  $s.Save(); [ShellProp]::SetLinkAumid($path, (Get-Aumid $i))
  "shortcut: $path"
}
function Get-OfficialLinks {
  @("$env:APPDATA\Microsoft\Internet Explorer\Quick Launch\User Pinned\TaskBar\Claude.lnk",
    (Join-Path ([Environment]::GetFolderPath('Desktop')) 'Claude.lnk'),
    "$env:APPDATA\Microsoft\Windows\Start Menu\Programs\Claude.lnk",
    "$env:APPDATA\Microsoft\Windows\Start Menu\Programs\Anthropic\Claude.lnk")
}

switch ($Command) {
  'install' {
    $inst = (Read-Config).instances
    Update-Icons $inst
    foreach ($i in $inst) {
      if ($i.kind -eq 'official') {
        $links = @(Get-OfficialLinks | Where-Object { Test-Path $_ })
        if (-not $links) { $links = @(Join-Path ([Environment]::GetFolderPath('Desktop')) 'Claude.lnk') }
        foreach ($l in $links) { Set-Link $l $i }
      } else { Set-Link (Get-DesktopLink $i) $i }
    }
    "`nDone. Right-click a Desktop shortcut -> 'Pin to taskbar' (Windows does not let scripts pin)."
  }
  'launch' { Invoke-Launch (Get-Instance $Id) }
  'icons'  { Update-Icons (Read-Config).instances }
  'list' {
    $rows = foreach ($i in (Read-Config).instances) {
      $d = Get-DataDir $i; $run = @(Get-Roots $d | ForEach-Object ProcessId) -join ','
      [pscustomobject]@{ Id = $i.id; Name = $i.name; Kind = $i.kind; Palette = $i.palette; DataDir = $d; Running = $run }
    }
    $rows | Format-Table -AutoSize
  }
  'add' {
    if (-not $Id -or $Id -notmatch '^[A-Za-z0-9_-]+$') { throw '-Id is required (letters, digits, - _)' }
    $cfg = Read-Config
    if ($cfg.instances | Where-Object id -eq $Id) { throw "Instance '$Id' already exists" }
    $new = [ordered]@{ id = $Id; name = $(if ($Name) { $Name } else { "Claude $Id" }); kind = 'cc-switch'; palette = $Palette }
    if ($Profile) { $new.profile = $Profile }
    $cfg.instances = @($cfg.instances) + [pscustomobject]$new
    Save-Config $cfg
    "added '$Id'. Run: .\claude-multi.ps1 install"
  }
  'remove' {
    $cfg = Read-Config; $i = $cfg.instances | Where-Object id -eq $Id
    if (-not $i) { throw "No instance '$Id'" }
    if ($i.kind -eq 'official') { throw 'The official instance cannot be removed (use uninstall).' }
    $lnk = Get-DesktopLink $i
    if (Test-Path $lnk) { Remove-Item $lnk }
    $cfg.instances = @($cfg.instances | Where-Object id -ne $Id); Save-Config $cfg
    "removed '$Id' (its data dir $(Get-DataDir $i) was left untouched)"
  }
  'uninstall' {
    foreach ($i in (Read-Config).instances) {
      if ($i.kind -eq 'official') {   # point the official shortcuts back at the packaged app
        $ws = New-Object -ComObject WScript.Shell
        foreach ($l in @(Get-OfficialLinks | Where-Object { Test-Path $_ })) {
          $s = $ws.CreateShortcut($l); $s.TargetPath = "$env:WINDIR\explorer.exe"
          $s.Arguments = "shell:AppsFolder\$OfficialAumid"; $s.IconLocation = ''; $s.Save()
          [ShellProp]::SetLinkAumid($l, $OfficialAumid); "restored: $l"
        }
      } else {
        $lnk = Get-DesktopLink $i
        if (Test-Path $lnk) { Remove-Item $lnk; "removed: $lnk" }
      }
    }
  }
}
