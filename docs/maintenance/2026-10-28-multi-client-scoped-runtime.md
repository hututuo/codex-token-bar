# 多客户端活动速度与来源一致性收尾

独立工作树 `codex/multi-client-tokens`；基线 `b1a664fa`。本批只修改分支源码、测试和文档。未安装或重启正式应用、未替换 Windows EXE、未迁移真实数据库、未向 Anthropic 发送请求。

## 已补齐

- Swift/C# 速度核心新增 `SourceModelRate`：已结算响应、未完成响应保留响应自己的模型；当前生成估算保留当前模型。两类贡献可以同时存在，旧尾迹不再被新模型重新标色。没有模型记录时保留未知段。来源总量与模型段总量守恒；原速度、计价、历史和签名上报数值算法不变。
- DSH、Gemini CLI、OpenCode 接入原聚合速度条和活动速度历史，不新增独立界面。本地显示/历史只读用户已启用的本地来源；排行榜沿用独立 opt-in 语义，见最终回执。Bar 模式仅 Codex 使用原 Bar 算法，其余用上游；Agent Speed 模式不再叠加一次 Bar 值。
- Mac 默认 Gemini 使用上游两个 tmp 根，包含 sandbox tmp；自选根替代默认。OpenCode 选择 `opencode.db` 时统一转为所在目录。根身份只在配置变更时计算，刷新时不做重复 symlink/stat/hash。
- Mac 显示与上报使用相同有效根配置，匹配配置复用进程内 monitor。Windows 显示读取应用实际选择的 Codex Home；上报进程环境里的 Codex Home 也显式覆盖为相同选择。自选 DSH/Gemini/OpenCode 根经有界 `localSourceRoots` 启动管道传递，绝不写入 HTTP 报文。真正换根时停止旧上报并重新建立基线；同一配置、外观修改不重启。关闭上报时配置变化不启动网络或 reader。
- Windows 路径检查区分合法的本地 `\\?\C:\...` 与 UNC/device/GLOBALROOT；继续检查 reparse point。大响应使用上游 Token 边界，取消误用 1 万 Agent 数上限导致的整帧丢弃。不可用快照明确列出所选客户端，不借用别人的读数。
- 其他客户端在本批提供 Token/缓存记录和活动速度；不把不完整的任务/额度信息包装成全面支持。Codex 正文 TPS 保持独立；Claude 不恢复正文/API TPS 页面。Claude 额度仍只读用户已有本地 statusline 缓存，缺失则未接入；不读账号凭据、不启动 Claude、不自动修改其配置、不允许上报。

| 客户端 | 本地用量/缓存 | 活动速度 | 额度 | 主/子任务 |
|---|---|---|---|---|
| Codex | 原索引/账本 | 默认原 Bar，可选 Agent Speed | 原额度链路 | 原实现 |
| Claude Code/Desktop | 本地 transcript | Agent Speed | Code 本地缓存有读数时显示 | 上游本地阶段/父子关系投影 |
| DSH / Gemini / OpenCode | 本地记录 | Agent Speed | 未提供 | 不增加完整任务 UI |

这里的活动速度是按本地事件估算的 output tokens/s，不能当作统一精确流式 TPS，也不是实际扣费证明。

## 数据库与读取器真实状态

B 的用量、活动速度和旧 Claude speed 只读导入共用 `multi-client-usage.sqlite`，本批没有新增持久业务库。原 Token、费用、历史价格、Auto Review 免费参考价规则不变。

**完整两库目标和唯一物理读取责任者仍未完成。** 这两项不能从“同一个解析库”推导为已完成：

- A 的 exact 索引仍每 Home 一库，并以文件为 generation/恢复隔离边界。Swift `sources`、`dashboard_5m`、session catalog、usage ledger 与 Rust 对应表/去重/归因表没有跨 Home 分区。不同旧库的 integer source/event ID 还需要有证明的重映射；简单拼表会混账。
- safety 当前恢复会把整个数据库族搬入 quarantine，再发布只有 safety 表的替代文件。合库前必须改为模块逻辑恢复，并为物理损坏设计全模块保全/恢复；本批没有改它的生产路径。
- Mac 上游显示/上报仅在根配置匹配时共享 monitor；原历史与 Bar 仍有独立读取。Windows helper 与 reporter 复用同一 vendored core 和有效根，但仍有两个进程。不能称为一次物理读取。

