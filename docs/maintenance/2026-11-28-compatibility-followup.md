# 2026-11-28 兼容性续查

所有编译、原生测试和打包仍通过云端执行。本次未替换安装包或发布。

## 全量原生回归失败与修正

前序 `7959996e7a7606bca4eb747711cf57fa31b280ea` 的 CI `46045084012` 在 macOS/Windows 均因 35 分钟 job 上限取消。两端最后完成的测试相同：`schema_admission_rejects_complete_tables_with_incompatible_keys`；没有完整 native summary 或 execution report，不能记作全量通过。压力测试尚无完成证据。

已确定的生产缺陷：

- `ensure_schema` 在 `BEGIN IMMEDIATE` 中从同一连接执行在线备份。锁定的 SQLite 3.50.2 会持续返回 `SQLITE_BUSY`，rusqlite 0.37.0 的 `run_to_completion` 持续重试。修正保留迁移写锁和事务内 admission，在任何 DDL 前通过独立只读连接生成已提交快照。已有升级测试增加 DELETE/WAL 两种模式，核对活跃 WAL、旧数据、备份版本、迁移前表集合及 integrity；未来 schema 拒写保持原断言。
- JSONL 的未完成 checkpoint 在文件大小不变时无条件回到 offset 0，导致正常 Gemini/Claude 分块无法继续。现在只有同尺寸且完整 fingerprint 改变时重扫；完整 fingerprint 相同的分块继续旧 offset，追加与同尺寸改写检测保留。

两端另有相同的 11 个测试报告 FAILED。除上述分页缺陷，还发现四组过期 fixture：

- 四项 quota history 测试使用 schema 0 的空内存库，违反新 B2 写入围栏；改用已有完整 B2 fixture，保留百分比、去重与组织/客户端隔离断言。
- activity v1 迁移 fixture 同时声明 B marker 与未来版本 17；改为支持的 B2，保留旧行、索引和 source 隔离。独立 standalone 任意版本保全及未来 B 拒写测试继续存在。
- future-schema legacy JSON importer 测试使用不符合 `body-speed-<identity>.sqlite` 合同的文件名，尚未到达目标拒写路径；修正名称，保留无备份、零行与版本保全断言。
- 四项 Claude 大记录测试的 checkpoint helper 缺少 entrypoint v3 与物理 witness。按新合同严格比较完整指纹，offset/size/mtime/账本重放断言保留。

相关升级、分页、quota 和 activity 测试加入 CI 必执行清单。上述失败的具体 panic 未从旧日志取得：libtest 尚未输出最终失败详情即超时；fixture 原因来自确定性的源码对照，实际结果以本次修正后的完整云端回归为准。

本次本地仅运行轻量脚本：execution gate 15 项、workflow contract 9 项、CI evidence gate 5 项及 vendor provenance 全部通过。

## 已完成证据及边界

本节保留历史时点记录；当前精确源码的完成状态以文末“精确 3256e3f0 云端结果”为准。

