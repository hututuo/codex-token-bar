# 功能区统一入口收束

基线：`109350b6310d6d544f89719396f434b89dd55c32`，工作树 `f97f`，分支 `codex/storage-responsibility-split-20261106`。

产品源码：`ba88596d86cbbba28b4b5b2c524b3000aeda6a57`，版本 `0.9.11 / build1008`。L1–L7 已实施并完成功能入口扫描，同SHA的完整CI、Public097、双端打包和8项formed历史矩阵全部通过；下载产物与原始执行证据已核验归档。build1008 已安装并完成启动、首刷与安装确认，macOS GUI 已测试。当前总记录为 **GUI_TESTED_WITH_FINDINGS；installed=true、guiTested=true**：侧栏速率详情与可见多客户端图表通过所列检查，但框选气泡的辅助功能容器摘要仍读 Codex 模型归因，尚未完成全部入口闭环，不能宣称所有验收项通过。本机没有运行构建/测试套件；既有脏文件、scratch、A–D 存储合同保留。

## L1：实时速率

定位：三级缺少圆圈对应的模型速度条；圆圈/设置预览各自选择速率与配色，Swift morph 仍直接使用模型色。旧速率 API 依赖调用者事先排除来源重叠；当前配置已明确排除 upstream 的 Claude，未发现重复计数实证。新入口按客户端选择 reader，保留该隔离。

合同：每个客户端只选择一个速率 reader；先按来源核对总值和未知残差，再生成 client+model 行。实时 total、modelRates、colorRates、行 share 与相对最大值条长来自同一快照。行保留客户端、原始模型、采样时间和来源标识；不同客户端同名模型保留独立行。颜色/短名复用现有注册表，数字统一一位小数。停用/不可用归零，状态不伪装为正常空闲。

| 入口 | 权威投影 | 消费者 |
| --- | --- | --- |
| Codex Bar / 本地 Claude / upstream 本地观察 | Swift `ClientLocalRuntimePresentation.liveRate` → `ModelRatePresentation.snapshot`；TS 对应纯投影及 reader adapter | 二级圆圈、一级竖条、morph、设置预览、三级实时模型条 |
| 正文完成样本 | 既有 Body TPS 投影 | 正文 TPS 历史，不加入实时 total |
| 近三分钟观察序列 | 既有活动历史 | 活动折线图，不以窗口均值替代实时条 |

检查：新增双端 `Tests/SharedFixtures/live-model-rates.json`、生产圆圈/模型条组件回归、非法值/停用/切源/来源身份/配色检查。`93d46fea` 云端前端通过，Swift 新行视图类型推导超时；`fe38279c` 拆成明确的名称/轨道/行组件。修订的 Public097 `42680101699` 与完整 CI `42680102143` 均通过；最终集成候选重新执行全套门禁，见文末。macOS 实机已完成二级圆圈打开三级、两种模式×两种配色、收起重开；同时活跃的多模型/多客户端组合仍以共享fixture为证，不伪造实机流量。

## L2：趋势桶与多客户端用量摘要

定位：`RecentUsageChartData.prepare` 与 TS `prepareRecentChartData` 因细序列覆盖情况将 7d 改为 300 秒；B 库趋势查询按 client/time 合并，没有模型维度；框选摘要读 Codex quota 的事件及 totals，模型只显示前三项，可能隐藏整个其他客户端。

| 入口 | 权威计算 | 消费者 |
| --- | --- | --- |
| B 已有事件与逐请求价格 | Swift `trendBuckets` / Rust `read_trend_buckets` 按 client+raw model+5m；同一只读事务，附缓存字段完整性 | 主页原图投影、图表外部贡献 |
| 原图显示范围 | Swift Range / TS RANGE_CONFIG：24h 300s、7d 3600s、30d 21600s | 单来源和汇总共用原图坐标、缩放、滚动 |
| Codex 原始模型桶 + 所选 B 趋势贡献 | Swift `RecentChartPreparedSnapshot.usageBuckets/usageSummary`；TS `buildChartUsageSnapshot/chartUsageSummary` | 曲线价格、顶部、单点 hover、固定框选、下方选区用量及所有模型 |
| Codex quota provider | 独立细序列证据；显示选区按时间映射，返回显示索引 | 额度下降、跨 reset、分钟证据、shared-account 归因；外部用量不参与 |