下一次改这两项必须连同 schema、跨 Home/模块迁移、失败恢复、断点和旧账对账一起落地；不能把未经验证的数据库重定向放进本批交付。当前没有对实际用户库执行迁移。

## 验证

测试日志位于本工作树 `scratch/multi-client-finish-*`。共享 fixture 位于 `Tests/Fixtures/activity-model-attribution.json`，Swift `ActivityEngineParityTests` 和纯计算 C# `tools/ActivityEngineProbe` 共用：切模尾迹、跨来源同名模型/未知模型、未结算响应模型、零 Token 响应共四例。

- Swift 全量（最终来源配置补丁之前）：2031 项应用 XCTest（20 项条件跳过）、8 项 capture、649 项上游 Swift Testing，通过。后续来源配置/关闭网络/切源基线相关定向回归见最终回执。
- 前端全量：1289/1289；TS/Vite 构建通过。
- Rust 全量第一轮：1431 通过、0 失败、11 ignored。路径、上报启动根与大 Token 帧补丁后的最终全量结果在后续追加。
- Windows Rust：`cargo xwin check --target x86_64-pc-windows-msvc --lib --offline --locked` 通过（含既有警告），没有生成或执行 EXE。
- C#：临时 macOS Arm64 .NET 10.0.403；Reader 编译/离线 self-test、四例共享计算 fixture、Reporter 编译/离线 self-test 通过，编译 0 warnings/0 errors。Reporter 只执行 `--self-test` 分支，没有运行 enabled 网络入口。回执 `scratch/multi-client-finish-dotnet-summary.txt`；SDK/构建产物仅在 `/private/tmp/claude-local-reader-validation.ACIPuB`。
- Vendor 来源锁和工具 7/7 通过。pin 不变，563 个上游文件、16 个逐项解释的本地适配；Swift/C# 同步，MIT 保留。
- Windows 真机文件系统/交互/DPAPI/联网注册、应用视觉和持续功耗：NOT_RUN。源码/交叉编译不替代这些门槛。

### 最终回执

- Swift 最终全量：2033 项应用 XCTest（20 项条件跳过）、8 项 capture、649 项上游 Swift Testing，0 失败；源码见本批最终提交，日志 `scratch/multi-client-finish-swift-all-final.log`。
- Rust 最终全量：1435 通过、0 失败、11 ignored，日志 `scratch/multi-client-finish-rust-all-final.log`。本批大 Token 合法响应和不一致/超限计数、显式不可用来源、Windows 本地磁盘命名空间、启动根协议均覆盖。
- Windows Rust 最终 `cargo xwin check ... --lib --offline --locked` 通过，含既有警告；日志 `scratch/multi-client-finish-windows-final.log`。不等同于 Windows 运行验收。
- 前端最终全量 1289/1289；TypeScript/Vite 通过。新三类客户端选择与双算法不重算有独立回归。
- Reader/Reporter 在临时 .NET 环境均编译通过（0 warnings/errors）、离线 `--self-test` 通过；四例共享引擎 fixture 通过。未运行 enabled reporter，没有真实注册或上报。
- 独立只读审计未发现 Claude 进入上报 monitor 或本地根进入 HTTP 签名报文的路径；没有做 egress 抓包验证。排行榜开关是独立的全来源 opt-in：关闭本地速度显示/历史客户端偏好，不自动撤销已开启的排行榜许可。显示/历史只采集已启用来源；排行榜继续按原策略识别所有非 Claude 默认源，并复用已启用来源的自选根。关闭排行榜开关会停止该链路，改根不会重新开启它。此独立语义未在本批改成“显示关闭即停止上报”。
- Vendor 来源锁、上游干净 checkout 核对与同步工具 7/7；`git diff --check` 通过。

A 旧库归并和唯一物理读取责任者仍按上文列为未完成；不以这些测试通过替代完整方案交付。
