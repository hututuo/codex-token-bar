# 功能区统一入口收束

基线：`109350b6310d6d544f89719396f434b89dd55c32`，工作树 `f97f`，分支 `codex/storage-responsibility-split-20261106`。

状态：实施中。源码检查不等于云端测试或实机验收。本机不运行构建/测试套件；最终同 SHA 完成 Hosted checks、Public097 和双端候选包校验后停在安装前，由 Argon 安排用户实机测试。既有脏文件、scratch、A–D 存储合同保留。

## L1：实时速率

定位：三级缺少圆圈对应的模型速度条；圆圈/设置预览各自选择速率与配色，Swift morph 仍直接使用模型色。旧速率 API 依赖调用者事先排除来源重叠；当前配置已明确排除 upstream 的 Claude，未发现重复计数实证。新入口按客户端选择 reader，保留该隔离。

合同：每个客户端只选择一个速率 reader；先按来源核对总值和未知残差，再生成 client+model 行。实时 total、modelRates、colorRates、行 share 与相对最大值条长来自同一快照。行保留客户端、原始模型、采样时间和来源标识；不同客户端同名模型保留独立行。颜色/短名复用现有注册表，数字统一一位小数。停用/不可用归零，状态不伪装为正常空闲。

| 入口 | 权威投影 | 消费者 |
| --- | --- | --- |
| Codex Bar / 本地 Claude / upstream 本地观察 | Swift `ClientLocalRuntimePresentation.liveRate` → `ModelRatePresentation.snapshot`；TS 对应纯投影及 reader adapter | 二级圆圈、一级竖条、morph、设置预览、三级实时模型条 |
| 正文完成样本 | 既有 Body TPS 投影 | 正文 TPS 历史，不加入实时 total |
| 近三分钟观察序列 | 既有活动历史 | 活动折线图，不以窗口均值替代实时条 |

检查：新增双端 `Tests/SharedFixtures/live-model-rates.json`、生产圆圈/模型条组件回归、非法值/停用/切源/来源身份/配色检查。`93d46fea` 云端前端通过，Swift 新行视图类型推导超时；`fe38279c` 拆成明确的名称/轨道/行组件。修订的 Public097 `42680101699` 已成功，完整 CI `42680102143` 尚在执行。GUI NOT_RUN。

## L2：趋势桶与多客户端用量摘要

定位：`RecentUsageChartData.prepare` 与 TS `prepareRecentChartData` 因细序列覆盖情况将 7d 改为 300 秒；B 库趋势查询按 client/time 合并，没有模型维度；框选摘要读 Codex quota 的事件及 totals，模型只显示前三项，可能隐藏整个其他客户端。

| 入口 | 权威计算 | 消费者 |
| --- | --- | --- |
| B 已有事件与逐请求价格 | Swift `trendBuckets` / Rust `read_trend_buckets` 按 client+raw model+5m；同一只读事务，附缓存字段完整性 | 主页原图投影、图表外部贡献 |
| 原图显示范围 | Swift Range / TS RANGE_CONFIG：24h 300s、7d 3600s、30d 21600s | 单来源和汇总共用原图坐标、缩放、滚动 |
| Codex 原始模型桶 + 所选 B 趋势贡献 | Swift `RecentChartPreparedSnapshot.usageBuckets/usageSummary`；TS `buildChartUsageSnapshot/chartUsageSummary` | 曲线价格、顶部、单点 hover、固定框选、下方选区用量及所有模型 |
| Codex quota provider | 独立细序列证据；显示选区按时间映射，返回显示索引 | 额度下降、跨 reset、分钟证据、shared-account 归因；外部用量不参与 |

模型贡献保留 client 与 raw IDs，展示 alias 仅在同一 client 内合并；原生/Antigravity 同名模型不吞并。所有选区模型在有界滚动列表中可见，不再截为前三项。按原始请求计价后再合桶，未知费用与缓存完整性单独保留；不修改 B 表结构、原始记录、A 库、迁移状态机或存储连接/事务拥有者。

共享 `recent-chart-usage.json` 验证三种粒度、六种 scope、同名跨渠道、反向/单点选区、费用守恒和未知缓存。新增真实 React 图表 hover/固定选区/下方摘要回归及 Swift/Rust 同桶多模型、价格、旧 IPC 缺省回归。原 7d 细桶测试改为断言 1h 显示与 5m quota 证据同时保留，未删除低点保护。新增代码尚待云端编译和测试，不以本机 JSON/脚本语法检查替代。

## 后续 Loop

- L2：固定 24h/7d/30d 为 5m/1h/6h；曲线、顶部、hover、选区共同消费带客户端/模型/已核算价格的桶，Codex quota 证据独立。
- L3：展示身份、计价身份、渠道身份；检查所有费用与名称/颜色消费点。
- L4：运行主/子任务聚合、source quality、标题与存活适配。
- L5：scope、IPC、异步回复、刷新和设置生命周期。
- L6：诊断事件裁剪、当前启动证据和升级回执。
- L7：剩余服务 owner 矩阵；只收束有实际重复决策证据的模块。

## L3：模型身份、渠道、名称与颜色

扫描：`ModelPresentationIdentity` / TS domain / Rust model_presentation 已共用严格身份 policy/cases，费用主页与侧栏已共用 `ClientModelCostPeriods` / `clientModelCostItems`，外部费用保留已核算逐请求价格。保留日期/TTL/长上下文计价，不合并账本身份。发现 Swift/TS 固定模型色、客户端色和客户端标题仍各维护一份；`ModelUsagePresentation` 的 key/label 与严格 identity 断开，导致完整 Thinking 人类名称不能稳定复用费用名/颜色。

收束：固定色/客户端色/标题进入既有 `model-presentation-policy.json`，无需新增独立资源加载器；Swift/TS presentation 通过严格 identity 识别已知模型，旧 Auto Review 日期/独立配额适配保留。完整 Opus/Sonnet 4.6 Thinking 名称用显式 displayAliases，Swift/TS/Rust 同一 cases 证明；不改 billingAliases。Antigravity sourceGroups 仍在 Gemini · Antigravity，Argon4 例外仍在最新主力。新增全注册表颜色与跨渠道别名/计价隔离测试。

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
