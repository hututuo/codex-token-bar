# Claude Desktop 额度更新触发与纯本地来源核查

日期：2026-11-04，北京时间。范围：公开文档/开源代码、已安装 Desktop 包的静态分析、现有本地缓存和日志。未打开额度页、未启动客户端或 CLI、未调用 Claude/Anthropic 账号接口、未读 Cookie/凭据、未改变设置。没有产品代码修改、安装、构建或测试。

## 结论

不是只有打开 Settings → Usage 才有额度请求。当前安装包有独立的后台额度轮询，网页端也有共用查询和其他限额提示触发的查询。但这些都不等于会持续更新某个特定磁盘文件。

目前没有找到 Desktop 对外提供的、无需配置且无条件实时更新的本地额度接口。纯读盘只能取得官方客户端此前已获得并落盘的状态；本地读得更频繁不能让服务器读数更新。

## 本机静态证据

- 包：`~/.local/libexec/claude-adapter/desktop/Claude.app`，Info.plist 版本 `4.4212.0`。只读该包，没有修改适配器、网络路径或应用。
- `app.asar` SHA-256：`0f8f7d420223874fbcfc8de8e29a978d0a04bb2ae620d4b454dc3714f275035c`。
- 主逻辑位置：`.vite/build/index.chunk-m4oMImJ-.js` 的 `plan-usage` / `plan-usage-history` 区域；网页查询在 `ion-dist.asar` 的 `shared-127-C581mZTe.js` 等资源。
- 下面是静态代码中存在的分支，不表示本机每个条件都已通过实机切换验证，也不保证其他 Desktop 版本相同。没有为验证触发条件而操作 UI 或触发请求。

### Desktop 后台轮询

| 条件 | 当前包的行为 |
| --- | --- |
| 功能启用、初始化轮询 | 立即尝试一次；需要可用的组织后端和登录/组织状态 |
| 普通后台状态 | 基础间隔 900,000 ms，即 15 分钟 |
| 最近一次托盘交互之后的 30 分钟 | 基础间隔 300,000 ms，即 5 分钟 |
| 右键托盘／托盘刷新操作 | 触发刷新尝试，记录交互时间 |
| 锁屏，或系统空闲至少 600 秒 | 跳过该次后台检查；解锁可恢复此前因空闲跳过的检查 |
| 超过配置允许的最近托盘打开时长，或没有此记录 | 暂停后台轮询；该限制可由远程功能配置控制 |
| 功能关闭、无有效组织、退出登录、网络/解析失败 | 不会产生可用的新额度状态 |

还存在组织切换和网页发来的刷新提示。5/15 分钟是满足条件时的请求调度间隔，不是读数更新承诺。失败重试、服务器返回内容与 HTTP 缓存写入不能从这个定时器推出。

本机 `~/Library/Logs/Claude/main.log` 存在以下明确日志：轮询要求最近 86,400,000 ms（24 小时）打开过托盘，以及因托盘未近期打开而暂停。现有 `config.json` 中没有 `planUsageLastTrayOpenAt`。这些是暂停路径的实际证据；不能仅凭旧日志断言当前进程这一刻必定处于该状态，也没有排除功能开关或请求失败等其他条件。

### 独立历史文件

`plan-usage-history.json` 是上述后台请求成功之后追加的历史，不是服务器推送接口。

- 同一组织采样最短间隔 270,000 ms（4.5 分钟），保留约 30 天。
- 真实后台调度可能是 5 分钟、15 分钟，或暂停，因此“Desktop 运行就每 5 分钟写入”不成立。
- 请求成功时可追加采样，即使百分比没有变化；“只是用量没变所以时间旧”不足以解释长期停止。
- 完整窗口/重置状态的 `plan-usage` provider 在当前代码里是内存对象（EventEmitter），没有发现该 provider 自己写另一份完整额度快照文件。
- 本机历史文件仍只有一个 2026-11-03 18:03:24 采样。不能把它当作当前额度。

