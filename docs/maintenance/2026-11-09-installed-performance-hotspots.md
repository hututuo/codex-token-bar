# build 997–999 实机性能热点定位与验收

本轮从已安装的 `/Applications/Codex Token Bar.app` 0.9.11/build 997、产品源码 `1fad508c` 出发。最终产品源码为 `c4330302c08434fab0e08cc2241670c7b7389a8e`，build 999 已安装。编译、测试和打包只在 GitHub Actions 执行。本机只运行已安装程序、系统采样器、下载包内的诊断工具和轻量证据脚本。活跃 Codex 会话仍在产生数据，不冻结、不删除、不复制回写真实业务库。

## 基线与已确认热点

工作区证据：`scratch/performance-hotspots-20261109`。初始运行 PID 75559；开启既有 opt-in 刷新探针后的首轮 PID 87071，180 秒观察窗内在第 5/45/100 秒分别采集 12 秒、5 ms 间隔调用栈；第二轮 PID 16711 使用相同协议，并增加启动后前 45 秒 Apple-event 响应测量。后续 998/999 使用相同脚本和时窗复测。

| 路径 | 直接观察 | 修复边界 |
| --- | --- | --- |
| 启动主线程 | 第 5 秒开始的采样中，1,065 个主线程样本里 667 个在 SQLite/存储路径；600 个经过 `installBusinessStore`，其中共享账号归因刷新占 421 个 | 安全库显式保留物理 SQLite 句柄的已解析 schema；每次操作继续检查路由、A 身份和 owner 状态，重新构造逻辑绑定。初始化及首次 schema 读取移到已完成生产准入后的 utility worker |
| 后台汇总读取 | 在 `attributionLedger.loaded` 后触发的 10 秒采样里，717 个相应工作线程样本进入 SQLite，648 个经过重新安装业务绑定；其中会话聚合路径 460 个、用量聚合 257 个 | 将相邻聚合读取收进一个短的同步连接作用域；不新增 writer gate、事务或结果缓存。已有 published-reader deferred 快照保持原样；摘录补全在作用域之外 |
| AgentSpeed 快照 | 平稳窗口后台 monitor 的 73 个样本中，67 个在 publish、66 个在 SnapshotContext；多次出现 TranscriptParser copy 与 memmove | 先将 `state` 的 nil-coalescing 链改为 family 选择，但 build 998 实测证明外层 stored-property 读取仍复制聚合值；build 999 进一步使用短 inout 投影。收益必须以最终装机样本核验，值语义、解析与计费结果保持原样 |

样本计数是调用栈出现频次，不能当作毫秒；上表中的父子调用不能相加。初始自然窗口中主线程 1,321 个样本里 1,086 个处于等待、218 个在 UI 更新，不能据此称应用一直阻塞。

首轮带探针启动，`usageStore.refresh` 数值发布约 30.189 秒，完整阶段约 32.085 秒，结束约 32.969 秒；其中精确分析约 25.439 秒达到数值就绪，摘录补全约 1.894 秒。这些是嵌套阶段，不能叠加。一次后续增量刷新约 21.843 秒数值发布、23.762 秒完整发布、24.572 秒结束；约 4,330 个来源，实际改变的来源仅 3 个。最终对比须列出版本、样本数、输入增长与主机负载。

## 其他路径的调查边界

文件签名扫描约 1 秒，增量扫描、来源物理身份复核及压缩源边界仍保留。未把缺乏当前热点证据的压缩/解压、SQLite 安全校验或轮询直接删掉。一次延迟维护约 5.7 秒，其中大部分为打开索引，结果 notDue；代码确认它是进程内每路径最多一天一次的维护调度，不能把它误报成每 30 秒反复执行。

侧栏通过五轮真实鼠标悬停展开/收起核对几何与响应。CGWindow 只反映原生窗口边界，而当前动画在固定 canvas 内合成，因此原生边界跳变间隔不能作为真实帧率。Apple-event 响应时间包含 osascript 启动/IPC 开销，不能作为纯主线程函数耗时。源代码、合成测试、系统采样和最终实机验收分别记录。

额外用系统 Animation Hitches 录制 25 秒，录制启动后自动执行五轮悬停，保留 CPU 和 context-switch 调用栈。工具报告 13 个超过 33 ms 的 potential interaction delay，其中 733 ms、3.384 秒两个长区间各只有 2 个主线程运行样本，边界栈主要为 `mach_msg` / `__CFRunLoopServiceMachPort` 正常等事件；3.384 秒区间发生在鼠标脚本结束之后。它们不是已证明的 SQLite 阻塞，也不能仅凭工具标签宣布应用卡死。该仪器的帧等待/显示表还包含合成和刷新率节奏，未将这些行数直接转换成产品 FPS 或作为提速百分比。

