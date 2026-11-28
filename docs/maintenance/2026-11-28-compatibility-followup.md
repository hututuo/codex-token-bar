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

本节保留历史时点记录；3256e3f0 的完成状态见“精确 3256e3f0 云端结果”，新候选的状态见下方完整 SHA 对应的运行记录。

- 精确 `6add665b4efde0965a30c493d886041690c6ef4f` 的公开 v0.9.7 升级 `46046493653` 双平台成功：macOS 8 项升级和 126 项支持回归；Windows 3 项 importer、生产恢复 probe 与 19 类 manifest 情景。原始输入哈希、精确来源及保全证明已复核。
- 同 SHA 的 SpeedEngine 配对 `46046493657` 成功，35 项语义比较通过；四种 workload 的 CPU 中位数下降约 80.0%–94.6%。这是合成子系统测量，不是整 App 资源验收。
- `995a4050f74cafb9143578c3c3c85ae951737b2c` 的整 App 配对 `46039953356` 完成 12 轮/6 对，原始资源样本独立复算与 summary 一致。20k 静态负载 CPU 秒 `0.218529252→0.121336336`（下降 44.48%）、RSS `231686144→213434368` B（下降 7.88%）、physical footprint `113134656→104369088` B（下降 7.75%），均未减半。只覆盖正式 App 主进程、固定可见 Dashboard、静态合成来源、每轮 120 秒暖机和 120 秒测量。
- `6add` 的整 App run `46046493268` 已完成两份精确 release App 构建，2026-11-28 02:53:56 +0800 开始整 App 配对采样，尚无本次测量结果。其旧 CI 的 Windows updater 因 Chocolatey NSIS 下载返回 504 失败；新 `0007569e` 的 Windows updater 已实际通过安装器故障回归。
- 精确 `0007569eaaa483d1790a2448be50dc591378aeff` 的公开升级 `46052256646` 已双平台成功，产物原始输入哈希和精确来源复核通过：macOS 8 项升级及 126 项支持回归；Windows 3 项 importer、非 `cfg(test)` 生产 probe、19 类 manifest 恢复情景。该证据不替代全量 native 与资源验收。
- 同 SHA 的 CI `46052256690` 中，frontend、Windows updater 通过；双端 native 已完整退出：macOS 1,915 passed / 1 failed / 14 ignored（198.01 秒），Windows 1,857 passed / 1 failed / 15 ignored（568.06 秒）。20k 压力及旧库备份、Gemini 分页、quota 四项、activity 迁移与 standalone 保全均实际通过。唯一失败为 `claude_jsonl_incomplete_append_waits_through_reopen_until_line_feed` 的返回值预期，见下文；后续 backup/physical-A 负控以及 Windows helper IPC/packaging 因前步失败未执行，不能记作通过。Swift 结果仍待收。

真实 2,008 次请求、263,914,258 个含 cache 输入 token 的恢复验收仍归属 build1061/`05e059ba…`，参见同目录 `2026-11-27-claude-account-usage-discovery.md`。独立只读重读覆盖清单所列209个原始 JSONL，并纳入另发现的48个文件后，按原审计时间窗、视频路径筛选、全局 `message.id` 去重及逐 token 字段取最大值重建的4,009条请求，与派生 `claude_requests.json` 的ID集合及请求字段逐条一致。当前原始日志可复算总输入488,118,717；263,914,258 / 488,118,717 = 54.0676%（约54.1%）。该比例表示隔离账号目录在本次选定视频路径审计输入量中的占比；它不是所有视频工作流的普遍占比。原始文件仍可在本机读取，但未冻结为本次审计的内容寻址快照；原清单中有5个文件大小已变化，另有48个新文件（在审计时间窗内均无 assistant usage 记录）。因此可确认当前日志与派生结果相符，不能证明其与当时取证瞬间逐字节相同。该 build1061 安装结果也不代表后续性能候选已安装。

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

该候选保留原两项空源状态发布回归，并新增 11 项 fake-clock 回归，覆盖成功/失败 TTL、state/WAL 变化、主库出现或替换、手动强制刷新、日志恢复、异步期间 pending、暂停及换源、同 identity 路径重绑、请求完成顺序与重新启用。CI 必执行清单同时要求这 13 项实际执行。日志恢复用例覆盖自然选中线程后进入 active poll 的路径；pending 用例直接注入信号，没有验证真实 watcher 投递或墙钟调度。该改动提出时原生编译与整 App收益仍待云端验收；精确 SHA 的后续结果及范围见下文。

