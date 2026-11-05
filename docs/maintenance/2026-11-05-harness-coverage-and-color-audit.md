# Harness 接入与统一配色核查

日期：2026-11-05。源码基线：`d39e3acfbeee557323a2d6eb884736c4ecb86f99`，分支 `codex/legacy-debt-20261104`。

后续：用户已批准并完成 Antigravity 三项源码接入及模型配色统一，见 [接入与验证记录](2026-11-05-antigravity-integration.md)。下文保留接入前的核查基线，不能作为接入后的当前状态表。

## 结论

当前确有接入缺口。底层 AgentSpeed 的 Swift 读取器列出 **13 种来源**，但产品的客户端注册、统一账本与显示范围只接了 **6 种**。Antigravity 属于剩余 7 种之一：底层能读，本机有数据，但没有完整进入首页用量、参考费用、侧栏速度和任务条的正式链路。“全部客户端”目前表示已注册的 6 种，不能覆盖全部底层来源。

颜色也没有完全统一。价格卡对旧模型使用灰色默认值，速度和任务条使用模型色；已有首页双击改色入口和共享颜色配置，但模型占比条的缓存没有随颜色配置一起失效。

本轮仅排查和记录，没有修改产品代码、用户设置或账本，没有启动上报、调用提供方接口、安装或发布。只读识别的安装版仍为 **0.9.11 / build 992**；下面的接入矩阵描述候选源码，不能等同于该安装版已运行候选修复。

## 1. 哪些接了，哪些没接

“已接”指候选源码存在采集/适配、范围选择和实际展示路径，不代表本机已启用，也不代表已用该客户端做实时验收。“费用”指用量按价表计算的参考费用，不是第三方中转站账单或余额。

| Harness | Token、历史与参考费用汇总 | 本地活动速度/速度条 | 主任务与子 Agent 任务条 | 核查依据 |
| --- | --- | --- | --- | --- |
| Codex | 已接，使用独立 Codex 账本后统一投影 | 已接 | 已接 | A、B、C |
| Claude Code | 已接 | 已接，独立 Claude 本地运行时 | 已接 | A、B、C |
| Claude Desktop | 已接 | 已接，独立 Claude 本地运行时 | 已接 | A、B、C |
| DeepSeek Harness / DSH | 已接 | 已接 | 未接入任务汇总 | A、B、C |
| Gemini CLI | 已接 | 已接 | 未接入任务汇总 | A、B、C |
| OpenCode | 已接 | 已接 | 未接入任务汇总 | A、B、C |
| Antigravity | 未接入产品账本/首页汇总 | 未接入正式本地显示范围 | 未接 | A、B、D |
| Oh My Pi / `omp` | 未接入产品账本/首页汇总 | 未接入正式本地显示范围 | 未接 | A、B、D |
| WorkBuddy / `workbuddy` | 未接入产品账本/首页汇总 | 未接入正式本地显示范围 | 未接 | A、B、D |
| WorkBuddy AI / `workbuddyAi` | 未接入产品账本/首页汇总 | 未接入正式本地显示范围 | 未接 | A、B、D |
| ZCode / `zcode` | 未接入产品账本/首页汇总 | 未接入正式本地显示范围 | 未接 | A、B、D |
| Kimi / `kimi` | 未接入产品账本/首页汇总 | 未接入正式本地显示范围 | 未接 | A、B、D |
| Grok Build / `grokBuild` | 未接入产品账本/首页汇总 | 未接入正式本地显示范围 | 未接 | A、B、D |

速度口径需单列：表中的活动速度支持多个来源；正文生成 TPS 的独立计时链路仍是 Codex。Claude Code 的可选 statusline API 耗时速率不等于正文生成 TPS，不能把这三种口径称作同一项已覆盖。

额度也不是 Token 接入的自动附属能力。Codex 有订阅额度路径；Claude Code、Claude Desktop 有各自的本地额度缓存读取路径，其余来源尚无产品额度接入。已确认 API 连接应沿用本分支的“不适用订阅额度”处理，继续用量统计，不通过反复请求官方额度来补接入。此前修复见 [API 模式与已知费用](2026-11-05-api-mode-and-known-cost-fix.md)。

### A. 产品注册与统一账本