- 精确 `6add665b4efde0965a30c493d886041690c6ef4f` 的公开 v0.9.7 升级 `46046493653` 双平台成功：macOS 8 项升级和 126 项支持回归；Windows 3 项 importer、生产恢复 probe 与 19 类 manifest 情景。原始输入哈希、精确来源及保全证明已复核。
- 同 SHA 的 SpeedEngine 配对 `46046493657` 成功，35 项语义比较通过；四种 workload 的 CPU 中位数下降约 80.0%–94.6%。这是合成子系统测量，不是整 App 资源验收。
- `995a4050f74cafb9143578c3c3c85ae951737b2c` 的整 App 配对 `46039953356` 完成 12 轮/6 对，原始资源样本独立复算与 summary 一致。20k 静态负载 CPU 秒 `0.218529252→0.121336336`（下降 44.48%）、RSS `231686144→213434368` B（下降 7.88%）、physical footprint `113134656→104369088` B（下降 7.75%），均未减半。只覆盖正式 App 主进程、固定可见 Dashboard、静态合成来源、每轮 120 秒暖机和 120 秒测量。
- `6add` 的整 App run `46046493268` 已完成两份精确 release App 构建，2026-11-28 02:53:56 +0800 开始整 App 配对采样，尚无本次测量结果。其旧 CI 的 Windows updater 因 Chocolatey NSIS 下载返回 504 失败；新 `0007569e` 的 Windows updater 已实际通过安装器故障回归。
- 精确 `0007569eaaa483d1790a2448be50dc591378aeff` 的公开升级 `46052256646` 已双平台成功，产物原始输入哈希和精确来源复核通过：macOS 8 项升级及 126 项支持回归；Windows 3 项 importer、非 `cfg(test)` 生产 probe、19 类 manifest 恢复情景。该证据不替代全量 native 与资源验收。
- 同 SHA 的 CI `46052256690` 中，frontend、Windows updater 通过；双端 native 已完整退出：macOS 1,915 passed / 1 failed / 14 ignored（198.01 秒），Windows 1,857 passed / 1 failed / 15 ignored（568.06 秒）。20k 压力及旧库备份、Gemini 分页、quota 四项、activity 迁移与 standalone 保全均实际通过。唯一失败为 `claude_jsonl_incomplete_append_waits_through_reopen_until_line_feed` 的返回值预期，见下文；后续 backup/physical-A 负控以及 Windows helper IPC/packaging 因前步失败未执行，不能记作通过。Swift 结果仍待收。

真实 2,008 次请求、263,914,258 个含 cache 输入 token 的恢复验收仍归属 build1061/`05e059ba…`，参见同目录 `2026-11-27-claude-account-usage-discovery.md`。不把该历史安装结果改写为本次源码的真实批次验收；54.1% 的分母仍未核实。

## 续查修正与待验范围

- Claude 未闭合长记录测试：CLI fixture 没有已提交首条记录，分类器正确返回 `Incomplete(PartialRecord)`；原 `unwrap()` 与现有分类合同冲突。现在严格核对完整诊断及实际读取字节数；Desktop 有已提交 header 时仍要求成功等待。两段 partial/无 LF 循环的完整账本相等、重开连接，以及补 LF 后的两个事件、精确 checkpoint 和重放断言均保留。未放松生产分类器。
- Swift 会话加载测试的 mock 原先仅轮询 1,000 次 `Task.yield()`，不能保证 MainActor 创建的工作已获调度。catalog/context 两类等待改为 actor 内注册事件，再通过带 10 秒超时的 `XCTWaiter.fulfillment` 等待；到达阈值时先移除 waiter 再 fulfill，超时后清理。
- 自动发现多个 Claude 根已改为先物理去重并固定首个逻辑路径，再为各根分配全局剩余预算的公平份额，扣除实际消费并继续后根。Swift 只对 Claude 分配 entry 份额，分类预算与 importer 游标独立保留；Rust 同时分配 entry/file 份额，各根局部截断合并到总量，精确 E/F 项不再提前丢失。没有提高总上限。新增 Swift 4 项、Rust 5 项小 fixture，覆盖前根噪声、递归截断、未用预算回流、missing/alias、零预算及精确边界；跨平台用例加入 CI 必执行清单。原 incomplete 提示保留，目前仍无证据证明真实漏采批次触及此上限。

以上续查修改已推送为 `f858ae03cbcbeec51d385b76921e0dc547af321c`；其 CI `46054347941` 后续已成功，Swift `2658 / 0 / 38`、macOS native `1921 / 0 / 14`、Windows native `1862 / 0 / 15`，Windows IPC、packaging 与双平台负控通过。当前包含其修改的 `3256e3f0` 另有下述独立精确源码证据。

## 可见 Dashboard 的后台工作优化

- 纯图标状态栏停止每秒 timer，并直接生成与旧空指标配置等价的空文字、固定辅助说明和恢复图标，省去 `TokenDisplaySnapshot`、radar 和指标计算。重新启用指标时立即刷新并恢复唯一 timer；同 owner 切换、owner 更换、重复 bind 和关闭的生命周期断言均覆盖，popover 的 lazy attach 和运行需求租约保持原路径。
- Dashboard 按主页、热力图、最近图三个解析后的客户端范围决定是否申请外部 usage charts；只看 Codex 时释放原 consumer UUID 的图表需求。独立图表选择外部客户端、all、失效选择回退及 available 变化均按子视图同一个解析函数处理；其它窗口的 consumer 不受影响，消失后不会因设置变化重新申请。既有最后一个 consumer 关闭后清空、重新从 ledger 加载的回归加入必执行清单。

