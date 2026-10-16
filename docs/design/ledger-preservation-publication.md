# 数值索引的保留与发布契约（2026-10-16）

适用：原生 macOS Swift 与 0.9.5 Windows/Tauri 候选。原始 JSONL、exact 数值账本、续问建议侧库分别保存；侧库不能改写主账本。Swift 整轮外层事务与 Windows durable pending 发布分别见下文；各端验收以维护报告为准。

## 一条写入流程

完整发现来源 → 按既有 fork / subagent 边界解析 → 分批 staging → 同一 SQLite 连接、整轮外层事务内导入 → 刷新可逆的重复投影 → 发布派生聚合、epoch/generation、扫描覆盖证明 → COMMIT → 清理 staging。

SQLite WAL 让读者在整轮提交前继续看到上一份完整版本。内部事务使用 SAVEPOINT，不能提前提交外层。任意后续批次或消息关联扫描失败，数值、来源位置、去重投影、版本和证明一起回滚。磁盘空间不足停止更新、保留上一版本；不通过删除旧账腾空间。持久 staging 在整轮提交后才清理，失败可复用。

## 保留规则

- 归档目录参与发现。普通归档、移动、删除只改变来源可用性，已入账数值继续参与统计；文本摘录可能不可用。
- 零来源仍打开已有账本。不创建空库假装历史存在；权限、I/O、损坏不会被当成“没有文件”。
- 续问建议 schema 2 保存 absent 标记，保留来源 checkpoint、自有轮次与样本。同路径重写切换 generation 时，旧 checkpoint、配对和自有轮次投影在同一事务归档；当前和历史共用查询视图。稳定 session+turn / pair 身份跨代去重，冲突继续保留证据。无稳定身份的 fallback 按代保留，可能保守重复计数，不能据此删除旧轮次。
- fork 继承前缀仍由 PaginatedHistoryBoundary / 既有解析器判断；fork 自有新增记录继续入账。跨不同 UUID 不用相同指纹作去重。

## 重复 UUID 与统一查询

physical `events` 不删除。`usage_ledger_duplicates` 记录可逆排除关系；`canonical_usage_events` 是所有数值聚合的共同输入。只在同一个有效 UUID 中，完整用量指纹、精确时间、模型、全部数值和核算字段一致时认定副本。UUID 相同但记录不同则保留；旧记录无完整指纹时保守保留并保留歧义门禁。

不再对不同来源的五分钟总量取 MAX；对统一投影 SUM。无法从现存物理事件重建的旧 attribution ledger 下限仍保留，不清空历史 tombstone 账目。去重变化重建派生聚合，不以破坏旧事件解决重复。

## 版本与覆盖证明

主 schema 保持 14，usage ledger 组件 revision 从 1 升至 2。迁移不重排事件 ID、不删除旧事件。旧程序拒绝写入 revision 2。迁移更新 generation，避免命中旧派生快照。

`usage_scan_certificate` 和数值在同一事务提交，包含 epoch、generation、scan ID、发现开始时间、来源数量和来源位置/签名/可用性的 SHA-256 见证。失败刷新不更新证明；快照缓存读取不冒充新扫描。派生快照发布验证 generation 和证明水位。它证明已发现的来源位置，不是对仍在写入的整个 Codex 目录做文件系统原子快照。

## 审计和回退

升级前使用 SQLite backup API 获取含 WAL 的一致快照，记录 SHA-256 与 quick_check；在副本上先迁移，再逐主键比较全部旧事件的数值、来源和归属。部署后重复比较；允许新增事件，旧键不能消失或无证明变更。

只回退程序会遇到 revision 2 拒绝写入，因此不可直接用旧程序覆盖新程序后继续运行。回退需先停止 Bar 并备份当前新库；保留新增事实，使用兼容 revision 2 的修正版优先。若必须恢复升级前库，先保留升级后的完整库与 WAL，明确这会暂时隐藏升级后新增用量，禁止自动覆盖。

验证结果、备份路径、安装身份及未验证边界见本次运行目录的报告。

## Windows/Tauri 对应流程（0.9.5 候选）

Windows 沿用已有的 durable pending generation：逐文件导入只写 pending 层，最终一个事务发布实体事件、canonical 排除关系、派生统计、epoch/generation 和扫描证明。它与 Swift 的整轮外层事务实现不同，但共同对外约束是“上一份完整发布或下一份完整发布”，不能暴露中间批次。

新增组件 revision 2、可逆 `usage_ledger_duplicates` 和统一 `canonical_usage_events`，所有普通数值查询使用同一投影。归因按受影响会话的完整 canonical SUM 重算，不取某一个物理副本的 MAX。无法对应现存来源的旧归因墓碑先保存为 `usage_ledger_attribution_floors`，升级与重算保留其下限；这部分不会冒充重新验证出的原始事件。旧 writer 不得写 revision 2。

扫描证明与发布事务一起提交，记录已发布 generation、epoch、scan ID、发现开始时间、发现数量及全部保留来源位置/签名/可用性的摘要。发现或 staging 失败停止最终发布，pending 可在重启后继续。该证明不声称对正在写入的整个 Codex 目录取得文件系统原子快照。

续问诊断使用单独 schema 2 数据库。后台 writer 使用独立进程锁；只读窗口不取得写锁，WAL 读者在长扫描期间可查看上一份结果。归档/缺失只改变 present，重写先归档上一代。稳定身份跨来源、跨代去重；存在冲突时保留证据并停止采用该配对。500 MiB 预算只暂停写入，不自动清理旧样本。

验收以本次维护报告和发布 locator 为准；本节描述实现契约，不代替 Windows 构建、迁移、安装及运行证据。