上述产品候选已推送为 `8b1549495d9ca2cd972a0573552d389c6c1e8ad2`。完整 CI `46070455053`、公开 0.9.7 升级 `46070454998`、形成版本双平台矩阵 `46070506166` 和整 App 资源配对 `46070874247` 均绑定该完整 SHA，且均已完成各自独立审计；不继承 3256e3f0 的通过或收益数字。

其中公开 0.9.7 升级已双平台成功，10 类独立审计全部通过：macOS 8 项升级及 126 项支持回归无失败或跳过，Windows 3 项 importer、非 cfg(test) 四阶段恢复 probe、19 类 manifest / 23 条报告通过；两份原始 ZIP 的 SHA-256 与 GitHub digest 一致，32 条 immutableFiles 哈希、最终 A/B 数据与重复启动导出均逐项复核。审计前后 862 个原始文件的字节哈希不变。证据在 `/tmp/tokenbar-public097-run-46070454998/`，简明报告为 `AUDIT.md`。这些都是 synthetic fixtures 与隔离 production-code probe，不能替代安装或真实用户库验收。

完整 CI `46070455053` 已独立审计通过，14 份 artifact ZIP 的 API SHA-256、候选 checkout 与执行前后源码封条均一致。Swift XCTest 为 2672 passed / 38 skipped，Swift Testing 为 701 passed / 1 skipped；后者尾部的 702 包含显式性能跳过项，不能全部计作通过。13 项空源发现必测各有唯一实际 passed 记录。macOS native 为 1921 passed / 14 ignored，Windows 为 1862 passed / 15 ignored；Windows 的真实 helper IPC 另行执行 1 passed，其余 14 个 ignored 仍未运行。frontend Node 1501、cloud Node 18、release Node 112 passed / 1 skipped，frontend Python 94 项通过。双平台 production、cleanup/identity 负控及 Windows updater/packaging 均通过；production dependency audit 为 0，但 npm ci 报告 3 个 high。完整 skip 与封条见 `/tmp/tokenbar-ci-run-46070455053/audit.md`。

形成版本矩阵 `46070506166` 已完成并独立审计通过：8/8 格、64 份 production proof、963 项检查，16 份 producer ZIP 的 256 成员、8 份 artifact ZIP digest、每格 249 个 production Git blob、最终恢复材料与 SQLite migration-state 均一致，全部 `cfgTest=false`。证据在 `/tmp/tokenbar-formed-run-46070506166/`；这是 synthetic Rust production 升级路径，尚未安装当前候选。

后续另将该矩阵的 C 输入与产品 R `750449be49627722a86e2ce9b21c9f9cac55997b` 做 Git 对象等价核对：八格的 249 个 production blob、完整 tauri-app/Vendor tree、七份额外构建输入、26 份外部 Rust embed 依赖，以及四份 formed workflow/probe/harness 文件均无变化；macOS LF 与 Windows CRLF 的 probe 模板和注入哈希也对应保留的原始材料。清单为 `/tmp/tokenbar-formed-C-to-R-source-equivalence.json`。因此仅针对 C→R 这些修改，没有重复执行内容未变的 Rust 形成版本矩阵；`46070506166` 仍记为 C 的执行证据，不改记为 R 的原生执行或安装验收。

资源 run `46070874247` 的 aggregate 子任务已成功并独立复核 482 项：schema2 输入 1200/12000、cold/cache-hit、24 records/12 pairs 的来源、字节哈希、物理行 oracle、数据库及语义一致。cold CPU 下降约 85.25%–87.74%，cache-hit 下降约 14.71%–18.64%；其 lifetime RSS 比值约 0.9776–1.0183，不含 physical footprint。整 App 配对也已完成并独立审计：356 项复核通过，2k CPU/footprint/RSS中位比值为0.752451/0.942900/0.964701，20k为0.428977/0.922110/0.922355，分别对应 CPU下降24.75%/57.10%、内存指标约下降3.5%–7.8%；整体内存没有减半。证据在 `/tmp/tokenbar-resource-run-46070874247/aggregate-independent-audit.md` 与 `/tmp/tokenbar-resource-run-46070874247/whole-app-independent-audit.md`。

## SharedSourceIO 上游读取候选

