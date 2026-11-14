# 本地客户端额度历史

用户要求沿现有路径接通 Claude、Antigravity 的额度记录、曲线和 24 小时变化，并替换本机正式版。一级菜单设计示例已经收起，本次接入使用现有额度展示和时间图表。

最终检查源码为 `eb5a348e1aabb290dbb2f3613a01d9345da1a8cf`，位于 `codex/storage-responsibility-split-20261106`。工作树为 `/Users/huyiyang/.codex/worktrees/f97f/codex-token-dashboard`。

## 数据链路

- Swift 的 `MultiClientUsageStore.refreshLocalQuotaCaches` 沿现有主页面刷新间隔读取客户端状态，在 `MultiClientUsageScanner` 内通过现有 `MultiClientUsageLedger` 记录、读取并准备图表时间桶。后台 actor 负责分桶，界面直接使用结果。
- Windows 的既有 `read_local_client_quotas` 返回当前读数和历史样本。后台 `refresh_and_publish` 在用量扫描释放 gate 后记录额度，因此隐藏 WebView 时也能持续积累。历史读写失败会保留当前额度读数并附带诊断。
- `DashboardRecentUsageChart.swift`、`DashboardAnalyticsSection.tsx` 以及侧栏的 24 小时图增加额度来源选择。Antigravity 的 Gemini、第三方模型各自选择 5h / 7d 两条曲线。图表继续使用既有 24h、7d、30d 范围和绘制逻辑。
- 来源切换同步更新曲线、图例和交互入口，金额采用各客户端的计价结果。

## 数据库兼容

沿用 `multi-client-usage.sqlite`，保留 `user_version=2`，增加可选表 `client_quota_observations`。旧应用可以继续打开数据库并忽略这张表。Codex 的额度历史与用量表维持既有结构。

该表保存客户端、来源、窗口 ID、原观测时间、已用百分比和重置时间。主键为 `(client, source, window_id, observed_at)`，百分比使用 REAL。

重复读取同一缓存沿用原时间并幂等写入。同一窗口在 5 分钟桶内重复的相同值会去重，数值或重置时间发生变化时立即保留。历史读取限定近 30 天，每客户端最多 500,000 条，超量会明确报告。这个范围覆盖 30 秒刷新、四个窗口整月变化的正常输入。

Claude Desktop 的 V1/V2 历史文件按最近组织导入，使用每条记录的 `t`。HTTP 缓存与历史文件各自保留来源，额外来源可通过图表里的“历史采样”项查看。

图表延续近期观测，并在已知重置时间、长时间无观测处留出空白。界面中的额度百分比保留最多两位小数。

## Antigravity

本机语言服务改读 `RetrieveUserQuotaSummary`，固定识别 `gemini-5h`、`gemini-weekly`、`3p-5h`、`3p-weekly`。逐模型 `GetUserStatus` 响应作为负例。兼容 root、response、summary 包装及明确的 remainingFraction 表达，保留缺失窗口。

请求延续已有的本机进程、端口、CSRF、TLS 和身份复核路径。客户端运行时可以提供新观测，关闭后的历史仍由本地数据库读取。

## 验证与安装

本机 `/Applications/Codex Token Bar.app` 已替换为 **0.9.11 / 1015**，安装时间为 2026-11-14 18:33（北京时间）。安装包来自源码 `e0407a73236d08f0fd81b9b1dc3ab77c2f77f69f` 的成功 macOS 打包任务。其后只有 Windows RPC 测试断言和 CI 必跑测试名称发生变化，已核对当前源码与该候选的原生 Mac 构建输入完全一致。

- [最终完整检查 43585422414](https://github.com/hututuo/codex-token-bar/actions/runs/43585422414) 成功。Swift 执行 2,514 项、跳过 38 项、失败 0 项；Rust macOS 1,853 项通过、14 项忽略，Windows 1,796 项通过、14 项忽略；前端 1,486 项通过。既有压力用例、必跑测试核对和安装器检查继续执行。
- [Public 0.9.7 数据库升级检查 43584175555](https://github.com/hututuo/codex-token-bar/actions/runs/43584175555) 的 macOS、Windows 两条任务均成功，源码为 `a89965e4f185be43aa3b1cf24d7b926ee72fff6c`，与最终检查源码仅差 CI 测试名称修正。
- [候选打包 43583090245](https://github.com/hututuo/codex-token-bar/actions/runs/43583090245) 的 macOS 任务成功，使用其 `candidate-macos-e0407a73236d08f0fd81b9b1dc3ab77c2f77f69f`。该次 Windows 打包任务遇到旧测试断言失败，断言已修复并通过最终 Windows 检查。本次完成的是 Mac 安装，Windows 尚无本机安装验收。
- 候选来源清单、ZIP 路径与内部链接、DMG 完整性、App 签名和安装后签名检查均通过。安装后可执行文件 SHA-256 为 `2c73bd1a289cfc724bec0b0c31e84b6402cb1738a4d3e791d9240784604c3a4e`。

安装前保留 1014 App、偏好设置和 352 个 SQLite 备份，数据库备份共 1,179,406,336 字节，备份检查均为 `ok`。安装后逐条比对多客户端账本原有的 24,172 条 revision，内容与备份一致，18,687 条用量事件仍完整，`user_version` 继续为 2，实时数据库 `quick_check` 为 `ok`。

真机已验证以下行为：

- 主页 Antigravity 仅显示四个固定窗口，百分比保留小数。
- 24 小时图可以切换 Claude Desktop、Antigravity Gemini、Antigravity 第三方模型，5h / 7d 图例与读数随来源更新。
- Claude 原有 77 组采样（每组两窗口）已导入，在“Claude Desktop · 历史采样”的七天图中可以看到；本地 HTTP 缓存仍作为独立来源保留。
- Antigravity 四个窗口均在安装后的多次后台刷新中继续增加记录。Claude 未更新的缓存一直保留原采样时间，没有产生虚假的新观测。
- 使用已有的 1 分钟额度刷新设置，验收后主页图表停在“跟随主页 · 汇总 / Antigravity · Gemini / 24h”。Antigravity 获取新观测需要客户端语言服务运行；历史曲线可以离线查看，未曾观测的时间段保留空白。

私有安装证据与备份位于 `~/Library/Application Support/CodexTokenBar-Maintenance/2026-11-14-quota-history-uhqkz9ut/`。`install-record.json` 记录安装及备份；`runtime-history-final-verification.json` 记录数据库保全、后台增长和真机图表核对结果。1015 会话已记录 `startup.ready`、`index.ready` 和后续刷新完成。日志还保留一次通用 frontend 诊断以及 updater 的 code 1001 事件，不能据此声称所有运行诊断均为空。

同目录 `rollback-build1014/restore-app.py` 默认只核对 App 身份，已通过只读核对。需要回退时显式传入 `--apply`，它保留当前数据库及新额度观测，仅恢复 1014 App，并另存被替换的 1015 App。数据库备份不自动覆盖回去。真实数据和运行日志只保存在此私有目录。