- `Sources/CodexTokenBar/MultiClientUsageModels.swift:3` 的 `UsageClient` 只有 Claude Code、Claude Desktop、DSH、Gemini、OpenCode；Codex 在自己的账本中处理。
- `tauri-app/src/multiClient/MultiClientUsage.tsx:7` 和 `tauri-app/src-tauri/src/core/multi_client_usage.rs:270` 使用同样的五种外部来源。
- `Sources/CodexTokenBar/MultiClientUsageStore.swift:435`、`IntegratedClientPresentation.swift:5`；Tauri 的 `multiClient/useClientScope.ts:41`、`integratedClientModel.ts:26` 将这些已注册、可用的客户端组成显示范围。
- 已注册客户端的历史 Token/费用通过 `ClientDashboardProjection.swift`（包含 `ClientModelCostPeriods`），以及 Tauri 的 `originalDashboardProjection.ts`（包含 `clientCostPeriods`）汇总到原有首页。这里已有统一投影，不需要为接 Antigravity 强制合并两个物理数据库。

### B. 本地活动速度的实际入口

- Swift `ActivitySourceConfiguration.swift:42`、`:51` 仅映射 Codex、DSH、Gemini、OpenCode；Claude 走独立本地运行时。`ActivitySpeedPresentation.swift:64` 再按允许来源过滤，`QuotaSidebarViews.swift:185` 组合选中的速率。
- Tauri `multiClient/activitySpeedMode.tsx:64` 按 `allowed` 过滤；`components/liveRate/SpeedDisplayControls.tsx:51` 使用带客户端范围的本地运行时。
- Rust `core/claude_local_runtime.rs:10` 的运行时白名单只有上述六种。Windows helper 的 `tools/ClaudeLocalReader/Program.cs:244` 同样只接受这六种 `--source` 参数。
- 因此不能只给前端加一个 Antigravity 名称，就宣称 Mac、Rust/Windows、本地采集和持久统计全部接通。

### C. 任务条比活动速度的覆盖更少

Swift `ClientLocalRuntimePresentation.swift:16` 的任务汇总仅组合 Codex 和 Claude。Tauri `multiClient/ClaudeLocalRuntime.tsx:118` 把 `mainAgents`、`subagents` 限定在 Claude Code/Desktop，再由侧栏与 Codex 任务组合。DSH、Gemini、OpenCode 虽能提供活动速度，任务数尚未进入这里。

此前十格任务条修复改变的是已有任务数据的显示方式，没有新增 Harness 任务采集能力。不能把十格组件通过验证，解释为所有客户端的任务都已接入。

### D. 底层和上报支持不等于本地首页接入

`Vendor/AgentSpeed/macos/Sources/AgentSpeedCore/Models.swift:3` 的 `SourceKind` 包括表中 13 种来源。`AgentSpeedReportingController.swift:24`、`:129` 的上报来源包含除 Claude Code/Desktop 外的来源；Claude 上报仍明确禁止。

上报设置列出 Antigravity 等来源，是另一条功能链路。Tauri `commands/agent_speed_reporting.rs:13` 明确让上报进程的本地显示关闭，实际显示由 scoped local runtime 承担；旧上报 DTO 或显示端点出现 `antigravity` 字段，不能作为首页已接入的证据。本机原有上报设置为开启，本轮没有改变它，也没有借此发起读取或上报。

另有待后续定向核验的 Swift 范围风险：`SharedAgentSpeedMonitor.swift:44` 发布池中合并快照，而 `LocalAgentSpeedReading.project` 可遍历所有来源。若较宽的上报订阅与局部显示共用池，某些菜单/悬浮显示可能出现和正式侧栏不同的范围。本轮没有复现此 UI 组合，本机速度模式为 `bar`，因此不把它当作已证实的当前故障。

## 2. Antigravity 的本机举证

### 机器上有源数据

只读枚举得到 Antigravity 安装版本 **2.26.0**：

| 默认来源目录 | 观测 |
| --- | --- |
| `~/.gemini/antigravity-cli/conversations` | 500 个 `.db`；最近文件时间为 2026-11-05 14:13:27 +08:00 |
| `~/.gemini/antigravity/conversations` | 第一次枚举 42 个 `.db`、22 个 `.pb`；最近文件时间为同日 20:43:06 +08:00 |
| `~/.gemini/antigravity-ide/conversations` | 不存在 |

