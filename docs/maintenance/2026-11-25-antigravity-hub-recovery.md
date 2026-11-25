# Antigravity 桌面额度恢复

## 新版 Hub 登记文件

Antigravity 2.35.1 的桌面语言服务将本机端口、PID 和 CSRF 值写入 `~/.gemini/antigravity/daemon/hub_<httpPort>.json`。原读取器仅检查进程参数中的 `--csrf_token`，因此没有发出额度请求。

build 1059 接入了客户端已有的登记文件。读取器先核对当前用户的已安装进程与其 loopback 监听端口，再读取对应登记文件并查询 `RetrieveUserQuotaSummary`。请求前后复核进程与端口绑定。读取范围保留 Gemini 和第三方模型各自的 5h、7d 四个 bucket，数值进入原来的 `local-antigravity-rpc` 历史来源。满额的窗口可以没有重置时间。

2026-11-25 用户明确允许 Antigravity 发额度请求。自动刷新使用主页面已有的间隔设置。本机当前为一分钟。接口可能由客户端继续向 Google 查询额度。

社区参考为 QuotaBar 在提交 `40869baeb49a8343c0f616433514bac4f1b552f0` 中的 Hub 登记方式。该方式在本机独立 Antigravity.app 2.35.1 上实测成功。[QuotaBar 源码](https://github.com/QuotaBar/QuotaBar/blob/40869baeb49a8343c0f616433514bac4f1b552f0/Sources/QuotaCore/Providers/AntigravityLocal.swift)

1059 安装时 Antigravity 处于登出状态。后来正常采样已恢复，最新成功样本到达 2026-11-25 21:30:41。1060 排查开始时，数据库已有 8,273 条 Antigravity 额度观测。

## 同名任务进程造成的再次中断

22:17 排查时，同一已安装 `language_server` 路径下存在两个进程。桌面进程 PID 58401 带 `--standalone`，由 Antigravity 主程序启动。任务进程 PID 38695 带 `--parent`，由本机任务程序启动。

1059 在解析模式之前要求同名进程总数等于一，因此把任务进程算入多个客户端的判断。22:18:57 独立检查桌面 Hub 返回 HTTP 200 和四个有效窗口。当前失效点在进程选择阶段。

1060 将已安装路径与 `--standalone` 模式一起用于桌面候选筛选。后台任务进程不参与候选计数。两个真实桌面 Hub 同时运行时仍保留歧义处理。Swift 与 macOS Rust 读取器同步修复，Windows 读取器已有先筛选服务模式的行为。

## 验证与安装记录

生产源码为 `da0fc57621112c475a6ecc2bf4fa316e19b6b9b0`。新增用例覆盖桌面与后台任务共存、用户目录含空格、相似可执行路径、相似参数和两个真实桌面 Hub。

1060 云端检查 `45633445890` 已全部通过。Swift XCTest 执行 2,569 项，38 项既有跳过，零失败，另有 681 项 Swift Testing 通过。Windows Rust 执行 1,803 项，14 项既有忽略，零失败。macOS Rust、前端和更新器检查通过。新增的后台任务共存用例在 Swift 和 Rust 中均通过。

候选构建为 `45633446361`。Mac 包已完成，归档摘要、源码凭证、应用签名与 DMG 校验通过。Windows 双架构候选于 23:09:35 完成，通过该作业的构建与清单检查。

本机已安装 0.9.11 build 1060，执行文件 SHA-256 为 `0cbfb626780a2133a3bc4a71ff0f0c5b508a272fae9545017b78d50bf6e13b5d`。1059 保留回滚。主程序 PID 25034，首轮精确刷新用时 21.912 秒，启动、刷新和安装回执均已确认。

23:00:42 应用自动写入四条额度，23:01:40 的下一轮将 Gemini 5h 从 91.335773% 更新为 87.82268%，Gemini 7d 从 34.835666% 更新为 34.22661%。第三方模型分别为 100% 和 58.345693%。23:03 的真实界面仍显示四条额度及新的读取时间，23:05:40 四个窗口再次完整写入，验证了后续自动刷新。相同余额在同一个五分钟记录区间中仍由原历史逻辑去重。

验收期间桌面 Hub PID 58401 与后台 worker PID 11437 同时运行。任务 worker 由原 PID 38695 更替后，额度读取继续成功。核对原有 8,273 条额度观测的内容摘要和数据库 inode 均一致。

本机证据目录为 `~/Library/Application Support/CodexTokenBar-Maintenance/2026-11-25-antigravity-1060/`。`quota-before.json`、`quota-after.json` 保存旧观测摘要与四条新读数，`continuous-refresh-observations.json` 保存刷新样本，`verified-process-evidence.json` 保存脱敏进程模式，`runtime-1060.json` 保存启动与刷新验收。安装与回滚信息保存在 `installation.json`。