Windows/Tauri 对应面板入口通过 `run_blocking_command` 执行后台读取，拆分后的 read model 共用传入连接；未发现需要套用 Swift 主线程修复的同形路径。Windows AgentSpeed 是引用类型解析器，状态属性不复制整个 Swift 式聚合。因此当前修改集中在已证实的 macOS 路径，双端完整回归仍须通过；不声称已实测 Windows 桌面帧率。

## 数据与恢复护栏

仅共享账号安全库显式开启物理句柄保留；外部 WAL、普通调用方、只读诊断采集器和迁移/暂存路径不改变。保留当前 recovery/cross-process gate、IMMEDIATE 与 FULL 提交。错误、未提交事务或逃逸语句仍关闭句柄；相邻聚合连接作用域不延续到 await 或摘录读取。有效 A 被替换、owner 封存/阻断、模块路由变化、并发事务、独立提交、回滚、外部新行及 schema 变化均增加回归覆盖。

AgentSpeed 的 upstream pin、原始哈希、价格、报告协议与账本不变，局部补丁有单独 provenance 哈希。每个 parser family 的真实状态、错误计数与独立值拷贝均纳入回归。

装机前还拦截过一次锁顺序风险：中间候选 `c4d08ec2` 完整 CI 通过但未安装，复核发现安全库外层 operation scope 先拿 driver mutex，内层 load/mutate 却先拿 recovery gate，另一个读者可能持 gate 等 driver。`9ad29a2c` 取消持久物理句柄安全库的外层 driver scope，各次 load/mutate 保持 recovery → driver 顺序；原有跨进程归因锁、每次权威读和独立事务保留。新增回归要求并发读者在外层归因回调期间真正完成，未放宽超时或健康判定。

## 验证与交付状态

数据库优化候选 `9ad29a2c09bb1346b5c0f626706e4abd3034bd6a` 的完整 CI `42504262756`、Release Packaging `42504265309` 全部通过，已作为 build 998 实机复测。完整保留 build 997 后安装，主程序 SHA-256 `ae88b10d16d06c569c2a9a845e260f05e5beec27fdbac501e52c4030f18e1f35`。回滚副本在 `scratch/performance-hotspots-20261109/local-install-998-vbogjlb4/rollback-build997/Codex Token Bar.app`。

该版的同法复测确认：启动到数值发布 39.821→31.350 秒；刷新内完整发布 32.488→28.013 秒；同一轮基线的后端相邻聚合读取为 4.683→0.396 秒（此前另一轮约 5.2 秒，不混用两轮数据）。第 5 秒采样的主线程存储样本 627/1180→27/1153，第 45 秒 250/1258→4/1311。启动 Apple-event p95 96.286→79.303 ms、max 422.687→110.484 ms。实时来源由 4,330 增至 4,335，系统负载不同；该观察不是冻结同数据的速度保证。180 秒内进程累计 CPU 时间为 98.82→105.90 秒，且第二轮额外发生一次完整精确刷新，不能据此宣布整体 CPU 或功耗下降。

但 build 998 的第 100 秒样本仍有 45 个完整 `TranscriptParser` copy，baseline 为 44：仅改内部 state getter 没有消除更外层 class-property getter 的复制，不能把它算作已验证收益。已继续将 monitor 的状态读取改为通过 `TrackedFile` 对 stored parser 的短 inout 投影，返回仅包含状态的小值，不缓存、不修改 parser、不改值语义；所有 family 覆盖读取、变更和 reset。另将主页面会话过滤中重复构造的客户端集合移出每行闭包，集合内容和视觉保持一致。