### 网页 HTTP 磁盘缓存

- VibeMenu 证实 Settings → Usage 是一种触发入口，读取 Chromium Simple Cache 中的既有响应。
- 当前网页资源的额度查询默认挂载/窗口重新聚焦时可重新取数，数据 staleTime 为 5 分钟；具体 refetchInterval 由调用者提供，且后台定时取数默认关闭。staleTime 不代表存在每 5 分钟定时请求。
- 还发现限额提示/探测相关的 usage 查询，所以不能说只有额度页才可能请求这个端点。
- 网页查询、后台主进程查询及带不同查询参数的请求是不同路径；不能假定它们都会刷新同一个缓存条目。
- 200 响应、304 重验证、缓存策略和淘汰会影响是否仍有可解码正文。VibeMenu 的 15 秒是读取器扫描节流，不能当成官方刷新周期。
- 本次复读仍取得 2026-11-03 23:59:52 的缓存：5 小时 13%、7 天 29%。这与 18:03 的历史文件不同，进一步说明两者不能当成同一条持续同步的来源。

## 其他纯本地途径

| 来源 | 能取得什么 | 更新与限制 |
| --- | --- | --- |
| Claude Code 官方 statusLine stdin | 真实 5h/7d 已用百分比及重置时间 | 第一条 API 响应之后才可能出现；随会话事件更新。采集脚本只处理官方已经给出的数据，无需自己调用账号接口，但需要用户启用本地采集 |
| statusLine refreshInterval | 定时重跑采集/显示脚本 | 不会自行取得新的服务器额度，不能把重复执行当成新采样 |
| Desktop 后台历史与 HTTP 缓存 | 真实的最近已落盘状态 | 条件更新，可能旧、缺失或被淘汰；均不能承诺实时 |
| 普通本地会话 JSONL | Token、缓存、模型等用量 | 无法精确反推出账号剩余额度。本次六份最新日志、每份至多 256 KiB 的结构化元数据抽样没有发现 rate_limits 等额度对象；抽样不证明所有日志绝对不存在 |

同一账号/组织的 Claude 与 Claude Code 通常共用套餐额度，因此 Code 的新采样可以作为该账号的额度证据，但必须确认账号/组织一致并显示真实来源和时间；不能因机器上同时装了两款客户端就合并。额外的模型/产品专用窗口不应被 Code 只有总窗口的读数覆盖。

本轮没有发现能够独立于官方已有刷新、仅凭被动本地读取就无条件取得 Desktop 最新服务器额度的稳定方案。推荐同时接受上述可靠本地来源，选择同账号中更新时间最新且字段可证实的数据；无新采样则明确显示历史/过期，不模拟“实时”。不打开隐藏页面、不做自动 CLI `/usage` 查询、不追加网络回退。

## 公开来源

- [VibeMenu 决策说明](https://github.com/Kirill-Chistov/VibeMenu/blob/master/docs/decisions/0016-claude-usage-limits.md) 与 [只读缓存读取器](https://github.com/Kirill-Chistov/VibeMenu/blob/master/Sources/VibeMenuCore/ClaudeDesktopUsageCacheReader.swift)：额度页缓存、304/淘汰、扫描节流。
- [Token Monitor PR #1126](https://github.com/Javis603/token-monitor/pull/1126) 与 [其本地历史读取实现](https://github.com/Javis603/token-monitor/blob/47b18ecaf094b296f80afef0f0ee4096b885960f/src/shared/providers/claude/desktopPlanUsage.js)：反编译/观察得出的私有历史格式，PR 仍 open；其约五分钟的说法需受本机静态代码条件修正。
- [官方 statusLine 文档](https://code.claude.com/docs/en/statusline)：执行时机、rate_limits 字段、字段缺失条件及 refreshInterval。
- [官方额度说明](https://support.claude.com/en/articles/11647753-how-do-usage-and-length-limits-work)：不同 Claude 产品入口共用账号额度。
