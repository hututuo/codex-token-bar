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

### C05b／C06b · 规模实测反馈和有界日常成本

- edff云端双native／前端／更新器通过。Swift整包2294项、36 skipped、2条断言失败，均在一个旧测试中要求“原文件不在，即使绑定快照有效也必须拒绝”；真实0.9.7 lane同类旧断言2条失败。C04d允许沿有效绑定快照恢复是本次获准的新行为。现将这两项负面用例明确改为“原文件与绑定原始快照都不可用必须拒绝，恢复后继续”，保留拒绝准入与旧账核对；有效快照恢复、篡改与无绑定拒绝的新增用例仍在。没有删除负面保护来过关，修改后整包待复测。
- edff规模lane **FAIL**：13／128／512的XCTest正确性均通过；backfill分别1.232／9.891／37.845秒，512最长进度空窗32.805秒，超过30秒预算。原脚本遇此失败提前结束，4124未测，不能算通过。新脚本收集失败后继续全部尺寸，并显式增加4124×122＝503128事件、6250个未消费空stage namespace（25000表）的synthetic压力case；不冒充真实旧版产物。
- 对只读恢复后的同一小job增加有界四项／编码数据至多8MiB的私有SQLite work复用，按seal、owner／contract及A连接data_version校验；外部提交强制失效，篡改payload不能由缓存掩盖，reclaimed不可重读。无任何新长期数据库。增加真实外层SQLite writer锁计时，报告20次无变化同步P95、对象数、原文件hash、计数及准备耗时；1秒P95／10秒写锁目标未达到时保留FAIL和profile，不改预算。
- 已注册的正常Mac quota／ModelTrace历史与设置读取也改为只读，不再为了读数做schema维护／legacy claim；认领仍由原有明确record writer执行。新增正常准入不写A的整包回归，待云端。
- Mac与Windows本地恢复增加最多6次的5／15／30／60／180／300秒退避，所有重试复用原coordinator／writer gate；手动重试使旧timer失效，未知合同／proof冲突不自动循环。Swift以结构化错误分类；Windows现有字符串错误只作为保守重试提示，绝不用于读写准入。
- 新恢复诊断只收固定phase、时间、计数、重试与数字错误码；不收路径、账号、凭据或会话内容。详细文件有界buffer、每session256KiB、30天／50MiB轮换，失败摘要至多4KiB独立保留。GC要求确切目录owner marker、UUID文件名／头部和文件身份，未知／symlink保留；诊断失败不改变账务结果。没有逐源fsync，也没有为日志增加业务库。
- Swift旧输入发现只遍历合同中的来源树，跳过诊断／导出等无关子树，并防重复扫描重叠根；已归并状态下未注册的物理stage不再凭文件名unlink。新／旧已消费A内payload仍按原回执后台回收。**物理旧库、不同证明的备份、schema11 rollback继续保留，尚未增加可越过证明的删除器**；存在无变化启动的必要目录发现，尚不能报告“零发现IO”。
- 本地当前storage32项通过；诊断Swift4项、Rust9项，Rust coordinator6项，脚本／workflow16＋7项通过；TypeScript及修改的Swift/Rust解析通过。最终同SHA整包、跨进程pool故障、所有历史版本及完整规模仍是未完成门禁。

### 真实0.9.8产库pilot（独立证据）

