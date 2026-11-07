# Orca Antigravity 默认目录接入

基线 `cd778491`，分支 `codex/legacy-debt-20261104`。

## 改动与行为

Orca 为 Antigravity ACP 设置独立的 `GEMINI_HOME`。原默认扫描仅包含 `.gemini` 下三个存储，因此 Orca 会话没有进入本地账本和实时监控。本次在源码中补齐真实目录，不创建符号链接、不复制用户会话数据库，也不依赖 Token Bar 继承 Orca 的环境变量。

macOS 默认目录现在为：

- `~/.gemini/{antigravity-cli,antigravity,antigravity-ide,antigravity-acp}/conversations`
- `~/Library/Application Support/orca/antigravity-chat/{antigravity-acp,antigravity-cli,antigravity}/conversations`

空路径（包括 nil、空串及空白）使用全部默认目录。显式选择 `.gemini`、`antigravity-chat` 等父目录时，同时尝试该目录自己的 `conversations` 和四个已知子存储；选择单个存储或 `conversations` 仍保持直接读取。显式路径替换默认目录，不混入用户未选择的其他位置。候选不按当前存在与否裁剪，使稍后创建的存储仍能被监控的周期发现机制识别。

Mac 账本复用 AgentSpeedCore 的目录解析。`ActivitySourceConfiguration` 的默认 `antigravityRoot` 继续是 nil，因此 `AgentSpeedReportingController` 与本地监控都保留完整默认目录列表；已有默认来源身份不变，避免割裂历史速率。监控调用链为 `MonitorConfiguration.resolvedRoots` → `TranscriptSession.watchedPaths` → `MonitorCore` 的 `DirectoryWatcher`。该分支的监听实现名为 `DirectoryWatcher`，没有单独的 `TranscriptWatcher`。

Rust 解析函数新增在 `antigravity_usage.rs`，并由实际偏好入口 `multi_client_usage.rs::source_roots` 调用。ACP 默认目录跨平台生效，Orca 的上述 macOS 路径仅在 macOS 默认加入。解析、conversation/step 去重、备份目录排除、符号链接文件排除及现有上报同意/Claude deny-list 规则保持不变。

## 文件清单

| 文件 | 用途 |
|---|---|
| `Vendor/AgentSpeed/macos/Sources/AgentSpeedCore/Monitor/TranscriptLocations.swift` | 默认目录、自选父目录解析 |
| `Vendor/AgentSpeed/macos/Sources/AgentSpeedCore/LiveMonitor.swift` | 向账本公开同一解析入口 |
| `Sources/CodexTokenBar/AntigravityUsageSource.swift` | 账本默认及自选目录复用 |
| `Sources/CodexTokenBar/ActivitySourceConfiguration.swift` | 说明默认监控与稳定历史身份语义 |
| `Sources/CodexTokenBar/MultiClientUsageViews.swift` | Mac 路径说明 |
| `tauri-app/src-tauri/src/core/antigravity_usage.rs` | Rust 目录解析、数据库与去重测试 |
| `tauri-app/src-tauri/src/core/multi_client_usage.rs` | 接入实际扫描入口 |
| `tauri-app/src/multiClient/MultiClientUsage.tsx` | Tauri 路径说明 |
| `Tests/CodexTokenBarTests/AntigravityIntegrationTests.swift` | 同时发现、解析、账本去重与自选路径 |
| `Tests/CodexTokenBarTests/ActivitySourceConfigurationTests.swift` | 账本和监控路径一致 |
| `Tests/CodexTokenBarTests/AgentSpeedReportingTests.swift` | 默认/自选上报路径、停用与禁止来源规则 |
| `Tests/CodexTokenBarTests/ActivityLiveHistoryTests.swift` | 修正全量回归发现的旧配色断言，保留已有统一模型配色与自定义颜色持久化检查 |
| `Tests/CodexTokenBarTests/InterfaceScaleSettingsTests.swift` | 将已有单日金额折叠工具栏计入 130% 缩放下的高度预算 |
| `Vendor/AgentSpeed/macos/Tests/AgentSpeedCoreTests/AntigravityTests.swift` | 更新默认目录断言 |
| `Vendor/AgentSpeed/macos/Tests/AgentSpeedCoreTests/TranscriptLocationsTests.swift` | 独立临时 home，监听目录、去重和新 WAL 步骤的实时完成事件 |
| `Vendor/AgentSpeed/UPSTREAM.json` | 三个本地补丁及一个本地新增测试的哈希与原因 |
| `Vendor/AgentSpeed/VENDOR.md` | 本地适配与保留边界 |
| 本文 | 修改清单、验证与构建回执 |