模型贡献保留 client 与 raw IDs，展示 alias 仅在同一 client 内合并；原生/Antigravity 同名模型不吞并。所有选区模型在有界滚动列表中可见，不再截为前三项。按原始请求计价后再合桶，未知费用与缓存完整性单独保留；不修改 B 表结构、原始记录、A 库、迁移状态机或存储连接/事务拥有者。

共享 `recent-chart-usage.json` 验证三种粒度、六种 scope、同名跨渠道、反向/单点选区、费用守恒和未知缓存。新增真实 React 图表 hover/固定选区/下方摘要回归及 Swift/Rust 同桶多模型、价格、旧 IPC 缺省回归。原 7d 细桶测试改为断言 1h 显示与 5m quota 证据同时保留，未删除低点保护。云端回归发现跨 range 的用量准备缓存被重复计算，已恢复有界三周期缓存；分桶规范进入共享 `recent-chart-policy.json`，包资源检查同步覆盖。未归因 Codex 用量保留 `codex|unknown` 残差与不完整提示，模型份额以整个显示范围为分母，不能把已知模型单独归一到100%。最终集成门禁见文末。

## 功能域推进顺序

- L2：固定 24h/7d/30d 为 5m/1h/6h；曲线、顶部、hover、选区共同消费带客户端/模型/已核算价格的桶，Codex quota 证据独立。
- L3：展示身份、计价身份、渠道身份；检查所有费用与名称/颜色消费点。
- L4：运行主/子任务聚合、source quality、标题与存活适配。
- L5：scope、IPC、异步回复、刷新和设置生命周期。
- L6：诊断事件裁剪、当前启动证据和升级回执。
- L7：剩余服务 owner 矩阵；只收束有实际重复决策证据的模块。

## L3：模型身份、渠道、名称与颜色

扫描：`ModelPresentationIdentity` / TS domain / Rust model_presentation 已共用严格身份 policy/cases，费用主页与侧栏已共用 `ClientModelCostPeriods` / `clientModelCostItems`，外部费用保留已核算逐请求价格。保留日期/TTL/长上下文计价，不合并账本身份。发现 Swift/TS 固定模型色、客户端色和客户端标题仍各维护一份；`ModelUsagePresentation` 的 key/label 与严格 identity 断开，导致完整 Thinking 人类名称不能稳定复用费用名/颜色。

收束：固定色/客户端色/标题进入既有 `model-presentation-policy.json`，无需新增独立资源加载器；Swift/TS 颜色查询复用严格 identity，raw 自定义色优先。通用 `ModelUsagePresentation.key` / `modelUsageKey` 保留已有原始身份规则，名称优先走名称注册表，再以严格 identity 回退，避免吞并包装/版本标识或回退 Grok Fast、DS 等既有名称。实时速率的规范化只限展示投影。完整 Opus/Sonnet 4.6 Thinking 名称用显式 displayAliases，Swift/TS/Rust 同一 cases 证明；不改 billingAliases。Antigravity sourceGroups 仍在 Gemini · Antigravity，Argon4 例外仍在最新主力。新增全注册表颜色与跨渠道别名/计价隔离测试；云端捕获的原始身份、名称与模型份额回归已在 `ba88596d` 修正，未放宽原断言。

## L4：运行态与父子归属

扫描：两端 Codex 生命周期 scanner 已维护 terminal 优先、24h 发现/5m 文件推进/长静默真实 writer，来源专属扫描不重复实现。Swift `ClientLocalRuntimePresentation.running` 和 TS `combinedRunningTasks` 已有 fresh/stale 聚合与来源命名空间；主页旧计数明确放在 Codex 专属工具，不能直接换成汇总后还标 Codex。Swift 一级设置预览漏了 enabled 客户端过滤。