随后只读结构抽样时，桌面目录已经有 43 个 UUID 数据库；两个采样不是同一事务快照，源目录继续变化。稳定的结论是 **500 个 CLI 库和 40 多个桌面库**，不能固定写成永远 542 个，也不能把文件数当作有用量的请求数。

从 CLI 和桌面目录各选一个最新数据库，以 `mode=ro`、`query_only` 检查结构；两者的 `steps` 表均有读取器要求的 `idx / step_type / status / metadata` 字段，分别有 5、20 行。未输出会话正文、标题、原始 metadata 或凭据。这只证明两个样本的必要结构满足条件，尚未证明全量真实 Token、模型、计时和费用解析均正确。

底层对应实现：`Monitor/TranscriptLocations.swift:92` 定义上述默认目录；`IO/TranscriptDiscovery.swift:121` 只接受会话目录直属的 UUID `.db`；`Antigravity/AntigravityDatabase.swift:11` 定义必要列；`AntigravityReader.swift` 实现首次完整读取与后续增量。`.pb` 文件不由这条数据库读取路径覆盖，不能直接计作已支持历史；其与 `.db` 是否重叠，本轮未判断。

### 产品函数确实会过滤它

`scratch/integrated-recovery/harness-coverage-audit-20261105/observe-product.mjs` 直接加载候选生产 TypeScript 函数，以合成数据检查：

```text
默认注册：claudeCode, claudeDesktop, deepseek, gemini, opencode
最大 all 范围：codex + 上述五种
输入：client=antigravity, model=gemini-4-argon, outputTps=88
按当前 all 范围汇总：[]
仅在进程内手动把 antigravity 加入 allowed 后：gemini-4-argon = 88 t/s
```

88 t/s 是验证过滤行为的合成数值，不是本机实测速率。结果说明范围注册是一个确定断点；并不说明只改这个数组就完成了上游订阅、账本和任务接入。

同次调用 `referencePrice('gemini-4-argon', 2026-11-05)` 能返回 `$2.00 / $10.00` 的输入/输出参考单价。底层还有 Antigravity 模型别名与计费回归。**“价表里有这个模型”与“这个 Harness 的实际用量进入费用卡”是两回事。**

### 当前业务库和开关

2026-11-05 20:50:54 +08:00 对本机 `multi-client-usage.sqlite` 做只读分组计数：

| client | `client_usage_events` 行数 |
| --- | ---: |
| claudeCode | 201 |
| claudeDesktop | 3393 |
| 其余外部 client | 无记录 |

Codex 存在独立账本，不在这张表中，不能因此判为 Codex 漏记。OpenCode 配置已启用但此时没有账本事件；本轮未定位它是没有本地历史、路径不匹配还是采集问题，不能称本机已验收。DSH 和 Gemini 设置为未启用，不能据空表判定代码失效。

显示范围已为 `all`，因此再选择一次“全部客户端”不会解决 Antigravity 的缺口。

## 3. 颜色统一和首页自定义

已有共用配置键 `speedDisplay.customColors.v1`。Swift 的 `SpeedDisplayPreferences` 与 `ModelUsagePresentation.colorHex`，Tauri 的 `speedDisplay.ts` 与 `modelUsageColor`，提供模型颜色；任务格和速度分段也复用它。

生产函数的实测结果如下，颜色覆盖只写在测试进程的模拟存储中，未改用户设置：

| 模型/状态 | 首页价格卡 | 速度条 | 任务格 |
| --- | --- | --- | --- |
| `gpt-6-astra`，当前组默认色 | `#a3d977` | `#a3d977` | `#a3d977` |
| `gpt-5.6-luna`，旧模型组默认色 | `#87919e` | `#7595bd` | `#7595bd` |
| `claude-sonnet-4-6`，旧模型组默认色 | `#87919e` | `#c08b28` | `#c08b28` |
| `gpt-5.6-luna`，自定义 `#123abc` 后 | `#123abc` | `#123abc` | `#123abc` |

具体缺口：

