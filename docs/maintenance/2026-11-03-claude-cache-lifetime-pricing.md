# Claude 缓存时效计价修复与 Desktop 额度来源调查

## 问题与修复范围

本地原始 Claude usage 同时记录 cache_creation_input_tokens 合计和 cache_creation.ephemeral_5m_input_tokens / ephemeral_1h_input_tokens 两项拆分。旧采集器只保留合计，计价器无法区分两档缓存写入单价，所以拒绝把完整金额显示成已知。价表本身包含本机使用的 Opus 5.5、Haiku 5.5，继续复用固定 Agent Speed 价表；没有另建一份价格。

- Swift/Rust 为现有事件 payload 增加可选 cacheWrite5mTokens / cacheWrite1hTokens，不增加数据库文件、列或 schema 版本。
- 原有输入/输出/缓存总量和 v1 请求 ID 不变；两种写入量只是原合计的组成，不能再次加入输入。
- 只有原请求的拆分完整、非负、与原合计及合并后合计一致时才计价。5 分钟/1 小时分别使用现有价表中的对应整数单价，沿用现有分档、时间段和舍入规则。
- 重复或迟到事件保留原计数最大值；元数据能补全，但不能清掉已证明的拆分。相同时间戳采用后到的完整一致拆分，双端一致。
- 历史来源文件还在的，通过现有后台扫描分批补读一次；仅更新扫描断点版本，原请求 ID 保持不变。文件已删除的旧记录与修订审计仍保留，无法证明的写入价格继续未知。
- 修订表仍记录原始观察，不改写为投影结果。Codex 原账本、额度周期和金额不变。
- 损坏、非文本或过大的可选 payload 不阻断已知用量统计，只影响对应记录的完整计价。

## 验证范围

按用户要求只跑相关检查，不做全量回归、安装包或本机替换。

- 原始 Swift 模型单文件类型检查、解析语法检查通过；最小包实测元数据合并与旧 payload 解码通过。
- 增加 Swift 解析 ID 稳定、避免重复计入输入、混合缓存单价、原始计数保留、旧/坏字段兼容、一次补读后回到增量及来源删除保留账目的用例。
- Rust 增加对应 payload、合并、计价、坏数据隔离、断点用例。
- GitHub 手动 claude_usage_only 只选择 MultiClientUsage Swift 测试和 multi_client_usage::tests Rust 测试；无关前端、升级矩阵、规模、业务恢复及安装包测试不运行。结果待本轮源码完成后记录。

## Desktop 额度调查（尚未接入）

1. Token Monitor PR #1126 的本地方式读取 plan-usage-history.json，v2 格式为 version / samples[]，采样含 t、org、u.fh/u.sd，分别代表 5 小时和 7 天已用百分比。该 PR 尚未合并，没有从本地历史保证出精确重置时间。来源：https://github.com/Javis603/token-monitor/blob/47b18ec/src/shared/providers/claude/desktopPlanUsage.js
2. VibeMenu 已实现对 Desktop Chromium HTTP 磁盘缓存的只读解析，可包含更丰富的重置/模型窗口信息，但依赖未公开格式、缓存可能为空或过期。来源：https://github.com/Kirill-Chistov/VibeMenu/blob/master/docs/decisions/0016-claude-usage-limits.md
3. CodexBar 的 Cookie/OAuth/CLI 路线会发网络请求；不能当成本地额度读取。来源：https://github.com/steipete/CodexBar/blob/main/docs/claude.md

本机确有 ~/Library/Application Support/Claude/plan-usage-history.json，v2、一个采样，采集时间为北京时间 2026-11-03 18:03:24，5 小时已用 0%、7 天已用 16%。采样已旧，不能标为实时。本次未输出组织标识，未读取凭据或发送 Claude/Anthropic 请求。

优先建议单独接本地 JSON 历史提供者：保留采样时间、显示来源与过期状态、组织隔离，不从 Token 数倒推额度，不估填文件里不存在的重置时间，也不在读不到缓存时自动走网络。HTTP 缓存解码可作为后续更复杂的可选来源；本轮没有实现 Desktop 额度提供者。