新增两项范围策略测试和一项状态栏生命周期测试已在精确 `3256e3f0` hosted CI 中执行通过；这些结果证明行为回归，不直接量化整 App 资源收益。整 App 验收仍使用原固定可见 Dashboard、相同合成来源及采样时长，资源是否减半单独看整 App 配对。

后续源码复核确认空 Codex 源还有两条重复工作路径：`threadID` 为空时每次 poll 都重新调用 recentThreadsLoader，绕过已有的 10 秒线程列表缓存；该分支也没有消费 `logChangePending`，一次目录信号即可在 fast hold 到期后继续维持 0.25 秒轮询。当前候选让自动发现复用缓存，失败按主数据库物理身份退避，成功空结果遇到 state/WAL 变化立即重试；手动 reset、空源恢复启用及物理数据库替换仍立即尝试。pending 在 await 前消费，保留异步读取期间的新信号。发现请求另用顺序标记拒绝被更新请求超越的完成，原 source/activity/binding 守卫保留。这是待云端验证的产品候选，未把后续收益计入上述 3256e3f0 数据。

该候选保留原两项空源状态发布回归，并新增 11 项 fake-clock 回归，覆盖成功/失败 TTL、state/WAL 变化、主库出现或替换、手动强制刷新、日志恢复、异步期间 pending、暂停及换源、同 identity 路径重绑、请求完成顺序与重新启用。CI 必执行清单同时要求这 13 项实际执行。日志恢复用例覆盖自然选中线程后进入 active poll 的路径；pending 用例直接注入信号，没有验证真实 watcher 投递或墙钟调度。独立源码审查已完成；原生编译、测试结果与新的整 App 资源收益仍待精确候选 SHA 的云端验收。

## 精确 3256e3f0 云端结果（2026-11-28）

以下结果均绑定完整源 SHA `3256e3f051ba35a463de5945d9b4faf08e0f2cc6`，不继承旧 SHA 的结论：

