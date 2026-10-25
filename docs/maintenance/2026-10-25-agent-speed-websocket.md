# Agent Speed 可选 WebSocket 与昵称流程

本线程独立测速线路，未合入 `codex/multi-client-tokens`。HTTP 继续保留，新安装、旧配置和未知传输值都默认 HTTP。只有用户选择 WebSocket 才启用该通道；断线不会回退 HTTP。上报仍默认关闭，旧用户的开关与身份不变。

## 产品与边界

- Mac 原生和 Windows 设置提供 HTTP / WebSocket 即时选择。开启邀请第一步确认数据范围，第二步填写 2–32 字符公开昵称；最后确认才开启。第一步开关不产生网络或密钥操作。
- 设备注册、更名等仍走官方 HTTPS API；上报才按用户选择走 HTTP 或 WebSocket。固定正式服务发现/API，WS URL 从已校验 API 同源同路径派生，不接受重定向或任意另一主机。
- 保留逐设备 P-256/ES256 签名和 `client.app: CodexTokenBar`。握手签 GET 空 body，报告签原 POST 路径；每份内层 JSON bytes 冻结后，用同一份 bytes 签名/hash/封装成 `body` 字符串。
- ACK 必须匹配当前连接世代、run、seq、body SHA256 和 accepted/duplicate 状态；ready、Pong 和 socket write 都不代表上报成功。待确认数量有界，ACK 超时断开；背压/断线丢弃窗口，不补发或积压。Retry-After 优先于随机退避，普通重连保留 run 和递增 seq，手动切换新 run。
- 按 discovery 严格整数能力协商，ready 配置必须一致；不一致只强制刷新一次。TLS/系统代理沿用系统栈，无 cookies、账号凭据、系统认证挑战、远端脚本或共享 API Key。
- 四个 realtime 字段只用于 WS。真实读取边界记录配对 wall/monotonic 时间，窗口保留最早一笔，重复和纯计时快照不刷新 observedAt。读取日志标为 log、轮询为 poll，混合为 mixed；未知采样间隔为 null。超过一秒的旧来源窗口丢弃，发前再次检查新鲜度。
- WS 才把事件 debounce / 变更发布改为 50ms，发送仍遵守协商最小间隔；500ms 速率衰减计时、1 秒兜底轮询、10 秒目录发现继续保留。HTTP 原事件节奏不变，不增加空闲 20Hz 采集。
- Agent Speed 的 3 秒 TPS、结算 Token、费用/未知费用和分享范围不改；不复用正文 TPS，不改 Token Bar 历史索引或费用账本，也不把日志来源说成逐 token 流式测速。

## 已验证

- 正式公网 Mac：新测试身份使用系统设备密钥，注册、签名握手、ready、三次有效 ACK 通过；原 run 断线恢复，经过实际 Ping/Pong 间隔仍可确认报告。三次构造至 ACK：439 / 416 / 419 ms。另一次独立探针为 414 ms。
- 完整 Mac 控制器：选择 WS 后注册与报告确认通过，HTTP `/reports` 请求数为 0，ready 时没有错误地更新成功时间。正式环境探针全为零用量，不虚增 TPS/Token。测试身份与生产身份分开，生产偏好没有被探针修改。
- Mac 当前显式 HTTP/HTTPS/SOCKS 系统代理关闭，接收端 DNS 为 Fake-IP，路由走 utun；测试未改网络设置。这证明当前 TUN 路径可用，不等于全部代理配置验收。
- Swift 上游核心 650 测试通过；相关回归另有 XCTest 28 通过、3 项公网门控跳过，以及 Swift Testing 18 通过（与核心测试范围有重叠，不相加）。邀请页 3 项测试与 TypeScript/Vite 构建通过。默认测试不访问公网，真实联调只在显式环境开关下执行。
- Windows 后端在 macOS 的 .NET 10.0.303 编译 0 warnings / 0 errors，reporter self-tests 通过；Rust 旧/缺失/未知配置默认 HTTP 的回归通过。50ms 仅 WS、严格能力、签名 bytes、ACK 世代、背压/睡眠窗口丢弃、读取时间单次消费、Retry-After、新鲜度均有回归。

## 尚未完成的实机验收

- Windows 最初 SSH 超时/拒绝连接；用户恢复机器后，本机打开悠悠映射，2222/2223/8000 转为成功，httwin-uu 登录 httwin\htt 已验证。正在独立目录进行真实 Windows 后端/DPAPI/传输验收；Mac 编译 C# 仍不代表 Windows 运行验收。
- 没有让用户整台 Mac 真正睡眠、断网或切换网络；已验证的是客户端连接中断/恢复与当前 TUN 路由。物理睡眠/切网仍待实测。
- 上述只有数次构造至 ACK 的保守往返指标，没有完成 10 分钟、至少 10,000 事件、时钟校准与浏览器绘制跟踪；100ms/250ms p95 仍未达成验收，不能拿三次 ACK 宣称达标。
- 未发布。Mac 正式应用已本地替换为 0.9.7/build958，旧 build957 已备份；实际 UI 中 HTTP 与 WS 均已确认真实统计上报，测试后恢复 HTTP。Windows 正式应用不覆盖。

## 证据与复测

证据在 `docs/maintenance/assets/20261025-ws-integration/`，私有构建/日志在项目根 `runs/20261025-ws-acceptance/`。未保存真实私钥、实际请求的签名头或对话内容到仓库。正式发现与协议引用/哈希见 `protocol-reference.json`。

显式 Mac 公网协议探针：`CODEX_SPEED_WS_SERVICE=https://deng.codexradar.com CODEX_SPEED_WS_LIVE_OUTPUT=<本地JSON> swift test -j 4 --filter AgentSpeedWebSocketTests.testExplicitTestServiceRegistrationAndWebSocketACK`。新测试身份与零用量，测试结束尝试删除其设备注册；不操作用户设备。

完整控制器探针：`CODEX_SPEED_WS_CONTROLLER_OUTPUT=<本地JSON> swift test -j 4 --filter AgentSpeedWebSocketTests.testExplicitProductionControllerUsesOnlySelectedSocketForReports`。使用独立测试套件与密钥，不改生产偏好。

## build958 本机实测

实际 Mac 安装包：`/Applications/Codex Token Bar.app`。已验证稳定签名 requirement、原更新公钥/feed 和媒体资源哈希；安装器仅更换应用包，不操作历史数据库。旧包/偏好及回滚脚本：项目根 `backups/20261025-agent-speed-ws-build958`。

保留原开启状态及昵称 TokenBar-c7560e68，启动后 HTTP 真实统计确认；从设置手动切到 WS 后看到“WebSocket 统计已确认”，随后恢复 HTTP 再次确认成功。当前持久配置 `http`、enabled=true。正式榜单已看到本机条目（留存截图为16.0M累计token、29.1 tok/s；动态值会变化），费用未分享显示破折号，不显示零费用。

官网当时界面另标数据延迟约10–12秒；这与构造至ACK的416–439ms是两个量，仍不能宣称网页250ms目标已通过。截图与 probe JSON 在相邻 assets 文件夹。
