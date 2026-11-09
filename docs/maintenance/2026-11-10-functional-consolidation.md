# 功能区统一入口收束

基线：`109350b6310d6d544f89719396f434b89dd55c32`，工作树 `f97f`，分支 `codex/storage-responsibility-split-20261106`。

产品候选：`ba88596d86cbbba28b4b5b2c524b3000aeda6a57`，版本 `0.9.11 / build1008`。L1–L7 源码与功能域扫描已完成，同SHA的完整CI、Public097、双端打包和8项formed历史矩阵全部通过；下载产物与原始执行证据已核验归档。状态为 **PASS_SOURCE_CLOUD_AND_CANDIDATE；INSTALL / GUI NOT_RUN**。本机没有运行构建/测试套件，现已停在安装前，由 Argon 安排用户实机测试。既有脏文件、scratch、A–D 存储合同保留。

## L1：实时速率

定位：三级缺少圆圈对应的模型速度条；圆圈/设置预览各自选择速率与配色，Swift morph 仍直接使用模型色。旧速率 API 依赖调用者事先排除来源重叠；当前配置已明确排除 upstream 的 Claude，未发现重复计数实证。新入口按客户端选择 reader，保留该隔离。

合同：每个客户端只选择一个速率 reader；先按来源核对总值和未知残差，再生成 client+model 行。实时 total、modelRates、colorRates、行 share 与相对最大值条长来自同一快照。行保留客户端、原始模型、采样时间和来源标识；不同客户端同名模型保留独立行。颜色/短名复用现有注册表，数字统一一位小数。停用/不可用归零，状态不伪装为正常空闲。

| 入口 | 权威投影 | 消费者 |
| --- | --- | --- |
| Codex Bar / 本地 Claude / upstream 本地观察 | Swift `ClientLocalRuntimePresentation.liveRate` → `ModelRatePresentation.snapshot`；TS 对应纯投影及 reader adapter | 二级圆圈、一级竖条、morph、设置预览、三级实时模型条 |
| 正文完成样本 | 既有 Body TPS 投影 | 正文 TPS 历史，不加入实时 total |
| 近三分钟观察序列 | 既有活动历史 | 活动折线图，不以窗口均值替代实时条 |

检查：新增双端 `Tests/SharedFixtures/live-model-rates.json`、生产圆圈/模型条组件回归、非法值/停用/切源/来源身份/配色检查。`93d46fea` 云端前端通过，Swift 新行视图类型推导超时；`fe38279c` 拆成明确的名称/轨道/行组件。修订的 Public097 `42680101699` 与完整 CI `42680102143` 均通过；最终集成候选重新执行全套门禁，见文末。GUI NOT_RUN。

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

产品候选固定为 `ba88596d`，后续证据文档提交不改变包的源码身份。已安装应用仍是 `0.9.11 / build1007`；本轮没有安装、启动候选、替换应用或操作GUI。没有创建公开 tag/Release、更新 appcast 或改动 vendor。源码回退可按功能提交 review/revert；实机回退仍使用既有已验证应用备份，不能删除或覆盖历史备份。

## 待 Argon 安排的实机验收（NOT_RUN）

这是用户明确要求的安装前停止线。Argon 先询问用户是否在场、是否亲自测试；本线程不因等待云端或用户尚未主动回复而开始安装。

1. 安装前建立唯一新目录备份 build1007，核对旧应用版本/可执行 hash 与备份一致，再按用户安排替换候选；记录实际进程路径、build1008、首刷与安装确认分别完成的证据。现有 build1006/1007 回滚材料保持原样。
2. 从二级速率圆圈打开三级：首屏应直接看到颜色、模型名、速度条、tok/s。同一时点/同一快照下总值守恒；Bar/AgentSpeed、模型/客户端配色、自定义色、展开收起、零速率与失效状态都应一致。正文TPS与三分钟趋势仍有独立标题和口径。
3. 图表切“汇总”及各有记录客户端，检查24h/7d/30d步长为5m/1h/6h；hover、单桶、正反向固定选区展示所有有贡献的客户端模型。选取同一时间范围比较模型合计、Token、调用、已知费用；unknown残差、未计价与缓存缺失要保留。Codex quota只覆盖自己的provider。
4. 确认Argon4最新主力分组、Antigravity Thinking模型的Gemini分组、费用四列30pt布局和同scope主页/侧栏主子任务计数。无实机记录的客户端继续以fixture证据说明，不能补造数据。
5. 检查两次点击固定选区、关闭气泡、滚动保持位置、切源清空旧选区及隐藏详情后的行为。完整滚动性能A/B和实体Windows GUI需独立安排；本轮不声称已验收。

## 云端与安装包证据