收束：Swift `taskClients/observedRunning` 统一选择和 reader 适配，二级/三级/预览共用；主页全局区新增独立观察的小型 indicator，共用该投影，避免每次实时变化重建整页。TS 新 indicator 直接消费 `combinedRunningTasks`，复用相同计数、来源质量和父子卡片合同。Codex 专属计数保留明确范围。回归补 disabled 有历史来源与 header/详情同投影；原 lifecycle、普通 fork、terminal、真实 writer 负控完整保留。

## L5：设置与来源生命周期

扫描：Swift 配置切换会清理本地 snapshot/smoother，图表准备有 request fence；TS `useSharedChoice` 已处理存储/窗口广播和卸载，不重新包装。实际缺口是 `ClaudeLocalRuntime.poll` 未关联配置代次、最后订阅销毁后晚到回复仍可能发布；speed preferences 初始异步读取可覆盖之后的新设置，原全局事件订阅没有随消费者释放。

收束：两处使用 `SnapshotEpoch` 判定回复是否仍属于同一来源/订阅生命期。切源立即隐藏旧 snapshot、清理速率/历史/response 缓存，迟到回复不重新注入；同源重绘不额外读取。最后订阅释放后撤销 listener/timer；preferences 的初始读取不得覆盖新事件。增加真实 runtime hook 的悬挂回复/切源/卸载回归。

## L6：诊断与升级证据

扫描：Swift/Rust events collector 都先读按 UUID 名称排序的前128文件，再按到达顺序取6000行，最后排序，直接解释旧诊断包漏新启动。固定 event schema/脱敏、只读安全文件打开、probe 子进程3秒预算、升级 launched/confirmed 绑定已有单一owner，继续保留。

收束：在已有最大2048目录项/每文件512KiB及子进程超时边界内，先筛允许文件并逐条验证事件；每个文件后按 at/session/sequence 保留最新6000条，输出仍为升序。Swift/Rust 同规则，unrelated 文件不占前128名额。新增7001事件+130无关文件反例：最新build/startup必须出现、omitted准确、原文件不改。不打开数据库、不改变确认回执语义。

## L7：剩余区域 owner 与保留边界

| 功能域 | 权威 owner / 消费入口 | 扫描结论与处理 |
| --- | --- | --- |
| 费用/参考价 | `StandardAPIPriceSchedule`、B ledger per-event pricing；`ClientModelCostPeriods/clientModelCostItems` | 已收束已知费用；参考价和 quota provider 为不同合同，保留 |
| 图表准备/交互 | `RecentChartPreparationStore` / bounded React prepared+usage cache | L2收束；追加共享 `recent-chart-policy.json` 与包资源测试，3range复用，旧scope无效化 |
| client scope/来源 | `ClientDisplayScope`、`useClientScope/useSharedChoice`；reader配置与source token | 页面/图表/侧栏显式独立选择是产品合同；L5只修真实晚到回复缺口 |
| 活动速度/正文TPS | `ActivitySpeedHistoryController` / local history；BodySpeed stores / stream reader | 实时、完成正文、窗口均值不同量；L1统一实时展示，保留历史生命周期 |
| Codex任务 | `RunningThreadScanner/RunningThreadLiveness`；Rust thread_activity/liveness | 不复制扫描；L4统一已有来源投影；不改24h/5m/terminal规则 |
| ModelTrace/榜单/上报 | `ModelTraceController/Probe` 与 commands/modeltrace；reporting controller/commands | 手动探测与显式上报分属权限owner；不因显示开启上报，不合并授权 |
| quota/API模式 | `AccountQuotaStore`、client quota providers；connection_mode 与前端quota合同 | 真实额度与API费用不同，未发现本轮需要合并的授权/计价入口 |
| 诊断/更新 | diagnostics fixed schema/collector、Sparkle/NSIS/install receipts | L6修最新事件保留，原只读/脱敏/超时/确认负控继续 |
| A/B库与备份恢复 | A Exact/route A–D owner；B multi-client ledger | 只扩B只读趋势维度，SQL schema、迁移、发布、连接/Drop、stage生命周期不动；最终追加历史formed矩阵 |
| Vendor/共享规范 | UPSTREAM pin + patch hashes；Resources policy/cases/price history | 不改vendor；沿用打包资源复制与云端完整性检查 |

