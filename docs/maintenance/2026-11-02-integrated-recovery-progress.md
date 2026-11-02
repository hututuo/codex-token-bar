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