[41520268814](https://github.com/hututuo/codex-token-bar/actions/runs/41520268814)在候选7ebf194上双端PASS。producer为tag0.9.8固定SHA`0a9520f99c3f13e0f48c098298b07611dc7acd63`，非cfg(test)。两端均执行committed／interrupted（故意退出86）→resume→reopen，保留typed proofs／中断WAL；新增rollout后连续读取不双计，移走原始sessions后A仍162、B仍310。此lane是实际Rust生产路径；Swift单独验证。不把新增raw rollout子断言称为独立target-extra场景。

### C07a · 跨进程故障门禁与实测反馈（仍未退出验收）

- `6c59f4ca`公开0.9.7升级 [41527073541](https://github.com/hututuo/codex-token-bar/actions/runs/41527073541) 双端PASS。完整 [41527073325](https://github.com/hututuo/codex-token-bar/actions/runs/41527073325) 前端／更新器通过；Swift和Mac native在分配runner前取消，不能算通过。Windows实际生产fixture通过，但全量1625通过／3失败：诊断目录检查把verbatim Windows路径的裸prefix当目录检查，提前禁用了日志模块。改为逐个完整祖先检查，保留reparse／symlink拒绝与原断言，新增Windows专用测试；本地9项和Windows目标编译通过，实际Windows执行待后续CI。
- `6c59f4ca`规模 [41527237426](https://github.com/hututuo/codex-token-bar/actions/runs/41527237426) **FAIL**。13／128／512／4124源的XCTest正确性均完成，backfill分别1.099／10.685／37.398／283.699秒；最长无进度间隔0.904／9.030／31.815／240.439秒；20次无变化P95为0.045／0.111／0.380／2.164秒。4124明确已完成，512进度与4124进度／P95超预算。压力case在1200秒被停止，日志只有Planning build，无XCTest/profile，不能声称压力已执行。
- 上述四档锁遥测全为0而被checker拒收，并非“没有写锁”。实际DEBUG storage probe证实SQLite报告`/private/var`而Foundation保存`/var`，同一文件路径匹配失败。已统一记录端标准化，并新增实际外层事务、嵌套savepoint和无关数据库测试；本地34项storage测试通过。增加固定phase的可选DEBUG计时，继续定位discovery、ready校验、stage、source比较、lineage、import、projection、publication和cleanup，不凭尾段时间猜唯一根因。
- 双端固定pool新增8个强退点：初始化commit前、chunk提交后、seal前／后、正式publication前／后、cleanup前／后。Swift DEBUG仅接受标记过的临时根，Rust仅fixture feature且非cfg(test)；发布与回执仍同A事务。父进程核对旧代／新代完整性，再连续3次重启。Swift实际storage模块及Rust选择性storage模块均通过；Rust probe的bootstrap依赖为stub，不冒充Tauri完整生产证据。实际Tauri fixture已接8点及完整bootstrap，待云端执行。
- 原生压力fixture已接4124源×122＝503128事件与6250个未封存candidate namespace（25000表），调用实际Rust同步／补全／汇总，保留输入hash、旧行ID与用量、目录对象增量0和无变化P95门禁。其synthetic输入不称历史producer；整包类型和运行验证尚未完成。`scale=true`时强制执行并校验完整profile，失败后原native全套仍跑，末尾门禁不会把fixture失败掩成成功。
- 新增Swift价格模型切换中的快照一致性保护：价格模型跟桶成本一起封在已准备快照，待新快照时选区继续沿用旧价格，不把新选择器值与旧hover混算。新增pending换价及跨本地午夜闭桶的24h／7d／30d回归；既有末桶／旧账断言保留，整包待CI。

余项：定位并修复大库耗时、长源字节进度、日常无变化发现成本、满足证明的物理冗余材料收纳、日志成本／隐藏窗口代理指标，以及最终同SHA双端全量／真实各版本产库／压力组合。当前没有正式版替换、main合并或发布。

### C05c／C06c · 目录事实、重复绑定成本和真实字节进度

- `0c98e5d1`完整检查 [41536039477](https://github.com/hututuo/codex-token-bar/actions/runs/41536039477)：Swift **2307项／36 skipped／0失败**，包含末桶／午夜／pending换价及写锁仪表回归。13源backfill 0.810秒，67次实际外层写事务最大0.659秒；phase中importing累计0.402秒占比最高。生产fixture因新增压力代码的四条编译错误尚未运行；native单测另有两个新增legacy存在性用例失败，不能把该完整检查记为通过。
- 两个native失败揭示了真实错误：`tb_store_objects`保存原始导入布局，运行时DDL并不一定登记它。现在held pool读取实际MAIN对象名，按`schema_version`＋`data_version`失效；只缓存名称／类型，编码预算16MiB，超预算继续以流式方式核对，不丢弃事实。owner、路径、source identity和prefix仍逐一核对；空的已知布局不变成账，未知表／列继续拒绝并保留。Rust选择性生产storage探针已复现运行时catalog为0、外部写入manifest后为true、外部新增未知表被拒绝，且13job目录/store增量0。完整双端重测待下一SHA。
- Swift同样改为实际结构核对。新增测试先前没有激活fixture的已注册路由，误获得新的随机job身份；现按实际启动安装原catalog identities，再核对运行时表确有数据且不在原导入目录，以及外部DDL使缓存失效。没有让未登记身份获得访问，也没有删掉原断言。
- 在同一namespace／TEMP标识符上下文中复用已经验证的单条DML／SELECT绑定结果，上限256项／512KiB SQL文本；上下文不同必须重新校验，不缓存DDL／PRAGMA，不缓存SQLite查询结果或绕开准备执行。真实存储模块35项本地通过，包含TEMP撤销和未知／跨库访问拒绝。实际绑定微基准同一SQL重复1万次，7.343秒→0.005秒，输出字节数一致；这是绑定层CPU结果，不冒充整轮补全加速，规模预算保持原值待CI。
- 双端在原有固定前缀扫描中报告真实decoded-byte位置，不额外读源、不写数据库、不改parser／费用／checkpoint。文件计数保持独立，读到EOF不算任务完成。Mac通知合并为250ms，保留phase／完成边界；Windows沿用UI的250ms轮询，后端同样限制字节更新，并按同Home操作generation拒绝旧worker。没有新增长期业务库、遥测上传或网络请求。
- Swift relay选定模块1项、Rust真实进度状态辅助函数提取2项本地通过；解析器“有／无回调”的事件、hash、边界和checkpoint对照已补，完整编译执行待云端。压力fixture补充测试内阶段标记与显式flush，使超时材料能区分旧账形成、目录构造、实际backfill和无变化刷新；标记不参与产品进度或门禁计算。

最终通过尚缺：本批完整双端及历史矩阵、规模与日常成本预算。未合并main、未替换正式版、未签名发布。

### C07b · 正式fixture门禁反馈

复核0c98的最终require步骤证实，生产fixture并未通过：新增scale fixture有路径函数参数强制转换、可变namespace及块尾iterator借用三处编译问题（四条编译诊断），已逐项修正。此前`continue-on-error`让步骤conclusion显示success，但实际outcome失败，末尾门禁正确使双端job失败；没有形成整体PASS。已去掉该步骤continue-on-error，以`!cancelled()`单独允许原native回归继续运行，末尾严格门禁保留并补结构测试。**8点全生产跨进程证据仍NOT_RUN**，选定模块证据不升级为全生产证据。下个源码SHA重测。

### C07c · 原有partial暂存合同与逐值保全证明

- `ef1f42cd`已通过feature编译并实际进入production fixture，先在`exact_fixture`的home-one被拦截：四张运行时空表中的manifest只有原有五个字段，正是现存`restartable_private_stage`支持的partial空态。它不是完整历史producer，也不是未知未来schema。现在仅精确认出该五列＋三张一列表、且四表全空的已有合同，返回“仍占用的恢复材料”，交回原validator／preserve流程；不会把它当成不存在，也没有扩大current-empty或未知格式允许集。
- 新单测与实际选择性storage helper验证：partial空态为占用，写入ordinal17后拒绝复用且17仍在；完整current空producer仍false，未知额外表仍拒绝，13job目录增长0。整包实际启动与8点强退继续待新SHA，不能以helper冒充。
- 压力验证从count／SUM提升为排序后的逐列typed摘要。Swift `events`、Rust `event_rows`仅排除本次允许补全的`model`，核对其余字段、稳定行身份、NULL／INTEGER／REAL／TEXT／BLOB存储类；列名与顺序也进入摘要。补全前后摘要必须一致，脚本拒收缺失／不同／非法摘要；原有数值、源码hash、对象数量和性能门限仍保留。此为验证强化，不改业务账本或parser。
- 0c98规模完整实测最终为：512最大写锁30.319秒，4124最大写锁197.120秒、backfill230.498秒、无变化P95 1.672秒；这些旧SHA仍FAIL。新SQL绑定复用后的整轮／压力结果等待云端，不从微基准预测通过。

### C05d／C07d · 写锁内重复工作与测试设施的具体失败

- `ef1f42cd`规模实际结果：512 backfill17.326秒、最大写锁13.368秒；4124 backfill158.273秒、最大写锁106.667秒、最大进度空窗107.567秒、无变化P95 1.015秒，仍FAIL。压力日志仅SwiftPM Planning build，未出现测试／fixture阶段，不能算执行了50万事件测试。现在在首档实际成功构建后解析受管`.build`里的唯一真实XCTest bundle，后续每档直接由XCTest执行同一个生产测试，保留全部原输入／断言／门限。超时保存本次进程组和实际阶段，不终止其他任务。
- 已定位Swift补全中两处确定重复：readiness、batch scheduling与最终import反复恢复同一个完整stage；每个source导入又扫描全部source寻找canonical重复组。现在仅在一次同步内保存已通过原classifier的manifest摘要，不保留额外payload／SQLite work；最终import的完整typed seal、源前缀与原子receipt校验不变。owner UUID集合唯一且无既有exclusion时只做最终整代canonical扫描；有重复UUID、既有exclusion或路径换owner仍走原路径。新增实际规模断言要求该无重复场景只扫描一次。没有改`UsageEventLedger.admit`、数值修正或事件身份逻辑，也没有新建业务库。
- `222e69fa`公开0.9.7双端升级 [41547445107](https://github.com/hututuo/codex-token-bar/actions/runs/41547445107) PASS；完整 [41547552120](https://github.com/hututuo/codex-token-bar/actions/runs/41547552120) 的Swift／前端／更新器通过，Mac native **1689 passed／0 failed／14 ignored**。其实际production fixture推进到新增native-scale-home后报`database is locked`，整项仍FAIL；已加明确phase与调用点上下文，并立即保存fixture证据，等待下一轮定位，未声称该写锁已修好。
- 同一222矩阵的真实旧版producer构建还发现绝对路径缓存问题：Tauri updater的permission metadata指向上次随机archive根，旧producer尚未运行即构建失败。每次归档构建现在仅清当前包及manifest中归档内path patch包的编译产物，保留registry/git依赖；越界路径拒绝。十项helper与七项workflow回归通过；不把缓存故障称为历史账本恢复失败，也不将其结果记为PASS。
- 本批Swift语法与41项脚本／workflow测试通过；性能、真实各版本产库、完整双端生产结果须绑定下一源码SHA重测。未安装、替换正式应用、合并main或发布。

### C03f／C07e · 两个writer的快照升级与新调度编译修正

- `eafd2f17`的旧版producer缓存修复实际生效，0.9.8双端及0.9.9 Mac已完成formed升级，其余lane继续运行。Swift新调度摘要复用块误放在排序闭包中，被云端类型检查拒绝，规模测试未进入执行；已把该块移到排序之后，未将该次检查写为PASS。新增同大小源替换发生在sealed摘要准备之后的原生回归，要求发布前仍拒绝、旧值／ID完整保留，恢复原字节后复用原job完成，不能靠摘要绕过最终源证明。
- 双端实际native压力都停在initial production snapshot，报`database is locked`，不是seed旧stage阶段。核对发现Rust pool的持久化初始化、payload、seal与cleanup使用DEFERRED事务；初始化先SELECT job状态，遇其他owner提交后升级写事务必得`SQLITE_BUSY_SNAPSHOT`。Swift对应mutator已是IMMEDIATE。现Rust同样在这些有界写操作开始时申请writer，真正的只读proof／私有work事务仍保持DEFERRED；未扩大整代发布或绕过busy失败。
- 本地两个真实SQLite连接控制明确复现旧顺序错误码517；新helper的竞争writer返回正常busy5，主事务提交后可重试成功，封存digest／原payload仍一致。实际Rust production storage源码的选择性probe编译并执行通过，日志`c07-writer-pool-control.log`；其route/bootstrap依赖为stub，不算完整Tauri生产验证。新Rust整包回归覆盖这个先读后写反例和当前helper，不以延长超时掩盖问题。
- Windows wrapper的cp1252中文输出错误已经通过实际TextIOWrapper回归复现；现显式UTF-8，保留真实子进程非零退出码与失败日志，拒绝产生成功profile。该修正仅影响云端fixture启动器，不改用户数据和会计逻辑。下一源码仍须完整双端／各版本／规模重测。

### C05e／C06d · 双端绑定成本、目录失效和诊断实际导入验证

- `b03d8d4b`自动标准整组 [41551696408](https://github.com/hututuo/codex-token-bar/actions/runs/41551696408) **PASS**，包括双native非cfg(test)生产fixture与8点跨进程强退、前端／更新器；Swift **2311项／36 skipped／0失败**，新sealed摘要之后同大小源替换回归已实际通过，另Swift Testing667项通过。这是标准整组，不含额外50万压力或新版三次reopen材料比较。b03规模／完整formed组合仍运行，不能借此宣布C07完成。
- Rust补上与Swift同口径的有界SQL名字翻译复用：仅单条已验证DML／SELECT／WITH，最多256项／512KiB SQL，任何DDL、PRAGMA、owner namespace可变访问、TEMP模式或attached alias变化立即清空。不缓存数据、结果、prepared plan或权限判定，不省略SQLite执行。实际binder全部16项本地通过，包括alias撤销／换owner、readonly写拒绝、TEMP／DDL失效、字面量／参数及缓存后真实查询能读到新值。1万次同一SQL微基准0.205314→0.003546秒、输出147万字节相同；不冒充整轮性能结果。
- 双端旧stage名称目录只按`schema_version`失效；之前把`data_version`也用于纯名称缓存，其他owner每次行提交都触发整个MAIN目录重扫。未缓存manifest行、事实值或seal；Swift恢复payload的独立`data_version`篡改保护保留，最终完整proof仍不省略。外部manifest提交仍被看见、外部未来DDL仍拒绝；新增warm-cache后DDL反例。Swift实际storage35项、Rust实际storage选择性13job／legacy／writer探针通过，仍不冒充全应用。
- 诊断增加真实导入回归：Swift四种sink（关闭／开启／未知目录不可用／写失败）经过生产migration/router，逐类型proof、原source和目标后续新增账都保持；Rust对应经过实际Container backup/import和owner receipt。fail注入仅DEBUG／cfg(test)，release权威账本路径不变。Rust目录首建原有marker `sync_all`使诊断端到端开销测到10.69%；该marker不是权威回执，现只write_all，丢失／partial只会安全禁用日志／GC，真实账本FULL与回执同步不改。
- 7对交替真实导入（含诊断start／Ready／close）本地选定storage模块：Swift关闭中位0.070152秒、开启0.072002秒，开销2.64%；Rust0.062536／0.061605秒，差异-1.49%属测量噪声，不称加速。原5%门限保留，并在完整scale组合双端启用。Swift2项、Rust诊断11项通过；这些不是能耗计量或安装后UI表现证据。
- formed helper现有每个committed／interrupted场景的resume后再独立启动三次candidate；每次仍执行原typed/WAL/A/B/缺原文断言，同时用受管场景的已知备份、schema11材料与A迁移状态完整摘要验证没有新attempt、覆盖或重复备份。不用mtime、不删除任何材料，不把排除的正常WAL／SHM当备份。44项脚本／workflow回归通过，含真实三个PID和第二轮产生backup／attempt时拒收的反例；全部旧版本实际运行待新SHA。

### C05f／C07f · 保留真实压力结果、导入语句复用与并发探针负控

- `e29d9294`标准整组[41554707063](https://github.com/hututuo/codex-token-bar/actions/runs/41554707063)和真实0.9.7双端[41554707170](https://github.com/hututuo/codex-token-bar/actions/runs/41554707170)通过。额外scale组合不是PASS：Swift诊断开启开销10.10%超过5%，Windows生产压力的并发探针报SQLite锁错误。不能由标准整组绿灯推出压力通过。
- 完整解析`b03d8d4b` scale小artifact：五档实际XCTest都完成且通过，各档raw accounting digest前后相同。13／128／512／4124事件分别backfill 0.327／3.130／11.980／90.497秒；最大写锁0.223／2.110／7.623／53.736秒。503128事件压力完成（非timeout）：backfill505.131秒，写锁322.747秒，进度空窗324.157秒，无变化P95 1.406秒。最后阶段unchanged-complete；该档importing248.376秒、sourceComparison57.463秒，合计解释大部分长锁。原report profiles空是XCTest通过后调用不支持的`swift test --show-bin-path`，不是这五档没执行。
- 报告器改用实际Swift CLI支持的`swift build --show-bin-path`；完成的profile在bundle定位前立即落盘，工具出错也不抹掉真实账务或压力数据。新增真实CLI help检查和“成功profile之后定位失败仍保留数据”的回归；不减少规模、不改预算、不把失败静默当绿。
- Swift仅在一次逐行导入作用域内复用已编译语句，最多64条／2MiB，结束或异常立即reset、清参数、finalize。每次仍先做namespace授权；不缓存结果、账务判断或跨代事实，不绕过原`UsageEventLedger.admit`的identity、correction、unresolved和turn规则。真实连接测试覆盖嵌套同SQL游标、异常清理、schema变化与回滚、权限撤销、参数不串到下条事件和容量上限；额外逐类型对账比较开启／关闭两条实际ledger路径的全部表、稳定ID、turn、binding、未决和修正回执。
- Swift诊断新建文件使用独占、不跟随符号链接的0600 best-effort写入，避免把非权威日志当作账本安全保存；保留已存在和中断marker，未知文件不覆盖。原SQLite FULL与权威迁移回执不改。本地实际导入7对比较开启／关闭开销先后0.80%和4.54%，这不是云端或能耗证明；5%门限仍保留，下一SHA完整组合须重新测。
- Windows probe原先每个并发parser都注册同一store、DDL建同一表再INSERT，250ms失败被直接写成“producer持锁”，这不足以归因。现在fixture先一次准备独立连接与表，hook只序列化探针自身的一行INSERT，实际parser／pool写入不串行化。保留250ms，另连接`BEGIN IMMEDIATE`必须让探针失败、rollback后必须恢复；4个并发探针必须留4行且catalog不变，实际Exact扫描的调用计数必须增加。runner严格检查这些字段；未显式启用的独立旧版probe不声称执行这项门禁。生产逻辑与超时未因探针调整放行。

当前仍不封候选：大库长锁／空窗／P95仍有明确失败，最新完整组合与三次重启材料报告尚未收齐。物理旧库／schema11 rollback缺完整所有权及恢复引用证明时继续保留，不能拿已消费A内namespace回执代替物理文件删除授权。隐藏／唤醒资源代理证据也仍缺；上述局部PASS不覆盖这些项。

### C04f／C07g · 调用点收束、已发布目录与读错误合同

- `e29d9294`完整run的8个formed lane在取消整组之前均已完成PASS：0.9.8／9／10／11 × Mac／Windows。逐份最终报告确认每种committed／interrupted场景都执行resume及三次独立candidate reopen，typed／WAL／raw-history断言保留，备份／schema11材料及迁移状态摘要不变，明确`mtimeCompared=false`。取消的父run本身不称为PASS；小型原始文字日志及整理数据在`scratch/integrated-recovery/c08-e29-evidence/formed-summary.json`。`cb227a48`的真实0.9.7双端升级也已PASS。
- `cb227a48`完整Swift不是通过：实际2320项、36 skipped、8条失败（含1 unexpected），全部失败分布在原有peer immutable fallback／对应quota补充读取。精确根因是本轮新`withStatement`把查询prepare错误的operation从`Prepare SQLite query`误写成`Prepare SQLite statement`，既有fallback按operation和错误码限定，因而不再触发。现恢复原合同，不改旧测试；新增开启／关闭复用都保留错误身份的专用回归。实际生产SQLite driver全部28项＋复用6项＋诊断／导入7项，本地选择性41项全部通过，包括原三项WAL无sidecar／轮转反例。不是整包或quota全量通过；等新SHA整组复测。cb诊断云端开销-0.16%（噪声范围），5%门禁已通过，不能掩盖上述8条失败。
- 新job调用点静态复查确认两端普通业务只进pool，旧物理stage writer仅服务未路由独立索引或明确的合成兼容fixture。删除Swift全仓仅定义、无调用的旧`materializeTemporaryStage`；旧格式只读恢复与证明型回收保留。
- 发现并补双端的实际目录缺口：session catalog浏览仍尝试开writer，pending recovery时把已有目录挡住。Mac按该Home暂停状态开已发布只读index；Rust在全局published-only状态下先走已发布目录分支，不等维护writer gate。两端仅浏览旧目录并携带警告，不能生成新的原文校验证据或开启危险操作。目录读取增加短一致快照。
- Swift `readCacheRequests` 经底层driver的默认Business路由原本已读A，静态初查把它当raw物理读取的猜测已纠正，未据此另写reader。本次仅把aggregate版本和分页查询放进同一短只读事务；新增实际A与留存物理旧库model不同、原文消失、writer暂停的回归，必须读A的新metadata且不改变A／物理源。
- 新目录回归经过Mac产品scanner及非cfg(test)双端storage fixture：发布目录非空、恢复重试时parser不得调用、旧条目保留、验证状态关闭、A完整proof不变。源码已parse／rustfmt解析，本段记录新增的要求，不提前称这些新集成用例已云端执行通过。

### C05g／C07h · 完整压力明确不达标，发布结构补充评审

- `cb227a48`八条formed lane再次全部PASS。Swift五档XCTest实际均完成，对账通过；报告器已正确保留profile并拒绝超预算。4124事件backfill107.084s／写锁68.823s／空窗69.598s；503128事件backfill450.662s／写锁284.589s／空窗285.609s／无变化P95 1.839s。压力原始类型／稳定ID／数值摘要前后一致，20次无变化没有parser调用，MAIN对象／store增量0；这些正确性不能覆盖红色性能门禁。
- Rust／Mac实际生产压力也已完成：503128事件、4124来源、25000旧对象的账目、model、聚合、源字节与旧候选保全断言均真；但backfill737.853s>600s，P95 1.237s>1s，`budgetPassed=false`。外层生产JSON的PASS和单项`PROFILED`只表示产出了测试／profile，不是整体性能PASS。原runner先因负控schema不匹配而拒绝，掩盖了后续预算错误；这里不将其记成“仅测试工具错误”。
- 2344的双端非压力生产fixture中，published目录2项、parser未调用、A完整proof不变等全部通过；Mac native单测1695通过、0失败、14 ignored。runner却按旧flat负控字段检查，实际producer已输出`negativeControl.{sqliteCode,heldByBeginImmediate,writeResumedAfterRollback}`；现按实际嵌套合同核对，并保留250ms、真实busy负控／rollback恢复、4探针写入、catalog不变及Exact调用计数。新增从真实2344 job文本原样脱敏取出的控制对象回归，41项脚本／workflow测试通过；没有放宽压力budget。
- 2344 Swift因新测试直接访问private extension里的scanner而在编译阶段拒绝，产品目录分支没有因该test运行。现测试通过公开`FoundationSessionManagementBackend.loadCatalog`及已有mock验证，未扩大产品成员可见性。原先被新增测试妨碍的全部回归要在下一SHA真正执行，不把parse当通过。
- Rust导入现在保留刚刚完整验证过的私有只读stage，直接挂载同一快照，不再为实际导入完整还原第二份。封存签名在打开前、验证结果及挂载前必须一致；owner／contract／源前缀和原账务逻辑均保留，legacy分支不换算法。非cfg(test)生产fixture用线程局部计数强制一次导入只restore一次；没有跨尝试缓存、无第三业务库。语法解析通过，等待下一SHA的实际生产构建／fixture。
- 依据原C05失败处理条款，新增[长事务补充评审](../design/2026-11-02-integrated-recovery-plan/长事务补充评审.md)。不改阈值、不拆半轮发布，不以纯模型特例另写记账。推荐评审锁外完整准备／锁内CAS及批量应用；**该结构切换尚未实施**。当前继续小修与正确性验证，不封候选，不替换或发布。

### C07i · 401完整正确性回归通过，Windows压力结果与六项收尾方案

- 最新产品40163c48的[标准组41563902354](https://github.com/hututuo/codex-token-bar/actions/runs/41563902354)、[真实0.9.7双端41563902287](https://github.com/hututuo/codex-token-bar/actions/runs/41563902287)、[0.9.8–0.9.11双端8条形成状态41564153315](https://github.com/hututuo/codex-token-bar/actions/runs/41564153315)全部PASS。此前新测试的编译与实际生产fixture检查已在这轮运行，不能据此覆盖未启用的压力和诊断profile。
- cb Windows native125661686981已完成，实际生产50万事件压力保留原始ID／类型／数值及源文件、模型补全和聚合，对账摘要前后相同，MAIN对象与store增量0；补全1093.275秒、无变化P95 2.883秒仍超600秒／1秒预算。该轮诊断profile6.413%超过5%，7组交错样本512KiB，耗时中位数开启0.0764439秒／关闭0.0718367秒；原因尚未细分，不能直接称为同步fsync问题。完整单测1639通过／1项诊断性能失败／14 ignored。小日志scratch/integrated-recovery/c10-status/cb-windows-native.log。
- 用户要求给出方案，新增[剩余六项收尾方案](../design/2026-11-02-integrated-recovery-plan/剩余六项收尾方案.md)，复用原C05／C06／C07合同，明确顺序、双端处理、退出条件与失败退路。本次仅文档整理，不表示用户已批准长事务结构切换，也不实施产品改造、安装或发布。
