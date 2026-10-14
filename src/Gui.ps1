# WinForms manager: how many instances, which provider and colour each one uses, launch / apply / sync.
Add-Type -AssemblyName System.Windows.Forms, System.Drawing
if (-not ('Dpi' -as [type])) { Add-Type -MemberDefinition '[DllImport("user32.dll")] public static extern bool SetProcessDPIAware();' -Name Dpi -Namespace Win32 }

function Show-Manager {
  [void][Win32.Dpi]::SetProcessDPIAware()
  [Windows.Forms.Application]::EnableVisualStyles()
  $zh = ((Read-Config).settings.language -eq 'zh')
  function L($zhText, $enText) { if ($zh) { $zhText } else { $enText } }
  $fams = (New-Object Drawing.Text.InstalledFontCollection).Families.Name
  $fam = (@('Noto Serif SC', 'Source Han Serif SC', '思源宋体', 'Georgia', 'SimSun') | Where-Object { $fams -contains $_ } | Select-Object -First 1)
  if (-not $fam) { $fam = 'Times New Roman' }
  $font = New-Object Drawing.Font($fam, 10)

  $cfg = Read-Config
  $pal = Get-Palettes
  $palNames = @($pal.PSObject.Properties.Name)
  $providers = @(Get-CcProviders)
  $snapshot = @{}; foreach ($i in $cfg.instances) { $snapshot[$i.id] = [string]$i.palette }
  $baseBmp = $null; $iconCache = @{}

  $form = New-Object Windows.Forms.Form
  $form.Text = L 'Claude 多开管理器' 'Claude Multi Manager'
  $form.Font = $font; $form.StartPosition = 'CenterScreen'; $form.ClientSize = New-Object Drawing.Size(1200, 790)
  $form.MinimumSize = New-Object Drawing.Size(1000, 600)

  # ---- grid
  $grid = New-Object Windows.Forms.DataGridView
  $grid.Location = '12,12'; $grid.Size = '830,470'; $grid.ColumnHeadersHeightSizeMode = 'DisableResizing'; $grid.ColumnHeadersHeight = 36; $grid.Anchor = 'Top,Left,Bottom,Right'
  $grid.AllowUserToAddRows = $false; $grid.AllowUserToDeleteRows = $false; $grid.RowHeadersVisible = $false
  $grid.SelectionMode = 'FullRowSelect'; $grid.MultiSelect = $false; $grid.AutoSizeColumnsMode = 'Fill'; $grid.BackgroundColor = 'White'
  $grid.RowTemplate.Height = 30; $grid.EditMode = 'EditOnEnter'
  $cName = New-Object Windows.Forms.DataGridViewTextBoxColumn; $cName.HeaderText = L '名称' 'Name'; $cName.Name = 'name'; $cName.FillWeight = 22
  $cId = New-Object Windows.Forms.DataGridViewTextBoxColumn; $cId.HeaderText = 'ID'; $cId.Name = 'id'; $cId.ReadOnly = $true; $cId.FillWeight = 10
  $cProv = New-Object Windows.Forms.DataGridViewComboBoxColumn; $cProv.HeaderText = L '供应商' 'Provider'; $cProv.Name = 'provider'; $cProv.FillWeight = 34
  $cProv.FlatStyle = 'Flat'
  $provText = [ordered]@{ '__official' = (L '官方订阅' 'Official subscription'); '' = (L '跟随 cc-switch 当前选择' 'Follow cc-switch selection') }
  $provFmt = @{}
  foreach ($p in $providers) {
    $fmt = [string]$p.meta.apiFormat; $provFmt[[string]$p.id] = $fmt
    $suffix = if ($fmt -and $fmt -ne 'anthropic') { L '  (需经 cc-switch 网关)' '  (needs the cc-switch gateway)' } else { L '  (直连上游)' '  (direct)' }
    $provText[[string]$p.id] = ($p.name + $suffix)
  }
  foreach ($k in $provText.Keys) { [void]$cProv.Items.Add($provText[$k]) }
  function Get-ProvId([string]$text) { foreach ($k in $provText.Keys) { if ($provText[$k] -eq $text) { return [string]$k } }; '' }
  $cPal = New-Object Windows.Forms.DataGridViewTextBoxColumn; $cPal.HeaderText = L '配色' 'Palette'; $cPal.Name = 'palette'; $cPal.ReadOnly = $true; $cPal.FillWeight = 16
  $cPick = New-Object Windows.Forms.DataGridViewButtonColumn; $cPick.HeaderText = ''; $cPick.Name = 'pick'; $cPick.Text = '…'; $cPick.UseColumnTextForButtonValue = $true; $cPick.FillWeight = 6
  $cStat = New-Object Windows.Forms.DataGridViewTextBoxColumn; $cStat.HeaderText = L '状态' 'Status'; $cStat.Name = 'status'; $cStat.ReadOnly = $true; $cStat.FillWeight = 14
  foreach ($col in @($cName, $cId, $cProv, $cPal, $cPick, $cStat)) { [void]$grid.Columns.Add($col) }

  function Get-Swatch($spec) {
    if ($spec -eq 'official') { return [Drawing.Color]::FromArgb(217, 119, 87) }
    $p = Resolve-Palette $spec $pal; $v = ($p.vMin + $p.vMax) / 2
    $rgb = ConvertFrom-Hsv $p.hue $p.sat $v
    [Drawing.Color]::FromArgb([int]($rgb[0] * 255), [int]($rgb[1] * 255), [int]($rgb[2] * 255))
  }
  function Set-PaletteCell($row, $spec) {
    $row.Cells['palette'].Value = $spec
    $c = Get-Swatch $spec
    $row.Cells['palette'].Style.BackColor = $c; $row.Cells['palette'].Style.SelectionBackColor = $c
    $lum = 0.3 * $c.R + 0.59 * $c.G + 0.11 * $c.B
    $fc = if ($lum -gt 140) { [Drawing.Color]::Black } else { [Drawing.Color]::White }
    $row.Cells['palette'].Style.ForeColor = $fc; $row.Cells['palette'].Style.SelectionForeColor = $fc
  }
  function Add-InstanceRow($i) {
    $idx = $grid.Rows.Add()
    $r = $grid.Rows[$idx]
    $r.Cells['name'].Value = $i.name; $r.Cells['id'].Value = $i.id
    if ($i.kind -eq 'official') {
      $r.Cells['provider'].Value = $provText['__official']; $r.Cells['provider'].ReadOnly = $true; $r.Cells['pick'].ReadOnly = $true
      Set-PaletteCell $r 'official'
    } else {
      $pid_ = $(if ($i.provider -and $provText.ContainsKey([string]$i.provider)) { [string]$i.provider } else { '' })
      $r.Cells['provider'].Value = $provText[$pid_]
      Set-PaletteCell $r ([string]$i.palette)
    }
  }
  foreach ($i in $cfg.instances) { Add-InstanceRow $i }
  $grid.Add_DataError({ param($s, $e) $e.ThrowException = $false })
  $grid.Add_CurrentCellDirtyStateChanged({ if ($grid.IsCurrentCellDirty) { $grid.CommitEdit('CurrentCellChange') } })
  $grid.Add_CellValueChanged({
    param($s, $e)
    if ($e.RowIndex -lt 0 -or $grid.Columns[$e.ColumnIndex].Name -ne 'provider') { return }
    $v = Get-ProvId ([string]$grid.Rows[$e.RowIndex].Cells['provider'].Value)
    if ($v -eq '__official' -and [string]$grid.Rows[$e.RowIndex].Cells['id'].Value -ne 'official') { $grid.Rows[$e.RowIndex].Cells['provider'].Value = $provText['']; return }
    if ($v -and $v -ne '__official' -and $provFmt[$v] -and $provFmt[$v] -ne 'anthropic') {
      [void][Windows.Forms.MessageBox]::Show((L '该供应商使用非 Anthropic 接口,必须经 cc-switch 网关,不能直连。已改回“跟随”。' 'This provider is not Anthropic-format and must go through the cc-switch gateway; reverted to "Follow".'))
      $grid.Rows[$e.RowIndex].Cells['provider'].Value = $provText['']
    }
  })

  # ---- preview
  $pic = New-Object Windows.Forms.PictureBox; $pic.Location = '860,12'; $pic.Size = '128,128'; $pic.SizeMode = 'Zoom'; $pic.Anchor = 'Top,Right'
  $picLabel = New-Object Windows.Forms.Label; $picLabel.Location = '1000,12'; $picLabel.Size = '180,60'; $picLabel.Anchor = 'Top,Right'; $picLabel.Text = L '图标预览' 'Icon preview'
  function Show-Preview {
    if ($grid.CurrentRow -eq $null) { return }
    $spec = [string]$grid.CurrentRow.Cells['palette'].Value
    if (-not $iconCache.ContainsKey($spec)) {
      $form.Cursor = 'WaitCursor'
      if (-not $script:baseBmp) { $script:baseBmp = Get-IconBase (Get-ClaudePackage) }
      $iconCache[$spec] = if ($spec -eq 'official') { $script:baseBmp } else { Convert-IconBase $script:baseBmp (Resolve-Palette $spec $pal) }
      $form.Cursor = 'Default'
    }
    $pic.Image = $iconCache[$spec]
  }
  $grid.Add_SelectionChanged({ Show-Preview })

  # ---- palette picker
  $menu = New-Object Windows.Forms.ContextMenuStrip
  $script:pickRow = $null
  $grid.Add_CellContentClick({
    param($s, $e)
    if ($e.RowIndex -lt 0 -or $grid.Columns[$e.ColumnIndex].Name -ne 'pick') { return }
    $script:pickRow = $grid.Rows[$e.RowIndex]
    $menu.Items.Clear()
    foreach ($n in $palNames) {
      $it = $menu.Items.Add($n); $it.Tag = $n
      $bm = New-Object Drawing.Bitmap 14, 14; $g = [Drawing.Graphics]::FromImage($bm); $g.Clear((Get-Swatch $n)); $g.Dispose(); $it.Image = $bm
    }
    $cu = $menu.Items.Add((L '自定义颜色…' 'Custom colour…')); $cu.Tag = '*custom'
    $pt = $grid.PointToClient([Windows.Forms.Cursor]::Position)
    $menu.Show($grid, $pt)
  })
  $menu.Add_ItemClicked({
    param($s, $e)
    $tag = [string]$e.ClickedItem.Tag
    if ($tag -eq '*custom') {
      $dlg = New-Object Windows.Forms.ColorDialog; $dlg.FullOpen = $true
      if ($dlg.ShowDialog() -ne 'OK') { return }
      $tag = '#{0:X2}{1:X2}{2:X2}' -f $dlg.Color.R, $dlg.Color.G, $dlg.Color.B
    }
    Set-PaletteCell $script:pickRow $tag; Show-Preview
  })

  # ---- buttons
  function Add-Btn($text, $x, $y, $w, $handler) {
    $b = New-Object Windows.Forms.Button; $b.Text = $text; $b.Location = New-Object Drawing.Point($x, $y); $b.Size = New-Object Drawing.Size($w, 32)
    $b.Anchor = 'Top,Right'; $b.Add_Click($handler); $form.Controls.Add($b); $b
  }
  function Read-GridConfig {          # grid -> config object (keeps official/primary kinds untouched)
    [void]$grid.EndEdit(); [void]$grid.CommitEdit('CurrentCellChange')
    $c = Read-Config
    foreach ($row in $grid.Rows) {
      $i = $c.instances | Where-Object id -eq ([string]$row.Cells['id'].Value)
      if (-not $i) { continue }
      Set-Prop $i 'name' ([string]$row.Cells['name'].Value)
      if ($i.kind -ne 'official') {
        Set-Prop $i 'palette' ([string]$row.Cells['palette'].Value)
        $pv = Get-ProvId ([string]$row.Cells['provider'].Value)
        if ($pv) { Set-Prop $i 'provider' $pv } elseif ($i.PSObject.Properties['provider']) { $i.PSObject.Properties.Remove('provider') }
      }
    }
    $c.settings.syncSessions = $chkSync.Checked
    $c.settings.syncSettings = $chkSet.Checked
    $c.settings.liveRefresh = $chkLive.Checked
    $c.settings.refreshOfficial = $chkOff.Checked
    $c.settings.protocol = $(if ($cmbProto.SelectedIndex -ge 0 -and $cmbProto.SelectedIndex -lt $protoIds.Count) { $protoIds[$cmbProto.SelectedIndex] } else { 'last' })
    $c
  }

  $numAdd = New-Object Windows.Forms.NumericUpDown; $numAdd.Location = '860,160'; $numAdd.Size = '60,28'; $numAdd.Minimum = 1; $numAdd.Maximum = 20; $numAdd.Value = 1; $numAdd.Anchor = 'Top,Right'
  $form.Controls.Add($numAdd)
  $null = Add-Btn (L '添加实例' 'Add instances') 926 158 254 {
    $c = Read-Config
    for ($k = 0; $k -lt [int]$numAdd.Value; $k++) {
      $n = 2; while ($c.instances | Where-Object id -eq "x$n") { $n++ }
      $used = @($c.instances | ForEach-Object { [string]$_.palette })
      $p = ($palNames | Where-Object { $used -notcontains $_ } | Select-Object -First 1); if (-not $p) { $p = $palNames[$n % $palNames.Count] }
      $new = [pscustomobject]@{ id = "x$n"; name = "Claude 3P $n"; kind = 'cc-switch'; palette = $p }
      $c.instances = @($c.instances) + $new
      Add-InstanceRow $new
      Save-Config $c
    }
  }
  $null = Add-Btn (L '删除所选' 'Remove selected') 860 200 320 {
    $r = $grid.CurrentRow; if (-not $r) { return }
    $id = [string]$r.Cells['id'].Value
    if ($id -eq 'official') { [void][Windows.Forms.MessageBox]::Show((L '官方实例不能删除。' 'The official instance cannot be removed.')); return }
    $c = Read-Config; $c.instances = @($c.instances | Where-Object id -ne $id); Save-Config $c
    $lnk = Get-DesktopLink ([pscustomobject]@{ name = [string]$r.Cells['name'].Value }); if (Test-Path $lnk) { Remove-Item $lnk }
    $grid.Rows.Remove($r)
  }
  $null = Add-Btn (L '应用(保存+图标+快捷方式)' 'Apply (save + icons + shortcuts)') 860 242 320 {
    $form.Cursor = 'WaitCursor'
    $c = Read-GridConfig
    foreach ($i in $c.instances) {                       # regenerate icons whose palette changed
      if ($snapshot[$i.id] -ne [string]$i.palette) { Remove-Item (Get-IconPath $i) -ErrorAction SilentlyContinue; $snapshot[$i.id] = [string]$i.palette }
    }
    Save-Config $c; Install-All | Out-Null
    $form.Cursor = 'Default'
    [void][Windows.Forms.MessageBox]::Show((L '已应用。请在桌面右键新快捷方式 → 固定到任务栏。' 'Applied. Right-click the Desktop shortcuts → Pin to taskbar.'))
  }
  $null = Add-Btn (L '启动所选' 'Launch selected') 860 284 320 {
    $r = $grid.CurrentRow; if (-not $r) { return }
    Save-Config (Read-GridConfig); Invoke-Launch (Get-Instance ([string]$r.Cells['id'].Value))
  }
  $null = Add-Btn (L '全部启动' 'Launch all') 860 326 320 {
    Save-Config (Read-GridConfig)
    foreach ($i in (Read-Config).instances) { Invoke-Launch $i; Start-Sleep -Seconds 2 }
  }
  $null = Add-Btn (L '立即同步会话' 'Sync sessions now') 860 368 320 {
    $form.Cursor = 'WaitCursor'; Backup-Sessions; Initialize-SessionStores; $n = Invoke-SessionSync; $form.Cursor = 'Default'
    [void][Windows.Forms.MessageBox]::Show((L "已同步 $n 个文件。" "Synced $n file(s)."))
  }

  # ---- language switch (applies by reopening the window)
  $lblLang = New-Object Windows.Forms.Label; $lblLang.Text = 'Language / 语言'; $lblLang.Location = '860,420'; $lblLang.Size = '320,26'; $lblLang.Anchor = 'Top,Right'
  $cmbLang = New-Object Windows.Forms.ComboBox; $cmbLang.DropDownStyle = 'DropDownList'; $cmbLang.Location = '860,448'; $cmbLang.Size = '320,28'; $cmbLang.Anchor = 'Top,Right'
  [void]$cmbLang.Items.Add('English'); [void]$cmbLang.Items.Add('中文')
  $cmbLang.SelectedIndex = $(if ($zh) { 1 } else { 0 })
  $cmbLang.Add_SelectionChangeCommitted({
    $c = Read-Config; $c.settings.language = $(if ($cmbLang.SelectedIndex -eq 1) { 'zh' } else { 'en' }); Save-Config $c
    Start-Process powershell.exe -ArgumentList '-NoProfile', '-ExecutionPolicy', 'Bypass', '-WindowStyle', 'Hidden', '-STA', '-File', "`"$Root\claude-multi.ps1`"", 'gui'
    $form.Close()
  })
  # ---- settings strip
  $chkSync = New-Object Windows.Forms.CheckBox; $chkSync.Text = L '在各实例间同步会话(后台)' 'Sync sessions across instances (background)'
  $chkSync.Location = '14,500'; $chkSync.Size = '1100,28'; $chkSync.Anchor = 'Bottom,Left'; $chkSync.Checked = [bool]$cfg.settings.syncSessions
  $chkLive = New-Object Windows.Forms.CheckBox; $chkLive.Text = L '实时刷新:其他窗口有新会话时,空闲且不在前台的实例会在后台静默重启以载入(忙碌/正在使用的窗口绝不打断)' 'Live refresh: when another window has new sessions, an idle, unfocused instance restarts silently in the background to load them (busy or focused windows are never touched)'
  $chkLive.Location = '14,530'; $chkLive.Size = '1170,28'; $chkLive.Anchor = 'Bottom,Left'; $chkLive.Checked = [bool]$cfg.settings.liveRefresh
  $chkOff = New-Object Windows.Forms.CheckBox; $chkOff.Text = L '同时对官方实例启用实时刷新(默认关闭:官方窗口里可能有未发送的草稿或正在运行的会话)' 'Also live-refresh the official instance (off by default: it may hold unsent drafts or running sessions)'
  $chkOff.Location = '14,558'; $chkOff.Size = '1170,28'; $chkOff.Anchor = 'Bottom,Left'; $chkOff.Checked = [bool]$cfg.settings.refreshOfficial
  $chkSet = New-Object Windows.Forms.CheckBox; $chkSet.Text = L '同步固定(置顶)/星标会话的顺序与 MCP 服务器' 'Sync pinned / starred sessions, pin order and MCP servers'
  $chkSet.Location = '14,614'; $chkSet.Size = '1170,28'; $chkSet.Anchor = 'Bottom,Left'; $chkSet.Checked = [bool]$cfg.settings.syncSettings
  $lblProto = New-Object Windows.Forms.Label; $lblProto.Text = L 'claude:// 链接打开到:' 'Open claude:// links in:'; $lblProto.Location = '14,650'; $lblProto.Size = '300,28'; $lblProto.Anchor = 'Bottom,Left'
  $cmbProto = New-Object Windows.Forms.ComboBox; $cmbProto.DropDownStyle = 'DropDownList'; $cmbProto.Location = '320,646'; $cmbProto.Size = '360,28'; $cmbProto.Anchor = 'Bottom,Left'
  $protoIds = @('last') + @($cfg.instances | ForEach-Object { [string]$_.id })
  [void]$cmbProto.Items.Add((L '最近使用的实例' 'Last used instance')); foreach ($i in $cfg.instances) { [void]$cmbProto.Items.Add([string]$i.name) }
  $cmbProto.SelectedIndex = [Math]::Max(0, [array]::IndexOf($protoIds, [string]$cfg.settings.protocol))
  $hint = New-Object Windows.Forms.Label; $hint.Location = '14,690'; $hint.Size = '1170,60'; $hint.Anchor = 'Bottom,Left,Right'; $hint.ForeColor = 'DimGray'
  $hint.Text = if ($providers.Count -eq 0) { L '未读取到 cc-switch 供应商(需要 python 或 sqlite3);仍可使用“跟随 cc-switch”。' 'No cc-switch providers found (needs python or sqlite3); "Follow cc-switch" still works.' }
               else { L '“跟随”共用 cc-switch 网关;选具体供应商则该实例直连其上游,可与其他实例同时使用不同供应商。' '"Follow" shares the cc-switch gateway; a specific provider connects that instance directly, so instances can use different providers at once.' }
  foreach ($ctl in @($chkSet, $lblLang, $cmbLang, $grid, $pic, $picLabel, $chkSync, $chkLive, $chkOff, $lblProto, $cmbProto, $hint)) { $form.Controls.Add($ctl) }

  # ---- live status
  $timer = New-Object Windows.Forms.Timer; $timer.Interval = 3000
  $timer.Add_Tick({
    try {
      $all = @((Read-Config).instances); $map = @{}
      foreach ($m in Get-ClaudeMains) { $x = Find-InstanceOf $m $all; if ($x) { $map[$x.id] = $m.ProcessId } }
      foreach ($row in $grid.Rows) { $id = [string]$row.Cells['id'].Value; $row.Cells['status'].Value = $(if ($map.ContainsKey($id)) { (L '运行中 ' 'running ') + $map[$id] } else { '' }) }
    } catch { }
  })
  $timer.Start()
  $form.Add_Shown({ Show-Preview })
  [void]$form.ShowDialog()
  $timer.Stop()
}
