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
- Agent Speed 的 3 秒 TPS、结算 Token、费用/未知费用计算口径不改；不复用正文 TPS，不改 Token Bar 历史索引或费用账本，也不把日志来源说成逐 token 流式测速。

## 已验证

- 正式公网 Mac：新测试身份使用系统设备密钥，注册、签名握手、ready、三次有效 ACK 通过；原 run 断线恢复，经过实际 Ping/Pong 间隔仍可确认报告。三次构造至 ACK：439 / 416 / 419 ms。另一次独立探针为 414 ms。
- 完整 Mac 控制器：选择 WS 后注册与报告确认通过，HTTP `/reports` 请求数为 0，ready 时没有错误地更新成功时间。正式环境探针全为零用量，不虚增 TPS/Token。测试身份与生产身份分开，生产偏好没有被探针修改。
- Mac 当前显式 HTTP/HTTPS/SOCKS 系统代理关闭，接收端 DNS 为 Fake-IP，路由走 utun；测试未改网络设置。这证明当前 TUN 路径可用，不等于全部代理配置验收。
- Swift 上游核心 650 测试通过；相关回归另有 XCTest 28 通过、3 项公网门控跳过，以及 Swift Testing 18 通过（与核心测试范围有重叠，不相加）。邀请页 3 项测试与 TypeScript/Vite 构建通过。默认测试不访问公网，真实联调只在显式环境开关下执行。
- Windows 后端在 macOS 的 .NET 10.0.303 编译 0 warnings / 0 errors，reporter self-tests 通过；Rust 旧/缺失/未知配置默认 HTTP 的回归通过。50ms 仅 WS、严格能力、签名 bytes、ACK 世代、背压/睡眠窗口丢弃、读取时间单次消费、Retry-After、新鲜度均有回归。

## 实机验收与剩余边界

- Windows 连接恢复后已完成真实 Windows 11 验收：隔离 SDK 10.0.303、生产 helper 编译及自测通过；DPAPI 两次加载同一测试身份/公钥；正式注册 201、HTTP 200 accepted，WS seq1、22 秒后原连接 seq2、同 run 重连 seq3 均获得严格匹配 ACK。已确认撤销测试设备并清除其独立密钥，不覆盖正式 Windows 应用。
- 没有让用户整台 Mac 真正睡眠、断网或切换网络；已验证的是客户端连接中断/恢复与当前 TUN 路由。物理睡眠/切网仍待实测。
- 上述只有数次构造至 ACK 的保守往返指标，没有完成 10 分钟、至少 10,000 事件、时钟校准与浏览器绘制跟踪；100ms/250ms p95 仍未达成验收，不能拿三次 ACK 宣称达标。
- 未发布。Mac 本地已从 build958 升为带费用修复的 0.9.7/build959，上一版已备份；当前仍为 HTTP。Windows 正式应用未覆盖，只有隔离后端和协议实测。

## 证据与复测

证据在 `docs/maintenance/assets/20261025-ws-integration/`，私有构建/日志在项目根 `runs/20261025-ws-acceptance/`。未保存真实私钥、实际请求的签名头或对话内容到仓库。正式发现与协议引用/哈希见 `protocol-reference.json`。

显式 Mac 公网协议探针：`CODEX_SPEED_WS_SERVICE=https://deng.codexradar.com CODEX_SPEED_WS_LIVE_OUTPUT=<本地JSON> swift test -j 4 --filter AgentSpeedWebSocketTests.testExplicitTestServiceRegistrationAndWebSocketACK`。新测试身份与零用量，测试结束尝试删除其设备注册；不操作用户设备。

完整控制器探针：`CODEX_SPEED_WS_CONTROLLER_OUTPUT=<本地JSON> swift test -j 4 --filter AgentSpeedWebSocketTests.testExplicitProductionControllerUsesOnlySelectedSocketForReports`。使用独立测试套件与密钥，不改生产偏好。

