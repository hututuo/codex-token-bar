# 整合修复进度与PR7保全映射

实施开始：2026-11-02。主方案：[完整方案](../design/2026-11-02-integrated-recovery-plan/完整方案.md)。本报告记录实际实施状态，优先于方案接续文档中的历史检查点。

## 固定输入和独立工作区

- main `d831ae416c78f9f1950e8b4ed9755c8718a5b51d`；PR7 `faa06a5b9ef0d091cf06a0b2edf0e938bdd466f2`；PR6 `41058ffe4b59fb921d2bdf962db1d0624aac9b87`，开始实施时已通过GitHub只读复核，未前进。
- 分支`codex/fix-integrated-ledger-recovery`；独立worktree：`/Users/huyiyang/.codex/worktrees/tokenbar-integrated-recovery/codex-token-dashboard`。
- 文档检查点从`8e9e6dc8`取入本分支为`c95cf696`。原工作区、先前撤回文件与调查材料保留，不参与产品修改；不安装、重启或发布。

## PR7的16项保全映射

下表均依据固定PR7源码，原回归不能因整合删除。F编号属于PR7，与旧调查包编号无关。生产路径列不代表整合后已运行通过。

| 项 | 产品入口／符号 | 原测试／场景 | 整合时的额外边界 |
|---|---|---|---|
| F01 | `multiClient/useClientScope.ts`：sharedChoiceEvents／useSharedChoice | sharedChoiceEvents.test.mjs：stored client choices use distinct valid native channels without migrating storage keys；发布、拒绝订阅、晚unlisten | 合入PR6存储失败保护；只保留一套hook和旧设置键 |
| F02 | quota_history/database.rs：rows_since_for_legacy_store／compatible_legacy_identity_rows | legacy_tauri_cycle_projection_preserves_schema_identity_and_unknown_rows；unsupported_legacy_shape_is_an_error_instead_of_empty_history；生产fixture quota | 缺列unknown、稳定身份、无身份不猜归属、原库只读 |
| F03 | runtime_recovery.rs：valid_for_earlier_request／candidate_path；route::exact_stage_candidates | 生产fixture runtime-recovery-production-path | 旧完整短合同保留；新任务改入pool；补跨进程强退，不把同进程drop当强退 |
| F04 | exact_usage_index.rs：stage_thread_metadata／open_read_only_source／live_state_wal_stamp | live_state_cache_observes_wal_only_commits_and_invalidates_frozen_reader_cache；生产fixture runtime-recovery-production-path | PR6旧可选列；持久只读连接变化信号；不能导入外部state |
| F05 | business_store_container.rs：readonly_file_uri | readonly_uri_preserves_verbatim_and_unc_paths_without_a_uri_authority；Windows：canonical_windows_readonly_attach_reads_committed_wal_and_refuses_writes | 编码和路径授权不同；实际SMB未验证，不宣称已支持任意远程路径 |
| F06 | exact_usage_index/ledger.rs：reconcile_full／event_at_raw_location／incoming_identity_count／published_compaction_event | 生产fixture legacy-backfill-indexed-reconciliation，4096事件、VM step和回放 | 不能替代Swift及50万事件规模验证；数值与canonical保持 |
| F07 | QuotaStrip.tsx：QuotaStripView归因effect | disabledDom.test.mjs：publishing attribution to a parent state settles and only clears it on unmount | 保留实现；只有反例或profile失败才改比较机制 |
| F08 | dashboardMergers.ts：normalizeFullLineage／mergePreciseDashboard；useDashboardData订阅 | a newer light summary cannot prevent the first completed full canvas from publishing；a non-forced initial quota request retains its precise subscriber after starting | Summary／Full各自前进；旧owner不能覆盖新scope |
| F09 | global.css：analytics-source-note | 无专用视觉测试；npm run build只证明构建 | 补布局证据，不拿构建替代重叠检查；不扩展成主页改版 |
| F10 | BusinessStartupGate；window_auth::allows_window_label | businessStartupGate.test.mjs三类启动失败／子窗导航／主窗重试；startup_observation_does_not_grant_child_window_business_authority | 后端window身份鉴权，URL不能授予写能力 |
| F11 | exact_usage_index：summary_at／activity_days／summary_file_contributions_full／prepare_dashboard_event_snapshot | broad_published_reads_seek_sources_and_preserve_daily_totals；dashboard_temp_view_keeps_one_wal_snapshot_across_all_sections | 生产大库查询预算、时区、模型、闭合桶与canonical |
| F12 | session_management：scan_rollout_supplements_with_parser／read_compressed_context_page；RolloutStream::open | compressed_catalog_reads_metadata_before_accounting_and_reuses_it；compressed_catalog_keeps_plain_precedence_and_atomic_failure；compressed_context_matches_plain_pages_and_preserves_partial_tail；compressed_recovery_package_preserves_and_verifies_original_bytes；compressed_resolution_retains_home_boundaries | 流式限额／取消补反例；原始压缩字节与Home边界不改 |
| F13 | auto_resume：list_threads／list_thread_options_with_request／state_db_only_parameter_is_unsupported | thread_picker_uses_metadata_pages_without_hydrating_rollouts；thread_picker_retries_only_an_explicit_unsupported_optional_flag；thread_picker_timeout_names_the_page_and_preserves_the_error；descendant_thread_list_request_is_state_db_only_and_carries_ancestor | 不增模型请求；只对明确unsupported回退，保留取消与分页 |
| F14 | rollout_source：RolloutReader::logical_length | plain_handle_length_tracks_mutation_without_moving_snapshot_bounds；compressed_handle_keeps_decoded_length_and_rejects_source_mutation；live_append_during_incremental_scan_publishes_each_prefix_once；live_append_validation_keeps_rewrite_truncate_and_replacement_guards | 冻结扫描边界与物理前缀验证分开，重写／替换继续拒绝 |
| F15 | ExactUsageIndex::turn_candidates | changed_excerpt_source_warns_once_without_changing_indexed_usage | 同源同快照合并告警，不吞独立错误／未来告警 |
| F16 | useDashboardData真实owner；open_registered_store_read_only；read_cache_turn_requests／synchronize_attribution_ledger | manual refresh remains disabled beyond the UI budget until its native owner settles；same-source refresh waiters stay busy while sharing one native owner；registered_read_only_store_does_not_wait_for_or_modify_a_publisher；registered_read_only_store_never_creates_or_registers_missing_inputs；cache_request_details_keep_canonical_duplicate_exclusion；incremental_attribution_keeps_unchanged_copies_and_unrelated_sessions | 真正只读不等注册写锁；全部UUID副本保留；明细单快照分页 |