全仓功能域扫描以入口/权威决策/消费端为单位，不以1162个源文件逐行无问题或“大文件拆短”为完成声明。现有分层正确的 provider/parser/存储边界保留；性能A/B与实体Windows GUI未执行，不能用本轮源码/云端结果替代。

## 提交与可回退边界

| 功能 | 提交 |
| --- | --- |
| L1 实时模型速率与视图接线 | `93d46fea`、`fe38279c` |
| L2 分桶、全客户端模型/金额摘要、quota 时间映射与缓存 | `56f94a22`、`3a8b3de0` |
| L3 共享展示策略 | `e95059ba` |
| L4 任务范围投影 | `b735c7d3` |
| L5 设置/来源生命周期 | `4a06fa4e` |
| L6 最新诊断事件 | `ea153ed0` |
| 功能域 owner 矩阵 | `e263c3b4` |
| 集成回归修正：原始身份、残差分母、TS narrowing、测试环境 listener | `ba88596d` |

产品源码固定为 `ba88596d`，后续证据文档提交不改变包的源码身份。已安装应用为 `0.9.11 / build1008`；build1007 的备份和被替换原件均保留于本批独立安装目录。没有创建公开 tag/Release、更新 appcast 或改动 vendor。源码回退可按功能提交 review/revert；实机回退可使用已验证的 build1007 备份，不能删除或覆盖历史备份。本次收尾仅更新验证文档和仓库外证据，不修改产品源码。

## 已安装运行态与 macOS 实机验收

原安装前停止线已进入后续安装/实机阶段；本节替换此前的 NOT_RUN 计划。此次用户明确授权使用 JXA、Accessibility action、CGEvent、screencapture 操作非激活 NSPanel，并要求提交验证文档。没有以工具限制为由更换程序、修改存储或启动本机构建。

证据子目录为 `local-install-1008-jMzbnP3E/`，相对下文归档根目录。`installation.json`、`runtime-validation.json` 与 `gui-validation.json` 分别记录安装、启动完成、界面检查，不相互替代。已有34组图表/主页截图与AX文本，本次新增8张侧栏PNG；原图、文本、诊断ZIP及操作记录的大小/SHA256统一保存在 `gui-validation.json`。前34张由既有截图工具输出，文件名虽为 `.png`，实际编码为JPEG；按字节格式登记并保留原件，未重新编码冒充原始证据。截图只留本机，仓库仅提交脱敏结论与索引。

