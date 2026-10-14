# Claude Desktop 多开:多个窗口同时用不同 API(多 API 同时工作)

[English](README.md) · **简体中文**

**Claude Desktop 多开,多个窗口同时使用不同 API。** 一个窗口保持**官方订阅**,其余窗口想开几个开几个,分别走**自定义 / 第三方 API**(由 [cc-switch](https://github.com/farion1231/cc-switch) 驱动)——*Claude Desktop 多 API、多窗口、多账号同时工作(Windows)*。官方与第三方窗口**同时运行**:各自独立数据、独立任务栏按钮、独立配色图标。第三方默认图标是官方图标的 **紫黑底 + 白色星芒**。

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
git clone https://github.com/TonF1917/claude-desktop-multiple-windows-different-api
cd claude-desktop-multiple-windows-different-api
.\claude-multi.ps1 install        # 为 instances.json 中的每个实例生成图标和快捷方式
```

桌面上的 **Claude Multi Manager** 快捷方式会打开图形界面(默认英文,可用右侧的语言框切换为中文)(`.\claude-multi.ps1 gui`):选择多开几个、每个用哪个 cc-switch 供应商、什么配色,一键启动、同步会话。

然后在桌面上对每个新快捷方式右键 →「固定到任务栏」(Windows 不允许脚本代为固定)。

增加实例(数量、颜色随意):

```powershell
.\claude-multi.ps1 add -Id gem -Name "Claude Gemini" -Palette gemini
.\claude-multi.ps1 add -Id work -Name "Claude Work" -Palette "#E11D48"
.\claude-multi.ps1 install
```

其他命令:`list`、`remove -Id <id>`、`icons -Force`(重新生成图标)、`uninstall`(恢复官方快捷方式并删除额外快捷方式)。

## 会话与 `claude://` 链接

* **会话同步 + 实时刷新。** 应用只在启动时读取会话列表(没有文件监听,也没有重载入口),所以无法把新会话“推”进一个*正在运行*的窗口。本工具在后台代理(任一实例运行时存在)里做两件事:
  1. 把所有 `local_*.json` 会话文件按“最新者优先”在数秒内镜像到各实例的会话目录(从不删除;首次同步会备份到 `~\.claude-multi\backup-sessions`;`~\.claude` 里的对话记录本来就共享);
  2. 当出现某个实例从未见过的新会话时,该实例会在后台**静默重启**(约 10-45 秒):前提是它不是当前焦点窗口、最近 45 秒没有写过会话文件、且其代理/工具子进程没有占用 CPU。重启后的窗口不会抢走焦点。忙碌或正在使用的窗口绝不会被打断,空闲后再刷新。官方实例默认不参与,可在界面勾选“同时对官方实例启用实时刷新”(官方窗口里可能有未发送的草稿)。
* **`claude://` 链接**由 `run.vbs` 路由到你最近使用的实例(或在界面里固定某一个)。目标已在运行则交给它的窗口,否则带着链接启动它。Claude 每次启动都会重新注册协议,所以后台代理会持续恢复这个处理器。

## 实例之间同步什么

| 项目 | 是否同步 | 在另一窗口出现的方式 |
|---|---|---|
| 会话(新会话、标题、归档状态) | 是 | 文件数秒内镜像;对方窗口在后台静默重启后载入 |
| 固定(置顶)/星标会话及其顺序 | 是 | 每个会话里的 `isStarred` 标记,以及 `claude_desktop_config.json` 里的 `starred-*`、`pinnedOrder`;只在窗口关闭时(或后台重启前)写入,避免被应用覆盖 |
| MCP 服务器 | 是 | 同一机制(`mcpServers`);可在界面取消勾选“同步固定/星标会话与 MCP 服务器” |
| 对话记录 | 是(天然共享) | 存放在 `~\.claude\projects`,所有实例共用 |
| 登录、供应商、模型列表、窗口大小位置 | 否 | 有意保持各实例独立 |

**为什么不能瞬时同步?** Claude Desktop 确实会读这些文件夹,但只在启动时读,以及登录账号/组织变化时再读。我实测过:它没有文件监听,改写它的 `config.json` 也不会触发重新读取,正式版还禁用了远程调试,所以应用之外没有任何办法让一个运行中的窗口重新读文件夹。最接近且安全的办法就是上文所述:对空闲、非焦点窗口做后台静默重启。

**同一会话在两个窗口同时发送会怎样?** 每个窗口为每个会话各跑一个 Claude Code 进程(`--resume=<id>`)。两边都发送时,它们会往同一份对话记录里写,但各自保留自己的上下文,历史会交错、两个窗口的内容不一致。某会话在两个实例里同时存活且其中一个正在工作时,后台代理会弹出 Windows 通知——同一会话请只在一个窗口里活跃。

**不同来源的会话怎么显示?** 每个窗口显示同一份合并后的列表,没有“来自哪个实例”的角标。会话保留自己的目录、模型和强度;在另一个窗口打开时,它走的是**那个窗口**的登录/供应商(官方窗口走订阅,第三方窗口走所选供应商)。

## 配合 cc-switch 使用

在 cc-switch 中为 Claude Desktop 选择第三方供应商(不要选「Claude 官方」)。cc-switch 会在 `127.0.0.1:15721` 启动网关,并把配置写入 `%LOCALAPPDATA%\Claude-3p\configLibrary`。之后启动第三方快捷方式即可生效;若该实例已在运行且配置较旧,会自动重启。

* 所有 `cc-switch` 类型实例都跟随 cc-switch **当前选中**的供应商(网关按该选择路由)。
* **每个实例同时用不同供应商:** 在界面里选具体供应商(或 `add -Provider <id>`)。该实例会用该供应商自己的 base URL / 密钥 / 模型映射生成配置,直连上游而不走共用网关(仅限 Anthropic 格式供应商;模型名使用上游真实 id)。
* 想为某个实例手写配置:在 `instances.json` 中设置 `"profile": "路径\\profile.json"`(参见 `examples/profile.example.json`)。
* cc-switch 选「官方」时,第三方实例没有配置,会显示普通登录界面——这是正常的。

## `instances.json`

```json
{ "instances": [
  { "id": "official", "name": "Claude",    "kind": "official",  "palette": "official", "isolate": true },
  { "id": "3p",       "name": "Claude 3P", "kind": "cc-switch", "palette": "violet" },
  { "id": "gem",      "name": "Claude Gemini", "kind": "cc-switch", "palette": "gemini", "provider": "<cc-switch 供应商 id>" }
], "settings": { "syncSessions": true, "protocol": "last" } }
```

`isolate`(仅官方实例,默认 `true`):即使 cc-switch 应用了第三方配置,官方 App 也不会被切成第三方模式,见下。

## 原理(踩坑所得)

1. **所有实例共用一份配置库。** 应用从 `%LOCALAPPDATA%\Claude-3p` 读 `configLibrary`;cc-switch 把第三方配置写在那里;带 `disableDeploymentModeChooser` 的配置会强制所有读到它的实例进入 3P 模式——包括官方实例下次启动时。
2. **`--user-data-dir` 与 `CLAUDE_USER_DATA_DIR` 无效。** 正式版会清除该环境变量,并在 3P 模式下覆盖数据目录,所以第二个 3P 实例会与第一个冲突并静默退出。
3. **`%LOCALAPPDATA%` 有效。** 3P 数据目录由该变量推导,因此每个额外实例用各自私有的 `LOCALAPPDATA`(`~\.claude-multi\<id>\Local`)启动,配置在启动时从 cc-switch 写入的那份镜像过来。
4. **官方隔离。** 开启 `isolate` 后,官方 App 以私有 `LOCALAPPDATA` 启动,其中 `Claude-3p` 为空(`Claude`、`Packages` 是指向真实目录的目录联接),因此永远不会被强制进入 3P。
5. **独立任务栏按钮。** Electron 给所有实例设置相同的 AppUserModelID,会被合并。启动后由一个小助手通过 `SHGetPropertyStoreForWindow` 给每个窗口设置独立 ID 和图标,快捷方式也带对应 ID。
6. **图标不能放在 `AppData\*\ClaudeMulti` 下。** 资源管理器和任务栏对这类目录里的 `.ico` 只显示空白页(放在其他任何目录都正常),所以图标生成到 `~\.claude-multi\icons`。
7. **更新无忧。** 每次启动都从 MSIX 包解析安装路径,不拷贝、不修改应用,也不记录版本号。

## 注意

* 官方实例的 `isolate` 要在它**下次重启**时才生效;正在运行的实例不会被改动。
* 绕过本工具的入口(开始菜单磁贴、协议链接)启动官方应用时没有隔离。
* 依赖应用的未公开行为,未来版本可能失效。
* 仅限 Windows。cc-switch 是独立项目。

## 许可证

MIT,见 [LICENSE](LICENSE)。
