# Antigravity 本地用量、活动速度与任务接入

基线：`d39e3acfbeee557323a2d6eb884736c4ecb86f99`，分支 `codex/legacy-debt-20261104`。本次接入 Antigravity 的三项产品能力，并落实前轮要求的模型配色统一。源码、本机只读验证和安装状态分开记录。

## 已实现

| 能力 | 实现与边界 |
| --- | --- |
| Token、历史、参考费用 | 注册为正式客户端，读取 CLI、桌面、IDE 三个默认存储目录的 UUID 会话数据库；写入现有多客户端账本并进入首页各时间范围的统一投影。使用已有价格表、时间段、缓存价格和已知费用小计，不把参考费用称为提供方实扣。 |
| 活动速度与速度条 | Swift 的来源配置、订阅、侧栏和历史；Tauri 的启用条件、白名单、内存曲线、显示范围；Rust 的 helper 配置和 C# 的来源映射均接入。停止、超时或不可用时遵循现有规则。不是新增正文生成 TPS。 |
| 主任务和子 Agent 条 | 使用底层实际 phase、isSubagent 和父会话关系，接入十格任务条、展开详情及设置预览。只计新鲜的运行状态；缺失来源不伪造为当前零任务。 |
| 颜色 | 同一模型在首页费用、速度分段、任务格和模型占比处统一取色。首页双击模型可修改/恢复默认；修复占比缓存不随配色刷新，补齐客户端色菜单的已注册来源。 |

客户端默认保持关闭，沿用其他客户端的显式启用方式。新候选运行后，在主页面的多客户端设置中启用 **Antigravity → 读取本地用量**，选择“汇总”或“Antigravity”，并保持实时速率开启即可使用对应显示。默认路径同时覆盖三种存储；自定义路径为单个 store 或其 `conversations` 目录。不会把其用量记到 Gemini CLI 名下。

没有新增订阅额度轮询，没有自动修改 Antigravity 配置，没有改上报开关，也没有迁移或清空 Codex 账本。`.pb` 不在本次数据库适配范围；`*-backup`、嵌套 `old`、非 UUID 文件和子级符号链接不参与自动发现。

## 数据与兼容规则

Swift 的 `AntigravityUsageSource` 通过一个小型公开包装调用原有底层读取器和解析器。新增包装已登记在 `Vendor/AgentSpeed/UPSTREAM.json`，原底层解析算法和 pin 不变。Rust 的 `antigravity_usage.rs` 独立封装相同 protobuf 字段与入账规则，使用共享真实格式 fixture 对照，不在通用扫描器中堆叠二进制解析。

已完成的 planner response 才形成用量事件。输入包含缓存输入，reasoning 属于 output，不重复相加。请求 ID 稳定；复制到另一 store/fork 的同一请求保留首次账本归属，计数取已知最大值。fork 继承旧记录按底层创建时间规则排除。重复扫描不重计；源数据丢失或关闭读取保留旧账。

读取使用只读 SQLite，处理 WAL。业务账本事务同时提交已解析事件与读取前的文件标记：本机继续写入时，当前已完成记录先落账，下轮重读改变过的数据库并去重，不因源文件持续增长反复放弃整批工作。每轮仍轮转最多 200 个文件，沿用原扫描调度。

模型原名保留。仅对 Antigravity，允许价格资产中明确列出的 effort 修饰后缀（例如 `-high`、`-thinking`）在基础模型确有价格时采用基础价；不猜测 `-n`、`-a` 或私有路由背后的模型，不改变其他客户端原有精确匹配规则。

## 本机生产扫描器验收

使用真实生产 `MultiClientUsageScanner`，只读本机来源，写入独立临时账本；未写本机正式业务库。最终采样：2026-11-05 22:39:50 +08:00。

