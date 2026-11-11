# Claude 合并分组、四列零用量卡与额度可见性

2026-11-10 开始，基线 `56d67d1d`（已安装应用仍为 build 1010）。界面/额度候选 `74a968c359bc533547d3df7f8eeab59540dd6cdd` / build 1011 已完成云端门禁；11 月 11 日用户批准追加 Claude 重复统计修复，新候选使用 build 1012。停止在安装和 GUI 验收之前。

## 模型费用：定位、扫描、收束

原来的费用投影按 `claudeDesktop` / `claudeCode` 分成两行，并过滤零用量，导致主力行不齐；一个额外型号也会生成第二个“其他”分组。两端消费者已扫描到主页、单日费用、周期费用和侧栏今日费用。

共享 `model-cost-order.json` schema 3 将 Claude Desktop / CLI 放入同一 Claude 展示分组。底层客户端 ID、来源过滤、账本和已计价贡献保持独立；同一展示型号合并 Token、占比和已知金额，保留来源客户端/原始型号。未知价格仍为未知，已知小计保留，Fast/Free 变体不并入标准价型号。

| 分组 | 第 1 列 | 第 2 列 | 第 3 列 | 第 4 列 |
| --- | --- | --- | --- | --- |
| Codex | Astra6 | Sol6.1 | Terra6.1 | Luna6 |
| Claude | Fable5.2 | Opus5.5 | Sonnet5.5 | Haiku5.5 |
| Antigravity | Argon4 | Opus5.5 | Sonnet5.5 | Haiku5.5 |

按本轮“0 也要放上去”的明确要求，已出现的客户端保留上述主力卡，未出现用量的型号显示 0 和“本周期暂无本地用量记录”。这修订了 build 1010 中“只有正用量才占首行”的规则；Flash3.8 等额外型号仍保留在同客户端“另 N 项”中，默认收起。只影响展示：零用量卡不写账本、不进入合计、不被侧栏今日明细当成真实记录。完全没有该周期来源记录时，不凭空建立客户端分组。

## 一级额度线标记

定位到 Swift 的 `compactMarkerDiameter=3` 与 Tauri 的 3px 覆盖样式，实际额度线宽为 4。改为直径与线宽相等，中心位置保持在顶部半圆中心；展开时仍变为 5pt/px 的品牌标记。同步生产渲染、动画端点、CSS 几何检查和 Swift 像素检查。

## 额度来源：定位、扫描、收束

- Claude Desktop 和 CLI 已有独立离线读取入口，不能把 Desktop 账号额度冒充 CLI。当前本机 CLI 配置含 API 接入参数，两个兼容 statusline 额度缓存均不存在；没有改写现有 statusLine，也没有读取或输出凭据内容。
- 本机 Antigravity 2.31.0 确实已安装。旧 IDE `userStatus` 中 7 个模型的重置时间停留在 2026-05-23；Tools 所选账号的 16 个额度记录采样于 2026-06-09。两者均不能作为 11 月当前额度。
- 新版 `app_storage.json` 是界面状态，未发现额度项；477 个已检查的 Chromium Simple Cache key 没有 quota/usage/GetUserStatus 响应；本地状态 pbtxt 仅包含引导/选择/迁移信息，当前 language server 日志也没有数值额度记录。只做本地只读检查，没有网络、localhost RPC、唤醒或 GUI 操作。
- 已将未知/过期/API 状态收束到共享 `client-quota-presentation.json`，Swift 与 Tauri 的设置、一级/二级/三级菜单使用一致文案。已发现的支持客户端和 CLI API 配置能进入可见来源列表，不需要先启用会话采集；不会借 Desktop 的账号额度填 CLI。
- 支持的来源缺少读数或解析失败时保留状态项；二级圆环显示“待 / 旧 / 缓存 / API”，完整状态、来源与采样时间保留在提示和详情中。过期 CLI 缓存也保留 stale 状态，两端和 Rust 输出一致；新鲜 Antigravity 数据与真实剩余 0% 仍正常显示。
- 本机 Antigravity 当前余额仍未在已检查的离线来源中找到。这是本轮的明确数据边界，不能把客户端已安装解释为一定有可读额度，也没有用旧记录伪造当前值。

## 检查边界

已通过生产 TS 投影的轻量定向检查：9 组共享案例、正反输入顺序、完整型号次序、部分未知计价守恒、单来源隔离，以及 Desktop/CLI/API、已检测 Antigravity、所有不可用状态与真实 0% 的额度投影；已通过修改 Swift 文件的语法解析、JS/Rust 语法检查和 diff 检查。新增两端合并/零用量/折叠交互及实际 Swift 布局测试，完整编译和运行交由云端。首轮 `c1cadba4` 的前端 1,475 项通过、1 项旧 Spark 选择器失败；该测试现已按四卡默认折叠、展开后检查真实 Spark 金额/占比的交互修正。最终门禁结果待补。受保护文件 hash 与原基线一致。

