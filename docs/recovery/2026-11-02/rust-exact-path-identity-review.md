# Rust Exact 虚拟路径身份接续：实现与验证边界

## 实际问题

原 `source_identity` 先 canonicalize 全路径，失败后只 canonicalize 直接父目录。A 内虚拟分区没有对应 SQLite 文件；暂存目录也可以不存在。当配置根目录是 symlink，或者 Windows 调用方使用普通路径而 canonicalize 返回 verbatim 路径时，创建缺失父目录会让同一个逻辑索引/暂存文件生成不同 ID。

普通暂存 `<index>.staging/<sourcehash>.sqlite3` 使用这个旧 ID。candidate-v2 虽有独立 logical family，family 仍由同一个不稳定的 index ID 计算。只枚举文件无法发现已经仅存在 A 中的旧分区。旧版可以在新 ID 下登记空分区，或重新解析形成另一份有效暂存；不能把“新地址没有表”当成没有历史。

Root 已实际运行的旧函数反例：`artifacts/path-identity-component-red/report.json`，exit 101。此轮独立重新编译逐字节生产函数：`artifacts/path-identity-stable-component/report.json`，同一次执行确认旧 ID 变化、新 ID 在创建父目录/文件和删除目录后保持相同，exit 0。旧函数 SHA-256 均为 `1ea346ab0e626eef00b30925bced330a757a3af6d4a8aa16f5da6ee98e6c35ab`。这只证明路径函数；不等同 A、seal、import、重启或 Windows 验收。

## 改动边界

- 全局 v1 `source_identity` 不改，quota/modeltrace/body-speed 不重新编号。
- Exact 的新地址从最近可解析祖先拼回剩余字面路径。不能安全穿过缺失目录的 `..`、无法读取的父目录、数据库文件叶 symlink 均拒绝；不创建目录来改变身份。
- 旧 ID 候选只来自当前请求的原始路径、已解析路径和 Windows ordinary/verbatim 对应拼写。每个候选使用 `tb_stores.store_id` 主键查询，在调用方已经打开的 A 连接上解析。candidate family 使用 `logical_path` 唯一索引的范围查询，替代旧的 `substr` 全目录过滤。
- 有且仅有一个历史 owner 时，所有读写、原件 receipt、seal、clone 和删除仍使用原 `StoreSpec`。不改旧 `store_id`、`logical_path`、SQL prefix 或源文件。
- 已打开的 `StoreConnection` 从其绑定的 store ID 在同一连接读取完整目录身份。stage 内容校验将这个 owner 放入短期 `StageStoreSignature`；比较、attach 和 IMMEDIATE import 的重验沿用该 owner，不在写入前按路径重算另一份身份。preserve-copy 的删除仍使用已复制 owner + 完整 proof 的 CAS。
- published/compatibility 的只读入口只读 A：不注册、不导入、不写 alias receipt。未知路径返回不存在。迁移/producer 的显式写入入口独立解析并复用旧 owner。

## 多 owner 的处理与剩余工作

本轮新 resolver 在登记前先查询旧候选，避免继续制造第二个 owner。已经形成的多 owner 必须单独区分：

1. **一份历史 + 空登记**：只有 `user_version=0, revision=0, state=ready`，且无实际对象、导入、对象目录、seal、旧输入 receipt 或未完成迁移 journal 的登记才算空。保留这个登记，继续读写唯一有历史的 owner。不能以 row count 为零推断“可丢弃”。
2. **完整 proof 相同的两份历史**：同一只读 snapshot 证明 schema、typed rows、各表计数、module version 完全相同后，可确定性只读选择 canonical 首选；两个原件均保留。写入仍需明确的 owner 收束记录，否则一次正常追加就会让另一份副本落后，下一次查询又变成冲突。
3. **不同有效历史**：现阶段保护保留两份，错误带完整 store ID；不按 token SUM、时间新旧、行数或文件是否存在任选一份。真实可达状态是旧 raw owner 已有 120，目录出现后旧 router 又在 canonical owner 形成 175。源码与测试不能把此保护拒绝宣称为成功接续。

