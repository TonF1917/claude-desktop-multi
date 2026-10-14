# Read-only access to cc-switch's provider list, and direct (gateway-less) profiles built from one provider.
function Invoke-CcSql([string]$sql) {
  $db = Join-Path $env:USERPROFILE '.cc-switch\cc-switch.db'
  if (-not (Test-Path $db)) { return $null }
  try {                                                   # 1) winsqlite3.dll (built into Windows)
    $rows = [WinSqlite]::Query($db, $sql)
    return @($rows | ForEach-Object { $o = [ordered]@{}; foreach ($k in $_.Keys) { $o[$k] = $_[$k] }; [pscustomobject]$o })
  } catch { }
  $py = Get-Command python -ErrorAction SilentlyContinue                                  # 2) python
  if ($py) {
    $code = "import sqlite3,json,sys;c=sqlite3.connect('file:'+sys.argv[1].replace('\','/')+'?mode=ro',uri=True);c.row_factory=sqlite3.Row;print(json.dumps([dict(r) for r in c.execute(sys.argv[2])],ensure_ascii=False))"
    $out = & $py.Source -I -c $code $db $sql 2>$null
    if ($LASTEXITCODE -eq 0 -and $out) { return ($out -join '' | ConvertFrom-Json) }
  }
  $sq = Get-Command sqlite3 -ErrorAction SilentlyContinue                                  # 3) sqlite3.exe
  if ($sq) {
    $out = & $sq.Source -readonly -json $db $sql 2>$null
    if ($LASTEXITCODE -eq 0 -and $out) { return ($out -join '' | ConvertFrom-Json) }
  }
  $null
}

function Get-CcProviders {   # Claude Desktop providers known to cc-switch (excluding the official subscription)
  $rows = Invoke-CcSql "select id,name,is_current,settings_config,meta from providers where app_type='claude-desktop'"
  foreach ($r in @($rows)) {
    if (-not $r -or $r.id -eq 'claude-desktop-official') { continue }
    $s = try { $r.settings_config | ConvertFrom-Json } catch { $null }
    $m = try { $r.meta | ConvertFrom-Json } catch { $null }
    [pscustomobject]@{ id = $r.id; name = $r.name; current = ([string]$r.is_current -eq '1' -or $r.is_current -eq $true); settings = $s; meta = $m }
  }
}

function New-DirectProfile([string]$providerId) {
  $p = Get-CcProviders | Where-Object id -eq $providerId | Select-Object -First 1
  if (-not $p) { throw "cc-switch provider '$providerId' not found" }
  $fmt = $p.meta.apiFormat
  if ($fmt -and $fmt -ne 'anthropic') { throw "Provider '$($p.name)' speaks '$fmt'; it needs the cc-switch gateway (use 'follow cc-switch')." }
  $env_ = $p.settings.env
  $url = [string]$env_.ANTHROPIC_BASE_URL
  $key = if ($env_.ANTHROPIC_AUTH_TOKEN) { [string]$env_.ANTHROPIC_AUTH_TOKEN } else { [string]$env_.ANTHROPIC_API_KEY }
  if (-not $url -or -not $key) { throw "Provider '$($p.name)' has no base URL / key" }
  $models = @()
  $routes = $p.meta.claudeDesktopModelRoutes
  if ($routes) {
    foreach ($r in $routes.PSObject.Properties) {
      $label = if ($r.Value.labelOverride) { $r.Value.labelOverride } else { $r.Name }
      $real = if ($r.Value.model) { $r.Value.model } else { $r.Name }      # the gateway aliases are meaningless upstream: send real model ids
      $models += [ordered]@{ name = $real; labelOverride = $label; supports1m = $true }
    }
  }
  [ordered]@{
    inferenceStreamIdleTimeoutSec = 1800
    defaultModelEffort            = 'medium'
    inferenceModelPricingEnabled  = $true
    coworkEgressAllowedHosts      = @('*')
    disableDeploymentModeChooser  = $true
    inferenceCredentialKind       = 'static'
    inferenceGatewayApiKey        = $key
    inferenceGatewayAuthScheme    = 'bearer'
    inferenceGatewayBaseUrl       = ($url.TrimEnd('/') -replace '/v1$', '')
    inferenceProvider             = 'gateway'
    inferenceModels               = $models
  }
}