可执行入口：`node scripts/cloud/run-node-tests.mjs tauri-app/src`；`cargo test --locked --manifest-path tauri-app/src-tauri/Cargo.toml --lib -- --test-threads=1`。生产fixture运行方式和隔离限制以整合后的脚本／workflow为准，不能把普通cargo test的cfg(test)直连当成共享A生产路径。

## C01新增测试和证据

- 保留固定PR7的五个前端测试文件，与main产品代码先跑红基线，再与整合结果比较。固定PR7单独67项已通过的历史证据见[审查报告](2026-11-02-pr-repair-coverage-review.md)，不冒充本分支通过。
- `PublishedLedgerAdmissionTests.swift`新增低空间迟到导入、提交前中断、重试三次场景，含升级后新账与只读原件核对；用实际迁移和路由入口。
- `scripts/check_startup_admission.py`重新编译本checkout七份生产Swift源码和受限probe。只替换资源定位及不使用的Exact目录发现依赖；真实migration/router/SQLite实现未替换。全量Swift XCTest和完整应用启动仍是后续单独门禁。
- PR6历史产库脚本／probe／Python测试保留固定源码SHA；八项checker测试已运行通过。它们只验证生成器与证据检查器，不代表真实0.9.8–0.9.11升级已通过。
- 历史真实产库会分别构建旧版本与候选，放云端。PR6脚本尚未接入现有workflow，C07须接好；它本身不生成数千半成品stage。大规模半完成stage仍须独立覆盖。

