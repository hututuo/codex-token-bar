# Windows Antigravity 本机额度读取

## 范围

这是对此前仅 macOS 接入实时读取的补齐。Windows 原有 Codex app-server、Claude/Antigravity 离线缓存、三天自动显示、小数与主页面刷新间隔逻辑保留。新增 Windows Antigravity 已运行客户端的 loopback RPC；尚未打包或替换已安装的 build 1013。

支持标准 LocalAppData/Programs、Program Files 安装位置的独立 Hub `resources/bin/language_server.exe --standalone`（也接受 `--subclient_type hub`）、旧 IDE 的 x64/ARM 语言服务，以及当前用户 `.gemini/bin/agy.exe --hub`。不启动 Antigravity、不读取 OAuth/Cookie、不直接请求 Google 或模型接口。没有 `forceRefresh`；本机语言服务自身仍可能联网，因此不称为纯离线。

## 识别与请求

ToolHelp 先筛选进程名，内核查询可执行文件路径及进程创建标识。仅对匹配已知安装路径的候选，用系统 Windows PowerShell 运行固定只读 CIM 脚本；同用户 SID 和路径检查通过之后才取命令行，使用 Windows 原生 `CommandLineToArgvW` 解析引号、空格及等号参数。不调用 WMIC、远程 CIM、第三方脚本或用户 PowerShell profile。

`Get-NetTCPConnection` 提供该 PID 实际持有的监听端口。只向固定 HTTPS loopback 字面量优先发送 `RetrieveUserQuotaSummary`，缺少可解析额度时再尝试 `GetUserStatus`，避免旧模型比例遮蔽新版周期额度。两者均只带客户端 metadata，不带强制刷新。不猜测默认端口，不请求外部监听地址；关闭代理和重定向。新 Hub 的 HTTP `--hub-port` 不优先探测。请求成功后重新核对进程创建标识、路径、CSRF 和端口所有者，进程重启则丢弃响应。

多个 Hub 或多个独立 IDE 候选不随意挑账号。单一新 Hub 优先于旧 IDE。正在运行但无法验证的客户端返回不可用，不改取其他账号旧缓存；没有运行候选时保留既有缓存路径。多用户会话、权限拒绝、受策略禁用的 PowerShell/CIM/TCP 元数据、自定义或便携安装位置可能不可用，不申请管理员权限或修改机器策略。

元数据输出至多 1 MiB，辅助进程最多 12 秒；RPC 总预算 8 秒、单请求至多 2 秒、正文至多 512 KiB。辅助进程超时只终止本次创建的元数据进程。返回值只投影额度标签、比例和重置时间，不保存完整响应或命令行。显式比例限定 0…1，缺失/布尔/越界值不当作零；缺少或过期重置时间保留过期状态。

## 依据与验收边界

- [AntigravityQuota 已合并 Windows 识别实现](https://github.com/Henrik-3/AntigravityQuota/blob/b63a3971273d85da7e75266a5c3827acf85def32/src/core/process_finder.ts)：Hub、IDE、agy 进程与 PID 所有端口。
- [其平台策略](https://github.com/Henrik-3/AntigravityQuota/blob/b63a3971273d85da7e75266a5c3827acf85def32/src/core/platform_strategies.ts)及[额度读取器](https://github.com/Henrik-3/AntigravityQuota/blob/b63a3971273d85da7e75266a5c3827acf85def32/src/core/quota_manager.ts)：本机 Windows 元数据与两种响应结构。
- [CodexBar 额度池解析](https://github.com/steipete/CodexBar/blob/7447bc77c2497323d9c41e40164ce705533493c8/Sources/CodexBarCore/Providers/Antigravity/AntigravityQuotaSummaryParser.swift)：嵌套比例与 protobuf oneof。没有复制强制刷新。
- [Windows Hub 参数观测](https://github.com/google-antigravity/antigravity-cli/issues/1255)补充 `--subclient_type hub` 变体；它仍须通过同用户、安装路径、CSRF 与端口归属约束。
- [Microsoft Get-NetTCPConnection](https://learn.microsoft.com/en-us/powershell/module/nettcpip/get-nettcpconnection)、[GetOwnerSid](https://learn.microsoft.com/en-us/windows/win32/cimwin32prov/getownersid-method-in-class-win32-process)、[CommandLineToArgvW](https://learn.microsoft.com/en-us/windows/win32/api/shellapi/nf-shellapi-commandlinetoargvw)。

三个新增 Rust 用例列入 required-execution 门禁：合成路径/身份/端口约束，Hub/旧 IDE/agy 与多账号歧义，响应解析及查询后重新验证。Windows 测试块另以测试进程自身实际创建 loopback 监听，执行真实系统 CIM、SID、TCP 归属与原生命令行解析；没有安装 Antigravity、调用提供商或发模型请求。

## Windows PowerShell 5.1 实测修正

首次完整受检源码 `6b1ea8ca9bec30da876a59509d863a77e736aa51` 的 Windows 原生用例真实失败：1,787 通过、1 失败、14 个既有 ignored。失败发生在当前测试进程的系统元数据返回空候选；没有跳过该用例。根因是 Windows PowerShell 5.1 将 `ConvertFrom-Json` 顶层数组作为一个 pipeline 对象输出，外层 `@(...)` 再包装后，路径允许列表成为嵌套数组，合法进程也被过滤。参见 [PowerShell 官方 issue 3424](https://github.com/PowerShell/PowerShell/issues/3424)。修正为直接赋值 JSON 转换结果，保留原路径和同用户限制。

新增编译前的 Windows PowerShell 5.1 系统门禁：实际创建本进程的 loopback 监听，验证单路径和多路径允许列表、错误路径拒绝、SID 与 TCP PID 归属；同时以无害路径夹具证明旧写法确实拒绝、修正写法接受。同一生产脚本通过该门禁，未发送 Antigravity/提供商请求。Rust 内原有真实系统用例及全部断言继续保留。

最终受检源码 `a69e01371c4778eca0e852e5ce28b5b3eacf44b4` 的 [完整 CI 43140820949](https://github.com/hututuo/codex-token-bar/actions/runs/43140820949) 全部通过，最终 evidence seal 通过。Rust Windows 1,788 / macOS 1,845 通过（各 14 个既有 ignored），三个新增 required 用例在两端均实际执行通过，Windows 内的真实系统元数据和原生命令行解析断言也保留并通过。编译前 PS5 系统测试及其旧写法失败对照同样通过。前端 1,480、云端脚本 18、Swift XCTest 2,470（38 个既有跳过）、Swift Testing 676、发布脚本 112（1 个既有平台跳过）通过。

同一源码的 [Public097 43140820935](https://github.com/hututuo/codex-token-bar/actions/runs/43140820935) Windows / macOS 双端通过。执行报告的源码、tracked 源码前后未变、无额外 untracked 输入、日志 SHA256、下载 artifact digest 与 required 用例通过记录均核对。Windows 整个 job 的系统门禁成功输出也单独留存。

私有证据目录为 `~/Library/Application Support/CodexTokenBar-Maintenance/2026-11-11-quota-investigation-7shd8xj3/antigravity-open-source/`：最终 `windows-ci-a69e0137/`、`windows-validation-final.json`、`windows-public097-final-run-a69e0137.json`；首次真实失败保留在 `windows-ci-6b1ea8ca/`，没有用新成功覆盖旧失败。

Windows 系统元数据实测与合成响应不等于真实 Windows Antigravity 客户端验收；本机只有 macOS 客户端诊断证据。当前安装和用户的众测推荐隐藏设置均未替换。