归档根目录：`/Users/huyiyang/Library/Application Support/CodexTokenBar-Maintenance/2026-11-10-functional-consolidation/ba88596d/`。每个run独立目录，保留原ZIP、GitHub artifact摘要、解压文件及下载回执；本地核验只读取云端产物，不执行构建、测试套件或候选应用。

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

本轮云端视觉预览已归档，离线查看模型名称卡片、紧凑主子任务层级和侧栏速度布局；新实时模型条另有Swift实际布局测量与React生产组件断言。这里不等于已安装GUI交互、用户实时数据或完整截图验收。

打包预检沿用 `release-macos-app` 的完整性、签名、更新配置和依赖边界检查。没有新增依赖、改动lockfile/权限或重新实现更新器；npm官方registry替换参数保持原样。`agent_speed_vendor.py check`通过，Vendor与本轮基线无差异。打包使用已审阅pin `a94a67fcc78e5d8eea5f82d8d5e737bccf994e2c`，并明确记录保留原因；观察到的上游HEAD `6a4d110480d133360e3be8a2e7944ac2b6511e87` 未在本轮集成，不能将pin豁免描述成已追平上游。

候选仅用于安排后续验收：ad-hoc签名、未公证、无更新签名、未公开发布。Finder安装器外观与实机权限保留测试均留到用户安排后进行。

macOS包已在 `staged-macos/Codex Token Bar.app` 独立解压核验：`CFBundleShortVersionString=0.9.11`、`CFBundleVersion=1008`、`lipo=arm64`；`codesign --verify --deep --strict`、diagnostics helper签名、`hdiutil verify`通过；designated requirement、Sparkle feed和公钥与现装build1007一致。模型/图表/分组/价格共6份资源与候选源码逐字节相等。Gatekeeper的未公证拒绝符合ad-hoc候选属性，不标成公证通过。没有运行候选可执行文件。

| macOS产物 | bytes | SHA256 |
| --- | ---: | --- |
| `CodexTokenBar-v0.9.11-macos-arm64.app.zip` | 28704592 | `5fa5d378c4de1a7d8b554273530e6243c6ffe7b61f94e97191468b04384e61b0` |
| `CodexTokenBar-v0.9.11-macos-arm64.dmg` | 29791319 | `a4c5480000b5231f43e2203a126c62c19f6ece548af17cf6fdb89ca58315e777` |
| app内 `CodexTokenBar` | — | `baad6e73a97de1760234bed5e4f011f57ba1ad7879ae25d1ea1ffbbf8db9fdce` |

兼容名 `CodexTokenBar.app.zip` 与版本化ZIP完全同hash。已安装build1007可执行hash仍为 `22dd9f96b4b22bda281c63774a68041181420aab673737572f6549d57972da2f`。

| Windows产物 | bytes | SHA256 |
| --- | ---: | --- |
| `CodexTokenBar-v0.9.11-windows-x64-setup.exe` | 69562261 | `e52fefd0bfb3359cccd9f5d9827d9f489b69d29b658f2c4456f1a74f9ad880dc` |
| `CodexTokenBar-v0.9.11-windows-arm64-setup.exe` | 63615589 | `290488fc621fbc7cedcb7903b42910743b11fffaa08830f4c4a6f232f7032b46` |

Windows两个架构均在真实Windows runner构建，`build-manifest.json`的版本、平台、大小、SHA256与外层candidate manifest及下载字节一致；本机未运行安装器。两条lane均通过仓库 `scripts/cloud/manifest.py verify` 的精确sourceSHA/runID/lane/asset集合检查。全部27个GitHub artifact ZIP（完整CI13、Public097 2、formed 8、打包4）的digest、size和安全解压路径已验证。

归档入口：

- `final-validation.json`：源码/云端/构件总门禁、文档HEAD、现装build1007与保护文件hash，以及安装/GUI未执行边界。
- `verified-checks.json`、`verified-public097.json`、`verified-formed.json`：原始执行证据的只读复验结果。
- `app-validation.json`、`app-verification.log`：双lane构件、macOS签名、资源、公钥/feed、版本架构和hash。
- `checks-42692564247/`、`public097-42692564607/`、`formed-42693285673/`、`installers-42693284176/`：各run的workflow/jobs、GitHub artifact元数据、原ZIP、解压文件和下载回执。
- `collect_artifacts.py`、`verify_evidence.py`、`verify_packages.py`：本批固定SHA的下载/只读复验脚本；不是安装器，不执行候选程序或测试套件。不能套到其他SHA冒充验证。

本轮到此交付给Argon：请先询问用户是否在场、是否希望亲自实机测试，再安排安装和上述验收。没有覆盖 `/Applications/Codex Token Bar.app`，没有启动候选或抢占GUI，也没有公开发布。
