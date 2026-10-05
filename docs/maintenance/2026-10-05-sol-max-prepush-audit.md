# 2026-10-05 独立发布前复审

## 范围和身份

用户要求最多两名 Sol Max 与主 agent 独立复审。审查基线为 `16711ea208e111ba6711c11094626f26b795c3c4`，初始审查代码为 `29c84923a543eed21b35c9f91672e6e140cdcdcf`（文档 HEAD `e841317c6d02b878ea1ea3a07addf437ed1ec450`）。两名独立 GPT-6.1 Sol Max 分别审查 Swift 和 Rust/Tauri/Windows；主 agent 负责上层调用、集成、安全边界及修复。没有恢复本地大型编译依赖，没有读写用户真实聊天正文或 live index。

## 确认问题和修复

1. **Rust 不可读入口被当作来源删除。** `physical_path` 在 plain 目录项仍存在但链接目标缺失时返回 NotFound；正式 owner 对这个错误不登记 seen/incomplete，从而按 missing 处理。修复为 InvalidData；compressed 悬空入口同样处理。只有两个表示确实均不存在才沿用 NotFound。还补上 materialize 在首次 plain lookup 后先发布 plain、再移除 zst 的窗口：compressed 缺失时再次查 plain；已出现则返回 Interrupted 并由 reader 重试，不登记删除。三次选择/开读重试耗尽改为 Interrupted，不能作为删除证据。开读后复核 plain 优先使用 symlink_metadata，包含刚出现的悬空目录项。
2. **Swift 合法转换漏重试。** macOS 的 FileHandle 对缺失路径实际抛 Cocoa code 4，旧 guard 只接受 260 和裸 POSIX ENOENT。独立合成转换竞态已复现。统一识别 code 4/260 和有界 underlying ENOENT；权限/损坏仍立即失败。zst 开读后用 lstat 确认 plain 优先，不忽略不可访问入口。
3. **Swift 轻量签名重复打开全体文件。** 完整索引 witness 查询先实际观察每个来源，cache-key 构造再观察一次。改为单次 SQL 取持久完整 witness，调用端以当前 stamp/mtime 对比后才能用旧 logical size；改名 `storedCompleteSourceObservations` 明确它不是当前观察。plain 当前观察恢复单次 lstat 快路，正文 proof 保留 pinned handle 与路径后置核对。独立元数据微基准约10倍成本只适用于旧两轮 metadata helper，不代表整体应用耗时。

4. **Swift 缺失 logical leaf 的父目录别名解析不稳定。** Foundation 对不存在的 leaf 可能保留 `/var` 或父目录 alias，旧来源却按 plain 存在时的 canonical path 保存。普通 UI scanner 已先选存在物理文件并 canonicalize；确定影响主要是直接 sync/tree API 的非 canonical logical 输入与测试，会失去旧 witness、触发不必要重建/路径迁移，不能据此声称正常 UI 已经双计。统一 helper 只解析父目录并保留 leaf，在 plain→zst→plain 保持同一 logical path，也不把危险 leaf symlink 隐藏到别的来源。同步、签名和去重三处复用；catalog 的完整 witness 查找也用 canonical key，已有 catalog row key 不迁移；不打开压缩正文做 canonicalize。

新增回归覆盖：悬空 plain/compressed 与真正丢失的分类；discovery 后 source 变化且另一新 candidate 强制正式 owner，检查发表代次、断点、missing、raw 可用性与可信消费保留，恢复后仅加一次新消费；官方 materialize 顺序插入两次表示 lookup 之间，reader/轻量长度重试并选新 plain，零压缩解码；真实 Foundation 缺失错误识别；stored witness 零文件 I/O；plain tree signature 零 opens；同长度/恢复 mtime 的 compressed 替换必须使 signature unknown；父目录 alias 的冷来源同步不重建、ID/path 保持、恢复追加只新增7，unsafe leaf 仍拒绝。

## 确认的兼容限制，未放宽安全门

Rust 独立审查将无 previous 或变化 cold source 使目录整体延期列为 P1 影响面。对照已批准的[实施方案第三组](compressed-history-implementation-plan.md#第三组目录与操作前置检查)，这是本轮明确选择的安全策略：没有可信 catalog 元数据时保留旧目录并拒绝不能证明路径唯一性的危险操作，不新增占位、不自动解码冷正文。不是“所有用户场景无影响”。它不会清零消费或删除历史账；普通会话目录也可能无法本轮刷新，严格归档/删除/恢复包前置检查可能被阻挡。state DB/官方 protocol 的展示仍可提供会话信息，不能因此声称路径认证已完整。

仅有 logical jsonl catalog 路径而磁盘只有 zst 时，session management 的 trusted path 仍不解析 twin；Swift UI scanner 仍仅枚举 plain。这两项为基线已有会话管理支持边界。本轮保留，不绕开身份/唯一性校验，不把恢复危险操作变成自动压缩正文读取。后续扩大支持必须单独给出身份与唯一性证明路径。

## 其他核对

未知 compressed signature 保留 candidate；前端 unknown/changed 仍进入正式 owner。正式 owner 获得实际大小后才进行 heavy/light 调度，不按 unknown=0 估算内存。稳定完整 cold source 不解码；必需 enrichment 与 Summary→Full 数字覆盖继续处理。plain 优先和双表示去重、message repair、摘录预算/descriptor 漂移、stage manifest/EOF/重启、非标准 Home watcher 均已审查。

Windows 保持写句柄打开时的零延迟 rewrite、ReFS/网络卷物理 witness 尚未实机验证。现有云端测试覆盖关闭句柄后保留 mtime 的改写；不能用它代替所有文件系统或客户恢复验证。

## 验证状态

- 初始代码同 SHA 全套 CI：PASS，run `37313120365`。不能代替这次修复的 CI。
- 本次 Swift syntax parse / diff whitespace：PASS。
- 修后两位 GPT-6.1 Sol Max 独立复核：PASS / SOURCE_CONFIRMED，未发现剩余确认缺陷。Swift 实际组件错误分类10项通过、合成转换每类5000次成功；Rust 实际 resolver/hook 的独立 std-only probe 通过。组件结果不能代替完整包/客户现场。
- 最终代码/测试 SHA：`1c1e624e90319d7c8e80509817cf526bfce86b54`；[CI 37330037503](https://github.com/hututuo/codex-token-bar/actions/runs/37330037503) 七项 job 全部成功，sealed checked-source.json 的 SHA/run ID/passed=true 已回读核对。Swift1664项（7 skipped）、Rust/macOS1205 passed（10 ignored）、Rust/Windows1154 passed（10 ignored），均0失败；两端超过两万文件压力回归通过，Windows打包 self-test及 updater 故障 fixture通过。前端1170项+云端契约11项通过、生产构建及依赖audit通过；Swift发布脚本103项（102 passed、1 skipped）。
- 中间 SHA `f9e0e4d4` 的 Rust/macOS 已为1205 passed、0 failed、10 ignored，三个新增 owner/resolver 测试通过；不能代替后续 Swift canonical/catalog 修补的全套验收。
- Windows 客户安装恢复、真实大历史 wall-time、应用实机体验、打包签名及正式发布：NOT_RUN。

修后同两位 Sol Max 独立复核通过，保留上文已知会话管理/文件系统边界；不能将源码和合成回归验收说成客户现场恢复或全部文件系统零风险。代码已经推到原 `codex/cold-history-read-paths` 分支；没有合并、打包签名或发布。

本次证据目录：`runs/20261005-sol-max-reaudit/`。所有微基准和转换实验只使用合成文件，测试结果与现场/发布验收分开记录。