| 检查 | 实测证据与结论 |
| --- | --- |
| 安装身份与回退 | `/Applications/Codex Token Bar.app` 为0.9.11/build1008；运行PID73933映射到该路径，可执行hash为 `baad6e73…b9fdce`。`backup-build1007/Codex Token Bar.app` 与被替换原件均保留；备份可执行hash复核为 `22dd9f96…da2f` |
| 首刷与安装确认 | 同一安装attempt的launched、startup ready、后端completed、UI completed、refresh ready、confirmed均存在。首刷从launch到ready为31.277秒；4385文件完成、pending0、schema14、generation27356；不是滚动性能指标 |
| 诊断新事件保留 | `post-refresh-diagnostics.zip`保留最新6000事件、遗漏计数21999，包含当前session及startup/refresh/confirmed；已检查固定字段与脱敏，未查询业务数据库 |
| 二级圆圈→三级详情 | 当前窗口几何定位 `CodexTokenBarQuotaSidebar`，AXPress `quota-sidebar-rate` 打开 `CodexTokenBarQuotaSidebarDetail`；首屏可见色点、Astra6、Codex、速度条、tok/s，正文TPS仍独立 |
| Bar/按模型与按客户端 | `sidebar-rate-tiers-same-frame.png`同屏圆圈/总值/模型行均12.4 tok/s；`sidebar-client-colors.png`均34.0 tok/s，圆圈、色点和条同时换为客户端色 |
| Agent Speed/两种配色 | `sidebar-agent-speed-client-settled.png`三处均13.8 tok/s；`sidebar-agent-speed-model.png`三处均18.1 tok/s，模型身份仍为Astra6/Codex。没有更改已有上报授权/设置 |
| 收起与重新打开 | 详情消失后再次悬停展开、AXPress打开；`sidebar-rate-reopened.png`三处均22.6 tok/s。最终恢复“活动估算/按模型”，侧栏回到16pt收起态，详情窗口不再显示；原PID仍存活 |
| 三周期与来源 | 既有截图/AX记录覆盖汇总、Codex、Antigravity、Claude Desktop的24h/7d/30d，以及Claude CLI空记录视图；粒度文字固定5分钟/1小时/6小时。切源清除旧选区，单点、正向/反向固定选区与关闭气泡有留档 |
| 可见框选模型与金额 | 汇总24h同时显示Argon4/Antigravity、Astra6/Codex、Opus5.5/Claude Desktop；7d/30d继续保留跨渠道同名Opus、更多模型和未报告模型。浮动气泡与下方摘要的显示值一致；精确Token/费用守恒仍由共享fixture和生产回归证明 |
| 费用与任务 | 今日、近7天、累计费用界面已有记录；Argon4与Antigravity分组按现有实机数据核验。主页和侧栏均观察到主1/子0；不是同帧的跨窗口计数证明，不据此替代生命周期fixture |

截图中的速率是采样时刻的数值，不是固定性能基准。第一张 `sidebar-agent-speed-client.png` 恰逢二级数字过渡动画，保留原图并用后续稳定同屏图核对；AX逐控件读取也不是原子快照，不能将一次遍历中不同采样时刻的数字作为守恒依据。

### 实机发现与尚未覆盖范围

**OPEN — 图表框选容器的辅助功能摘要仍为Codex口径。** `chart-aggregate-24h-fixed.txt`的容器摘要报“模型占比 Astra6 100%”，但同一容器的可见子列表实际为Argon4 49%（Antigravity）、Astra6 40%（Codex）、Opus5.5 11%（Claude Desktop）；7d/30d亦能复现摘要/列表分歧。源码 `ChartSelectionSummaryBubble.accessibilitySummary` 仍调用 `selection.fullAttributionEvents`，没有使用已接入可见列表的 `usage` 模型集合。这个问题影响辅助技术读取容器摘要；本轮仅登记，不修改源码或把旧云端门禁标成修复证明。下一源码候选需要收束该入口，添加同一汇总选区的AX摘要/可见模型一致性回归，再完成云端门禁。

以下仍为NOT_RUN或fixture-only：Windows实体GUI；同时有多个客户端/多个模型实时生成时的侧栏现场测试；自定义色编辑、停用/过期/零速率现场矩阵；本机没有记录的Gemini CLI及Antigravity Thinking模型组合；完整滚动性能A/B；Finder安装器外观和完整权限保留矩阵。`guiTested=true`只表示已执行上述macOS检查，`allAcceptanceCriteriaPassed=false`明确保留这些边界及AX发现。

## 云端与安装包证据

归档根目录：`/Users/huyiyang/Library/Application Support/CodexTokenBar-Maintenance/2026-11-10-functional-consolidation/ba88596d/`。每个run独立目录，保留原ZIP、GitHub artifact摘要、解压文件及下载回执；构件核验阶段只读取云端产物。后续安装与GUI证据另存上述安装子目录；本机始终没有执行构建或测试套件。