## 验证记录

- Rust Antigravity 定向测试：5 通过、0 失败；通过实际 `source_roots` 入口，验证新旧目录同时发现、读取、conversation/step 去重、重复刷新、WAL 完成及迟到模型。`--locked --offline`，当前 macOS host，保留现有编译警告。
- Swift 定向测试：CodexTokenBarTests 28 通过、2 个显式验收测试按原条件跳过；AgentSpeedCoreTests 13 通过。测试数据库位于隔离临时目录，测试结束自动删除。
- Vendor 离线来源检查通过；来源工具单元测试 18 通过。原上游 pin `a94a67fcc78e5d8eea5f82d8d5e737bccf994e2c` 与 `files` 原始哈希未修改，当前本地差异分别进入 `patches` / `additions`。
- TypeScript 与 Vite 生产构建通过。
- 最终完整 Swift 回归：`orca-antigravity-swift-final.json` 为 **exitCode 1**，耗时 259.99 秒。CodexTokenBarTests 执行 2,414 项，37 项按原条件跳过，两个用例共 3 个失败断言；其余 2,375 项通过。AgentSpeedCoreTests 的 Swift Testing 汇总 664 项、78 个 suite、0 失败，原有可选性能场景跳过。不能将本轮描述为全量通过。

最终仍失败的未修改用例：

| 用例 | 最终观察 |
|---|---|
| `CodexUsageAnalyzerTests.testActiveAppendPublishesNextNumericTotalsBeforeEarlierDetailFinishes` | 日汇总 Token 为 130（预期 205）、请求数为 1（预期 2）；同一用例在首次全量中通过。生产总量断言没有失败，尚未确认差异原因。 |
| `SessionManagementStoreLoadingTests.testSupersededContextLoadCannotUnlockOrReplaceNewSelection` | baseline context load 未开始，触发 1 个失败断言。该用例及生产加载实现本轮未修改。 |

按用户最后指令，直接读取最终结果收尾，不再重复全量耗时测试，也没有屏蔽上述失败或据此扩展修改账本/会话代码。本次新增 Antigravity 用例和修正的配色、尺寸预算用例在最终运行中均通过。

全量回归首次发现 `testHomepageOldModelsAreGrayAndSavedOverridesWin` 仍断言历史模型一律灰色，而此前 `fba01169` 已按用户要求统一模型配色。本次只更新该旧测试，检查历史/当前模型与共享配色一致、用户覆盖保存及清除后恢复默认；没有为迁就测试改回产品配色。

同轮 `testStatStripKeepsCompactHeightAtLargeManualScale` 的旧 180pt 预算未计入 `560e4b84` 新增的单日金额折叠工具栏。保持原费用行预算，额外为该行文字、内边距和间距分配 24 个逻辑点并按 1.30 缩放；仍检查高度下限及总上限，展开日历不包含在此预算。没有修改生产 UI。

原始命令、退出码、耗时及日志 SHA-256：`scratch/integrated-recovery/day-cost-20261106/orca-antigravity-{rust,swift,swift-full,swift-final,vendor-check,vendor-tests,frontend-build}.{json,log}`。`swift-full` 保留首次发现旧断言的记录；`swift-final` 为修正后的完整复测。

## 编译与运行边界

Swift 测试编译了当前 Mac 应用、AgentSpeedCore 与测试二进制；Rust 编译了完整应用 library test target；前端生成生产资源。没有构建签名 `.app`、DMG 或 Windows 安装包，没有安装、重启或发布，已安装应用仍为 build 992。

已清理本轮重新生成的 `tauri-app/src-tauri/target/debug`（1,254,620 KiB，约 1.20 GiB），可通过 `cargo test` 重建；来源、依赖、用户数据库和日志没有删除。隔离 SQLite 测试夹具自动释放。保留 Swift debug 编译产物、前端生产资源及小型命令/日志证据。

本次未运行真实账号注册/上报验收，没有向速蹬榜发送测试数据。上述证据证明目录与监听、解析、账本和上报配置接线，不代表网站已经显示新会话；需要安装修复后的应用，在已同意上报且有新活动时进行现场确认。上报保持实时语义，不回填旧历史。