后续收束必须在写者持有的事务/操作锁中完成，保留所有 alias 原件，证明选定 owner 覆盖每一份旧有效事实，并记录选定 owner 与被冻结 alias 的完整 proof。已有 `exact_history_covers` 用于 schema 13/14 主库，要求 metadata/Home、完整持久事实和特定兼容语义；四表 stage 不符合这个入口，不能不加约束直接套用。相同 proof 的 writer-owned alias receipt 可以作为最窄下一步；不同 stage 的选择还必须复用生产 manifest、source prefix、generation 和 pending-history guard。没有这样的证明时，拒绝写入是保护措施，不是此状态验收完成。

旧 raw ID 只保存了路径字符串的 hash，没有保存 symlink 当年的物理目标。候选命中是寻址，不是物理身份认证。本轮不会逆推已经删除/retarget 的旧别名，也不扫描其他 Home 的 manifest 猜归属。活动 A 文件身份验证、主索引 Home 校验、stage source/session/generation 校验和最终 typed proof/CAS 仍各自成立。仅凭最终 physical spelling 无法恢复已经完全丢失的旧 alias 字符串时，应保留原分区并提供有证据的恢复路径；不能声称任意 alias 变更已经自动覆盖。

## 新验证用例

`business_store_route/path_identity_tests.rs` 使用真正 Container/StoreConnection/API 的 11 个测试：

- 两层缺失目录创建、真实文件出现、目录移除，main/primary/candidate 的新地址稳定。
- 真旧 raw owner 已有数据而无物理 stage，目录出现后 readonly 读到原 owner；Windows 增加 ordinary→verbatim 读者。
- 真旧 candidate family 已有数据，目录出现后目录身份不改。
- writer 在旧 owner 追加，不注册空替代分区。
- 未知只读路径既不登记也不建目录。
- 旧 120/new 175 冲突保留双方完整 proof。
- 完全相同 proof 的双 owner 只读保留，写入不静默分叉。
- 一个历史 owner 加纯空登记正常接续，空登记也不删除。
- catalog 身份不一致拒绝且不落入新登记；已打开连接拒绝继承随后变更的 logical_path。
- Unix 数据库文件叶 symlink 拒绝。

`exact_usage_index/path_identity_fixture.rs` 是 non-cfg(test) feature CLI 的真实生产接入点。输入已有生产 parser 完成并 seal 的 stage；克隆到旧 raw primary 和旧 candidate family 后创建物理目录。调用实际 `stage_or_reuse_full_rebuild`，要求相同 artifact ID、固定旧 owner、无替代解析；移除目录后调用真实 import 两次，检查 typed pending/ledger 幂等，并检查原主库、原 stage、原 raw 完整保全。它不改生产 manifest 字段来假造一次成功，也不使用 cfg(test) 独立文件存储代替 A。

接入位置：`runtime_recovery::verify` 取得 `old` 和 `original_proof` 后执行 `super::path_identity_fixture::verify(&home, &index_path, &old, generation)?`。只有这段真实执行返回成功后才输出 `legacyExactPathIdentityRecovered=true` 和 `readOnlyExactPathIdentityPreserved=true`。runner 必须严格拒绝字段缺失或非布尔 true；不能先填字段再把它称为验证。

**当前状态：**Linux 路径组件实际运行成功，`git diff --check` 成功。上述 Rust unit 与 feature CLI 尚未在此私有树运行；由 Rust agent 串行 Cargo/native 执行，结果须绑定最终源码与二进制。Windows 路径行为仍须 Windows 原生结果，不由 Linux 组件替代。

## 双有效 owner 的真实形成回归

后续 `verify_competing` 接收 surrounding fixture 的两个实际 production parser 产物（完整 120 前缀及追加后的完整 175）。使用未修改的旧 `source_identity` 在创建目录前后各计算一次地址，再用生产 Container clone/seal 形成两个不同的、独立有效的 A owner；不改任何 manifest、event、fingerprint 或 checkpoint。测试要求普通 `stage_or_reuse_full_rebuild` 成功选中完整 175，固定 StoreSpec 在目录移除后导入并实际 publish，重开后 canonical 175 可见，原 120/175 两个 namespace 及 raw 原件完整不变。

这是成功恢复的正控制，当前只有 `fb0ff633` 的保护 resolver 时预期仍会失败（多 owner 尚未接续），不能记录为 PASS。集成位置是在真实 `candidate` 形成后，调用 `super::path_identity_fixture::verify_competing(&home, &index_path, &old, &candidate, generation)?`。待原生回归实际闭环再添加对应强制 evidence 字段；不在尚未执行时先声明 recovered。
