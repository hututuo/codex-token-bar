# Antigravity 本机读取、额度自动显示与兼容性

## 用户边界与实机证据

用户先要求 Antigravity 不外发额度查询。调查开源实现后，用户明确表示可参考本机 RPC 方式继续。此前只做缓存、只读 DOM 定位与 45 秒被动响应观察：没有调用额度 RPC，被动观察没有收到额度响应，也不能据此证明内存中不存在额度。随后获得本机 RPC 授权，才对已运行的 standalone Hub 调用一次 `GetUserStatus`，没有 `forceRefresh`。返回 HTTP 200、16 个带额度模型；只保存模型额度、重置时间及读数时间，不保存姓名、邮箱、认证字段或完整响应。

已安装 Antigravity 为 macOS 2.31.0。它是独立 Hub，旧 IDE 数据库及 Tools 采样数月未更新，原磁盘读取无法获得新额度。新读数来自正在运行的客户端，不与 Tools 所选账号或旧 IDE 数据合并。

开源依据：

- [CodexBar 的 AntigravityStatusProbe](https://github.com/steipete/CodexBar/blob/7447bc77c2497323d9c41e40164ce705533493c8/Sources/CodexBarCore/Providers/Antigravity/AntigravityStatusProbe.swift#L1585) 主路由对 `RetrieveUserQuotaSummary` 传 `forceRefresh: true`，另有 `GetUserStatus` 回退。本实现只借鉴调用接口与数据结构，没有复制其强制刷新或 OAuth 路线。
- [Antigravity Monitor](https://github.com/nextcortex/antigravity-monitor/blob/main/src/quota-fetcher.ts#L51) 与 [Antigravity Pulse](https://github.com/codavidgarcia/antigravity-pulse/blob/main/src/quota-fetcher.ts#L146) 通过 localhost `GetUserStatus` POST 解析逐模型额度。

localhost 只约束 Token Bar 的请求目标，不证明语言服务内部不会联网。产品说明明确客户端可能自行联网；不宣称这条 RPC 路径纯离线。本实现没有直接 provider URL、OAuth、模型请求、客户端启动或强制刷新。原 Claude 离线约束保持。

## 下一版实现

Swift 与 Tauri macOS 读取器只识别当前用户、标准系统/用户 Applications 目录中正在运行的 standalone Hub。核对内核可执行文件路径、进程参数及该 PID 的 loopback 监听端口；动态 HTTPS 端口从已有启动日志的有界前缀提取，再核对进程实际持有该端口。仅使用该运行进程的 CSRF，不读取 OAuth、Cookie 或 Keychain。查询前后重新识别 endpoint，重启或端口重用时丢弃结果。多个候选或当前进程读取失败均 fail closed，不退到其他来源账号的旧采样。

请求地址固定为 `https://127.0.0.1:<owned-port>/exa.language_server_pb.LanguageServerService/GetUserStatus`，禁用代理、Cookie、缓存与重定向。只对该经验证的 loopback endpoint 接受本机自签证书。系统元数据命令、日志、请求时长、正文和模型数量均有边界；不执行 shell 或第三方查询程序。生产实现不使用 CDP。

响应只投影模型 ID/标签、显式数值 `remainingFraction` 和重置时间；缺失不能当 0，布尔/越界/非有限值拒绝，重复 ID 只取首项，至多 128 个模型，正文至多 512 KiB。不合计共享模型池。缺失或已过重置时间标为过期。`capturedAt` 是本机读取时间，界面标“读取于”，不假定为服务端采样时间。

本机读通的是接口诊断，不是新 Swift/Rust 二进制的实机验收。当前安装仍为 build 1013（Claude 解析修复），没有安装本次源码。

## 自动显示与小数

用户要求首次读到就自动显示；Claude API 默认不显示，最近三天缓存才自动显示。显示策略与采样是否实时分别处理：

- Codex 已有窗口一旦读取即自动展示；没有窗口的占位不自动选中。
- Claude/Antigravity 的有效、过期或已缓存读数必须有可信采样/读取时间，处于最近 72 小时内（最多容忍未来 60 秒）才自动选中；API、错误、未接入和时间未知不自动选中。过期余额仍保留原有过期表达，不因三天显示门槛冒充实时余额。
- 设置目录仍保留不可自动展示的项目，可显式勾选；显式隐藏优先，刷新不能把隐藏项勾回。无需开启会话用量采集。
- 额度统一最多两位小数，去掉无意义尾零；主页面数值/进度、侧栏圆环、详情、菜单栏与无障碍文字共用该规则。保持原始数值，格式化不改余额、模型池或账本。

用户撤回删除众测雷达，最终仅取消当前二级菜单 radar/众测推荐勾选。该 layout key 已备份并只向 `hiddenExpanded` 加入 `radar`，其他字段保留；没有移除功能、解析器或后台读取。当前版 controller 在启动时加载 layout，因此随后正常退出并重新启动同一个 build 1013；没有强制终止、替换程序或改动安装版本。重启后重新核对保存的 layout、版本及启动/index ready。journal 同样存在一条通用 `frontend.failed` 事件，未携带来源/详情，不将其描述为已查清或宣称全界面零异常。没有做 GUI 点击验收，也不将默认设置强行覆盖其他用户的显式选择。

## 兼容性边界

| 来源 | 是否需软件运行 | 当前覆盖与限制 |
| --- | --- | --- |
| Codex | 不必打开主窗口 | Token Bar 使用安装的可执行文件启动自有 app-server 并调用 `account/rateLimits/read`；需要兼容二进制和有效订阅登录，可由 app-server 联网。API 模式没有订阅余额。 |
| Antigravity macOS standalone Hub | 需要语言服务进程运行，窗口不必在前台 | 本机 2.31.0 接口诊断成功；标准系统/用户 Applications 路径；多进程、自定义安装路径、日志轮换缺少 HTTPS 启动记录等情形可能不可用，不能假定兼容。 |
| Antigravity Windows Hub / 旧 IDE / agy | 新增实时读取源码，需要语言服务运行 | 后续 Windows 补齐与单独门禁记录见 [Windows 读取说明](2026-11-12-windows-antigravity-quota.md)；没有运行候选时保留缓存读取。仍未做真实 Windows Antigravity 客户端验收。 |
| Claude CLI | 读取缓存时不需要运行 | 需要此前配置本地额度采集或存在兼容 statusline 缓存；API/Bedrock/Vertex/Foundry 等模式默认不展示订阅额度。自定义配置目录及环境来源可能影响模式识别。 |
| Claude Desktop | 读取缓存时不需要运行 | 识别支持的 plan-history 与 Chromium Simple Cache 格式；支持本轮确认的 zstd 2 MiB 流和查询参数。应用版本、缓存格式/位置改变、缓存清理、Windows 封装路径等可能造成未读到，不能用安装检测代替有效采样。 |

三天年龄依据缓存内容的采样时间/HTTP Date 或本机 RPC 收到时间，不使用数据库/文件 mtime。未知账号、未知采样、过期重置与读取失败均不推断为 100% 或 0%。

## 验证

新增纯合成共享 RPC 夹具及两端解析、进程/端口/CSRF 约束回归；自动显示测试覆盖三天边界、未来时间、API、首次出现及手动隐藏/勾选；小数回归覆盖主页面/圆环/详情/无障碍。只在本机做轻量语法和 diff 检查；完整编译和套件交云端。

此前 macOS 读取与自动显示阶段的受检源码 `652fd7145efb0830d29dbd327e7e85f722a40229` 的 [完整 CI 43074744378](https://github.com/hututuo/codex-token-bar/actions/runs/43074744378) 全部通过，最终 evidence seal 通过。前端 1,480、云端脚本 18，Swift XCTest 2,470（38 个既有跳过）、Swift Testing 676，发布脚本 112（1 个既有平台跳过），Rust macOS 1,842 / Windows 1,785（各 14 个既有 ignored）通过。新增四个 Swift、两个 Rust 约束用例列入 required execution 门禁；下载的执行报告源码、前后 tracked 源码未变、无额外 untracked 输入、日志 SHA256 与 artifact digest 均已核对。最终源码的主页面实际渲染也验证 `9.11%` 和 `90.89%`，没有绕回旧整数格式。

首次前端回归发现“Codex 已返回但不可读的储备窗口”被新自动规则隐藏。已修正为“窗口对象存在即保留不可用状态”，未返回的占位仍默认不选中；不能把未知当作零。上述最终源码已通过该既有回归。

另一次最终收口中，Windows 在 `620535a7` 上出现一项既有缓存提醒标题测试失败（1,784 通过、1 失败）。该测试给新观察使用早于逻辑轮询的固定时间，慢 I/O 可能触发独立的五秒恢复保护；已只把两条合成观察对齐各自轮询时间，保留全部断言及产品保护逻辑。最终 Windows 全量实际执行并通过该用例，没有跳过失败项或放宽产品规则；旧失败日志保留在私有证据中。

同一最终源码的 [Public097 升级门禁 43074744203](https://github.com/hututuo/codex-token-bar/actions/runs/43074744203) macOS / Windows 双端通过。没有存储/账本改动，没有新增无关历史矩阵。

私有证据目录：`~/Library/Application Support/CodexTokenBar-Maintenance/2026-11-11-quota-investigation-7shd8xj3/antigravity-open-source/`，最终 CI 入口 `ci-652fd714/`，以及同级 `sidebar-recommendation-visibility.json`、`sidebar-visibility-restart.json`。不提交真实额度响应和用户身份数据。当前安装仍是 build 1013；本轮后续功能未打包、未安装，不以云端编译测试代替新二进制在用户客户端上的验收。