## build958 首次本机实测（费用修复前）

实际 Mac 安装包：`/Applications/Codex Token Bar.app`。已验证稳定签名 requirement、原更新公钥/feed 和媒体资源哈希；安装器仅更换应用包，不操作历史数据库。旧包/偏好及回滚脚本：项目根 `backups/20261025-agent-speed-ws-build958`。

保留原开启状态及昵称 TokenBar-c7560e68，启动后 HTTP 真实统计确认；从设置手动切到 WS 后看到“WebSocket 统计已确认”，随后恢复 HTTP 再次确认成功。当前持久配置 `http`、enabled=true。正式榜单已看到本机条目（留存截图为16.0M累计token、29.1 tok/s；动态值会变化），费用未分享显示破折号，不显示零费用。

官网当时界面另标数据延迟约10–12秒；这与构造至ACK的416–439ms是两个量，仍不能宣称网页250ms目标已通过。截图与 probe JSON 在相邻 assets 文件夹。

## 费用字段修复（服务端反馈后补齐）

此前 HTTP / WS 的 section 白名单只允许 sources、models，Windows 还未将 PriceBook 注入 LiveMonitor，导致 cost 整段缺失。本次将协商后的 cost 接回双端两条传输路径，并使用实际内置价表版本（当前 2），不再沿用默认版本 1。Windows 同时启用 Agent Speed 原有的逐响应定价器。

上报原协议的 liveMicroUsdPerSecond、peakMicroUsdPerSecond、knownShare、deltaMicroUsd、unpricedRequests、priceVersion；源和模型的费用分项也由原 builder 生成。金额是 API 等价估算，单位为 micro-USD。没有价格的请求继续用 unpricedRequests / knownShare 表达；deltaMicroUsd 是已知部分的和，不能将“已知金额为 0”解释成全部请求免费。不另猜价格、不回填旧上报窗口、不动本地费用账本。

开启页和设置中的数据范围说明同步加入“估算费用”。费用仅随排行榜总开关开启，并受 discovery.sections 协商限制；网络流量、路径和账号凭据仍不允许上报。

新增回归覆盖：历史种子费用不进入新窗口、已知费用和未定价请求并存、全部未定价时保留未知标志、HTTP 与 WS 都含正确 cost 结构与价表版本，以及费用块不能夹带任意非数值内容。

### 费用修复验收

- Mac build959 本机替换完成，稳定签名/更新 feed 与公钥/视频哈希不变。当前 HTTP、原昵称和参加状态保留；正式榜单本机条目已出现正数 API 等价费用。仅上传新窗口，之前未分享的费用不伪造回填，因此榜单仍可能显示“部分费用未分享或未定价”。截图：assets/20261025-ws-integration/leaderboard-mac-cost-build959.png。
- Mac 完整控制器在补齐费用后也再次通过正式 WS ACK 验证，HTTP report POST 数为 0，使用独立新测试身份和零用量，未改变生产偏好。证据：assets/20261025-ws-integration/mac-controller-production-cost.json。
- Windows 补齐费用后重新真实编译、自测、离线 fixture 和正式 HTTP/WS 全流程通过。cost 六字段齐全、priceVersion=2。最终脱敏 JSON 的 19 个检查均为 true：assets/20261025-ws-integration/windows-production-cost.json。空用量的 knownShare=1 是协议语义（当前无输出），不是未知费用被冒充为免费。
- Windows 当前代理 bypass 诊断为 false，正式 API 的两条通道都可达；没有改变代理、网络或整机睡眠状态。这不等于全部代理组合/物理睡眠/切网验收。
- 新费用回归：Mac 6 项本地通过（1 项公网门控跳过）；Windows helper 自测包含已知/部分未知/全部未知费用、HTTP/WS 白名单、价格版本检查；开启页 3 项、TypeScript/Vite 构建通过。完整原核心 650 项未因这个接线改动重复运行，先前结果保留。
