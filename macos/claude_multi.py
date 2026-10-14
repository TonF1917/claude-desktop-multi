#!/usr/bin/env python3
"""Claude Desktop: multiple windows with different APIs - macOS port (EXPERIMENTAL).

Written without access to a Mac: the portable parts (config, palettes, icon recolouring, cc-switch profiles,
session mirroring, GUI) are exercised on Windows; the macOS-only parts (bundle cloning, codesign, `open`,
iconutil) follow the documented behaviour of those tools but have not been run on real hardware.
Needs only the Python 3 that ships with the Xcode Command Line Tools (standard library only).

    python3 macos/claude_multi.py gui
    python3 macos/claude_multi.py add --id gem --name "Claude Gemini" --palette gemini [--provider <cc-switch id>]
    python3 macos/claude_multi.py install        # builds one tinted Claude.app clone per extra window
    python3 macos/claude_multi.py launch --id gem
"""
import argparse, binascii, colorsys, json, os, plistlib, re, shutil, sqlite3, struct, subprocess, sys, time, zlib
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
CONFIG = ROOT / 'instances.json'
PALETTES = ROOT / 'palettes.json'
HOME = Path(os.environ.get('CLAUDE_MULTI_HOME') or Path.home())
HOME_ROOT = HOME / '.claude-multi'
APP_SUP = HOME / 'Library' / 'Application Support'
IS_MAC = sys.platform == 'darwin'
APP_CANDIDATES = [Path('/Applications/Claude.app'), HOME / 'Applications' / 'Claude.app']
SRC_3P = APP_SUP / 'Claude-3p'            # where Claude (and cc-switch) keep the shared 3P config library
CLONES = HOME / 'Applications' / 'Claude Multi'


# ------------------------------------------------------------------ config
def read_config():
    c = json.loads(CONFIG.read_text(encoding='utf-8-sig'))
    s = c.setdefault('settings', {})
    for k, v in (('syncSessions', True), ('liveRefresh', True), ('refreshOfficial', False), ('language', 'en'), ('protocol', 'last')):
        s.setdefault(k, v)
    return c

def save_config(c):
    CONFIG.write_text(json.dumps(c, indent=2, ensure_ascii=False) + '\n', encoding='utf-8')

def palettes():
    return json.loads(PALETTES.read_text(encoding='utf-8-sig'))

def get_instance(c, iid):
    for i in c['instances']:
        if i['id'] == iid:
            return i
    raise SystemExit(f"no instance '{iid}'")

def data_dir(i):                          # Claude userData of a window ("<dir>-3p" is derived from it by the app)
    return APP_SUP / 'Claude' if i['kind'] == 'official' else HOME_ROOT / i['id'] / 'Claude'

def store_root(i):                        # where its claude-code-sessions live
    return APP_SUP / 'Claude' if i['kind'] == 'official' else HOME_ROOT / i['id'] / 'Claude-3p'

def official_app():
    for p in APP_CANDIDATES:
        if p.exists():
            return p
    raise SystemExit('Claude.app not found in /Applications or ~/Applications')


# ------------------------------------------------------------------ PNG + palette recolouring (pure Python)
def read_png(path):
    d = Path(path).read_bytes()
    assert d[:8] == b'\x89PNG\r\n\x1a\n', 'not a PNG'
    pos, idat, w = 8, b'', 0
    while pos < len(d):
        ln, typ = struct.unpack('>I4s', d[pos:pos + 8]); body = d[pos + 8:pos + 8 + ln]; pos += 12 + ln
        if typ == b'IHDR':
            w, h, depth, ctype, _, _, inter = struct.unpack('>IIBBBBB', body)
            assert depth == 8 and ctype in (2, 6) and inter == 0, 'only 8-bit RGB/RGBA non-interlaced PNG is supported'
        elif typ == b'IDAT':
            idat += body
    bpp = 4 if ctype == 6 else 3
    raw = zlib.decompress(idat); stride = w * bpp; out = bytearray(); prev = bytearray(stride); p = 0
    for _ in range(h):
        f = raw[p]; line = bytearray(raw[p + 1:p + 1 + stride]); p += 1 + stride
        for x in range(stride):
            a = line[x - bpp] if x >= bpp else 0; b = prev[x]; c = prev[x - bpp] if x >= bpp else 0
            if f == 1: line[x] = (line[x] + a) & 255
            elif f == 2: line[x] = (line[x] + b) & 255
            elif f == 3: line[x] = (line[x] + ((a + b) >> 1)) & 255
            elif f == 4:
                pa, pb, pc = abs(b - c), abs(a - c), abs(a + b - 2 * c)
                line[x] = (line[x] + (a if pa <= pb and pa <= pc else b if pb <= pc else c)) & 255
        out += line; prev = line
    if bpp == 3:                           # promote RGB to RGBA
        rgba = bytearray()
        for k in range(0, len(out), 3):
            rgba += out[k:k + 3] + b'\xff'
        out = rgba
    return w, h, out