本提交优化缓存 `pread` 的重复分配：此前每次先将页拼入完整 `Data`，返回后再复制到调用方缓冲区；现在在原有锁和文件 generation 校验范围内保存不可变页/range，完成末次 stamp 校验后直接复制。最多持有 65 个页片段，即使本次读取中发生缓存逐出，片段也保留有效存储；所有读取或校验错误都在写 caller buffer 前返回。公共 `read` 的组装、物理探针、嵌套 uncached、4 MiB 单次上限、EOF、独立 descriptor offset 和缓存统计合同保持。此次没有根据 heap 类型猜测删除缓存或解析状态，也没有改变 `rawRead` 分配策略。

新增五项公共 API 回归：跨页与尾页、逐出后的最大范围和 cap 后 sentinel、probe/嵌套 bypass、错误时 buffer 保全、零长度/EOF；错误用例先缓存第一页，再用同 inode 的只写 descriptor 读取跨页范围，验证前页命中而后页 `EBADF` 时整个 buffer 不变。五项既有 `read` 回归与五项新 `pread` 回归均加入 CI 必执行清单。独立静态审查无明确阻断；本地 execution-gate 15 项、workflow contract 9 项及 YAML/bash/diff 检查通过。后续精确 R CI 已核实 SharedSourceIO 12/12 专项回归实际通过；整 App收益另见 R 配对结果，不能把删除分配代码路径当作已经量化的 CPU/RSS/footprint 改善。

该候选已推送为 `1d59f34b1851b806d7cb3fbf9aaf0ce08790e4bb`，远端完整 SHA 已读回复核。完整 CI `46074134352`、公开 0.9.7 升级 `46074134405` 及资源配对 `46074193555` 均绑定该源；资源 run 的产品和 harness 都为该 SHA，输入保持原 baseline、静态来源与采样协议。dispatch 请求及 run 绑定保存在 `/tmp/tokenbar-dispatch-1d59f34b-resource.json`。三项结果均已独立审计；所有结论仍只归属于该 SHA，没有将旧 C 的结果改记到本 SHA。

其中公开升级 `46074134405` 已完成并独立审计通过：142 项选定测试实际 passed、0 failed、0 skipped/ignored，29 个 workflow steps 全部成功。两份 ZIP 与 API SHA-256/大小相符，26 份 fixture receipt 的 104 个哈希及 32 条 immutableFiles 全部匹配；Windows 四个 production recovery 阶段、19 个 manifest 场景/23 份报告、最终 A/B SQL、完整初次导出与公开原库的 typed rows/schema 均核对，862 个原始文件字节保全。证据在 `/tmp/tokenbar-public097-run-46074134405/AUDIT.md`。macOS 没有上传最终临时 A/B 库，最终 SQL 独立核对仅适用于 Windows；未保留单独的恢复前 WAL 字节快照。该结果不代替全量 CI、资源或安装验收。

完整 CI `46074134352` 后续已完成并独立审计通过：14 份 artifact ZIP 与 API SHA-256 一致，checkout、执行前后封条与 17 份固定源文件均绑定该完整 SHA；SharedSourceIO 必执行 10 项和 discovery 必执行 13 项各有唯一实际 passed 事件。Swift XCTest 2677 passed / 38 skipped，Swift Testing 701 passed / 1 skipped；macOS Rust 1921 passed / 14 ignored，Windows Rust 1862 passed / 15 ignored，另行真实 helper IPC 1 passed。frontend/cloud/release Node 分别 1501/18/112 passed，release 另有 1 skip；Python 94 项、updater 11 项通过。两端 production 各 16 项检查、8 个强退阶段、24 次 reopen 和全部四份负控已核对。完整清单及边界在 `/tmp/tokenbar-ci-run-46074134352/audit.md`。可选矩阵未在该 CI 运行，生产依赖 audit 为 0 但 npm ci 报 3 个 high；这些计数不包括未执行的 filtered/ignored 测试，也不是安装验收。