| 项目 | 结果 |
| --- | ---: |
| 发现的 UUID 数据库 | 545 |
| 完成全轮所需扫描调用 | 3 次，每次最多 200 个文件 |
| 累计请求 | 2,255 |
| 再调用一次后的累计请求 | 2,255 |
| 输入 Token（含缓存） | 184,272,674 |
| 输出 Token（含 reasoning） | 1,901,461 |
| 已知参考费用小计 | $32.706732 |
| 尚未定价请求 | 1,544 |
| 该次三轮初次读取总时间 | 4.698 秒 |
| 该次后续单轮检查时间 | 0.105 秒 |

两个耗时分别是**三轮初次读取**和**一轮已有断点检查**，不是 Swift/Rust 同输入性能对比，也不是 Token 生成速率。较早采样为 2,253 笔，此后本机又产生两笔新请求；不同时间的源目录不作为静止同一份输入比较。

未定价分布：`gemini-3.8-flash-n` 837 笔、`gemini-3-flash-a` 520 笔、`gemini-pro-default` 186 笔、无模型 1 笔。这些 Token 均已计入；缺少可靠价格映射的部分继续标注未定价。`gemini-4-argon-high`、`gemini-3.8-flash-high`、`claude-opus-4-6-thinking` 已按明确修饰规则计价。

另用正式 C# helper 在本机只读采样：Antigravity `sourceAvailable=true`；当时没有当前生成/工具任务，速率为空、主/子均为 0。它证明真实来源可发现和读取，不证明活跃生成时的速度已在安装版实测通过；也不是 Windows 实机验收。

## 验证记录

- Swift 定向集合：97 项执行，96 通过、1 个本机读取 opt-in 用例跳过；应用 Swift Testing 10 通过，底层 Antigravity/定价回归 17 通过。opt-in 用例随后通过显式环境参数单独运行，结果如上。
- Rust：多客户端 57 通过，本地运行时 23 通过；最后的文件名 Unicode 边界修正另跑 Antigravity 三项通过。没有把重复执行累计成更多测试。
- 前端：49 通过；TypeScript 与 Vite 生产构建通过。
- C# helper：使用与仓库 CI 相同的 `LangVersion=latest / Nullable=enable / ImplicitUsings=enable` 参数编译并通过离线 self-test，覆盖 Antigravity 的源选择、速率、父子关系与 ID 脱敏。未在 Windows 机器运行。
- Vendor 清单检查通过；`git diff --check` 通过。
- 浏览器中使用真实产品组件和合成数据：双击首页模型打开改色，改变 Gemini 色后费用标记、速度条、模型占比、任务格和任务文本同步更新；操作 3→0→3 验证任务亮格归零与恢复。截图 `preview.png` 是合成预览，不是安装版真实数据截图。

初次验证中修正了 Swift actor 调用边界、Rust helper fixture 必需的禁用来源字段，以及一个遗留的前端任务条测试参数；C# 初次未带仓库规定的编译参数，按 CI 参数重跑通过。旧解析 fixture 的专用价表与当前正式价表不同，未用旧价表的“全部可计价”断言覆盖当前未知价格规则；增加明确修饰后缀与不透明路由边界的测试。

本轮证据在 `scratch/integrated-recovery/antigravity-integration-20261105/`：各命令 `.json/.log`、`local-price-receipt.json`、`live-helper-receipt.json`、预览和 `manifest.json`。

## Codex CLI 的说明与安装边界

Codex CLI 已有接入，与 Codex 桌面记录使用同一个 `codex` 来源，不是额外缺失的 Harness。`CodexDataSource.swift:48` 解析所选 Home 的 `sessions`，其发现同时支持 `CODEX_HOME`、默认 `.codex` 和用户指定目录。CLI 若在另一个 Home 下运行，需要选择/配置相应数据源；不能假定“Codex 已接”就覆盖每一个任意 Home。

本次完成的是源码及上述本地验证，没有替换 `/Applications/Codex Token Bar.app`、更改本机客户端开关或发布。已安装版本仍为前轮记录的 0.9.11/build 992；要在常驻应用里使用此次接入，仍需安装此候选后的运行验收。
