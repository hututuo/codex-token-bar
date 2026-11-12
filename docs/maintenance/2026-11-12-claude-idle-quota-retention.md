# Claude Desktop 闲置期间保留额度采样

## 本机证据与用户要求

用户确认在 Claude 客户端打开“用量”后额度恢复。本机已验证的缓存 HTTP Date 前一条为 2026-11-12 00:51:04 +08:00，新一条为 12:58:55 +08:00；当前安装 build 1013 的 20 分钟新鲜度规则会将旧缓存标为过期并清空数字。只读缓存无法判断停用期间的真实额度是否变化；官方 reset 时间只能说明旧周期到了边界，不能据此推算新额度。打开用量这次确实伴随新采样，但不保证客户端始终自动采样或每次点击都立即写新响应。

用户要求移除这项过期清空机制。修改仅作用 Claude Desktop 的 Chromium HTTP /usage 缓存和 plan-history 采样；CLI statusline 的独立 10 分钟策略、API 默认隐藏及 Antigravity 的状态策略保持原有范围。

## 行为

- 不因闲置 20 分钟或跨越 reset 时间清掉最后读到的比例，保留原采样时间和服务端重置时间，不改成读取时间。
- 数值表示上次采样；主页面、详情及辅助面板标“缓存”。已到官方 reset 时间标“重置待更新”，不猜 0%、100% 或新周期余额；无 reset 的历史文件不编造 reset。
- 最近 72 小时作为自动显示门槛，仍容忍未来最多 60 秒；较老记录默认不选中，显式选择可看已标注的历史读数，显式隐藏优先。
- 只读取已有本地缓存，不打开 Claude、不自动点用量、不发送网络或模型请求。新采样、空响应、无效响应继续作为完整观测处理，不补入其他账号或较旧来源的窗口。
- HTTP Date、缓存边界、CRC、键绑定、zstd 内存/输出上限、数值范围、未来时间与源码文件读写边界不放宽。

新增共享 HTTP 夹具覆盖隔夜、三天外和 reset 已过的原始数值；Swift/Rust required 用例检查解析后不改比例和采样时间，前端渲染回归覆盖主页面、详情、配对圆环、辅助面板、缓存提示和三天自动选择。仅本机做语法/格式检查，完整测试交云端。

## Antigravity 同时复查

2026-11-12 对本机正在运行、进程和 loopback 端口身份通过现有源码发现约束的 Antigravity 服务只发一次 `GetUserStatus`，不带 forceRefresh。HTTP 200，16 个模型配置均有合法额度和未过期 reset；无须 Summary。请求前后进程和端口身份一致。没有启动客户端、请求 provider/OAuth/模型端点或保存账号身份和完整响应。

本机仍是 build 1013，二进制 SHA256 `1de453a06cd66f4e7766bc07c10780a638cc9d8e53d376afa4ccf4618f79357e`，没有安装后续 RPC 接入及本次保留逻辑，因此旧安装版的“没有显示”不等于新读取器读取失败。脱敏实机证据见私有维护目录 `antigravity-open-source/live-2026-11-12.json`，过夜诊断见同级上一层 `claude-overnight-cache-2026-11-12.json`。

## 验证结果

最终受检源码 `023e28ced2512874721477b31543d27e0dcd3aa7` 的 [完整 CI 43161740546](https://github.com/hututuo/codex-token-bar/actions/runs/43161740546) 全部通过，最终 evidence seal 与 checked-source 均对应同一源码。同源 [Public097 43161740482](https://github.com/hututuo/codex-token-bar/actions/runs/43161740482) Windows/macOS 双端通过。

Swift XCTest 2,471（38 个既有跳过）、Swift Testing 676、Rust macOS 1,846 / Windows 1,789（各 14 个既有 ignored）、前端 1,481、云端脚本 18、发布脚本 112（1 个既有平台跳过）通过。新增 Swift/Rust required 用例均实际执行并通过；前端新增用例实际验证隔夜数值、重置待更新、三天外默认隐藏、显式显示、主页面、配对圆环和详情输出，未改变原始采样。

初始 `601e5657` 的前端出现 1,480 通过、1 失败：新提示漏掉了 HTTP 缓存来源标记。补回三端来源标签，保留既有断言，没有跳过或放宽检查。该前端失败原始 job 日志与 artifact/digest 保留，随后旧 run 取消并以修正版重新验证。

已核对原生/Swift 报告源码、tracked 源码前后未变、无额外 untracked 输入与日志 SHA256；六路下载 artifact digest 均核对。前端报告自身没有 sourceSha 字段，源码关联由同源 run、带 SHA/run ID 的 artifact 名、checked-source seal 及实际 checkout 的完整 job 日志共同验证；该日志包含新增用例成功输出，并单独保存 SHA256。

私有证据位于既有维护目录的 `antigravity-open-source/claude-retention-ci-023e28ce/`、`claude-retention-validation-final.json`、`claude-retention-public097-023e28ce.json`，首次前端失败在 `claude-retention-ci-601e5657/`。原始脏文件保持原内容。

本次未制作或替换新安装版，当前 1013 的二进制与众测推荐隐藏设置再次核对；不以本机接口诊断或云端测试代替新二进制界面验收。