资源 run `46074193555` 的 aggregate 子任务另已独立审计通过：完整原始 ZIP/API SHA-256 一致，4,142 个成员逐项核对 CRC；保留全部审计材料与两个精确 executable，未展开无关 Cargo 中间产物。24 cases 的 48 组完整 output/mutation 比较，以及 78,000 个独立 counter/completeness/price/lastSeen 字段核对通过，seed 与全部 24 个修改后的 schema2 数据库符合物理行算术真值。1,200/12,000 档 cold CPU 比值分别为 0.12550/0.13879，cache-hit CPU 比值为 0.78644/0.95406；四档 after-loop peak RSS 比值约 0.97953–1.01826。其整 App 配对也已完成并独立审计：12轮/6对中，2k CPU/footprint/RSS中位比值为0.734801/0.941168/0.966012，20k为0.488456/0.934839/0.917521；20k CPU约下降51.15%，RSS/footprint仅下降约6.5%–8.2%。证据为 `/tmp/tokenbar-resource-run-46074193555/audit/aggregate-audit.json` 与 `/tmp/tokenbar-resource-run-46074193555/audit/audit-report.md`。这些 Rust 子系统测量不含 physical footprint，不能替代整 App指标。

## 原始页存储的后续候选

新分配栈将一个 98,304 B 的 Data 分配定位到 C 的 `rawRead` 页读取入口。后续候选将 `Data(count:)` 后再写入，改为 `malloc(count)` 的独立未初始化存储，原 `Darwin.pread` 循环读满后通过 `Data(bytesNoCopy:count:deallocator:.free)` 转交所有权；任意读取错误在返回前释放裸存储。EINTR 重试、提前 EOF 的 EAGAIN、最后 stamp 校验、缓存预算与所有 probe/cap 语义保留；malloc 失败现在抛出 ENOMEM。缓存中的页保持不可变。两个独立静态审查未发现阻断；精确 R CI 的 SharedSourceIO 专项执行证据见下节，整 App收益由配对数据单独判断。

新增两项公共 API 回归，覆盖热缓存上的 64 KiB 物理 probe、73 字节尾页、4 MiB cap、EOF 不读取、独立 descriptor offset、返回 Data 副本修改、另一 inode 的页/owner 逐出，以及重热后同 inode 同长度覆盖时旧快照保全。精确 CI `46075158971` 已独立核验 SharedSourceIO 12/12、Claude discovery 13/13 必执行测试均实际通过；R 的 `swift test` 退出码为0，源封条与原始日志哈希匹配。完整 Swift XCTest 为2679通过/38跳过，Swift Testing为701通过/1跳过；macOS native 1921通过/14 ignored，Windows native 1862通过/15 ignored。其余完整清单见 `/tmp/tokenbar-ci-run-46075158971/AUDIT.md`，这些测试结果不等于安装验收。

该产品候选已推送为 `750449be49627722a86e2ce9b21c9f9cac55997b`。完整 CI `46075158971`、公开 0.9.7 升级 `46075158856`、资源配对 `46075190349` 分别绑定该完整 SHA；资源 dispatch receipt 为 `/tmp/tokenbar-dispatch-750449be-resource.json`，已经与 runId 及 head SHA 绑定。整 App baseline 为 `f9e917917df07a24a800bf63d00700d0028bcb28`，aggregate baseline 为 `3eadadc66168802643ef595712c739877083559e`。公开升级、完整 CI、aggregate 与 whole-app-pair 均已独立审计通过。whole-app-pair 于2026-11-28 07:32 +08成功完成；artifact SHA-256、391 个成员的路径/CRC/提取内容、12 份 metrics 复算和 12 份归档账本完整性均通过。三对中位比值：2k CPU/footprint/RSS为0.756000/0.944206/0.967150，20k为0.502991/0.921712/0.918969；CPU分别下降约24.40%和49.70%，RSS/footprint约下降3%–8%，20k CPU略未达减半线。候选仍未安装、未签名、未发布，真实账号目录修复验收仍仅归属 build1061/`05e059ba…`。

公开升级 `46075158856` 的 12 类独立审计全部通过：双平台 checkout 与精确 R 源码一致，两份 ZIP 的 API SHA-256/大小/CRC 全部匹配；Swift 8 项升级及 126 项支持回归、Windows 3 项 importer 与四阶段非 cfg(test) production recovery 实际通过，没有把 filtered/ignored 计作执行。19 个 manifest 场景/23 份报告、14 份重复 typed-SQL 投影、32 条 immutableFiles 哈希一致；Windows 最终 A 的两分区 token 总量为 162/310，quota id42 和 committed-before-exit witness 保全，B 的旧 body 仅一份且 canary 保留。审计前后 862 个原始文件字节不变，42 份原始 JSONL ZIP 成员与提取件相符。证据为 `/tmp/tokenbar-public097-run-46075158856/audit-report.json`。最终 SQL 独立核对适用于 Windows，macOS 未上传最终临时 A/B 库；最终 A 已 checkpoint，未单独保留恢复前的 crash-time main/WAL 对。强退 exit86、恢复前 WAL 存在与读取由精确源码及已完成 hosted 日志证明，不能声称可从保留字节独立重放该早期时点。该结果仍是云端 synthetic fixtures/隔离 probe，不是候选安装或真实用户库验收。

