# Exact / 业务库路由拆分批次 D 与最终收束

按[全局总计划](../design/2026-11-07-storage-global-decomposition-master-plan.md)执行最后一批。基线为 C 封存提交 `d4ae2ad5a76abb5b40cb7e70c17663b42663fc3c`，工作树 `f97f/codex-token-dashboard`，分支 `codex/storage-responsibility-split-20261106`。本批迁移生产实现保持原函数体、SQL、状态机、锁与版本合同；新增验证代码与搬移等价证据分开记录。

## 最终职责归位

| 模块 | 职责 | 行数 |
| --- | --- | ---: |
| `exact_usage_index/migration.rs` | 兼容性评估、schema9/10 转换、schema11 candidate/phase/switch/retention、accounting、legacy bootstrap | 2,934 |
| `exact_usage_index/migration/proof.rs` | 原有事实生成、序列化与 preserves 比较；未移动状态机到 proof | 803，未改 |
| `exact_usage_index.rs` | 根状态、open 外层锁与候选选择、sync/enrichment 编排、begin/resume/finalize、公开 facade 和原测试 hook | 5,695 → 2,885 |
| `business_store_route/import_coordinator.rs` | journal、旧输入、冻结备份、替换/激活协调链，完整 `open_store_at_address_with_hook` | 673 |
| `business_store_route/exact_namespace.rs` | Exact owner 解析、注册/已发布读取、candidate、receipt、clone/replace/seal/alias 桥接 | 393 |
| `business_store_route.rs` | bootstrap、通用公开 facade、维护入口及原内嵌测试 | 2,188 → 1,195（包含原测试） |

根文件不为达到最初预估行数再切碎完整编排函数。原 `ExactUsageIndex` 字段、连接/租约次序、`IndexPreparationTrace` 和测试身份保留；维护入口、公开兼容性探针和同步/发布的完整事务仍在根层。route 的全局 initialized marker 仍由 bootstrap 在所有导入完成并 fsync 后发布，未搬入分区 helper。`admission.rs` 的唯一 active identity 状态不复制、不改写。

## 状态机与提交点

| 阶段 | 受保护的原持久化点 |
| --- | --- |
| Prepared | 固定源 receipt/facts 和候选/rollback 路径后耐久写 manifest；源 facts 连接在可能切换前释放 |
| Copied | 在线备份或 A namespace clone 完成/已有完整副本核验后再写 phase |
| Migrated | 原 schema9/10 转换事务、约束恢复和 test VACUUM / production seal 完成后写 phase |
| Validated | 候选结构/内容/lineage/完整性核验，源 receipt 再核对后写 phase；跨进程恢复不能把这个字符串当新证明 |
| Switching | 重启自 Validated 时重验候选；candidate 同步和 parent barrier 后写 Switching，再执行原切换流程 |
| Switched | production clone rollback → replace namespace → seal → 候选事实复核 → 写 Switched → 原 candidate namespace 清理；test 保留文件/旁车 rename、fsync 与同次 open 内证明复用的独立分支 |
| Retained | 普通同步已发布后写 Retained manifest，再写 metadata success receipt；不删除原库或恢复材料 |

`open_store_at_address_with_hook` 保持一个完整函数。journal 在首次替换前写入；source/destination proof 继续经原容器 API 在写事务内最终 recheck；source receipts、after_import hook、导入后 source 再核验和首次 bootstrap / late-import 的不同 journal 完成规则不变。没有用策略对象替代事务内检查，也没有移动全局 marker 提交点。

## 名称和副作用核对