最终跟进源码 `c4330302c08434fab0e08cc2241670c7b7389a8e` 的 [完整 CI 42509129728](https://github.com/hututuo/codex-token-bar/actions/runs/42509129728) 与 [Release Packaging 42509131811](https://github.com/hututuo/codex-token-bar/actions/runs/42509131811) 所有 job 均 completed/success。下载构件逐项核对 GitHub SHA-256、source SHA、workflow run ID、执行日志 seal 与 package manifest；验证结果在 `c4330302/final-validation.json`。

| 云端门禁 | 实际结果 |
| --- | --- |
| Swift XCTest | 2,411 passed，38 项原有显式 skip，0 failed |
| AgentSpeed Swift Testing | 676 tests passed；两项新增投影测试分别运行 10 个 family case |
| Rust macOS / Windows 完整库 | 1,820 / 1,763 passed；各 14 ignored，0 failed |
| 前端全量 / 云端脚本 / release-script 合同 | 1,446 / 18 / 112 passed；release-script 另有 1 项原有 skip |
| 生产 business-store 场景 | macOS / Windows 各 16 项通过 |
| 备份清理负控、有效但物理 A 被替换负控 | 双端原始通过 → 故意破坏被拦截 → 源码恢复后通过 |
| 新增 SQLite 回归 | 8 项均出现在执行日志和必跑名单内；包括新行/schema 可见性、sealed/admission、A 替换、回滚/独立提交、并发、deferred 快照、recovery → driver 锁顺序 |
| 诊断包保护 | 双端通过；已下载 macOS helper 另实跑 0.365 秒，持 EXCLUSIVE 锁仍导出、源目录不变、敏感诱饵不泄露、既有目标不覆盖 |

这些 skip/ignored 仍按仓库已有平台/专用场景策略保留，不能把它们计作通过。新增性能边界测试没有 skip。Windows 包实际包含 x64 与 ARM64 两种架构；本轮没有 Windows 桌面实机响应/FPS 测量。

## 最终同口径实机对比

主对比使用 `build997-repeat`、`build998-startup`、`build999-startup`，PID 分别为 16711、17195、78882。同一台 Mac、同一 180 秒脚本、相同 5/45/100 秒采样时点和 12 秒/5 ms 采样设置；前 45 秒执行相同 Apple-event 响应探针。时间来自刷新 trace，不用调用栈频次换算毫秒。系统文件缓存、实时任务、用户侧栏悬停状态和源数据没有冻结，因此这是同协议实机观察，不是严格固定输入 A/B，也不是纯空闲耗电测试。

| 指标 | build 997 | build 998 | build 999 |
| --- | ---: | ---: | ---: |
| 发现的源文件 / 已索引事件 | 4,330 / 550,413 | 4,335 / 550,671 | 4,338 / 550,831 |
| 本轮改变文件 / 新增事件 | 3 / 4 | 4 / 21 | 3 / 8 |
| 观察到进程启动 → 首次数值发布 | 39.821 s | 31.350 s | 30.902 s |
| 首次 refresh 开始 → 数值发布 | 30.447 s | 26.081 s | 25.863 s |
| 同一次 refresh → 完整发布 | 32.488 s | 28.013 s | 27.947 s |
| 同一次 refresh → 收尾结束 | 33.318 s | 28.151 s | 28.052 s |
| attribution 已加载 → 相邻聚合读取结束 | 4.683 s | 0.396 s | 0.399 s |
| 启动 Apple-event 响应 p50 / p95 / max | 70.75 / 96.29 / 422.69 ms | 67.64 / 79.30 / 110.48 ms | 67.18 / 81.92 / 95.14 ms |
| Apple-event 请求数 | 135 | 140 | 138 |
| 第 5 秒主线程存储样本 / 主线程总样本 | 627 / 1,180 | 27 / 1,153 | 92 / 1,050 |
| 第 45 秒主线程存储样本 / 总样本 | 250 / 1,258 | 4 / 1,311 | 7 / 1,028 |
| 第 100 秒主线程存储样本 / 总样本 | 9 / 1,321 | 10 / 1,221 | 226 / 1,291 |
| 主线程 schema 重新解析样本（5 / 45 / 100 秒） | 550 / 219 / 0 | 0 / 0 / 0 | 0 / 0 / 0 |
| 全线程完整 TranscriptParser copy 样本（5 / 45 / 100 秒） | 9 / 57 / 44 | 22 / 48 / 45 | 0 / 1 / 5 |
| 系统 load1 中位数 | 7.48 | 6.38 | 6.81 |
| 180 秒内进程累计 CPU 时间 | 98.82 s | 105.90 s | 112.61 s |

首次数值可见的观察时间比 997 减少约 22%，完整刷新减少约 14%，相邻聚合读取减少约 91%。999 相比 998 的首次整体刷新基本持平，不能把 0.07 秒差异当作确定收益。998、999 在观察窗末尾各多完成一次自动精确刷新，分别为数值/完整 16.003/17.691 秒、17.593/19.385 秒；997 的同窗没有第二次精确刷新完成，不用这两次不同输入事件构造升级退化结论。累计 CPU 也没有降低的实证。

解析器复制的主要修复有两层证据：下载的 998 与 999 优化二进制反汇编显示，`sessionCounts` 和 `malformedLines` 中原有整份 `TranscriptParser` copy 调用已被去掉；实机中两条调用链也不再出现该复制，而 `MonitorCore.publish` / `SnapshotContext` 仍正常采到。第 100 秒 `SnapshotContext` 样本由 63/75 降至 39，残留 5 个 parser copy 全在 `unsupportedSources -> parser.isUnsupported`，不把它称为完全清零。客户端集合过滤样本降至 5/6/7 量级，作为小幅辅助优化，不单独承诺端到端收益。

### 未消除项与限制

- 999 第 100 秒有 217 个主线程样本经过 `configureSessionMutationMonitor -> loadContinuityLoss -> SharedAccountUsageSafetyDatabase.load`，其中 208 个落在 fresh binding 的 SQLite 页面 `pread`。源码对应每次重新读取 owner 与 `sqlite_master` 名单。重复解析 schema 已消除，但权威目录磁盘读取仍可能阻塞主线程；这是明确残留，不能只展示第 5/45 秒的改善。进一步改造需要独立处理异步投影、失效时序和 owner/路由一致性，不能用缓存旧准入结果或跳过检查解决。
- Antigravity `unsupportedSources` 仍有少量完整 parser copy；主要快照状态投影已优化，但未把所有 parser 属性一律改写。
- exact open 在 999 观察窗内中位数约 6.009 秒，首次为 7.177 秒；签名扫描约 1.060 秒，增量同步约 5.162 秒，摘录补全约 2.016 秒。包含身份、完整性和账本处理，未为降低数值绕过这些边界。
- 不能从首 45 秒 Apple-event max 下降推断之后整个运行周期无卡顿，也不能从 CGWindow 尺寸变化或 Instruments potential-hang 标签宣称 FPS/所有卡顿清零。

### 侧栏与 Instruments 交互验收

997 与 999 都在 Animation Hitches 开始录制后执行五轮实际鼠标悬停，输入结束后恢复鼠标位置。没有更改显示模块、刷新频率或侧栏偏好。CGWindow 原生宽度仍为收起 16pt / 展开 88pt，固定 canvas 内的视觉动画另以实机截图验收。

| 配对窗口响应 | build 997 | build 999 |
| --- | --- | --- |
| 五次展开响应 | 151 / 42 / 76 / 56 / 44 ms | 57 / 29 / 33 / 44 / 44 ms |
| 五次收起响应 | 852 / 859 / 838 / 820 / 837 ms | 819 / 833 / 815 / 822 / 821 ms |
| 展开、收起、动画中途反转 | 基线正常 | 实机五张截图与窗口边界检查 PASS |

收起时间包含既定宽限和动画时间，不把约 0.82 秒算作卡顿；展开响应也不是合成帧率。999 云端绘制图和实机图均确认圆点不越出轨道，分段条首尾端帽保留，展开内容与反转恢复正常。

Instruments 在 997/999 中分别标出 13/5 个超过约 33 ms 的交互延迟区间；由于场景实时输入不同、且含录制边缘区间，不据此声称卡顿减少某个百分比。999 的两段 122.673 / 124.423 ms `Brief Unresponsiveness` 各有 112/122 个主线程 CPU 样本，确实包含 `refreshSharedAccountAttribution -> loadContinuityLoss -> safety.load -> installBusinessStore` 及 SQLite 读取。这与前述主线程目录读取残留一致，仍是可感知短停顿的来源。另两段标记为 36.704 / 86.323 ms。

999 最长 998.889 ms 的 `Hang` 标记起点为录制后 25.348965 秒，而实际 CPU 样本止于 25.348517 秒；该区间没有 CPU 样本，紧邻之前的切换栈主要为 runloop 等待。它已经落在采样覆盖之外，不能确认原因或将其计为本次实测 1 秒业务阻塞，也不能强行归零。997 的长区间同样缺少充分运行证据。原始帧 hitches 表分别有 957/786 行，均无超过 200 ms 的该类行；这些行含显示节奏与合成等待，未转换成 FPS 或性能提升百分比。

## 安装身份与回滚

2026-11-09 03:05:38（Asia/Shanghai）完成 build 999 替换，旧程序正常退出；新旧 app 全文件清单、文件哈希、符号链接与签名核对后原子换位，新进程启动成功。bundle ID、Sparkle feed、公钥与 designated requirement 均保持一致。macOS 沿用 ad-hoc 签名，未做 Developer ID/notarization；这是用户授权的本机候选安装，没有更新公开 appcast、tag、main 或 GitHub Release。

| 产物 | SHA-256 |
| --- | --- |
| 已安装 build 999 主程序 | `c34b46c77b21c35f36521776884427773a80e591c1cc625090cf9eed48dc9307` |
| macOS app zip | `31b662d813ac32fe64eb1196d7d6df9ec11d4a7184f786bb2043e9382a9d4d44` |
| macOS DMG | `ce9660f5c5e2f10cb2398cefde7ca0a9e0a051b1fe82a4472219194d3f7ae43b` |
| Windows x64 installer | `5899644eea602f90f63eb3c55556e107c9c2f86f41521e32095f60e3ef8204c7` |
| Windows ARM64 installer | `89847a522e6a44fbf5d7c13d938271e10dd57d0f85ef0f40554335b880880e9d` |

build 998 回滚副本：`scratch/performance-hotspots-20261109/local-install-999-3esbq3dd/rollback-build998/Codex Token Bar.app`；build 997 副本仍在前述 `local-install-998-vbogjlb4` 下。安装回执在 `local-install-999-3esbq3dd/installation.json`，旧版备份不覆盖。运行事件需以首次刷新成功后的升级 confirmed 为准，不把 `open` 请求成功等同于升级验收完成。

已安装 helper 与主程序 `--export-diagnostics` 实测分别 2.823 / 3.073 秒，主进程不变，ZIP 通过无原始 home/认证字段检查，状态证明没有打开业务数据库，升级回执在首次刷新成功后 confirmed。完成采样后普通重启，最终核验 PID 1308、主窗口 1512×897、右侧收起条 16×308，签名与可执行文件哈希仍匹配；进程环境无性能探针变量。重启前 11 份历史事件文件哈希全部保留，新一轮首次刷新成功，见 `local-install-999-3esbq3dd/final-runtime.json` 与 `after-restart-validation.json`。

## 证据与复现入口

以下路径均相对于 `scratch/performance-hotspots-20261109`，原始采样和轨迹留在本机，不上传含本机路径的原始内容：

- `comparison.json`：三版时序、样本、输入规模、主机负载、CPU 时间和 Apple-event 响应；`capture.py` / `summarize.py` / `compare.py` 是本次统一采样和归纳脚本。
- `binary-projection.json` 及对应 disassembly：998/999 两个快照 getter 的实际云端产物对比。
- `build997-hover.trace` / `build999-hover.trace`、`hover-comparison.json`：同协议悬停、原始轨迹及原生窗口边界响应。初始 `build997-animation.trace` 的鼠标动作未正确落在录制窗内，不作为配对动画基线。
- `local-install-999-3esbq3dd/live-mYWKvr/live-sidebar.json` 与五张 PNG：收起、展开、收起、反转展开、反转收起实机证据。
- `c4330302/final-validation.json` / `app-validation.json` / `artifacts.json`：源码与云端产物的完整校验链。

导出 Instruments 明细曾因并行解压产生大量临时文件，已停止并行导出并改为逐项处理。清理 3 个确认无进程占用、与本轮时间对应的临时 `.ktrace`（合计约 19.4 GiB），完整已保存 `.trace`、XML、应用备份及业务数据均保留；清理记录在 `temporary-trace-cleanup.json`。该事件发生在 180 秒对比测量和悬停录制结束之后，不混入上述性能计时。

## English

Build 999, source `c4330302c08434fab0e08cc2241670c7b7389a8e`, is installed after complete cloud CI and packaging passed. Builds 997 and 998 have separate retained rollback copies. The changes retain a validated physical handle for the safety store, prewarm it after startup admission on a utility worker, scope adjacent aggregate reads to one connection, borrow the stored parser for state projections, and hoist repeated client-set construction. Authoritative reads, ownership checks, recovery-first lock ordering, transactions, accounting and visual geometry remain intact.

Using the same 180-second installed protocol, observed startup-to-numeric latency changed from 39.821 to 30.902 seconds, full refresh from 32.488 to 27.947 seconds, and adjacent aggregate reads from 4.683 to 0.399 seconds. Build 999 is broadly level with 998 for full refresh while removing the dominant parser copies from snapshot counts. Active sources increased from 4,330 to 4,338; inputs, filesystem cache and UI activity were not frozen. Overall CPU reduction is not established. A file-watcher-triggered safety catalog read still performs synchronous main-thread disk I/O, and a smaller unsupported-source parser copy remains. These are explicit residuals.

The final normal launch has no temporary performance probe environment. Startup, first refresh, upgrade confirmation, diagnostics export, retained prior event files and sidebar expand/collapse/reversal passed installed checks. Sample counts, refresh times, Apple-event response and compositor warnings remain separate measurements; potential-hang labels alone do not prove stalls or FPS. This was a local candidate deployment, not a public release or a claim that every possible stall is eliminated.
