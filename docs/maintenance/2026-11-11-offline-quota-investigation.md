# Claude / Antigravity 额度调查续接

日期：2026-11-11（Asia/Shanghai）。从 `bffd13be`、已安装 build 1012 续接；用户反馈是额度仍为空或显示过期。

## 授权与刷新合同

用户明确纠正：自动刷新也必须离线，不主动发网络请求。自动刷新指定时重读已有本地数据，不调用可能联网的 localhost RPC，不获取认证凭据，不唤醒客户端。此次没有执行额度 API、localhost RPC、模型请求、GUI 操作或应用替换。

Swift 的 `MultiClientUsageStore.start / refreshLocalQuotaCaches` 已在启动和每 60 秒独立重读三个本地提供者，不依赖会话采集或速度监控开关；Rust 本地额度读取也保留 60 秒有界缓存。此次修复缓存解析，不引入另一套刷新循环。

## Claude：已复现的解析故障

旧历史文件仍停在 11 月 9 日，但本地 Chromium Simple Cache 中已有 11 月 11 日更新的官方 `/usage` 响应。只提取响应格式、额度与时间检查，没有保存原文、组织标识、Cookie 或认证字段。

两个真实缓存响应的 zstd 帧都没有预先声明正文长度，解压窗口为 **2 MiB**；现有 Swift / Rust 流式读取器却将窗口上限设为 **1 MiB**。按生产相同的 zstd 流式调用做只读诊断：原上限报 `Frame requires too much memory for decoding`，改为 2 MiB 后分别完整解码 2,491 / 3,242 字节，均含五小时和七日额度字段。这是底层库诊断，不冒充新 Swift / Rust 程序运行结果。

另有真实响应使用 `/usage?cedar_ember=1&skip_spend=1` 等查询参数；原 key 识别只接受不带参数的路径，会漏掉较新的完整或部分观察。

同步修复 Swift `ClaudeDesktopHTTPCache` 与 Rust `claude_desktop_http_cache`：

- 解压窗口上限改为 2 MiB；解码正文仍限 64 KiB、缓存条目仍限 2 MiB，目录上限和符号链接规则保持。
- 接受同一官方 HTTPS 主机、组织路径和 `/usage` 端点的查询参数；拒绝其他主机/路径、片段与空白控制字符，使用严格终止匹配。
- 继续校验两个 footer、CRC32 与 key SHA256；继续按响应日期整份选择最新观察，不从较旧响应补齐缺失的窗口，不以文件修改时间冒充采样时间。

共享夹具新增 10 个纯合成案例：未知正文长度的 2 MiB 流、查询参数、4 MiB 流拒绝、解压正文超限、错误主机/路径、片段、内部及末尾控制字符。两端新增目录级回归，证明较新的带参数部分响应能胜出、不会借旧响应补齐窗口、原文件字节不变。夹具不包含真实响应或用户身份字段。

本机诊断证据：`~/Library/Application Support/CodexTokenBar-Maintenance/2026-11-11-quota-investigation-7shd8xj3/claude-zstd-window-diagnostic.json`。

## Antigravity：离线数据边界

已安装 Antigravity 2.31.0。Tools 当前选中账号的本地 `quota.last_updated` 仍为 6 月 9 日，16 个模型均为旧采样，reset 也都在 6 月 9 日；只读重查 IDE 的旧 `userStatus`，7 个模型额度的 reset 均为 5 月 23 日，且没有可信采样时间。不能从数据库修改时间、安装状态或未来 reset 推断当前余额。

已安装额度扩展的源码表明它通过语言服务的 `GetUserStatus` RPC 获取新数据；该接口不能仅因目标是 127.0.0.1 就被视为离线读取。遵循本次用户纠正，没有调用它。没有将 Tools 所选账号与当前 IDE 账号假定为同一账号，也没有改为跨账号/跨来源回退来掩盖过期。

已安装 `ag-quota` 扩展的 `last_snapshot` 只存在内存，更新回调仅写日志和更新状态栏，没有 `globalState`、`workspaceState` 或文件读数持久化；其配置只保存用户设置。定向检查未发现扩展的额外额度缓存。`modelCredits` 状态项虽然存在，现有结构不能证明它是逐模型余额或提供可信采样时间，因此没有猜测字段单位或据此伪造新额度。

不把 Tools 过期后的跨来源 fallback 当作修复：IDE 缓存本身更旧，且两个来源没有当前账号一致性证据。保留当前选中账号边界。此次未取得可验证的新鲜采样，Antigravity 保持过期/不可用状态。

## 验证与交付状态

本机仅执行源码/JSON检查、Swift 语法解析、Rust 格式与语法检查、diff检查，以及上述只读底层库诊断；未进行本机编译或测试套件运行。新增回归和完整编译交由云端。应用仍为 build 1012，尚未包含此次修复；不以源码修改宣称实机已恢复。

保护原有 dirty / untracked 文件，未修改 A–D 存储、账本、用户设置或 provider 缓存。保护的三个文件 SHA256 与前序已核验值一致。

产品源码：`cba17c63fc376fd3e03221fe10256149327b5992`。推送后自动触发的 [Hosted project checks 43039490456](https://github.com/hututuo/codex-token-bar/actions/runs/43039490456) 和 [Public v0.9.7 upgrade 43039490648](https://github.com/hututuo/codex-token-bar/actions/runs/43039490648) 均全部通过；CI 最终 evidence job 也已通过。

- Swift XCTest 2,465 通过、38 个既有跳过；Swift Testing 676 通过。发布脚本 112 通过、1 个既有 Windows 专属跳过。
- Rust macOS 1,839、Windows 1,782 通过，两端各 14 个既有 ignored；两端生产存储检查、清理负控与物理身份负控通过。
- 前端 1,477、云端脚本 18 通过，无跳过。
- 新增目录级回归和包含全部新夹具的现有额度回归，在 Swift 与两个 Rust 平台的实际日志中均执行通过。三个原生执行报告的源码 SHA、受检 tracked 源码未变、无额外 untracked 输入、日志 SHA256 均已核对。
- Public v0.9.7 升级门禁的 macOS / Windows 两个 job 均通过。未改存储/迁移/账本合同，没有追加无关历史矩阵。

执行日志与报告保存在上述本机证据目录的 `ci/`。此次为额度调查与源码修复，未准备新安装包；结束时重新读取已安装版本仍为 build 1012，没有替换、重启或 GUI 验收，不将 build 1012 标为已修复。

## 后续用户批准替换

用户随后要求先替换，再将本地额度刷新接到主页面已有频率设置，后者留下一版。build 1013 已完成云端打包、双端包校验和本机替换；频率接线继续作为下一版源码。具体安装证据、边界与后续验证见 [替换与刷新设置记录](2026-11-11-local-quota-refresh-cadence.md)。