### 界面/额度候选 74a968c3 验证（追加修复前）

- Swift XCTest 2,461 通过、38 个既有跳过；Swift Testing 676 通过。包含实际 640/840pt 宽度的三行十二卡布局、4pt 圆点像素与动画端点、CLI API 来源可见性、Desktop/CLI 独立状态和 Antigravity 缓存状态测试。
- Frontend 1,477 通过、0 跳过；云端脚本 18 通过；macOS 发布脚本 112 通过、1 个 Windows 专属案例按原规则在 Windows 执行。
- Rust macOS 1,835、Windows 1,778 通过，两端各 14 个既有 ignored，受检 tracked 源码干净，无额外未跟踪输入。Windows 打包自检和两端生产存储负向检查通过。
- 在候选构建中发现共享额度文案 JSON 未列入 SwiftPM 显式资源清单。`74a968c3` 已补齐 `Package.swift` 和安装包资源校验入口；最终 Swift 执行报告确认该文件可以正常加载。
- 最终云端渲染图已查看：`client-model-four-slots-640.png`、`client-model-four-slots-840.png`、`sidebar-quota-dot-contained.png`。它们是合成数据的生产组件渲染，不是已安装 GUI 截图。

| 门禁 | Run | 状态 |
| --- | --- | --- |
| Hosted project checks | [42848403064](https://github.com/hututuo/codex-token-bar/actions/runs/42848403064) | 全部通过，最终 CI 执行报告 PASS |
| Public v0.9.7 database upgrade | [42848402897](https://github.com/hututuo/codex-token-bar/actions/runs/42848402897) | macOS/Windows 全部通过 |
| Prepare hosted installers | [42848616146](https://github.com/hututuo/codex-token-bar/actions/runs/42848616146) | macOS/Windows 全部通过；macOS 已完成本机包校验 |

macOS arm64 候选 `0.9.11 / 1011`：manifest source/run/lane、精确资产集合、大小和哈希全部通过；`codesign --verify --deep --strict`、`hdiutil verify` 和从 `/private/tmp` 运行候选的 `--verify-bundled-resources` 均 PASS。该参数在 AppKit、业务服务和数据库初始化前退出，未启动 GUI。`client-quota-presentation.json` 与 `model-cost-order.json` 的包内字节和源码一致。bundle ID、designated requirement、Sparkle feed/公钥保持不变；ad-hoc 签名、未公证、未发布公共更新。

| macOS 资产 | SHA256 |
| --- | --- |
| 版本 app.zip | `086285b8a436a97a896cf2c9c060ffa2045effb4b99fdab785194a6a7ca3e5f0` |
| DMG | `ea6da5f16947afb8c2d9e0ea90efe6ddd637a1f9442a7ff74572df91af24f617` |
| App 主程序 | `cdea68fe736ef563e91dd6cb4b802a77c25f1ea8584ed0deccdcee891f105c34` |

本机证据根目录：`~/Library/Application Support/CodexTokenBar-Maintenance/2026-11-10-unified-claude-quota-TPVXlE/`。最终候选证据放在 `final-74a968c3/`，前序尝试分开保留。没有在本机进行重编译或完整测试，未改写受保护文件、用户配置或 provider 缓存。

## 同轮追加的 Opus 金额诊断

用户随后要求核查 Opus 金额与其订阅消耗印象是否一致。只读对照实际账本和两个本地源文件，确认部分 Claude Desktop 响应在不同 session 中具有相同消息 ID、UUID、时间与 usage，却因现有 `v1:sessionHash:id:messageHash` 主键而被重复汇总。Swift/Rust 都使用该身份规则；界面合并 Claude 分组不会解决源头重复。

用户已明确批准纳入本轮，要求保留原始记录。私人用量、金额及具体会话标识不提交到仓库；本机 `opus-cost-audit.md/json` 保留核验结论。候选 1011 仅包含界面/额度可见性修改，不能用于验收以下修复。

### 收束：共用有效响应读取层

新增 `client-usage-effective-events.sql`，由 Swift `ClientUsageReadModel` 与 Rust `effective_usage_query` 使用同一份 SQL。SwiftPM 显式资源和安装包资源校验同时接入。所有数值消费者都查询 `effective_client_usage_events`；原始记录的写入、读取旧 payload 合并、备份与诊断仍使用物理表。

| 消费入口 | 修复后的读取合同 |
| --- | --- |
| 累计/今日/七日/指定日期模型汇总 | 同一有效响应的 Token、调用次数、缓存完整性与逐请求价格 |
| 5 分钟趋势与日历日桶 | 去重后才应用时间范围；最新观察跨边界时只归属一个桶/日期 |
| 主页、侧栏、图表顶部/悬停/框选 | 继续消费上述汇总和模型桶，无新增 UI 计价或去重旁路 |
| 缓存排行请求、会话、会话型号集合 | 请求与会话均基于有效响应；对应同一个确定性代表记录 |

仅合并 Claude Desktop / CLI 各自内部具有合法 `v1:<64位session hash>:id:<64位response hash>` 的同响应、同原始型号副本。客户端边界、原始型号、Fast 等计价变体保持独立；fallback、seq、格式损坏的 ID 及其他客户端不参与此合并。不能凭相同 Token、显示名或时间猜测重复。

同响应取各计数的最大已知观察值与最新时间，未知保持 NULL；缓存写入 5m/1h 必须来自与合并总量一致的一整对有效观察，不能分别取最大值拼出虚假拆分。没有有效拆分时沿用既有标准 5m 规则。代表 `event_id` 取确定性最小值及其所属 session，仅用于稳定展示，不宣称辨认了真正的原会话/分叉父子关系。每个有效响应先按其原始型号、时间和缓存 TTL 计价，再汇总。

没有 DELETE、UPDATE 历史数据、schema 变化、checkpoint 重置、重新导入或 A/B 路由调整；旧记录保留在 B `multi-client-usage.sqlite` 及 revision 账本中。新副本/补全仍按原规则追加 revision，使现有汇总和价格缓存失效；重开旧账本立即得到修正后的读取结果。

### 全面检查

共享 11 组夹具覆盖完整复制、流式补全、跨窗口、完整/缺失/冲突 TTL、未知缓存、客户端边界、Fast 型号、fallback、非法哈希和非 Claude 来源。Swift/Rust 集成测试验证正反输入顺序、历史只读重开、全部消费者守恒、后续副本使缓存更新、真实 parser 跨本地午夜，以及原表/修订/checkpoint/schema 不变。原有畸形/BLOB/超大 payload 和逐请求分时价格测试接到生产共享读取层，保留原断言。

本机轻量检查：共享 SQL 11 组通过；旧直接汇总会在其中 6 组重复计数。只读实际账本的历史窗口与人工核验一致，没有修改业务数据；Swift 语法解析、Rust 语法解析、vendor 离线校验和 diff 检查通过。新候选完整编译/回归、历史版本兼容与安装包结果见下，不复用 build 1011 的旧门禁冒充本次通过。

### build 1012 追加修复候选

产品源码固定为 `9a0ebc4c51231f6c00eb8436c20faf8092da8d09`。后续维护文档提交不改变安装包对应的产品源码。

| 门禁 | Run | 状态 |
| --- | --- | --- |
| Hosted project checks | [42857922228](https://github.com/hututuo/codex-token-bar/actions/runs/42857922228) | 全部通过；attempt 2 最终执行封印 PASS |
| Public v0.9.7 database upgrade | [42857922475](https://github.com/hututuo/codex-token-bar/actions/runs/42857922475) | 两端通过 |
| 0.9.8–0.9.11 formed-state matrix | [42858041358](https://github.com/hututuo/codex-token-bar/actions/runs/42858041358) | 4 个版本 × macOS/Windows 全部通过 |
| Prepare hosted installers | [42858049578](https://github.com/hututuo/codex-token-bar/actions/runs/42858049578) | macOS ARM64、Windows x64/ARM64 全部通过；安装包已下载校验 |

- 前端 1,477、云端脚本 18 通过；Rust macOS 1,838、Windows 1,781 通过，各 14 个既有 ignored。两端新增的 3 个去重集成测试均实际执行通过，受检 tracked 源码未变，没有额外 untracked 输入；生产存储负控和 Windows 打包自检通过。
- 正式 CI 和 macOS 打包任务均实际执行 Swift XCTest 2,464 通过、38 个既有跳过，Swift Testing 676 通过；包括新增去重、历史只读、后续缓存更新和真实 parser 跨午夜测试。发布脚本 112 通过、1 个既有 Windows 专属跳过；最终 CI 封印 PASS。
- 正式 Swift CI 初次任务未取得 macOS ARM64 托管运行器，15 分钟后在零步骤状态被取消，GitHub 明确记录容量不足；没有编译或测试失败。重试仅针对该任务及其依赖的证据封印，保留已通过的前端和两端 Rust 结果，重试已成功。最终封印按 artifact ID `13786597793` 下载并核对归档 SHA256，未误用同名的初次失败报告。
- Public097：Swift 升级 8 项和相关回归 107 项通过；Rust 升级 3 项及生产恢复/manifest 场景通过。
- formed-state 矩阵使用真实旧版 producer 与当前 Rust 生产探针（`cfgTest=false`），每个版本/平台验证 8 个场景；committed/interrupted 各执行 3 次独立进程重开，恢复材料均保留。报告的候选 SHA、242 个受保护 Rust 源文件 blob hash 已与提交核对。原生 Swift 由独立 Swift/Public097 门禁证明，不能把 Rust 的 macOS 探针称为 Swift 矩阵。
- 已查看本次源码生成的 640/840pt 四列模型布局图与一级额度圆点图：Claude 合并、三组各四槽、零用量 Haiku5.5、额外型号折叠和圆点直径与轨道同宽均符合预期。这些仍是云端合成数据的生产组件渲染，未冒充已安装 GUI 截图。

macOS arm64 `0.9.11 / 1012` 已通过 manifest 精确资产集合/source/run/lane、checksum 文件、归档路径、深度严格签名、designated requirement、DMG 完整性及从 `/private/tmp` 执行 `--verify-bundled-resources`。共享 SQL、额度策略与型号排序资源的包内字节与源码一致；bundle ID、更新 feed 和公钥与 build 1010 一致。ad-hoc 签名、未公证、未发布公共更新。

| build 1012 macOS 资产 | SHA256 |
| --- | --- |
| app.zip | `db615b18b78857240b33c0391eadb988ab28de33409a1a99f637baba7ef11ebf` |
| DMG | `d3646c08de5775afd666dbb94ed9ac9ba664d84221490315f1e23230330cfd44` |
| App 主程序 | `bf86dd7a7140762975596bd6eeab4072ca7e677d0b6c87f5f146f5d7e898cb49` |
| 共享有效响应 SQL | `b4606fc4f517bd1e578ad8baa3e12a1bbebde370670f0f7f4dd5202735b89a0d` |

Windows 构件的 candidate manifest 和 build manifest 均已核对：精确资产集合、同一源码/run、版本 0.9.11、`windowsArch=both`、平台标识、大小与 SHA256 一致。云端分别使用 `x86_64-pc-windows-msvc` / `aarch64-pc-windows-msvc` 编译并打包；NSIS 外层启动器本身均为 PE32 x86，不把该外壳误认成应用架构。未进行 Windows 实体 GUI 验收。

| Windows 安装包 | SHA256 |
| --- | --- |
| x64 | `ec8c39f4fba858e827aeea94b63cc234a8058799025b82430241efae5d12aa81` |
| ARM64 | `cd5be221bb1fc08a169b6689ad900cd09352c7cf98a190e9f4461c9094c90363` |

2026-11-11 01:34（Asia/Shanghai）全部门禁与包校验完成。证据收拢在前述本机根目录的 `final-9a0ebc4c/`，最终索引为根目录 `final-validation.json`；旧候选证据分开保留。已安装应用仍为 build 1010；没有停止、替换或操作实机 GUI。受保护的三个文件 hash 与原基线一致，其余既有未跟踪文件保留。停在安装之前，由主控先询问用户是否在场，再安排备份、安装和 GUI 验收。

### 用户批准替换后的安装结果

用户在上述安装前报告后明确回复“替换”。2026-11-11 11:16（Asia/Shanghai）已将 `/Applications/Codex Token Bar.app` 从 build 1010 替换为 `0.9.11 / 1012`，产品源码仍为 `9a0ebc4c`。替换前完整备份校验了 130 个文件/符号链接及签名，原安装包本体另行保留；旧进程正常退出，候选在 Applications 同卷暂存后改名到正式路径。安装后的主程序 SHA256 与云端候选一致，深度严格签名、包内资源和共享 SQL 校验通过。

已安装进程 PID 38685：11:16:33 启动、11:16:39 startup ready；11:16:59 存储完成 4,406 个文件、pending 0、schema 14、published generation 27813；11:17:08 首次刷新 numeric/detail ready，并生成 build 1012 的安装确认回执。启动会话未观察到 failed 事件。

本机证据为前述根目录 `install-build1012.P1fb9x/installation.json`，备份位于该目录的 `backup-build1010/Codex Token Bar.app`，原安装包保留为 `original-build1010.app`。最终验证索引已更新为 installed=true、guiTested=false；本次完成替换与启动验证，界面交互由用户查看验收。没有修改用户设置，受保护文件保持原样。