资源 run `46075190349` 的 aggregate 子任务已完成独立审计：24 raw records/12 pairs、48 次完整语义比较、78,000 个独立字段检查全部通过；另对 26 个 seed/post-mutation schema2 数据库直接执行固定 canonical SQL，171,600 个逻辑行/2,059,200 个字段符合算术真值。ZIP 的 API SHA-256/全部 4,142 成员 CRC，以及精确源码/SQL/prices/两个保留 executable/toolchain 封条均匹配。cold CPU 比值为 0.172472/0.164064，cache-hit CPU 为 1.001377/1.003425；RSS 是 lifetime process peak，不含 physical footprint。证据为 `/tmp/tokenbar-resource-run-46075190349/audit/aggregate-audit.json`、同目录 `canonical-sql-audit.json` 与 `aggregate-pair-math-audit.json`。whole-app-pair 同 run 已成功并独立审计，专属 artifact `whole-app-pair-46075190349-1` 为21,550,446 B，API SHA-256 `848643cae86fb2dbef843f56e427c0477266ff6c189afc88bbb37b4c6e07e9af`；artifact SHA、391 个成员的路径/CRC/提取内容、12 份 metrics 及12份归档账本均核验通过。三对中位比值为2k 0.756000/0.944206/0.967150、20k 0.502991/0.921712/0.918969（顺序为CPU/footprint/RSS）。C/N/R 的 Rust aggregate 输入未改变，各次测值分开记录，不能把跨 run 差异归因于 Swift 页存储修改。

这里请求的分配尺寸等于逻辑读取尺寸，不代表 malloc 的物理尺寸无取整，也不保证 Foundation 永不复制。没有通过 `withUnsafeBytes` 指针调用 `malloc_size` 写永久断言：该 API 提供连续视图，不是通用的 malloc 所有者起点合同。实际分配大小、后续 Data mutation 的复制成本与整 App 收益仍须精确 SHA 云端诊断和非插桩配对，不能由删除预填充或预留代码直接推算。

现有四地址诊断优先选最大 Data 与另一块 98,304 B Data；若后续页变为 64 KiB 或被 heap 标成一般 malloc，可能不再入选。因此“不再选到旧栈”本身不构成分配改善证据。SourceSeconds 的稀疏页可行性也已复核：实际共有 13 种 source，本份 20 文件 fixture 仅有 Claude Code 一种，Float 元素载荷为 360,000 B；20 个会话不等于 20 个 source。本批没有改其 Float32 舍入、subset cache 或存储表示。

后续 harness 增加可选 `exact-64k-spread-v1` 抽样，默认仍为 `data-string-float-v1`。新 profile 从捕获输出中的完整正地址记录去重，仅取恰好 65,536 B 的候选，按数值地址排序，在至多四个均匀 rank（含端点）采栈；没有其它尺寸补位，也不按 MeCab、Data、malloc 等推测标签筛选。元数据保留原始 label、候选池条数、零基 rank、profile 和缺失角色，request、summary 与 collector 记录同一 profile。地址分布可能与 allocator zone/owner 聚集相关，四个 rank 既不是随机样本也不能保证命中页存储；heap 超时或截断时，池与 rank 只描述保留的完整前缀。只有实际栈映射到精确产品的 `rawRead` 分配行，才形成该采样地址的分配站点证据。四地址、时间/字节上限、PARTIAL 与非性能资格保持原合同。`46076363363` 的采集与独立审计结果见下文；该运行没有建立 `rawRead` 分配归属。

两份 stdlib harness 测试现为 76 项，本地全部通过；其中 allocation 模块 45 项，覆盖 0/1/2/3/4/5/10 个候选的固定 rank、数值排序、重复/不完整/零地址、保留推测 label、无异尺寸补位、截断 PARTIAL、预先退出、CLI 拒绝未知 profile，以及 CLI→callback→summary 的 profile 和非性能资格。YAML、全部 run shell block 的 `bash -n` 及 diff 检查通过。没有为这些轻量检查执行本地产品构建或启动 App。

