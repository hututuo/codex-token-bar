# 当前客户端能力核对

2026-10-26，分支`codex/multi-client-tokens`的源码核对。已实现不等于所有客户端均完成实机验收；隔离预览里的Codex／Claude百分比是模拟额度，不能作为真实接入证据。没有请求Anthropic，也没有安装或修改客户端。

## 结论

当前不能称Codex与Claude Code均为完整支持。Codex是原有完整主链路；Claude Code已接本地Token、会话和模型归属、已知价格下的费用估算及已有额度缓存读取，但未接TokenBar活动速条／正文TPS及任务、子Agent计数。其他几个客户端也已有本地Token解析，不能一概说「只有测速API」。

独立Agent Speed采集／上报是另一条路线。它读取支持的本地来源，而不是通过各厂商服务器API查询测速；上报接口才是网络接口。当前随默认关闭的上报选项开启，未将各客户端样本送入TokenBar的速度环／正文TPS表，不能混称同一个测速模块。

| 客户端 | 输入／输出Token | 缓存与思考字段 | 会话／模型／费用 | TokenBar速条、正文TPS | 订阅额度 | 主任务／子Agent计数 | 独立Agent Speed |
|---|---|---|---|---|---|---|---|
| Codex | 已接原账本 | 缓存、思考按现有日志字段 | 已接；原价格和账本链路 | 已接；速条为活动估算，TPS为完成正文采样 | 已接现有Codex额度通道 | 已接；当前圆环数据只来自Codex | 有来源适配 |
| Claude Code | 已接本地assistant记录 | cache-read／cache-write；thinking字段存在才记，缺失不补零 | 本地session ID／model；已知且完整价格条件下估算 | 未接入这两条轨道 | 只读已有本地statusline缓存；没有就未接入 | 未接入 | 有来源适配 |
| Claude Desktop | 仅本地Code／Agent记录 | 同Claude解析器；不含云端聊天全量 | 本地session ID／model；已知价格才估算 | 未接 | 无独立Desktop额度提供者 | 未接 | 有来源适配 |
| DeepSeek Harness／DSH | 已接本地日志 | cache-read／write；思考暂无独立解析 | session／model；未知模型或价格不伪造费用 | 未接 | 未接 | 未接 | 有来源适配 |
| Gemini CLI | 已接本地日志 | cache-read；thoughts保留为思考子集；无cache-write | session／model；未知价格不伪造 | 未接 | 未接 | 未接 | 有来源适配 |
| OpenCode | 已接本地日志／只读SQLite | cache-read／write／reasoning | session／model；已知价格才估算 | 未接 | 未接 | 未接 | 有来源适配 |
| omp、Antigravity、WorkBuddy、WorkBuddy AI、ZCode、Kimi、Grok Build | 未并入TokenBar用量账本 | 未并入 | 未并入主界面统计 | 未接 | 未接 | 未接 | 只有独立路线的来源适配 |

所有「字段已接」均以实际本地记录提供该字段为前提；来源不可读／没有记录不等于用量为0。费用为API等值估算，不是订阅实际扣费。外部客户端读取默认关闭，先发现再由用户启用。

## Claude额度的实际限制

读取`~/.claude-monitor/statusline/latest.json`，要求已有Claude-Code-Usage-Monitor状态行捕获。文件最多64KiB，时间戳超过10分钟标旧，不安装hook、不读凭据、不启动Claude、不联网。缓存尚未绑定当前账号／进程，不能当作自动登录或严格跨账号余额验证。联网提供者仍保持未实现／默认关闭。

## 可定位的源码依据

- 独立来源列表：`Vendor/AgentSpeed/macos/Sources/AgentSpeedCore/Models.swift`的`SourceKind`；Windows对应`Vendor/AgentSpeed/windows/src/AgentSpeed.Core/Models.cs`。
- 主速条／正文TPS的Codex范围限制：`Sources/CodexTokenBar/QuotaSidebarViews.swift`的`supportsCodex`、`rateRing`、`QuotaSidebarBodySpeedReadings`；`tauri-app/src/quota-sidebar/QuotaSidebarApp.tsx`的`scopeHasCodex`及`SidebarBodySpeeds`。正文采样：`ThroughputTelemetry.swift`。
- 本地用量解析：`Sources/CodexTokenBar/MultiClientUsageParsers.swift`中的`claudeEvent`、`deepSeekEvent`、`geminiEvent`、`openCodeEvent`；Rust对应`tauri-app/src-tauri/src/core/multi_client_usage.rs`。
- 会话／模型账本及价格：`MultiClientUsageModels.swift`、`MultiClientUsageLedger.swift`、`ClientDashboardProjection.swift`；Tauri对应`originalDashboardProjection.ts`。
- Claude额度：`Sources/CodexTokenBar/ClaudeLocalQuota.swift`、`MultiClientProduct.swift`，Rust的`multi_client_usage.rs`／`multi_client_product.rs`。
- Codex额度：`AccountQuotaReader.swift`、Rust`core/quota/persistent.rs`的`account/rateLimits/read`。
- 任务计数：`RunningThreadScanner.swift`只扫描Codex数据源；Rust`commands/thread_activity.rs`要求Codex来源token。
- 独立上报开关／实现：`AgentSpeedReportingController.swift`、`AgentSpeedReportingView.swift`、`tools/AgentSpeedReporter/ReporterRuntime.cs`、Rust`commands/agent_speed_reporting.rs`。

本次范围为能力核对与侧栏交互修正，没有扩展Claude实时速度或任务计数，也没有改变默认关闭的网络上报／额度边界。

核对中发现的误导显示已修正：单看Claude等不含Codex的范围时，不再展示Codex任务圈／状态条；汇总范围仍显示Codex任务，并在帮助信息中说明归属。