def write_png(path, w, h, rgba):
    raw = b''.join(b'\x00' + bytes(rgba[y * w * 4:(y + 1) * w * 4]) for y in range(h))
    def chunk(t, b): return struct.pack('>I', len(b)) + t + b + struct.pack('>I', binascii.crc32(t + b) & 0xffffffff)
    Path(path).write_bytes(b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', struct.pack('>IIBBBBB', w, h, 8, 6, 0, 0, 0)) + chunk(b'IDAT', zlib.compress(raw, 6)) + chunk(b'IEND', b''))

def resolve_palette(spec, pal):
    m = re.fullmatch(r'#?([0-9a-fA-F]{6})', spec or '')
    if m:                                  # any #RRGGBB
        r, g, b = (int(m.group(1)[k:k + 2], 16) / 255 for k in (0, 2, 4)); h, s, v = colorsys.rgb_to_hsv(r, g, b)
        return dict(hue=h * 360, sat=max(.35, s), vMin=.15 * v, vMax=max(.35, v), glyph='#FFFFFF')
    if spec not in pal:
        raise SystemExit(f"unknown palette '{spec}'")
    return pal[spec]

def recolor(w, h, rgba, p):
    gl = tuple(int(p['glyph'].lstrip('#')[k:k + 2], 16) for k in (0, 2, 4)); out = bytearray(len(rgba))
    for k in range(0, len(rgba), 4):
        r, g, b, a = rgba[k:k + 4]
        if a == 0:
            continue
        mx, mn = max(r, g, b), min(r, g, b); val = mx / 255; sat = 0 if mx == 0 else (mx - mn) / mx
        t = min(1, max(0, (sat - .20) / .25))                       # 1 = coloured body, 0 = white glyph
        v = min(p['vMax'], max(p['vMin'], p['vMin'] + (p['vMax'] - p['vMin']) * ((val - .75) / .2)))
        rr, gg, bb = colorsys.hsv_to_rgb((p['hue'] % 360) / 360, p['sat'], v)
        out[k:k + 4] = bytes((int(gl[0] + (rr * 255 - gl[0]) * t), int(gl[1] + (gg * 255 - gl[1]) * t), int(gl[2] + (bb * 255 - gl[2]) * t), a))
    return out


# ------------------------------------------------------------------ cc-switch: providers and direct profiles
def cc_providers():
    db = HOME / '.cc-switch' / 'cc-switch.db'
    if not db.exists():
        return []
    con = sqlite3.connect(f'file:{db.as_posix()}?mode=ro', uri=True)
    rows = con.execute("select id,name,is_current,settings_config,meta from providers where app_type='claude-desktop'").fetchall()
    out = []
    for pid, name, cur, sc, meta in rows:
        if pid == 'claude-desktop-official':
            continue
        out.append(dict(id=pid, name=name, current=bool(cur), settings=json.loads(sc or '{}'), meta=json.loads(meta or '{}')))
    return out

def direct_profile(provider_id):
    p = next((x for x in cc_providers() if x['id'] == provider_id), None)
    if not p:
        raise SystemExit(f"cc-switch provider '{provider_id}' not found")
    fmt = p['meta'].get('apiFormat')
    if fmt and fmt != 'anthropic':
        raise SystemExit(f"provider '{p['name']}' speaks '{fmt}'; it needs the cc-switch gateway (use 'follow')")
    env = p['settings'].get('env', {}); url = env.get('ANTHROPIC_BASE_URL'); key = env.get('ANTHROPIC_AUTH_TOKEN') or env.get('ANTHROPIC_API_KEY')
    if not url or not key:
        raise SystemExit(f"provider '{p['name']}' has no base URL / key")
    models = [dict(name=r.get('model') or k, labelOverride=r.get('labelOverride') or k, supports1m=True)
              for k, r in (p['meta'].get('claudeDesktopModelRoutes') or {}).items()]
    return dict(inferenceStreamIdleTimeoutSec=1800, defaultModelEffort='medium', inferenceModelPricingEnabled=True, coworkEgressAllowedHosts=['*'],
                disableDeploymentModeChooser=True, inferenceCredentialKind='static', inferenceGatewayApiKey=key, inferenceGatewayAuthScheme='bearer',
                inferenceGatewayBaseUrl=re.sub(r'/v1$', '', url.rstrip('/')), inferenceProvider='gateway', inferenceModels=models)

def sync_profile(i):
    """Give a window its own config library; returns the profile's timestamp (restart a running window when it is newer)."""
    dst = store_root(i) / 'configLibrary'
    uid = '00000000-0000-4000-8000-0000000000%02d' % (binascii.crc32(i['id'].encode()) % 100)
    dst.mkdir(parents=True, exist_ok=True)
    if i.get('provider') or i.get('profile'):
        prof = json.loads(Path(os.path.expandvars(i['profile'])).read_text(encoding='utf-8-sig')) if i.get('profile') else direct_profile(i['provider'])
        text = json.dumps(prof, indent=2)
        f = dst / f'{uid}.json'
        if not (f.exists() and f.read_text() == text):
            for old in dst.iterdir(): old.unlink()
            f.write_text(text, encoding='utf-8')
            (dst / '_meta.json').write_text(json.dumps(dict(entries=[dict(id=uid, name=i['name'])], appliedId=uid)), encoding='utf-8')
        return f.stat().st_mtime
    src = SRC_3P / 'configLibrary'                          # follow cc-switch's current selection
    if not src.exists():
        return 0.0
    for old in dst.iterdir(): old.unlink()
    for f in src.iterdir():
        shutil.copy2(f, dst / f.name)
    return max((f.stat().st_mtime for f in src.iterdir()), default=0.0)


# ------------------------------------------------------------------ macOS: tinted Claude.app clones
def sh(*a, check=True):
    return subprocess.run(a, check=check, capture_output=True, text=True)

def app_version(app):
    return plistlib.loads((app / 'Contents' / 'Info.plist').read_bytes()).get('CFBundleShortVersionString', '?')

def build_icns(icns_in, palette_spec, out_icns, tmp):
    tmp.mkdir(parents=True, exist_ok=True)
    base = tmp / 'base.png'
    sh('sips', '-s', 'format', 'png', str(icns_in), '--out', str(base))
    w, h, px = read_png(base)
    write_png(tmp / 'tint.png', w, h, recolor(w, h, px, resolve_palette(palette_spec, palettes())))
    iconset = tmp / 'icon.iconset'; iconset.mkdir(exist_ok=True)
    for s, name in ((16, 'icon_16x16'), (32, 'icon_16x16@2x'), (32, 'icon_32x32'), (64, 'icon_32x32@2x'), (128, 'icon_128x128'), (256, 'icon_128x128@2x'),
                    (256, 'icon_256x256'), (512, 'icon_256x256@2x'), (512, 'icon_512x512'), (1024, 'icon_512x512@2x')):
        sh('sips', '-z', str(s), str(s), str(tmp / 'tint.png'), '--out', str(iconset / f'{name}.png'))
    sh('iconutil', '-c', 'icns', str(iconset), '-o', str(out_icns))

def ensure_clone(i, force=False):
    """APFS-clone Claude.app (no extra disk space), tint its icon, rename it, drop its claude:// handler, ad-hoc sign."""
    src = official_app(); dst = CLONES / f"{i['name']}.app"; stamp = dst / 'Contents' / '.multi-version'
    if dst.exists() and not force and stamp.exists() and stamp.read_text() == f"{app_version(src)}|{i['palette']}":
        return dst
    if dst.exists():
        shutil.rmtree(dst)
    CLONES.mkdir(parents=True, exist_ok=True)
    if sh('cp', '-cR', str(src), str(dst), check=False).returncode != 0:
        sh('cp', '-R', str(src), str(dst))
    plist_path = dst / 'Contents' / 'Info.plist'; info = plistlib.loads(plist_path.read_bytes())
    icon_name = info.get('CFBundleIconFile', 'electron.icns'); icon_name += '' if icon_name.endswith('.icns') else '.icns'
    icns = dst / 'Contents' / 'Resources' / icon_name
    if i.get('palette') not in (None, 'official'):
        build_icns(icns, i['palette'], icns, HOME_ROOT / 'tmp' / i['id'])
    info['CFBundleName'] = info['CFBundleDisplayName'] = i['name']; info['CFBundleIdentifier'] = f"{info.get('CFBundleIdentifier', 'com.anthropic.claudefordesktop')}.multi.{i['id']}"
    info.pop('CFBundleURLTypes', None)
    plist_path.write_bytes(plistlib.dumps(info))
    sh('xattr', '-cr', str(dst), check=False); sh('codesign', '--force', '--deep', '--sign', '-', str(dst), check=False)
    stamp.write_text(f"{app_version(src)}|{i['palette']}")
    return dst


# ------------------------------------------------------------------ processes
def running(i):
    """PIDs of the main process of this window (macOS: matched by its --user-data-dir)."""
    out = sh('ps', '-axo', 'pid=,lstart=,command=', check=False).stdout
    pids = []
    for line in out.splitlines():
        m = re.match(r'\s*(\d+)\s+(\w+\s+\w+\s+\d+\s+[\d:]+\s+\d+)\s+(.*)', line)
        if not m or '--type=' in m.group(3) or 'Claude' not in m.group(3):
            continue
        if i['kind'] == 'official':
            if 'Claude.app/Contents/MacOS' in m.group(3) and '--user-data-dir' not in m.group(3) and '.multi.' not in m.group(3):
                pids.append((int(m.group(1)), time.mktime(time.strptime(m.group(2), '%a %b %d %H:%M:%S %Y'))))
        elif f"--user-data-dir={data_dir(i)}" in m.group(3):
            pids.append((int(m.group(1)), time.mktime(time.strptime(m.group(2), '%a %b %d %H:%M:%S %Y'))))
    return pids

def launch(i, url=None):
    if i['kind'] == 'official':
        sh('open', '-a', str(official_app()), *(['--args', url] if url else []))
        return
    prof_time = sync_profile(i)
    for pid, started in running(i):
        if started < prof_time:                              # a running window read its profile at start-up
            sh('kill', str(pid), check=False); time.sleep(2)
    app = ensure_clone(i)
    sh('open', '-n', str(app), '--args', f"--user-data-dir={data_dir(i)}", *([url] if url else []))


# ------------------------------------------------------------------ sessions: mirror + silent refresh
def session_folders(c):
    for i in c['instances']:
        cs = store_root(i) / 'claude-code-sessions'
        if cs.exists():
            for a in cs.iterdir():
                if a.is_dir():
                    for o in a.iterdir():
                        if o.is_dir() and not o.name.endswith('-backup'):
                            yield i['id'], o

def sync_sessions(c, stale):
    """Newest-wins mirror of every local_*.json into every session folder; a window that receives a session it never had becomes stale."""
    folders = list(session_folders(c))
    if len(folders) < 2:
        return 0
    best = {}
    for _, f in folders:
        for p in f.glob('local_*.json'):
            m = p.stat().st_mtime
            if p.name not in best or m > best[p.name][1]:
                best[p.name] = (p, m)
    copied = 0
    for iid, f in folders:
        for name, (src, m) in best.items():
            dst = f / name
            if (not dst.exists()) or dst.stat().st_mtime < m - 1:
                new = not dst.exists(); shutil.copy2(src, dst); os.utime(dst, (m, m)); copied += 1
                if new:
                    stale[iid] = time.time()
    return copied

def agent(interval=6):
    c = read_config(); stale = {}; last_restart = {}
    while True:
        c = read_config()
        if c['settings']['syncSessions']:
            sync_sessions(c, stale)
        if c['settings']['liveRefresh']:
            front = sh('osascript', '-e', 'tell application "System Events" to get unix id of first process whose frontmost is true', check=False).stdout.strip()
            for i in c['instances']:
                if i['kind'] == 'official' and not c['settings']['refreshOfficial']:
                    continue
                since = stale.get(i['id'])
                if not since or time.time() - since < 8 or time.time() - last_restart.get(i['id'], 0) < 120:
                    continue
                pids = running(i)
                if not pids or str(pids[0][0]) == front:
                    continue
                cs = store_root(i) / 'claude-code-sessions'
                if any(time.time() - p.stat().st_mtime < 45 for p in cs.rglob('local_*.json')):   # the app wrote recently: busy
                    continue
                sh('kill', str(pids[0][0]), check=False); time.sleep(2); launch(i); stale.pop(i['id'], None); last_restart[i['id']] = time.time()
        time.sleep(interval)


# ------------------------------------------------------------------ CLI
def cmd_list(a):
    c = read_config()
    for i in c['instances']:
        print(f"{i['id']:<10} {i['name']:<24} {i['kind']:<9} {i.get('palette', ''):<12} {i.get('provider', '')}  pid={[p for p, _ in running(i)] if IS_MAC else '-'}")

def cmd_add(a):
    c = read_config()
    if any(i['id'] == a.id for i in c['instances']):
        raise SystemExit('already exists')
    n = dict(id=a.id, name=a.name or f'Claude {a.id}', kind='cc-switch', palette=a.palette)
    if a.provider: n['provider'] = a.provider
    if a.profile: n['profile'] = a.profile
    c['instances'].append(n); save_config(c); print(f"added '{a.id}'. Run: install")

def cmd_remove(a):
    c = read_config(); i = get_instance(c, a.id)
    if i['kind'] == 'official': raise SystemExit('the official window cannot be removed')
    c['instances'] = [x for x in c['instances'] if x['id'] != a.id]; save_config(c)
    app = CLONES / f"{i['name']}.app"
    if app.exists(): shutil.rmtree(app)
    print(f"removed '{a.id}' (its data in {HOME_ROOT / a.id} was left untouched)")

def cmd_install(a):
    c = read_config()
    for i in c['instances']:
        if i['kind'] != 'official':
            print('built', ensure_clone(i, force=a.force))
    print(f'\nDrag the apps from {CLONES} to the Dock. Start them through this tool (launch) so they get their own data directory.')

def cmd_launch(a):
    launch(get_instance(read_config(), a.id), a.url)

def cmd_sync(a):
    print('copied:', sync_sessions(read_config(), {}))

def cmd_providers(a):
    for p in cc_providers():
        print(p['id'], p['name'], '(current)' if p['current'] else '')

def cmd_gui(a):
    from claude_multi_gui import run
    run(sys.modules[__name__])

def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter); sp = ap.add_subparsers(dest='cmd')
    sp.add_parser('list').set_defaults(f=cmd_list); sp.add_parser('gui').set_defaults(f=cmd_gui); sp.add_parser('sync').set_defaults(f=cmd_sync)
    sp.add_parser('providers').set_defaults(f=cmd_providers); sp.add_parser('agent').set_defaults(f=lambda a: agent())
    p = sp.add_parser('add'); p.add_argument('--id', required=True); p.add_argument('--name'); p.add_argument('--palette', default='violet'); p.add_argument('--provider'); p.add_argument('--profile'); p.set_defaults(f=cmd_add)
    p = sp.add_parser('remove'); p.add_argument('--id', required=True); p.set_defaults(f=cmd_remove)
    p = sp.add_parser('install'); p.add_argument('--force', action='store_true'); p.set_defaults(f=cmd_install)
    p = sp.add_parser('launch'); p.add_argument('--id', required=True); p.add_argument('--url'); p.set_defaults(f=cmd_launch)
    a = ap.parse_args()
    (a.f if getattr(a, 'f', None) else cmd_gui)(a)

if __name__ == '__main__':
    sys.path.insert(0, str(Path(__file__).resolve().parent))
    main()
