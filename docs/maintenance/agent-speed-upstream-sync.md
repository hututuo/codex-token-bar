# Agent Speed 复用与同步维护

维护入口：`Vendor/AgentSpeed/VENDOR.md` 和 `Vendor/AgentSpeed/UPSTREAM.json`。每次准备发布都要检查上游；Swift、C#、spec 和上游测试按同一个提交同步。

2026-10-26 已核对公开仓库 HEAD：`a94a67fcc78e5d8eea5f82d8d5e737bccf994e2c`，与当前内置版本一致。版本锁覆盖 563 个上游文件，另列出 6 个经过审核的本地适配及原因。

## 现在复用哪些部分

| 能力 | 复用入口 | Token Bar 的接法 |
|---|---|---|
| 各客户端的本地日志发现、增量跟踪和读取 | AgentSpeedCore.LiveMonitor / IO / source adapters | Claude 本地监视器和独立上报监视器直接使用同一个 vendor；明确传入启用来源，不依赖默认全开 |
| Token 归一化、重复记录合并、请求起止和测速校准 | 上游 ClaudeParser / TokenUsage / SpeedEngine | 消费公开快照和 responseCompleted 结果；内部算法继续由上游维护 |
| measured / estimated 区分 | SourceStatus.liveEstimated / SpeedSnapshot.liveEstimatedShare | Mac 按所选来源计算占比，Windows 使用上游结果；无法分离单客户端的聚合占比时留空，不套用其他客户端的估算 |
| 运行阶段、主任务、子 Agent 与父子关系 | AgentStatus.phase / isSubagent / parentId | 只做本产品的时间新鲜度、脱敏、范围和界面映射 |
| 模型价格、分层价格和缓存类别计价 | PriceBook.bundled / TieredPrices / ResponseCost | 共用整数 pico→micro USD 计价和四舍五入；历史账本仍先检查精确型号、时段价格、缓存写入生命周期和数量边界，不扩大猜价 |
| 设备注册、签名、上报、头像与多设备协议 | vendored Reporting / Profile | 沿用既有 opt-in；Claude Code/Desktop 在 Token Bar 入口硬性禁止上报 |
| 压缩读取、SQLite 和固定价表资源 | vendored IO、CZstd 与 spec assets | 本地监视器沿上游调用链使用；不增加重复的下载或旧日志测速扫描 |

## 这些仍由 Token Bar 保留

- 原 Codex 原始账本、费用周期、fork/归档保留规则和迁移/备份。
- 多客户端的逐事件持久账本及五分钟/24h/7d/30d产品投影。上游 HistoryService 是另一套日聚合与数据库，不能替换逐事件记录，也不额外启动一个全历史扫描器。
- Claude statusline 的额度、上下文和累计 API 耗时。上游 transcript API 不提供这些字段；它的请求区间速度与这条 API 耗时测速分开显示和保存。
- 原有 Token Bar 界面、模型色彩和小数显示习惯。上游 SpeedFormat 会改变读数的舍入与缩写，暂不替换。
- Claude 本地保护、上报来源过滤及应用自己的设置/生命周期。同步上游不能覆盖这些适配。

## 日常和发版检查

以下命令都从 Token Bar 工作树根目录运行。

```sh
# 日常/PR 校验：离线核对文件哈希、来源、MIT License 和本地补丁。
python3 scripts/agent_speed_vendor.py check
python3 -m unittest discover -s scripts/tests -p test_agent_speed_vendor.py

# 发版准备：额外只读取 GitHub 的公开 HEAD。不是客户端运行时行为。
python3 scripts/agent_speed_vendor.py check --remote
```

普通 CI 执行离线检查。`prepare-release.yml` 的 Mac/Windows 任务依赖 `agent-speed-sync`：上游已更新、无法确认 HEAD、vendor 被偷偷改动或许可证/提交号不一致时停止准备安装包，先处理同步。该流程不会自动发布或安装。

## 上游更新时

1. 在独立开发分支保存当前改动；准备一个干净的 Agent Speed 源码 checkout，检出待审核的完整 SHA。工具不执行 fetch、checkout 或安装器。
2. 查看范围内的改动，未包含的 UI/研究目录不会混进产品：

```sh
python3 scripts/agent_speed_vendor.py compare --upstream /绝对路径/agent-speed
```

3. 审查解析字段、时间口径、Token/缓存归一化、模式证据、模型价格、文件读取性能，以及启动时和读取时的网络/凭据路径。Claude 只读本地、不请求 Anthropic、不读凭据、不自动改 Claude 配置、不得上报的约束继续生效；新增来源和别名也要检查。
4. 同步 `UPSTREAM.json` 列明的四个范围及 `LICENSE`；保留六项本地适配（身份两项、隔离/协议测试四项）。新增/撤销本地适配必须有明确原因。产品适配尽量写在 vendor 之外。
5. 同时检查 `Package.swift`、Windows helper 的目标框架/引用、资源打包、Swift/C#/Rust/TS DTO 和默认关闭策略。不得触碰用户账本、凭据或正式安装目录。
6. 跑上游核心测试与 Token Bar 回归：请求时间、重复事件、输入/缓存/输出、分层与 Fast 价格、未知价格、来源过滤、禁上报、停用立即停读、5/15/30滚动窗口、父子归属。Windows 需实际 .NET/目标平台构建；没有构建环境要写 NOT_RUN，不能宣称双端实机完成。
7. 更新 `VENDOR.md` 中的 SHA。把所有实际差异的“相对路径 → 原因”写成 JSON（参考旧锁中的 patches）。完成审查后记录新的来源锁：

```sh
python3 scripts/agent_speed_vendor.py record \
  --upstream /绝对路径/agent-speed \
  --commit 待审核的40位SHA \
  --patch-reasons /绝对路径/patch-reasons.json \
  --reviewed
python3 scripts/agent_speed_vendor.py check --upstream /绝对路径/agent-speed
python3 scripts/agent_speed_vendor.py check --remote
```

`record` 只写来源锁，不复制源码或修改上游。任何未解释的差异、增删漏同步或脏上游 checkout 都会失败。锁更新和源码/测试作为同一个提交交付，并在本页补同步回执；原 Git 提交提供源码回退点。

## 本次验证回执

- 上游公开 HEAD 与当前 pin 一致；干净 checkout 的源码核对一致。
- 除已列明六项适配外，没有改动上游核心源码。
- 增量使用 SourceStatus.liveEstimated 和 ResponseCost；未增加 Claude 网络路径或历史扫描器。
- PASS：Swift 应用回归 27 项、上游价格表 18 项；来源锁工具 7 项；前端范围/SSR 4 项；发版工作流契约 7 项；前端构建和两份 YAML 语法检查。离线来源核对和公开 GitHub HEAD 检查均通过。
- 真实活跃 Claude / Windows 产物验收状态延续上一轮，不能以这次核心回归替代；没有安装或替换正式应用。

## 2026-10-27 标准价表合并要求

Codex 原当前标准价已接到 pinned PriceBook / prices.json；Mac 与 Tauri 历史价格共用 `Sources/CodexTokenBar/Resources/standard-api-price-history.json`。今后同步上游价格时，保留冻结历史，追加新的生效日期、价格与 revision，不得把新价套进旧事件。雷达历史基准/Spark 参考价不随当前表修改。具体改动与口径见 [核对报告](2026-10-27-speed-reading-and-price-unification.md)。
