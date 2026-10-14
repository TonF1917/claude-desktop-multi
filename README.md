# Claude Desktop Multi

**English** · [简体中文](README.zh-CN.md)

Run the **official Claude Desktop (subscription)** and any number of **cc-switch–driven third-party Claude Desktop** windows **at the same time** on Windows — each with its own data, its own taskbar button and its own recoloured icon. The default third-party icon is the official one in **purple-black with a white star**.

> Unofficial community tool. Not affiliated with or endorsed by Anthropic or cc-switch. Icons are generated **locally** from the icon of your installed app; no Anthropic artwork is shipped in this repository.

## What you get

| | Official | Third-party (default `3p`) | More instances (`add`) |
|---|---|---|---|
| Login / provider | your Claude subscription | whatever provider cc-switch has selected for *Claude Desktop* | same, optionally a private profile |
| Data | `%APPDATA%\Claude` (untouched) | `%LOCALAPPDATA%\Claude-3p` | `%USERPROFILE%\.claude-multi\<id>\Local\Claude-3p` |
| Icon | original | purple-black + white | pick a palette or any `#RRGGBB` |
| Taskbar | its own button | its own button | its own button |

Palettes: `violet` (default), `gemini`, `gpt`, `perplexity`, `deepseek`, `workbuddy`, or any hex colour such as `#E11D48`. Edit `palettes.json` to add more.

## Requirements

* Windows 11 (10 should work), PowerShell 5.1+
* Claude Desktop installed from the Microsoft Store / MSIX (`AnthropicPBC.Claude`)
* [cc-switch](https://github.com/farion1231/cc-switch) with a *Claude Desktop* provider (this is what starts the local gateway)

## Quick start

```powershell
git clone https://github.com/TonF1917/claude-desktop-multi
cd claude-desktop-multi
.\claude-multi.ps1 install        # icons + shortcuts for every instance in instances.json
```

A Desktop shortcut **Claude Multi Manager** opens the GUI (`.\claude-multi.ps1 gui`): choose how many instances you want, which cc-switch provider and which colour each one uses, launch them, sync sessions.

Then right-click each new Desktop shortcut → **Pin to taskbar** (Windows does not allow scripts to pin).

Add another instance (any number, any colour):

```powershell
.\claude-multi.ps1 add -Id gem -Name "Claude Gemini" -Palette gemini
.\claude-multi.ps1 add -Id work -Name "Claude Work" -Palette "#E11D48"
.\claude-multi.ps1 install
```

Other commands: `list`, `remove -Id <id>`, `icons -Force` (regenerate), `uninstall` (restore official shortcuts, delete extra ones).

## Sessions and `claude://` links

* **Session sync + live refresh.** The app reads its session list only when it starts (it has no file watcher and no reload hook), so there is no way to push a new session into a *running* window. This tool therefore does two things in a background agent (running while any instance runs):
  1. every `local_*.json` session file is mirrored newest-wins into the session folders of all instances within seconds (nothing is deleted; the first sync backs everything up to `~\.claude-multi\backup-sessions`; transcripts in `~\.claude` are shared natively);
  2. when a session appears that another instance has never seen, that instance is restarted **silently in the background** (about 10-45 s): only if it is not the focused window, has not written a session file in the last 45 s, and none of its agent/tool child processes is using CPU. The restarted window does not take the focus back. Busy or focused windows are never touched; they refresh as soon as they become idle. The official instance is excluded unless you tick *Also live-refresh the official instance* in the GUI (it may hold unsent drafts).
* **`claude://` links** are routed by `run.vbs` to the instance you last used (or a fixed one, chosen in the GUI). If it is already running the link is handed to that window; otherwise it is started with the link. The agent re-asserts the handler because Claude re-registers itself whenever it starts.

## Using cc-switch

In cc-switch choose a *Claude Desktop* provider (not "Claude 官方 / Official"). cc-switch then starts its gateway on `127.0.0.1:15721` and writes the profile into `%LOCALAPPDATA%\Claude-3p\configLibrary`. Launching a third-party shortcut afterwards picks it up; if the instance was already running with an older profile it is restarted automatically.

* All `cc-switch` instances follow cc-switch's **currently selected** provider (the gateway routes by that selection).
* **Different provider per instance, at the same time:** in the GUI pick a specific provider (or `add -Provider <id>`). That instance gets a profile built from the provider's own base URL / key / model routes and talks to the upstream directly instead of the shared gateway (Anthropic-format providers only; model ids are the real upstream ids).
* For a hand-written profile per instance set `"profile": "path\\to\\profile.json"` in `instances.json` (see `examples/profile.example.json`).
* When cc-switch is set to *Official*, third-party instances have no profile and show the normal sign-in screen — that is expected.

## `instances.json`

```json
{ "instances": [
  { "id": "official", "name": "Claude",    "kind": "official",  "palette": "official", "isolate": true },
  { "id": "3p",       "name": "Claude 3P", "kind": "cc-switch", "palette": "violet" },
  { "id": "gem",      "name": "Claude Gemini", "kind": "cc-switch", "palette": "gemini", "provider": "<cc-switch provider id>" }
], "settings": { "syncSessions": true, "protocol": "last" } }
```

`isolate` (official only, default `true`) keeps the official app out of third-party mode even when cc-switch applies a profile — see below.

## How it works (what was found the hard way)

1. **One config library for everyone.** The app reads `configLibrary` from `%LOCALAPPDATA%\Claude-3p`; cc-switch writes the third-party profile there; a profile with `disableDeploymentModeChooser` forces *every* instance that reads it into 3P mode — including the official one on its next start.
2. **`--user-data-dir` and `CLAUDE_USER_DATA_DIR` do not help.** The production build strips the env var and overrides the data dir in 3P mode, so a second 3P instance just collides with the first and exits silently.
3. **`%LOCALAPPDATA%` does.** The 3P data dir is derived from that variable, so each extra instance is started with its own private `LOCALAPPDATA` (`~\.claude-multi\<id>\Local`). Its profile is mirrored from the cc-switch one at launch.
4. **Official isolation.** With `isolate`, the official app is started with a private `LOCALAPPDATA` whose `Claude-3p` is empty (`Claude` and `Packages` are junctions to the real ones), so it can never be forced into 3P.
5. **Separate taskbar buttons.** Electron sets the same AppUserModelID for every instance, so they would merge. After start a small helper sets a per-window AppUserModelID and window icon (`SHGetPropertyStoreForWindow`) and the shortcuts carry matching IDs.
6. **Icons must not live in `AppData\*\ClaudeMulti`.** Explorer and the taskbar render a blank page for `.ico` files under such a folder (a `.ico` in any other folder works), so icons are generated into `~\.claude-multi\icons`.
7. **Update-proof.** The install path is resolved from the MSIX package on every launch; nothing is copied or patched, and no version number is stored.

## Caveats

* The official instance picks up `isolate` the next time it is **restarted**; a running instance is never touched.
* Shortcuts that bypass this tool (Start-menu tile, protocol links) start the official app unisolated.
* Everything relies on undocumented app behaviour and may break with a future Claude Desktop release.
* Windows only. cc-switch is an independent project.

## License

MIT — see [LICENSE](LICENSE).