该抽样 harness 已推送为 `975bccf546be02ea2dcbc30e33c94f0eb3580c0f`，诊断 `46076363363` 固定产品 `750449be49627722a86e2ce9b21c9f9cac55997b`、profile `exact-64k-spread-v1`。该 run 已终态 failure 并完成独立审计：App trial PASS，但四个 `malloc_history` 输出都达到 65,536-byte 上限并被终止；保留的首段栈经过 `_DictionaryStorage.resize → ClaudeParser.consumeAssistant → TranscriptSession.seed`，未出现 `rawRead` 或 `SharedSourceIO.swift:135`。rawRead 分配归属仍未建立，不能把缺失栈解读为没有此类分配。160 项审计通过，证据见 `/tmp/tokenbar-allocation-run-46076363363/independent-allocation-audit.md` 与 `selected-stack-review.json`。该 `[skip ci]` harness 提交未触发新的产品配对或原生回归。

进一步的可选 `allocation_class_summary` 只改变诊断 harness：原地址筛选仅打印至少 64 KiB 的块，无法归属剩余小分配的聚合。启用后，先完成原 heap 地址与最多四个 history，再以 `/usr/bin/heap -s --noContent PID` 收集全类别汇总，最多 60 秒/8 MiB，并使用原 120 秒总 deadline 的剩余时间作为超时上限；helper 清理仍保留既有有限 wait 宽限。退出或预算耗尽则跳过，失败/超时/截断保留已取得的栈与 PARTIAL。默认关闭，不增加 history 或地址数量。Apple 的本机 heap(1) 文档说明，插桩时部分 non-object 类型名由 allocation backtrace 推导；类别汇总仍不证明 retaining ownership、泄漏或可回收 footprint。该可选汇总的云端结果归属 `46077995146`，不属于固定 harness `46076363363`；采集和证据边界见下文。

增加该可选汇总后，两份 stdlib harness 测试共 80 项全部通过，allocation 模块为 49 项。新增回归覆盖默认关闭、两种 profile 与 flag 的端到端传递、原 deadline 剩余 20 秒时的超时夹紧、命令/环境/产物哈希、summary 超时/截断/非零退出时保留有效栈、无栈不因 summary 成功而误报，以及 App 退出或 deadline 用尽时不再查询。YAML/全部 shell block/diff 轻量检查通过，没有本地 native 构建或 App 启动。

allocation 并发组另包含 selection profile 与 classes/addresses 标识，分别隔离不同诊断请求，避免它们在 pending 状态相互替代；产品 SHA/ref 后缀、`cancel-in-progress:false` 及原 pair 并发组保持。该分组只调度独立 runner，不改变采样、预算或诊断的非性能资格。

该可选汇总 harness 已推送为 `3bb1ea137ce8445c2b2ef93f72099421fc0b9a3b`，以产品 R、`exact-64k-spread-v1` 和 `allocation_class_summary=true` 显式启动诊断 `46077995146`；receipt 为 `/tmp/tokenbar-dispatch-750449be-allocation-exact64k-classes.json`，已与 run/head 绑定。该 run 已终态 failure 并完成 160/160 项独立审计：App trial PASS，collector PARTIAL。heap summary 成功返回 1,920,804 bytes；记录了20,000个 ResponseStorage 对象/4,480,000 B、107个 `__DataStorage._bytes`/5,280,944 B、ResponseStorage字典2,113,536 B等类别。四个精确65,536 B地址的 history 均因输出上限被截断；前三个栈属于 ResponseStorage 字典，经 `TranscriptSession.seed`，第四个为 MeCab。故该 run 仍未建立 rawRead 归属、retaining owner、泄漏或可回收字节，也不具备性能资格；证据见 `/tmp/tokenbar-allocation-run-46077995146/independent-allocation-audit.md` 和 `independent-class-summary-audit-160.json`。

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

更新的 harness `a5571562272a3fc05eaa98909b8bc3aced58d47c` 已推送，独立诊断 `46068336931` 于 2026-11-28 05:08:40 +0800 启动，产品源仍固定为 `3256e3f0`；完成结果如下。