| 门禁 | Run | 结果 |
| --- | --- | --- |
| 完整 Hosted project checks | [42692564247](https://github.com/hututuo/codex-token-bar/actions/runs/42692564247) | PASS，原始 `ci-execution.json` 与 `checked-source.json` 同源 |
| Public v0.9.7 database upgrade | [42692564607](https://github.com/hututuo/codex-token-bar/actions/runs/42692564607) | PASS，双平台 |
| Prepare hosted installers / build1008 | [42693284176](https://github.com/hututuo/codex-token-bar/actions/runs/42693284176) | PASS，macOS ARM64与Windows x64/ARM64已下载核验 |
| formed 0.9.8–0.9.11 双平台 | [42693285673](https://github.com/hututuo/codex-token-bar/actions/runs/42693285673) | PASS，8/8；独立补充，不代替完整CI |

所有run均使用 `ba88596d86cbbba28b4b5b2c524b3000aeda6a57`。本地 `verified-checks.json` 复验云端原始记录、日志hash、65项Swift/72项Rust原门禁必跑测试和本轮新增测试；不生成或伪造云端通过收据。Swift/Rust执行前后 tracked diff 均为空，无未授权untracked输入；`workingTreeDirty=true`只来自明确登记的日志、生产报告和视觉预览。

| 实际执行 | 通过 | 既有跳过/忽略 |
| --- | ---: | ---: |
| XCTest | 2446 | 38 |
| Swift Testing | 676 | 0 |
| Rust macOS | 1830 | 14 |
| Rust Windows | 1773 | 14 |
| 前端 | 1466 | 0 |
| 云端脚本 | 18 | 0 |
| 发布脚本 | 112 | 1 |

双平台各16项生产恢复场景通过官方report validator；backup cleanup负控均为0/101/0，route identity负控均为0/1/0，负控编译成功后命中指定失败，恢复后六入口拒绝有效物理A替换，marker和原/替换文件保留。没有用任意编译失败代替负控。

Public097的真实旧tag为 `0219554ce444b0013987da7b82e3c2e891f4afdb`：Swift升级8项、支持回归106项、Rust升级3项、4个非test生产阶段和19个旧manifest场景通过。本地 `verified-public097.json` 绑定日志中的具体测试/阶段及旧版本身份；其中 `--nocapture` 日志按完整测试名、proof marker、换行后的ok和最终数量核对。

formed矩阵8份报告、每份237个候选生产文件blob身份已复核；每个版本/平台都覆盖committed/interrupted恢复后各3次独立重启，64条阶段报告通过官方 `parse_report`，恢复材料manifest与迁移状态hash不变。注意interrupted旧producer在B形成前退出，其 `formedB=false` / `oldBPreserved=false` 是原测试合同；committed必须为true，不可把前者误报为旧B丢失。详见 `verified-formed.json` 和原始 `*-formed-state.json`。

本轮云端视觉预览已归档，离线查看模型名称卡片、紧凑主子任务层级和侧栏速度布局；新实时模型条另有Swift实际布局测量与React生产组件断言。云端证据与上文后续已安装GUI证据分开记录，后者也不代表所有客户端/状态矩阵均实测。

打包预检沿用 `release-macos-app` 的完整性、签名、更新配置和依赖边界检查。没有新增依赖、改动lockfile/权限或重新实现更新器；npm官方registry替换参数保持原样。`agent_speed_vendor.py check`通过，Vendor与本轮基线无差异。打包使用已审阅pin `a94a67fcc78e5d8eea5f82d8d5e737bccf994e2c`，并明确记录保留原因；观察到的上游HEAD `6a4d110480d133360e3be8a2e7944ac2b6511e87` 未在本轮集成，不能将pin豁免描述成已追平上游。

此包为内部验收候选：ad-hoc签名、未公证、无更新签名、未公开发布。macOS安装运行与所列GUI已验证，Finder安装器外观与完整权限保留矩阵仍未执行。

macOS包在安装前于 `staged-macos/Codex Token Bar.app` 独立解压核验：`CFBundleShortVersionString=0.9.11`、`CFBundleVersion=1008`、`lipo=arm64`；`codesign --verify --deep --strict`、diagnostics helper签名、`hdiutil verify`通过；designated requirement、Sparkle feed和公钥与当时的build1007一致。模型/图表/分组/价格共6份资源与候选源码逐字节相等。Gatekeeper的未公证拒绝符合ad-hoc候选属性，不标成公证通过。`app-validation.json`保留安装前的时间点状态；后续安装运行状态以 `final-validation.json` 和安装子目录记录为准。

| macOS产物 | bytes | SHA256 |
| --- | ---: | --- |
| `CodexTokenBar-v0.9.11-macos-arm64.app.zip` | 28704592 | `5fa5d378c4de1a7d8b554273530e6243c6ffe7b61f94e97191468b04384e61b0` |
| `CodexTokenBar-v0.9.11-macos-arm64.dmg` | 29791319 | `a4c5480000b5231f43e2203a126c62c19f6ece548af17cf6fdb89ca58315e777` |
| app内 `CodexTokenBar` | — | `baad6e73a97de1760234bed5e4f011f57ba1ad7879ae25d1ea1ffbbf8db9fdce` |

兼容名 `CodexTokenBar.app.zip` 与版本化ZIP完全同hash。已安装build1008可执行hash与上表候选一致；保留的build1007备份hash为 `22dd9f96b4b22bda281c63774a68041181420aab673737572f6549d57972da2f`。

| Windows产物 | bytes | SHA256 |
| --- | ---: | --- |
| `CodexTokenBar-v0.9.11-windows-x64-setup.exe` | 69562261 | `e52fefd0bfb3359cccd9f5d9827d9f489b69d29b658f2c4456f1a74f9ad880dc` |
| `CodexTokenBar-v0.9.11-windows-arm64-setup.exe` | 63615589 | `290488fc621fbc7cedcb7903b42910743b11fffaa08830f4c4a6f232f7032b46` |

Windows两个架构均在真实Windows runner构建，`build-manifest.json`的版本、平台、大小、SHA256与外层candidate manifest及下载字节一致；本机未运行安装器。两条lane均通过仓库 `scripts/cloud/manifest.py verify` 的精确sourceSHA/runID/lane/asset集合检查。全部27个GitHub artifact ZIP（完整CI13、Public097 2、formed 8、打包4）的digest、size和安全解压路径已验证。

归档入口：

- `final-validation.json`：源码/云端/构件总门禁、文档HEAD、现装build1008与保护文件hash；installed/guiTested均true，GUI_TESTED_WITH_FINDINGS及未执行边界明确登记。
- `local-install-1008-jMzbnP3E/gui-validation.json`：34组原GUI记录、8张新增侧栏截图及原始证据hash清单；侧栏通过项、图表AX问题和NOT_RUN项。
- `local-install-1008-jMzbnP3E/installation.json`、`runtime-validation.json`：build1007备份位置、build1008身份、实际进程、首刷、安装确认与最新诊断包。
- `verified-checks.json`、`verified-public097.json`、`verified-formed.json`：原始执行证据的只读复验结果。
- `app-validation.json`、`app-verification.log`：双lane构件、macOS签名、资源、公钥/feed、版本架构和hash。
- `checks-42692564247/`、`public097-42692564607/`、`formed-42693285673/`、`installers-42693284176/`：各run的workflow/jobs、GitHub artifact元数据、原ZIP、解压文件和下载回执。
- `collect_artifacts.py`、`verify_evidence.py`、`verify_packages.py`：本批固定SHA的下载/只读复验脚本；不是安装器，不执行候选程序或测试套件。不能套到其他SHA冒充验证。

本轮收尾交付给Argon：build1008安装运行与授权范围内的macOS实机检查已有可复查证据，侧栏三级模型速度条验证完成；图表辅助功能摘要发现已登记为OPEN，不能将本报告视为所有入口收束完毕或公开发布批准。最终恢复用户原速度设置并收起侧栏，既有dirty/untracked文件和历史回滚材料保持原样。本次仅提交维护文档，不重新编译、不替换已验证产品SHA、不发布新版本。
