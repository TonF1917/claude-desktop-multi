# Claude Desktop Multi(多开)

[English](README.md) · **简体中文**

在 Windows 上让 **官方 Claude Desktop(订阅)** 与任意数量的 **cc-switch 驱动的第三方 Claude Desktop** **同时运行**:各自独立数据、独立任务栏按钮、独立配色图标。第三方默认图标是官方图标的 **紫黑底 + 白色星芒**。

> 非官方社区工具,与 Anthropic、cc-switch 无任何关联。图标由你本机已安装的应用图标**在本地生成**,仓库里不含 Anthropic 的任何图片素材。

## 效果

| | 官方 | 第三方(默认 `3p`) | 更多实例(`add`) |
|---|---|---|---|
| 登录 / 供应商 | 你的 Claude 订阅 | cc-switch 里为 *Claude Desktop* 选中的供应商 | 同左,也可用独立 profile |
| 数据目录 | `%APPDATA%\Claude`(不动) | `%LOCALAPPDATA%\Claude-3p` | `%USERPROFILE%\.claude-multi\<id>\Local\Claude-3p` |
| 图标 | 原版 | 紫黑 + 白 | 选配色或任意 `#RRGGBB` |
| 任务栏 | 独立按钮 | 独立按钮 | 独立按钮 |

内置配色:`violet`(默认紫黑)、`gemini`、`gpt`、`perplexity`、`deepseek`、`workbuddy`,或任意十六进制色如 `#E11D48`。可在 `palettes.json` 中新增。

## 环境要求

* Windows 11(10 理论可用),PowerShell 5.1+
* 通过 Microsoft Store / MSIX 安装的 Claude Desktop(`AnthropicPBC.Claude`)
* [cc-switch](https://github.com/farion1231/cc-switch),并配置了 *Claude Desktop* 供应商(由它启动本地网关)

## 快速开始

```powershell
git clone https://github.com/TonF1917/claude-desktop-multi
cd claude-desktop-multi
.\claude-multi.ps1 install        # 为 instances.json 中的每个实例生成图标和快捷方式
```

然后在桌面上对每个新快捷方式右键 →「固定到任务栏」(Windows 不允许脚本代为固定)。

增加实例(数量、颜色随意):

```powershell
.\claude-multi.ps1 add -Id gem -Name "Claude Gemini" -Palette gemini
.\claude-multi.ps1 add -Id work -Name "Claude Work" -Palette "#E11D48"
.\claude-multi.ps1 install
```

其他命令:`list`、`remove -Id <id>`、`icons -Force`(重新生成图标)、`uninstall`(恢复官方快捷方式并删除额外快捷方式)。

## 配合 cc-switch 使用

在 cc-switch 中为 Claude Desktop 选择第三方供应商(不要选「Claude 官方」)。cc-switch 会在 `127.0.0.1:15721` 启动网关,并把配置写入 `%LOCALAPPDATA%\Claude-3p\configLibrary`。之后启动第三方快捷方式即可生效;若该实例已在运行且配置较旧,会自动重启。

* 所有 `cc-switch` 类型实例都跟随 cc-switch **当前选中**的供应商(网关按该选择路由)。
* 想让某个实例使用不同网关:在 `instances.json` 中设置 `"profile": "路径\\profile.json"`(参见 `examples/profile.example.json`)。
* cc-switch 选「官方」时,第三方实例没有配置,会显示普通登录界面——这是正常的。

## `instances.json`

```json
{ "instances": [
  { "id": "official", "name": "Claude",    "kind": "official",  "palette": "official", "isolate": true },
  { "id": "3p",       "name": "Claude 3P", "kind": "cc-switch", "palette": "violet" },
  { "id": "gem",      "name": "Claude Gemini", "kind": "cc-switch", "palette": "gemini" }
] }
```

`isolate`(仅官方实例,默认 `true`):即使 cc-switch 应用了第三方配置,官方 App 也不会被切成第三方模式,见下。

## 原理(踩坑所得)

1. **所有实例共用一份配置库。** 应用从 `%LOCALAPPDATA%\Claude-3p` 读 `configLibrary`;cc-switch 把第三方配置写在那里;带 `disableDeploymentModeChooser` 的配置会强制所有读到它的实例进入 3P 模式——包括官方实例下次启动时。
2. **`--user-data-dir` 与 `CLAUDE_USER_DATA_DIR` 无效。** 正式版会清除该环境变量,并在 3P 模式下覆盖数据目录,所以第二个 3P 实例会与第一个冲突并静默退出。
3. **`%LOCALAPPDATA%` 有效。** 3P 数据目录由该变量推导,因此每个额外实例用各自私有的 `LOCALAPPDATA`(`~\.claude-multi\<id>\Local`)启动,配置在启动时从 cc-switch 写入的那份镜像过来。
4. **官方隔离。** 开启 `isolate` 后,官方 App 以私有 `LOCALAPPDATA` 启动,其中 `Claude-3p` 为空(`Claude`、`Packages` 是指向真实目录的目录联接),因此永远不会被强制进入 3P。
5. **独立任务栏按钮。** Electron 给所有实例设置相同的 AppUserModelID,会被合并。启动后由一个小助手通过 `SHGetPropertyStoreForWindow` 给每个窗口设置独立 ID 和图标,快捷方式也带对应 ID。
6. **更新无忧。** 每次启动都从 MSIX 包解析安装路径,不拷贝、不修改应用,也不记录版本号。

## 注意

* 官方实例的 `isolate` 要在它**下次重启**时才生效;正在运行的实例不会被改动。
* 绕过本工具的入口(开始菜单磁贴、协议链接)启动官方应用时没有隔离。
* 依赖应用的未公开行为,未来版本可能失效。
* 仅限 Windows。cc-switch 是独立项目。

## 许可证

MIT,见 [LICENSE](LICENSE)。