该运行随后完成：App trial PASS，collector PARTIAL，103 项列明的独立一致性检查通过。heap 运行 17.731 秒，输出 10,668 bytes、106 条完整的至少 64 KiB 地址，未超时或截断；四份 malloc_history 都取得完整首组主要栈，随后在 Binary Images 清单内触及 64 KiB cap，返回 `-9`、`truncated=true`、`timedOut=false`。这解释了部分成功与 workflow failure，不能写成“无分配栈”或完整采集通过。原始 ZIP SHA-256 为 `e11f105200f49ff5cfdea752d789595f1a3148953c1e4673a802f175e46e84d2`，44 个成员与解包字节一致；保留的主 executable SHA-256 为 `06da46ca4ea6e58a5f18c1f23c68d15378eaeb301769225de6dd4d973a697b14`，Mach-O UUID 与四份 history 主 image 一致。完整 App、Sparkle 与所有资源并未逐文件归档，103 项审计不代表完整运行包已保留。原始数据和审计在 `/tmp/tokenbar-allocation-run-46068336931/`。

四个分配站点为：802,816 B 的 ResponseStorage 字典经 `TranscriptSession.seed`，671,744 B 的 `Deduper.owners` 经 `Deduper.claim`，81,920 B 的 Sparkle XPath/XQuery，以及 65,536 B 的 pricing 初始化 resolution cache。前者的优化行号 338 是 autoreleasepool 调用点，尚不能唯一分辨 Claude parser 与 SpeedEngine 的同类型字典。源码证明两类状态都跨 seed 存活，分别用于同 key 合并和 ledger replace/重定价；Deduper 还必须保留跨文件 ownership 与后续 live 重访语义。直接在文件或 seed 结束时清空不安全。分配栈不是动态 retain path，也不证明泄漏或等量 footprint 可回收。

上述四块只占约 1.55 MiB。完整 heap 还列出 62 个 `__DataStorage._bytes (malloc)`、合计 6,127,616 B，尚无其栈。因此下一轮仅更换诊断抽样为 `data-string-float-v1`：同类型最大 Data、另一个恰好 98,304 B 的 Data、最大 String array、最大 Float array；目标缺失则从其余最大块补足，仍最多四个地址，逐条记录 selectionRole 与 missingSelectionRoles。不硬编码本轮地址，不把类型名当 owner。原始输出、时间/字节预算、截断/失败语义和性能资格不变；抽样策略已改变，不能称整个诊断协议不变。

两份 stdlib harness 测试现为 67 项，全部通过，包含精确类型、独立地址去重、缺失角色补位和持久化元数据。对已有原始 heap 的轻量复算命中四个新角色；这只是选择器复算，不是新产品的诊断结果。workflow 的并发组另按 allocation/pair 分开，允许两个独立 runner 同时测量与诊断，保留各自精确 source/harness 和 artifact 标识。

该 harness 已推送为 `ecefd40cd5f416c2046ddfc798f1fb460fc48b02`，新诊断 `46072357467` 于 2026-11-28 05:45:36 +0800 启动，产品固定 `8b1549495d9ca2cd972a0573552d389c6c1e8ad2`。后续 SharedSourceIO 候选不属于该诊断产品；不把其结果当作 SharedSourceIO 候选的实测结果。

新诊断已完成并独立核对 142/142 项，App trial PASS，整体 diagnostic 仍为 PARTIAL：四份 history 各触及 64 KiB cap，返回 `-9`、`truncated=true`、`timedOut=false`，导致 pinned harness 退出 1。四份主栈分别有 41/23/22/20 个连续帧并到达线程或进程入口，cap 均发生在其后的 Binary Images 清单；没有缺失或补位角色。四个选中分配共 983,040 B：PriceBook bundled Data 131,072 B、SharedSourceIO 原始页读取 98,304 B、Deduper ring String array 393,216 B、SourceSeconds Float array 360,448 B。heap 在 17.748 秒完成，106 条至少 64 KiB 地址中 Data 共 62 块 / 6,127,616 B；只有一个 Data 页站点被采栈，不能据此把全部 Data 归给缓存。原始 ZIP 的 SHA-256 `b417835782a172e95334e727854b8627624dcd7eb37edbe6dafd64196cd8cae2` 与 API 一致，44 成员、binary UUID、完整 20k ledger 及另存的 11 份精确 C 源文件均核对。报告在 `/tmp/tokenbar-allocation-run-46072357467/independent-allocation-audit.md`。这些是分配站点证据，仍不是 retaining ownership、可回收量、泄漏或合格性能配对。

PriceBook 的源码所有权另已独立核对：`static bundled` 保留的 `PriceTable.data` 就是 loader 原样传入的原始 JSON，供 HistoryAnalyzer 写入 HistoryDatabase 的版本化 BLOB，并在恢复时重新加载。这是产品保留历史价格所需的文档，不能将其作为无用临时 Data 删除。源码解释了预期持有者，尚未将它与所选地址的 retaining graph 直接绑定。