- Hosted project checks `46055591655` 成功：Swift `2661 passed / 0 failed / 38 ignored`；macOS native `1921 / 0 / 14`；Windows native `1862 / 0 / 15`；Swift release contracts `112 passed / 1 skipped`；frontend、cloud scripts、Windows updater、macOS/Windows production recovery、backup-cleanup 负控、route-identity 负控及 Windows Claude helper IPC 均通过。两端 native execution 的 source SHA、`trackedDirty=false`、`untrackedInputs=[]` 已独立复核。IPC 与生产 probe 使用 disposable synthetic fixtures，不等于安装包或真实用户数据验收。证据目录：`/tmp/codex-token-bar-run-46055591655/`。
- Public v0.9.7 upgrade `46055591754` 成功，Swift 8 项升级与 126 项 supporting regressions、Windows importer/production probe/19 类 manifest 情景均通过。producer/provenance 标记 `synthetic=true`，因此这是确定性 CI/夹具升级路径证据，不是已安装应用或真实用户库证明。独立复核目录：`/tmp/tokenbar-public097-review-46055591754-N1Mn3J/`。
- Rust production aggregate `46055679102` 的 `ledger-pair` 成功：schema2 synthetic 输入 1200/12000、cold/cache-hit、3 trials，共 24 records/12 pairs；数据库完整性、seed hash、输入副本和语义比较均通过。冷路径 CPU 约下降 82.9%–84.1%，cache-hit 约下降 40.7%–52.0%；该 artifact 只有 Rust aggregate RSS/CPU，不含整 App physical footprint，不能替代资源配对。aggregate artifact 已保存在 `/tmp/codex-token-dashboard-run-46055679102/aggregate/`。
- 形成历史版本矩阵 `46057708579` 成功，8/8 全通过：`0.9.8`、`0.9.9`、`0.9.10`、`0.9.11` × macOS/Windows。每格 candidate SHA 均为当前 SHA，committed/interrupted 各 resume 与三次独立 reopen 共 8 proofs 全通过，producer ZIP/manifest、source tree、recovery manifest 与 migration-state hash 均核对一致；各格 `cfgTest=false`，candidate 249 个 production files unchanged。证据目录：`/tmp/formed-run-46057708579/`。这仍是 Rust production probe，不替代 Swift 原生或已安装升级验收。
- 当前整 App 资源配对 `46055679102` 的 `whole-app-pair` 成功，12 trials / 6 pairs。原始 metrics、每档 20 个输入 JSONL 的字节/哈希、12 份 archived ledger 的稳定列/总量/摘要及 integrity、startup PID/session、固定可见窗口和测后诊断边界共 830 项独立核对全部通过。各档三对 candidate/baseline 比值的中位数：2k CPU `0.752773639`（下降 24.72%）、RSS `0.960858995`（下降 3.91%）、physical footprint `0.943649120`（下降 5.64%）；20k CPU `0.459023661`（下降 54.10%）、RSS `0.917332772`（下降 8.27%）、physical footprint `0.925623000`（下降 7.44%）。20k 三对 CPU 均减半，2k CPU 与所有 RSS/footprint 均未减半，整体性能目标未完成。仅覆盖正式 App 主进程、固定 1240×812 可见 Dashboard、静态 synthetic 来源、120 秒暖机及至少 120 秒测量。artifact 没有保存 executable 字节，只能核对构建与各轮记录的 executable hash 相等，不能独立重算缺失 binary。证据与可复算脚本：`/tmp/codex-token-dashboard-run-46055679102/whole-app/`、同父目录 `independent-audit.json`、`independent-audit.md`、`independent_audit.py`。

## 内存归属诊断

独立诊断 run `46065587494` 已完成，产品源固定为上述 `3256e3f0`，harness 为 `068f17861703340b686bfad93c77af0510ec5d7f`。构建与 App trial 通过；采集步骤失败，collector 为 `UNAVAILABLE`。实际 heap 在 10.025919 秒内没有输出任何字节，随后因 10 秒工具上限被终止，返回 `-9`，`timedOut=true`、`truncated=false`；没有地址或 malloc_history 栈。此次没有触及 128 KiB 输出上限，也不能据此推断没有大块分配。同 trial 的 post_sample 替代了普通内存诊断，没有第二份 heap 可推算完成时限。

artifact 原始 ZIP SHA-256 为 `344b2ba41abcf394a89c6b5e400b90019376ca4d9f919edd9775c4a9f26b8a39`，与 GitHub artifact metadata 相同。精确产品/harness 来源、保留的 executable/Info.plist 字节、完整 fixture/ledger、可见窗口、采样边界、诊断资格及全部 40 个归档文件共 79 项独立核对通过；这是证据完整性通过，采栈仍未成功。审计与原始输出保存在 `/tmp/tokenbar-allocation-run-46065587494/`。

后续仅调整采集预算：heap 最长 60 秒、完整原始输出最多 8 MiB；每个 history 最长 10 秒/64 KiB、最多四个地址，总采集 deadline 120 秒，清理 helper 另有有限 wait 宽限。增加原始输出上限是为覆盖已知约 1.79 MB 的普通类别报告，不是本次失败原因。60 秒是下一次有界诊断预算，不是已实证的完成上界；保留超时/截断时的部分证据和失败状态，不修改产品分配行为。

两份 stdlib harness 测试共 66 项通过，新增约 2 MiB 类别前缀后的地址采集、零字节超时、截断且返回 0 的 PARTIAL 负控及剩余 deadline 分配；未执行本地产品构建或 App 启动。

更新的 harness `a5571562272a3fc05eaa98909b8bc3aced58d47c` 已推送，独立诊断 `46068336931` 于 2026-11-28 05:08:40 +0800 启动，产品源仍固定为 `3256e3f0`；尚待其真实采集结果。