1. **默认色不统一。** Swift `ModelUsagePresentation.swift:316` 和 Tauri `modelUsagePresentation.ts:178` 单独把非最新组默认色改成灰色，旧测试也明确锁定这一行为。用户现在要求全局统一，后续应同步调整规则及测试，旧模型身份不能因位于价格卡而换色。读取中过期等状态仍应有自己的状态表达。
2. **首页改色已有入口，但不直观。** Swift `DashboardHeaderView.swift:1233`、`ModelColorEditing.swift:11` 支持双击价格卡模型项打开颜色选择；Tauri `StatsStrip.tsx:270` 支持双击和 Enter/Space。已有保存和恢复默认，可做成首页明确入口，不需要新建第二套颜色设置。
3. **即时刷新不完整。** Swift `QuotaSidebarViews.swift:420`、`QuotaSidebarModuleSettingsView.swift:196` 的模型占比颜色缓存仅在模型数据变化时更新；Tauri `QuotaSidebarApp.tsx:390` 的 `useMemo` 同样没有颜色依赖。源码依赖关系可确认这个缺口，但本轮没有在安装版 UI 实际操作复现。
4. **客户端改色菜单不完整。** 两端 `ClientColorSettings` 只列 Codex、Claude Code、DSH，不能作为全部 Harness 的配色管理入口。“按模型”与“按客户端”是两个不同分组；同一模型跨 Harness 应复用同一模型色，客户端分组色应使用独立的 `client:` 键。

用户要求应落实为：**同一模型在费用、速率、任务格和模型占比处使用同一颜色，首页编辑后所有视图同步刷新，并支持恢复默认。** 单纯增加更多颜色常量无法满足这一要求。

## 4. 已跑验证和边界

| 检查 | 结果 | 能证明什么 |
| --- | --- | --- |
| Swift XCTest 定向集合 | 56 项执行，55 通过、1 个截图用例按 opt-in 跳过，0 失败 | 现有来源配置、颜色/速率、任务格、账本行为 |
| Swift Testing 应用集合 | 10 通过 | 本地速度显示与订阅隔离的既有回归 |
| Swift Testing 底层集合 | 17 通过 | Antigravity 数据库/WAL/增量/并发 fixture 与模型价格别名 |
| 前端五份测试文件 | 22 通过，0 失败、0 跳过 | 现有颜色、活动速度、价表、首页投影、侧栏契约 |
| 生产函数独立观测 | 通过断言并保留输入输出 | 上述范围过滤、颜色差异、自定义覆盖及价表查询 |
| 本机源目录与业务库 | 只读完成 | 文件存在、两个样本结构、客户端事件计数与配置 |

测试通过不表示新要求已满足：旧颜色测试正是要求历史组灰色，缺少 Antigravity 的正式产品范围也是现有代码行为。本轮没有安装候选、没有实时生成任务验收，也没有新跑 Windows 实机。日志中的耗时是测试命令用时，不是数据库扫描或产品速度指标。

证据目录：`scratch/integrated-recovery/harness-coverage-audit-20261105/`。`local-inventory.json`、`antigravity-schema-sample.json`、`local-ledger-clients.json`、`local-settings.json` 保留脱敏观测；`product-observations.json` 保留生产函数输入/输出；两组测试的 `.json` 记录命令、源码 HEAD、退出码与日志 SHA-256，`.log` 保留结果。`manifest.json` 汇总证据及相关源码哈希。

## 5. 建议收束顺序

1. 先统一现有模型颜色规则、首页编辑入口与颜色缓存刷新，使已经接入的模块一致。
2. 明确每种 Harness 的历史用量、活动速度、任务、额度能力和统一显示范围；由同一份能力清单约束各入口。以 Antigravity 为首个补齐对象，接通本地发现/开关 → 用量事件与历史账本 → 显示范围 → 费用与速度投影。任务计数要有独立可靠事件依据，不能以速度非零推算子 Agent 数量。
3. 用 Antigravity 的固定样本和真实增量分别验证模型/Token/参考费用守恒、重复扫描不重计、源日志持续增长仍能推进、停止后速度归零、跨客户端同模型汇总及颜色一致。Mac 与 Windows 的正式读取链路分别验收。
4. 其余六种底层来源，以及 DSH/Gemini/OpenCode 的任务缺口，按相同契约补齐；缺少可靠字段时明确标记不支持，不用伪造 0 或任意估算掩盖。

本轮证据指向的主要工作是**产品适配与显示能力没有随底层读取器一起扩展**，没有证据要求推倒现有账本或重写已完成的恢复、计费修复。新增来源应沿用现有保留旧账、幂等写入、已知费用保留和 API 模式不读订阅额度的规则。