- `validate_pending_snapshot` / `validate_pending_batch`：可能按同一 frozen source proof 重建应用拥有的备份，保留既有拒绝别名/非普通目标及错误顺序；留在 import coordinator，原函数注释继续明确“不纯”。`verify_bootstrap_pending_inputs` 间接触发相同恢复，补注释说明其必须先于 marker。
- `assess_index_migration`：读取调用者提供的连接，retention/ledger/representation 的 validate 都只读，不另开连接、不 quick-check、不修复。没有因为函数名带 assessment 就假定外层 open 也无副作用。
- `schema11_receipt_matches_current`：经 effectful open 读取 receipt，namespace stamp 可补 seal；without_quick_check 不等于无 I/O。`_with_integrity` 还执行 quick-check 和前后 receipt 比较。`schema11_receipt_metadata_matches` 保持借用既有 handle 的 metadata-only 分支。
- `prepare_schema11_candidate_if_needed`：可进行旧库准入、完整性检查、Prepared 写入、clone/convert/validate/switch 或恢复 phase；归 migration 生命周期，根 open 保留 Home/operation 锁。
- `schema11_file_stamp` / `schema11_sync_file`：production 读取/建立 namespace seal；test 使用物理文件 metadata/fsync，两个合同未合并。
- `record_successful_migration_retention`：manifest 和 SQLite metadata 是两个持久化动作，仍按原顺序重试；“retention/cleanup”不会删除旧证据。
- `existing_exact_store_spec`：所谓 pure lookup 是不注册、不取得 writer admission，仍有文件 metadata、只读 A open 和查询；`writing` 参数控制 owner 解析合同，不是 runtime ready 许可。

## 搬移等价证据

本地不启动 Cargo、SwiftPM、Xcode 或前端构建。证据目录 `scratch/exact-migration-route-d-20261108/` 保存固定基线重建脚本和独立词法核对器。

- 8 个既有/搬移文件完整重建一致，仅模块、显式 imports、原域范围可见性、函数体外注释及新 fixture 的模块接线变化；217 个其他既有 Rust 源文件逐字未变。
- **332 个既有函数体、1,840 个业务字符串/SQL/格式字面量字节一致**，包括 root open/sync/finalize、完整 route coordinator、现有 fixture；新增独立负控实现不混入这个“未变”计数。
- 静态内存负控修改 Validated 重验条件、Switching phase、目标最终 proof 参数和 journal SQL，均被拒绝。不是运行时负控的替代。
- 移动边界额外检查属性归属；在送云端前发现并修正 `prepare_exact_store_for_home` 的 `cfg(not(test))` 搬移范围，避免属性落到 root impl。原 cfg 和函数体均保留。语法解析不替代生产/单测/fixture 类型检查。
- 根内跨模块依赖核对 Exact 16 项、route 17 项；3 个目标模块的 27 个私有自由函数无域外调用。连接消费者改为直接导入 migration 合同，未退回裸 rusqlite 或全模块通配。

## 新增路由物理替换负控

新 `business_store_fixture/route_identity.rs` 和独立 feature-only example 在每次独立进程/临时根中执行生产配置，普通 16 场景 fixture 不扩容。先通过正式 bootstrap 缓存物理 A 身份，建立 generic=123 / Exact=175 canary，关闭 SQLite 连接并把有效 A 复制成另一份字节一致的文件。复制品经容器 catalog 和 quick_check 验证；保留有效 marker，将原文件移出原路径、复制品移入原路径。

检查 6 个真实入口：generic writer/reader、Exact writer/reader、stage admission、published-read admission。要求它们因物理身份变化拒绝，而不是依靠损坏 marker 或 schema；两个数据库影像和 marker 内容保持。最后恢复原文件，确认 canary 可读，保留被拒绝影像。

`scripts/check_route_identity_gate.py` 仅允许云端执行：原实现运行通过 → 临时把 `verify_active_container_identity` 改为成功返回，要求 fixture 因“接受被替换 A”而失败 → 恢复原字节并重新构建/运行通过。编译失败不能冒充负控成功。保留每轮源码/二进制/log hash、退出码和原始报告，临时 mutation 在 finally 恢复。CI native 两端均执行并上传单独 artifact。

本地只检查 Python/manifest/Rust 语法及报告解析器；7 类不完整/错误负控报告均被拒绝。实际物理替换与三轮编译/运行结果等待下方云端验收，不预先宣称成功。

## 收官验收

待同一最终候选 SHA 的双平台完整库、两端各 16 个生产场景、备份负控、物理 A 替换负控、0.9.8–0.9.11 双平台历史矩阵及 Public097 全部通过并下载复核后填写。

未访问正式用户数据库、安装、合并主线或发布；没有新全量性能结论。原有 Windows 报告及未跟踪资料保持，报告 SHA256 为 `63801116c53adee10cb0692cdad6553e6187906f7659ae0aea67b69d4f24ecef`。
