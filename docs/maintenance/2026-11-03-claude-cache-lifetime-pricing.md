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
- GitHub 手动 claude_usage_only 只选择 MultiClientUsage Swift 测试和 multi_client_usage::tests Rust 测试；无关前端、升级矩阵、规模、业务恢复及安装包测试不运行。
- [定向云端检查 41666299056](https://github.com/hututuo/codex-token-bar/actions/runs/41666299056) 已成功，对应源码 `bae4dda184f32d17d70ff7262fe035c736bb2d01`：Swift 38 项、macOS Rust 44 项、Windows Rust 42 项，均零失败。Swift 实际编译完整模块后只执行这两个相关测试类；Rust 只执行 multi_client_usage::tests。其他测试任务均 skipped。
- 云端通过了时效补全不增请求/Token、混合时效单价、原日志删除仍保留旧账、重复扫描不增修订、旧/坏可选字段容错，以及不允许较小且自相矛盾的观察借用旧合计“凑出”可计价拆分的用例。
- 没有本机账本写入、安装、替换、重启或发布。安装后才会由现有后台扫描逐批补读历史；本轮未声称已重算本机账目。

## Desktop 额度调查（尚未接入）

1. Token Monitor PR #1126 的本地方式读取 plan-usage-history.json，v2 格式为 version / samples[]，采样含 t、org、u.fh/u.sd，分别代表 5 小时和 7 天已用百分比。该 PR 尚未合并，没有从本地历史保证出精确重置时间；其账号特定的写死每周重置时刻不能复用。来源：https://github.com/Javis603/token-monitor/blob/47b18ecaf094b296f80afef0f0ee4096b885960f/src/shared/providers/claude/desktopPlanUsage.js
2. VibeMenu 已实现对 Desktop Chromium HTTP 磁盘缓存的只读解析，可包含更丰富的重置/模型窗口信息，但依赖未公开格式、缓存可能为空或过期。来源：https://github.com/Kirill-Chistov/VibeMenu/blob/master/docs/decisions/0016-claude-usage-limits.md
3. CodexBar 的 Cookie/OAuth/CLI 路线会发网络请求；不能当成本地额度读取。来源：https://github.com/steipete/CodexBar/blob/main/docs/claude.md

本机确有 ~/Library/Application Support/Claude/plan-usage-history.json，v2、一个采样，采集时间为北京时间 2026-11-03 18:03:24，5 小时已用 0%、7 天已用 16%。采样已旧，不能标为实时。本次未输出组织标识，未读取凭据或发送 Claude/Anthropic 请求。

优先建议单独接本地 JSON 历史提供者：保留采样时间、显示来源与过期状态、组织隔离，不从 Token 数倒推额度，不估填文件里不存在的重置时间，也不在读不到缓存时自动走网络。HTTP 缓存解码可作为后续更复杂的可选来源；本轮没有实现 Desktop 额度提供者。

### 11 月 4 日只读实测更新：优先磁盘缓存

用户指出本地 JSON 历史过期，要求立即按 VibeMenu 的磁盘缓存方式读取。已在本机以独立只读探针验证：只枚举 Claude/Cache/Cache_Data 的普通小文件，按修改时间取最近 160 项、每项不超过 256 KiB，只对缓存键为组织 usage 端点的条目寻找 Zstandard 帧，解压上限 8 MiB。未打开网络连接、未读取 Cookie/凭据、未启动或改动 Claude，也未保存原始缓存正文或组织标识。探针只用本机已有 libzstd，不为正式产品增加依赖。

- 找到并成功解码 1 个额度条目；HTTP Date 为北京时间 2026-11-03 23:59:52，与文件修改时间一致。
- 5 小时已用 13%，重置时间北京时间 2026-11-04 04:09:59。
- 7 天已用 29%，重置时间北京时间 2026-11-04 18:59:59。
- 以上为读取时的真实本地缓存，不是模拟数据，亦不保证未来每次都存在。正式接入应优先使用该来源并验证采样时间；18:03 的旧历史文件不作为当前额度的首选来源。
- 本次仅完成读取验证，尚未把探针接入正式额度提供者；未安装或替换产品，未运行全量检查。

用户同时指定后续计价规则：套餐登录缺少缓存时效拆分时默认 1 小时，明确拆分仍优先。当前已验证的 bae4dda1 尚未包含该兜底；不能将此新增规则误写成已上线，也不能把原始记录中缺少的字段改写成“源报告的 1 小时”。登录类型与推定来源需要在接入时明确，不能无依据地把 API-key 调用算成套餐。