实际运行结果（2026-11-03）：

| 检查 | 结果 | 解释 |
|---|---|---|
| PR7五组测试对main旧实现 | 67项：56 PASS、11 FAIL、0跳过，13.55秒 | 成功得到整合前红基线，非法通道／生命周期／完整结果接收等问题仍存在；不是候选通过 |
| 当前七份生产Swift源码＋受限admission probe | 编译PASS；运行FAIL，4.12秒 | 空间失败后activation=importing、已发布行123仍保留、routes=false；空间恢复后ready且123／456均可读。证明可用性错误，不是丢账或用户现场原因的证明 |
| PR6 formed-release checker单测 | 8 PASS，0失败 | 检查器本身通过，真实旧版生产与恢复尚NOT_RUN |

原始结果：本worktree的`scratch/integrated-recovery/c01/`，含命令、源哈希、退出码与日志。XCTest整包、真实旧版产库、固定池及大规模测试还未执行；C01固定这些入口，不把后续门禁提前算通过。

C01已固定基线／映射和新增故障入口；剩余规模、形成状态及跨进程场景按后续阶段完成。下一步C02：整合已审查的读取／前端修复，保持PR7测试不变，再加入PR6额外兼容场景。

## C02 · 读取和前端基础整合

已选入固定PR7的34个文件改动，按上表16项逐项保留；其旧candidate路径作为C03的legacy适配基础，不是最终新暂存writer。未合并PR，也未取入发布版本或签名操作。PR6只选取共享选择hook和它的测试，未叠加第二套stage／恢复实现。

补充外部state读取器：只读／query_only，不导入A；已知旧列动态投影，缺必需列返回失败并保留旧值；Mac同连接data_version，短事务一致快照，正常并发提交留给下一刷新；物理替换重开。缓存最多16个来源，不在渲染或主线程扫描历史。

Windows连接寿命作平台适配：实际锁定SQLite源码的`winOpen`使用FILE_SHARE_READ|FILE_SHARE_WRITE，没有FILE_SHARE_DELETE；持久只读句柄会阻挡其他程序替换state。Windows改为每轮短连接真读，读完比较稳定行内容，不把跨连接data_version当版本。测试同时核对读取后来源可替换，原PR7的unchanged元数据语义保留。

本地针对性结果：原67项加PR6额外5项，共**72通过、0失败、0跳过**；原11个失败已转绿；TypeScript noEmit通过，Rust新增模块／整合文件语法解析通过。新外部读取器的四项真实SQLite/WAL测试在小型隔离crate中通过：直接编译本checkout的external_state.rs／sqlite.rs／native identity helper，不是重写算法。探针首次module布局不匹配，修正隔离crate的路径后通过；未修改产品测试期望来通过。完整Rust生产配置／Windows与Swift整包仍待云端，不能据此前端绿灯宣称数据库修复完成。

### 首轮云端反馈，源码e19f4551