只读源码复核另确认：`SharedSourceIO.shared.pages` 会长期保留最多 4,194,304 个逻辑字节的原始页，按 65,536 字节目标页读取，`Data` 实际 capacity 尚无直接证据；当前 fixture 的换行缓冲不需要跨块保存。Dashboard 已用 LazyVStack，侧栏详情与状态栏 popover 按需创建，默认 Codex 范围下外部 ranking projection 直接返回空，未发现适用于本份 fixture 的可安全删除大块状态。上述源码路径只提供待验证 owner，不能把 64×80 KiB 的全局 size 桶直接绑定到共享页缓存。

三轮 20k heap 快照均显示，ResponseRecord 字典原为 15,679,488 B，当前 ResponseStorage 对象与对应字典合计 6,593,536 B，减少 9,085,952 B；Double 数组约 2.884 MB 降至 16,016 B。剩余约 15.6–15.8 MB 的 non-object 与约 5.317 MB 的 malloc 组仍无确定的分配归属。后者在不同快照里出现 `__DataStorage._bytes`、`CodexSessionMutationMonitor.stream`、`NetworkAgent.NetworkAgentBackingClass.data._end` 等不同标签，不能把未插桩 heap 的字段推测标签当成具体 owner。vmmap 显示活分配减少和 allocator dirty fragmentation 增加同时存在，heap 字节差额不能替代 physical footprint。

12 份既有 vmmap 的独立分区复算进一步量化了这一区别：20k 的三轮中位 live heap 为 `68.105→55.211 MiB`，malloc-zone dirty 为 `79.2→72.2 MiB`，reported fragmentation 却从 `10.9→17.0 MiB`；候选 DefaultMallocZone 的 fragmentation 约 15.3 MiB。2k 的对应 live heap 为 `48.533→43.509 MiB`，fragmentation 为 `9.299→9.164 MiB`。候选 `snapshot footprint − malloc-zone dirty` 两档均约 28.1 MiB，是当前窗口协议的观测残差，不能称为不可降低的底线。即便乐观地把全部 reported fragmentation 清零，按合格 role medians 距离半基线 footprint 仍约差 29 MiB；这些脏页并非已证实可回收量。summary vmmap 的 resident 也不等于采样 RSS，不能把 clean framework mapping 总量当成 App 独占的可削减预算。

新增独立 `allocation_diagnostic` 云端入口，只构建指定 candidate，保留原 GUI/fixture/ledger 门槛，以同一 20k 合成输入运行一次。仅 App 子进程出生时启用 `MallocStackLogging=1`，辅助命令保持清洁环境；测量结束后查询至少 64 KiB 的有限地址，最多四个 malloc_history，采用两大块及 80/64 KiB 桶的抽样。工具采用上述有界预算，保留完整预算内的原始输出、参数、时间、hash、截断和不可用状态。地址可能在选择后释放或复用，栈也不等于保留关系。新结果显式标记 `performanceComparable=false`、`performanceVerdict=NOT_EVALUATED`；配对汇总拒收插桩结果，所有资源观察均不能用于减半验收。构建 artifact 同时保存 executable 与 Info.plist 字节，便于独立重算 hash。取得有效栈前，不据静态容量猜测删除产品状态。

新账号隔离根的实现边界也已复核：自动发现覆盖默认根、existing guarded 根及 registry 中合规的 `accounts/<32-hex>/code/projects` 根；显式路径偏好仍保持单根独占。Swift/Rust 均先 canonical 去重，再在各根之间公平分配 entry/file 预算；cursor 只在已枚举候选文件中轮转，目录遍历本身每轮从头开始，超份额固定尾部可能持续遗漏，未用预算只流向后根而不回访已截断前根。Claude 分类另有单轮 64 MiB 上限，因此不能承诺后续刷新必然完整；触界必须保留 incomplete。缺失账号目录目前不会单独产生 incomplete 标记。没有证据表明真实批次触及这些预算边界。真实的 2,008 请求、263,914,258 输入 token 仍只属于 build1061/`05e059ba…` 的安装验收；在当前 SHA 安装并读取同一真实 ledger 前，不把它宣称为 3256e3f0 的实测修复。