只读源码复核另确认：`SharedSourceIO.shared.pages` 会长期保留最多 4,194,304 个逻辑字节的原始页，按 65,536 字节目标页读取，`Data` 实际 capacity 尚无直接证据；当前 fixture 的换行缓冲不需要跨块保存。Dashboard 已用 LazyVStack，侧栏详情与状态栏 popover 按需创建，默认 Codex 范围下外部 ranking projection 直接返回空，未发现适用于本份 fixture 的可安全删除大块状态。上述源码路径只提供待验证 owner，不能把 64×80 KiB 的全局 size 桶直接绑定到共享页缓存。

三轮 20k heap 快照均显示，ResponseRecord 字典原为 15,679,488 B，当前 ResponseStorage 对象与对应字典合计 6,593,536 B，减少 9,085,952 B；Double 数组约 2.884 MB 降至 16,016 B。剩余约 15.6–15.8 MB 的 non-object 与约 5.317 MB 的 malloc 组仍无确定的分配归属。后者在不同快照里出现 `__DataStorage._bytes`、`CodexSessionMutationMonitor.stream`、`NetworkAgent.NetworkAgentBackingClass.data._end` 等不同标签，不能把未插桩 heap 的字段推测标签当成具体 owner。vmmap 显示活分配减少和 allocator dirty fragmentation 增加同时存在，heap 字节差额不能替代 physical footprint。

12 份既有 vmmap 的独立分区复算进一步量化了这一区别：20k 的三轮中位 live heap 为 `68.105→55.211 MiB`，malloc-zone dirty 为 `79.2→72.2 MiB`，reported fragmentation 却从 `10.9→17.0 MiB`；候选 DefaultMallocZone 的 fragmentation 约 15.3 MiB。2k 的对应 live heap 为 `48.533→43.509 MiB`，fragmentation 为 `9.299→9.164 MiB`。候选 `snapshot footprint − malloc-zone dirty` 两档均约 28.1 MiB，是当前窗口协议的观测残差，不能称为不可降低的底线。即便乐观地把全部 reported fragmentation 清零，按合格 role medians 距离半基线 footprint 仍约差 29 MiB；这些脏页并非已证实可回收量。summary vmmap 的 resident 也不等于采样 RSS，不能把 clean framework mapping 总量当成 App 独占的可削减预算。

独立 `allocation_diagnostic` 云端入口只构建指定 candidate，保留原 GUI/fixture/ledger 门槛，以同一 20k 合成输入运行一次。仅 App 子进程出生时启用 `MallocStackLogging=1`，辅助命令保持清洁环境；测量结束后查询至少 64 KiB 的有限地址，最多四个 malloc_history，最初采用两大块及 80/64 KiB 桶，下一轮采用上述 `data-string-float-v1`。工具采用上述有界预算，保留完整预算内的原始输出、参数、时间、hash、截断和不可用状态。地址可能在选择后释放或复用，栈也不等于保留关系。结果显式标记 `performanceComparable=false`、`performanceVerdict=NOT_EVALUATED`；配对汇总拒收插桩结果，所有资源观察均不能用于减半验收。构建 artifact 同时保存 executable 与 Info.plist 字节，便于独立重算 hash。取得有效栈前，不据静态容量猜测删除产品状态。

新账号隔离根的实现边界也已复核：自动发现覆盖默认根、existing guarded 根及 registry 中合规的 `accounts/<32-hex>/code/projects` 根；显式路径偏好仍保持单根独占。Swift/Rust 均先 canonical 去重，再在各根之间公平分配 entry/file 预算；cursor 只在已枚举候选文件中轮转，目录遍历本身每轮从头开始，超份额固定尾部可能持续遗漏，未用预算只流向后根而不回访已截断前根。Claude 分类另有单轮 64 MiB 上限，因此不能承诺后续刷新必然完整；触界必须保留 incomplete。缺失账号目录目前不会单独产生 incomplete 标记。没有证据表明真实批次触及这些预算边界。真实的 2,008 请求、263,914,258 输入 token 仍只属于 build1061/`05e059ba…` 的安装验收；在当前 SHA 安装并读取同一真实 ledger 前，不把它宣称为 3256e3f0 的实测修复。