[完整检查41479626985](https://github.com/hututuo/codex-token-bar/actions/runs/41479626985)、[旧版升级41479626893](https://github.com/hututuo/codex-token-bar/actions/runs/41479626893)已启动，只推送隔离分支，没有合并／签名／发布。

- 全量前端和Windows更新器故障测试通过；Windows旧版升级生产路径通过。
- macOS Rust生产配置编译及生产reader fixture通过；单测1653通过、2失败、14 ignored。两项失败定位为本轮新增读取器漏保留旧的结构错误提示，以及stat-only变更时漏刷新provenance。已按原合同修源码，原测试断言不改；等待新提交双端复测。
- Swift实际执行2257项、36 skipped；4条失败断言全部来自C01新增的2个PublishedLedgerAdmission用例，准确复现importing／路由关闭问题。未把它们豁免或删除，C04必须转绿。
- 以上是中间批次结果，不是最终整合通过；进行中与未运行项目不计成功。

### C02复测，源码f8d93d22

[完整检查41486330788](https://github.com/hututuo/codex-token-bar/actions/runs/41486330788)中，Mac／Windows的native整包、实际业务存储fixture、前端与Windows更新器全部通过；[公开旧版升级41486330731](https://github.com/hututuo/codex-token-bar/actions/runs/41486330731)双端通过。Swift仍为2257项、36 skipped，4条失败断言全部是上述两项新增admission用例，未出现其他失败。待C04修复，不豁免。

## C03a · Swift固定暂存池与扫描器接线（进行中）

- 新pool独立module／稳定namespace，六张固定表和固定保护trigger；新job只加行，不注册逐源store。原Exact主schema、parser和A根版本不变。
- 解析仍用现有解析器，写SQLite自动删除的私有工作区；完成后以有大小限制的typed-row块封存进A。Int64、REAL位型、NULL、TEXT原始字节和BLOB不经JSON；双端共用字节向量。
- seal保护单个job；正式事实与消费回执在原整轮发布的同一个A事务提交。只有匹配owner／摘要／回执才能回收payload。旧namespace通过只读适配恢复，不再作为新任务写入目标。
- 第一次追加pool结构前做一次WAL一致的SQLite备份；已完成备份缺回执可接续，已确认归属的未完成副本保留后重试；未知副本不搬动。不会用旧备份覆盖升级后新事实。
- 已接到Swift实际stage创建／验证／发布入口；完成新job后不再调用逐源TEMP→MAIN建四表路径。Windows固定池接线、旧stage后台清理、完整规模／恢复验证仍待完成。

本地结果：实际生产存储源码的隔离XCTest **14通过、0失败**，含共享codec向量、13个job的MAIN／store数量不增长、封存拒写、回执与事实回滚、旧stage只读／回收门槛、备份中断恢复。只替换资源查找及不使用的app发现依赖；不是完整app测试。Swift扫描器接线已通过语法检查，整包类型／调用路径和规模验证留给本批云端；原admission红用例继续保留。

源码`7f27eca7`的[完整检查41495387633](https://github.com/hututuo/codex-token-bar/actions/runs/41495387633)：Swift2271项、36 skipped，5条失败。4条仍为C01的admission；1条是旧测试把获准增加的唯一结构备份误计作第三个活动数据库。已将该断言改为精确核对“A＋固定路径的唯一备份”、备份完整性／回执，并新增pool仅1个、旧逐文件stage为0的断言；没有移除旧账／缺原文／多Home断言。该修改待下一轮云端。Mac与Windows的native／前端／更新器通过（此SHA尚无Rust pool）。

## C03b · Rust固定池与同A发布桥（待整包核验）

- Rust新任务解析到自动删除的SQLite私有工作区，存入独立的`exact.rust.pool`六表；旧candidate名称保留为legacy读取入口，新任务不再物化逐源MAIN四表。
- Rust逐源导入只登记pending_generation；整代发布事务核对正式published_generation，并在同句柄写消费回执。旧事实／回执一起回滚；清理不能把building当成已发布。固定TEMP只读投影复用现有导入SQL，不开放任意namespace SQL。
- 两端共享typed-row fixture；Rust保留Int64／REAL位型与原始TEXT字节。备份采用Rust实际根合同：容器schema1和initialized提交点，兼容其原本没有Swift activation_state的情况；未知显式activation状态不放行。
- Rust pool独立结构备份目录为`structural-stage-pool-rust-v1`，原A不覆盖；初始副本／receipt中断处理与Swift同原则。
- 生产fixture继续形成真实旧式stage，核对旧短合同保留、较长新job恢复、原文不变、旧账幂等；另加入13个pool任务的固定对象数量／typed TEMP／只读／原子回执测试。全量双端fixture待云端。

本地：直接编译实际Container／SQL binder／StoreConnection／pool／backup源码的小crate通过，13个任务MAIN和store增长0；原子回滚、只读别名、重复回收均通过。此探针仅替换路径定位／未使用的源证明，不能替代实际启动路径。新增3项pool单测、1项binder单测及共享codec／backup单测待整包；codec原3项与backup原4项曾在独立小crate通过，备份根合同调整后的全量结果不得提前算成功。

尚未退出C03：旧stage合格短边界／旧base的Swift分类、两端旧namespace带回执后台清理、未消费job跨进程强退和最终源前缀复核仍须收尾；C04启动读写准入、C05规模／图表、C06诊断与C07组合验收继续保留门禁。当前没有安装、合并main或发布。

### C03b云端反馈与收尾修正

源码`42019d54`的[完整检查41498844813](https://github.com/hututuo/codex-token-bar/actions/runs/41498844813)：生产配置双端编译通过；Mac生产fixture（含新pool13任务、实际parser旧短stage→新pool恢复）通过。Mac整包测试编译暴露backup测试未导入常量，已修；Windows生产fixture最后离线改名A时因常驻pool句柄报共享冲突，原Windows SQLite没有FILE_SHARE_DELETE。这不是删除／跳过缺库测试的理由：已增加真实维护用的空闲owner租约，拒绝关闭仍在使用的pool，并在租约持有期间阻止重开；原改名／拒绝新建空A／恢复测试继续执行。该修正待双端重测。

同时补充：Swift已知不同请求种类的完整stage通过原有全验证器分类，保留证据后分配新任务；未知格式／坏proof仍拒绝，新增实际扫描器回归。两端需要读取冻结前缀字节时显式绕过共享物理块缓存，不改变正常解析游标；Rust嵌套与异常展开有恢复测试。新的13任务探针仍通过。旧stage后台清理、跨进程强退、启动准入及规模预算仍NOT_DONE，不能用上述局部通过替代。

源码`0a8e9193`的[完整检查41501202269](https://github.com/hututuo/codex-token-bar/actions/runs/41501202269)：Windows生产fixture及全量native已通过，原离线缺库测试保留并执行；Mac native runner未开始步骤即被取消，不能计通过。Swift2272项、36 skipped：4条仍为旧admission基线；新增stage分类测试误把后缀为`.sqlite`的目录当作文件，EISDIR，已按同文件既有fixture筛选regular file。不是通过改产品校验或删除旧断言转绿。等待含C04a的新提交。

## C04a · 已发布准入与迁移重放保护（进行中）

- Mac迟到导入新增独立admission记录；初始化marker与容器合同通过后，保留已发布owner的读取，pending新owner暂不展示，相关writer在后端拒绝。旧版留下的importing＋有批次journal状态只恢复批次外已验证owner；无journal的旧importing继续保留原拒绝。
- discovery本身遇到坏材料时，已ready A仍可只读；所有新writer暂停，直到来源可分类。正常重试解除该限制，不创建空A或删除未知材料。
- startup可进入带恢复提示的已发布读取状态，重试不重复构造业务owner；全程保持单writer进程锁。**首页Exact／quota／ModelTrace的现有读方法还借用writer，需要C04b显式只读适配；当前不得称为完整启动UI通过。**
- late操作不再把活跃A切到DELETE或做全库checkpoint；同线程复用既有operation connection，事务边界不扩大。原始旧库备份使用显式physical source，避免提前恢复路由后误导出A逻辑分区。这是本轮新接线中被隔离probe拦下的问题，不宣称为用户旧版本的既定原因。
- 同一已提交输入重放前以typed-row覆盖核对保留目标独有新账；来源变化时只允许替换仍精确匹配原冻结import proof的目标，比较在原写事务内完成。独立目标新事实与变化来源冲突时保留双方、限制该owner，不猜赢家／不覆盖。原module主动restore语义未扩展到迁移器。
- 已存在A的打开路径显式NO_CREATE，避免物理A丢失时默默建空库。

当前实际证据：admission生产模块probe编译／运行PASS，低空间失败后ready、routes可用，旧123与新456都保留。生产数据库源码的隔离XCTest共**22通过、0失败**：原14项pool/codec＋8项admission，覆盖低空间、提交前中断／三次重启、pending读写门禁、其他owner继续写、physical/logical备份分离、同输入保留目标新账、来源与目标独有数据冲突保留、坏discovery只读准入与恢复、NO_CREATE。非完整app、非Windows C04验证；跨进程强退／实际旧版产库／读UI适配／规模仍待完成。

### C04b · 已发布读取入口（进行中）

- Mac Exact全量／compact／fast在owner暂停时使用显式只读连接和同一SQLite读快照。没有JSON缓存或原始会话时仍投影已发布账；不扫描、不迁移、不推进generation、不签发同步receipt，覆盖时间沿用原证明。没有完整图表覆盖证明时保留已知汇总并明确失败，不伪造完整覆盖。
- quota历史的暂停路径不执行ensureSchema／维护／legacy claim写入；可选周期列在同一读事务中按旧格式投影。稳定身份保持原过滤，未认领旧行不按显示名推归属。ModelTrace历史和设置可读，检测新请求与自动检测在对应writer暂停时停止。
- 新增真实Analyzer读取、quota旧列／身份、ModelTrace scope／设置和未注册owner的回归测试；语法检查通过，整包类型检查与执行留待本批云端，不预报通过。
- 源码`601c5f5f`的[旧版升级41505616299](https://github.com/hututuo/codex-token-bar/actions/runs/41505616299)中，Mac与Windows实际v0.9.7升级步骤均通过；Mac后续兼容复查有1个旧进程来源漂移fixture的4条断言失败。[完整检查41505616287](https://github.com/hututuo/codex-token-bar/actions/runs/41505616287)Swift2278项／36 skipped也仅该4条失败。新门禁正确拦住了fixture用普通产品writer模拟的外部变化；已改成先断言该writer被拒，再以隔离的物理来源writer模拟旧进程追加，保留原两次快照／目标新账／独立分区的全部保全断言。待云端复测。
- 同一源码的22项存储模块隔离XCTest再次通过。Windows读权限、前端恢复提示／调度、真正跨进程和规模门禁仍未退出。

### C04c · Windows读取准入与界面接线（待生产执行）

- Windows新增已验证published只读状态；只有真实initialized marker、已知容器catalog和本次物理身份通过才能准入。writer仍要求完整Ready；恢复重试不撤销已准入读取、不重复调起后台owner。非bootstrap未完成分区的只读访问显式拒绝；历史bootstrap journal继续以initialized提交点为准。
- Exact在该状态直接读取已发布分区，不启动同步／迁移。full数据和元数据取同一读快照，图表水位保留旧值、不授予新observer／freshness、不重新写缓存；compact读取已知汇总。可选对话摘录不读原文。ModelTrace历史／设置不再用建表或导入连接；quota暂停路径不维护、不认领未知身份，兼容旧周期列并复用原投影。
- 前端与Mac主页增加简短恢复状态及重试入口；子窗口只读取状态，不能触发迁移。前端8项专项已通过，覆盖全部surface准入、main唯一重试、重试时保留owner和状态请求失败不清空旧页。TS本地noEmit通过。Mac协调器补单次激活／保留旧账读取测试；重试增加活跃A物理身份门槛。
- 新Windows生产fixture会验证全量／compact无原始会话读取、旧123＋升级后789保留、未完成分区拒读、writer拒绝、重试仍可读及A整库proof不变。**这些Rust／Mac新增接线仅完成语法检查；真实生产fixture和整包类型／测试需本提交云端执行，不提前计PASS。** C03后台清理、跨进程强退、C04历史产库矩阵与C05–C07保持未完成。

源码`64907294`的[全量检查41508815056](https://github.com/hututuo/codex-token-bar/actions/runs/41508815056)：Swift2281项／36 skipped／0失败，新增无原文与缓存读取、quota旧列、ModelTrace scope／settings、未知owner反例全部执行通过；[公开0.9.7升级41508814980](https://github.com/hututuo/codex-token-bar/actions/runs/41508814980)双端通过。

源码`3ac20b56`的[全量检查41510648154](https://github.com/hututuo/codex-token-bar/actions/runs/41510648154)：Swift2282项／36 skipped／0失败，Windows native1614通过／14 ignored／0失败，实际生产fixture包括`published-recovery-reads`通过；前端和Windows更新器通过。[公开0.9.7升级41510648109](https://github.com/hututuo/codex-token-bar/actions/runs/41510648109)双端通过。Mac Rust job未分配runner、steps为空即取消，不能计通过；下批改用已能执行本项目Swift／Rust升级检查的macOS26 runner，保留完整native测试与生产fixture，不跳过或降低断言。

## C03d · 已消费暂存的后台回收（待整包复测）

- 两端正式事实与消费回执仍在原同A事务提交；Rust旧四表artifact也写入固定pool的operation行，只有最终generation事务才转为消费回执。BUILDING、回滚和未消费材料不进入删除队列，不增加新表／逐文件store。
- Mac与Windows各一个utility维护器。每轮最多4项、250ms软预算，空闲30秒、失败60秒退避；实际单项耗时计入后续退让。清理写锁等待50ms，不把长等待传给前台writer或发布返回。Windows空闲期不额外持有Arc，保留已有离线维护租约。恢复状态下不运行结构清理。
- 回收旧namespace前核对完整typed schema／row proof和消费回执；只删它自己的对象并退休其输入receipt，原始物理旧库及其他账不动。proof后到短删除事务之间有`data_version` CAS，任何外来提交都延期重试；内容改变则保留证据。消费回执／轻量头继续保留，原同步清理入口不再承担生产回收。
- 存储模块隔离XCTest **25通过／0失败**，新增限量回收、未消费payload保留、已消费旧stage变化拒删、writer忙时50ms退避及随后重试。选定真实Rust模块probe编译／运行通过：13项MAIN／store增长0；旧stage的回滚、BUILDING不删、内容变化拒删、幂等清理及正式134保全均通过。此probe复制实际路径映射辅助函数，但运行环境／coordinator门槛仍是隔离stub，不能替代生产fixture。
- 增加3项Rust旧quota只读单测，覆盖缺cycle列、已有claim不更新、无claim不猜、foreign身份排除及原writer认领语义保持；当前仅语法检查，待云端执行。
- PR6真实backfill规模fixture和脚本原样移入，保留13／128／512／4124、精确Token／事件／原库字节和累计进度断言；脚本3项unit通过，实际规模尚NOT_RUN。没有用SQL小库或新库改版本号代替真实旧版形成状态。

### 历史形成状态的托管入口

新增独立reusable workflow，固定0.9.8／0.9.9／0.9.10／0.9.11生产源码形成输入，再由同SHA候选恢复和重复启动；双平台外部TEMP、只读仓库权限、不涉及签名发布。通过原有CI的显式`formed_release`／`formed_only`参数调用，普通push不启动8个历史构建；只跑历史矩阵不会生成全项目通过artifact。工作流矩阵实际生成／拒绝非法输入、SHA／权限／输出目录合同等7项，以及既有helper8项unit通过；历史托管生产执行尚NOT_RUN。F03原调查包无SQLite，仍不宣称这些合成形成场景就是用户原库验收。

源码`65f98b26`的[检查41515343966](https://github.com/hututuo/codex-token-bar/actions/runs/41515343966)中，macOS26 native实际生产fixture已执行通过，含旧artifact消费／变化保留和published只读完整数据。随后原库unit编译在新增quota测试辅助函数发生E0597临时迭代器生命周期错误；已给collection结果显式局部绑定，不改产品或数据断言，待重测。Windows同一测试编译会遇到同项错误，不计unit通过。

## C06a · 累计进度（待执行）

按PR6已审查实现复用同一个串行progress box，修正每4项重置、worker回调交错、发布重试回零；各批offset按实际封存结果累计，输入签名真的变化则另行重置。已落库的正式数值／parser算法不变。两端保留真实N/N任务数，但图形百分比在正式complete前最多99%；新增失败／回滚不能变为100%的断言。规模fixture仍保留原精确账目／原库字节／不重解析断言，尚待执行结果。托管历史矩阵与普通检查分开并发组，避免新push把排队的历史验证无声顶掉。

### C04d · 原始旧库丢失后的绑定快照接续

- Mac补齐directory discovery看不到原始文件时的恢复：pending journal的source／store必须与A中未退休legacy receipt一致，备份只能是该receipt绑定的owned路径；original和normalized的完整typed proof均需匹配。优先使用确切UUID的attempt receipt，不按目录顺序、时间或文件名相似度选副本；未知归属、权限错误、坏proof和未绑定导出不被当成空输入。
- 当前归一化合同的有效快照直接接续；0.9.8这类未标注normalizationRevision的旧回执只作为原始备份证明，另建当前归一化attempt，保留原来一对文件。原始路径不重新创建，目标独有升级后事实仍受原typed-row覆盖／CAS保护。
- 存储源码隔离XCTest **29通过／0失败**：新增原始文件丢失＋convenience receipt损坏、目标额外999保留和三次无变化重启；未标注归一化版本的两对attempt保全；首次bootstrap中断丢原始库后接续；original／normalized被改坏及未绑定export均拒绝，其他已发布123／789和原目标456保持。
- 仍需同SHA整包和真实历史生产验证；这里不把29项模块测试当作整个C04退出。未消除“缺原始文件且没有任何可验证绑定证明”的真实未知状态，也没有从未知备份猜造账。

### C05a · 实际补全准入、目录查询与局部不确定性

- 云端65f／17b的新增规模XCTest复现：namespaced索引的已知`eventEnrichment`在构造期被误判为需要旧文件交换，尚未进入补全。现只放行评估器已确认的、纯`eventEnrichment`原地补全；schema13和未知enrichment/parser仍拒绝。保留原规模测试和未知合同断言，等待新SHA全套验证。
- Mac在同步owner锁内复用既有、带物理身份／准入检查的operation连接；不扩大事务、不让解析持有写锁。两端旧stage候选改用既有`logical_path`唯一索引的源摘要范围；Rust在pool的已验证连接上查询，避免每个源重开并验证整个A目录。没有新增数据库、根schema或第二份解析器。
- 未报告压缩用量只影响当前账户segment的可比闭合桶区间；Mac保留已知Token／费用小计，双端只暂停重叠区间的份额／差额推断。区间外、旧账户segment和尚未闭合桶不再让整个七天账变空。Rust原周期消费证据与图表区间保护保留。
- 本地存储模块XCTest30通过／0失败，含候选索引计划、owner拒绝和29项既有恢复测试；Rust实际storage源码探针（13job，旧stage原子回滚、building保留、篡改拒绝、重复回收）通过。共享归因28项通过，TypeScript及Swift语法检查通过。这些不是整包或实机证明。
- 新增显式手动云端规模门禁，13／128／512／4124全部保留；默认push不启动额外大型矩阵。工作流结构单测6项、formed结构单测7项通过。真实0.9.8双端producer pilot运行中，尚未算PASS。17b的公开0.9.7升级双端已通过；其Swift整包仍因上述已定位补全准入失败，本批必须转绿。
