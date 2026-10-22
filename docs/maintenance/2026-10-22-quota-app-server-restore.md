# 额度和重置卡恢复 Codex 官方查询链路

变更在 `codex/quota-app-server-restore-20261022` 集成到 v0.9.7；最终构建、安装、发布状态与资产哈希见 `../releases/v0.9.7-local-locator.json`。

## 请求与生命周期

macOS 和 Windows 的正式额度入口由 Bar 自建 HTTP 客户端切换为一个自有的、持久化的 `codex app-server --disable plugins --listen stdio://` 子进程。通过本地 stdin/stdout 完成 initialize / initialized，再调用官方 `account/rateLimits/read`。额度和重置卡共享同一返回结果，五秒内相邻读取合并；无创建会话、模型推理或重置卡消耗请求。没有直连 HTTP 回退。保留的旧 HTTP reader 不是生产入口。

本地协议见 [OpenAI App Server 文档](https://learn.chatgpt.com/docs/app-server)。这是官方本地接口，网络请求由 Codex 发出；一个新子进程仍使用自身继承的环境，不能把它描述为复用了已运行 Desktop 的连接。雷达和更新下载不属于此额度 RPC。

连接串行化并按请求 ID 匹配响应。数据源、账号、配置、环境文件或 Codex 二进制变化时清理旧连接后重建。普通网络/账号 RPC 错误保留进程，EOF、损坏响应和超时清理连接并按 1/2/4/8/16/30 秒退避；退出时只清理自有进程。stdout 行及待收响应有容量上限，不保存空闲通知；stderr 使用既有有界尾部收集器。Windows 使用持有的 kill-on-close Job Object 保护子进程生命周期，创建或归属失败则返回错误。

卡片返回未提供/null 时不能解释为零张；`availableCount` 没有明细时仍保留数量。Mac 的现有 `quota-account:` 历史身份保持不变，不迁移或删除统计库。

同时适配新版 macOS 的 `Contents/Resources/codex-cli/bin/codex`，保留旧版 bundle 路径、身份验证和 CLI 路径回退。

## 验证

- Swift 额度、历史、启动相关回归：453 项通过，0 失败，包含真实 Codex 连续两次读取额度和卡片且仅启动一次进程。
- macOS Rust 额度/历史相关：195 项通过，0 失败。
- Windows 原生 Rust 额度/历史相关：177 项通过，0 失败，包含真实 Windows Job Object 关闭清理夹具。远端源码按基线哈希保护同步，更新文件与本机源码逐项校验一致。
- 新增生命周期回归覆盖共享快照、跨缓存过期复用、RPC 错误、EOF、超时、退避、目录切换和关闭后拒绝新读。
- Windows 真实账号查询仍受测试所选 Codex Home 未登录限制；只能确认本地握手，不作为实际额度成功验收。
- v0.9.7 完整回归：Swift1804项、11项环境跳过、0失败；前端1213项、Mac Rust1302项、Windows Rust1252项通过。macOS build929与Windows x64已安装，旧账与测速数据保留核对通过。Mac原生额度/卡片界面和持久进程已验证；Windows UI及ARM64硬件运行未验收。

本机短时常驻资源实验：初始化约 0.30 秒，首次查询 1.36 秒，后续约 0.93/0.95 秒；RSS 65–77 MiB，十秒空闲期无可见 CPU 时间增加。这是特定 macOS/Codex 版本的样本，不代表 Windows 或长期资源上限。

原 0.9.6 维护记录关于“额度 app-server 继承环境”的文字只对应保留的旧实现，并未识别当时正式入口实际使用独立 HTTP。本次以生产入口和真实 RPC 回归重新确认链路。

本地证据：外层 `runs/20261022-quota-transport-audit/`，含不带凭据的审计结果、资源实验、双端日志和完成收据。v0.9.7 已恢复独立实际低缓存命中提醒，时间建议及额外扫描仍关闭；ModelTrace PR继续暂停。最终发布证据见 `runs/20261022-quota-cache-v097-release/`。
