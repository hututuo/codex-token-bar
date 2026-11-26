# 性能、多客户端与数据库兼容性验收

更新日期：2026-11-27（Asia/Shanghai）。当前候选：`ff55ace1ded93db84e18c1802840819092a3f54d`，包含产品代码 `9ae6a13b` 和证据编解码修复；最近完成的速度引擎配对源码：`4410b16bbf182b90bb6cface265f698182a61039`。三个目标继续保持 active。

## 验收状态

| 目标 | 已完成的工作 | 尚未通过的门槛 |
| --- | --- | --- |
| CPU、内存降低一半 | 响应排序与 latest-end 缓存；启动分窗解码及 WAL reader 回收；共享不可变响应与紧凑 timed-response；逐行导入临时对象回收；有界 Home 历史缓存；跨图表 range 共享归属数据 | 正式整 App、相同负载的 CPU 与 physical footprint 配对结果；4410 局部 RSS 改善最高33.43%，尚未减半；后续内存改动尚待云端原生验证及测量 |
| 客户端及各组件兼容 | 检查 Codex、Claude CLI/Desktop、DSH、Gemini、OpenCode、Antigravity 的发现、解析、身份、quota、live、导出、展示与 reporting；修复已确认的路径/投影差异；旧候选真实 Windows helper IPC 已通过 | 最新产品 SHA 的完整双平台回归；真实客户端与安装运行验收 |
| 数据库结构与后续兼容 | 聚合复用单次 TEMP canonical projection；缓存 revision 修复；两端 schema admission 和旧 payload 合并修复；Swift 显式列名写入；增强旧 producer B 账本真实入口重放验证 | 新增 producer probe 的四版本×双平台执行结果及当前生产聚合配对结果；不是任意未来 schema 的无损写回承诺 |

所有编译、原生测试、前端构建和打包通过云端。本报告中的后续性能候选未合并 main、正式发布或替换当前安装。

原始 Claude 隔离账号漏计修复已另行安装并验收：build1061、源码 `05e059ba09181bf4a97026dda47470d5ee6551e2`，生产 importer 找回全部2008次请求、263,914,258个含cache输入token。整个隔离账号集合2083次请求、289,842,334输入token及102个checkpoint均在账；未发现既有事件丢失、计数降低或pending请求。见 `docs/maintenance/2026-11-27-claude-account-usage-discovery.md`。此安装结果不能外推为后续性能优化已安装。

## 本次增量

### 数据库：`db97ce32`

- Swift 重放同时比较 payload、物理 session/model 列。旧列漂移会修复，并仅推进一次 revision；再次重放不增加 revision。
- Swift event/checkpoint 的 INSERT 使用显式列名，保留追加 nullable 列的已有值。
- 两端在迁移写入、备份或启用 WAL 之前检查已存在的保留对象。残缺同名表、冒充表的 view、错误 metadata 结构被拒绝；合法的未版本化 unrelated 表仍走备份升级。
- Rust 拒绝负 `user_version`；旧 payload 的 `quality` 缺失或 null 时与 Swift 一样默认 `recorded`，避免重放较小计数时覆盖旧大计数。
- Swift 新增 24 个碰撞 fixture 的三入口保全矩阵、负版本、列漂移、追加列及未版本化 unrelated 备份测试；Rust 新增拒绝前文件保全和旧 optional quality 重放测试。
- 旧只读测试的 fixture 现检查 checkpoint busy、DELETE 实际返回、header 18/19 及调用前 sidecar，保留全部调用后保全断言。此前失败日志同时显示调用前后目录名称相等，不能把既存 sidecar 归因为拒绝入口首次创建。

### 性能测量：`87c713d2`

- XCTest 可将诊断插入 stdout 中间；原测量记录因此损坏。改用每个 case 独立 JSONL，原始控制台日志继续保留。缺失、截断、错误身份及无执行仍失败。
- unchanged-loop fixture 先建空 day ledger，再按固定 index 写入原 seed，避免首次字典遍历对 Float32 source 桶的舍入噪声。20k dense 重叠、原数据、200 ticks、整数精确守恒及 `1e-6` 门槛保留。
- 此 unchanged case 不再覆盖 seed 后无序 bulk-ledger 初始化；独立 compatibility trace 保持原样，继续检查首建、替换、边界、回拨及 retention。
- manifest 强制声明 `recordTransport` 和 `seedOrder`。失败的旧 run 不作为性能 PASS。

### 内存：`c49bcb7b`

- 排序缓存只复制最近一次重建时 30 分钟窗口内的有效响应。今天的原始记录及 DayLedger 继续保留，latest-agent-end 仍取全部响应。
- cutoff 回退到缓存覆盖范围之外时，从权威 responses 重建，保留时钟回拨行为。同 ID 的前移/后移会置 dirty 并重建。
- 缓存不在每个正向 timer tick 主动缩容，故不是“始终只驻留当前最近 30 分钟”。收益仍须实测。
- 新增旧 today 保全、回拨重入和同 ID 进出 window 的原生测试。Vendor pin 未变，两个 patch hash/reason 已更新。

### 目录归属和测量恢复：`a41657c5`

- Swift/Windows Claude 的目录 ownership 独立于 enablement；禁用源及 nested root 保留去重归属，仅 enabled roots 参与扫描和 watch，状态不泄漏禁用源路径。
- Windows 新增四组真实 MonitorCore 离线回归；Swift watcher fixture 采用 POSIX realpath，消除 `/var` 与 `/private/var` 差异。
- SQLite refusal fixture 通过绑定的 `VACUUM INTO ?` 生成新 DELETE 快照，保留 production 源库和全部字节、sidecar、三入口保全断言；BodySpeedHistory fixture 修复负时间输入。
- whole-app harness 区分不存在与真实空 defaults domain；合成响应有 user 起点、`end_turn` 及明确1秒时长。ledger IDs、时间戳及用量真值不变，新增 fixture schema2 和本地日界检查。

### 不可变响应 revision：`a60544fa`

- Parser cache、ResponseUpsert 和 Engine 使用同一个不可变 `ResponseStorage`；更新创建新 revision，保留排队 partial/final emission 与 parser copy 的值语义。
- 定价仅在 cost 改变时 detach；不会把 Engine 定价写回 Parser 或另一个 Engine。公开 `ResponseRecord` 仍为值类型。
- 新增 holder 生命周期、嵌套赋值 detach、partial/final 独立、首次与延迟定价隔离测试；独立源码审核未见阻断项。原生全量结果仍以云端对应 SHA 为准。

### 真实历史 B 账本验证：`1d2d980c`

- 0.9.8–0.9.11 的真实 Rust producer 经公开 save/refresh/read 入口生成2个事件、2条 revision，并包含 legacy `fallback_identity` payload；不以 raw-read canary 代替候选入口验证。
- 候选经实际 `open_activity_module_connection`、公开 snapshot reader，再用不同前导空行触发两次完整重扫。每次必须实际推进完整 offset/size/fingerprint，事件与 revision 保持 `2 / 2→2→2`。
- 保全 rowid、全部事件字段、原始 payload、revision 历史、sequence、主体 schema 和 activity canary；候选首次写入前另存合成 producer 原始目录 ZIP、逐文件哈希及 A/B WAL。
- 新增 proof 缺失、次数、第一/第二次 revision 漂移、phase 语义及原始归档保全负控。24项相关 Python 检查通过；不冒充原生 producer/candidate 执行结果。

### Antigravity 目录合同：`077d5dc3`

- Rust display/reporter source-read allowlist 统一四个默认 store；display 自定义 parent 为自身加四个 child，直接 store/conversations 保持单根，backup 排除；名称大小写、尾分隔符和不存在的后建 child 与 C# 规则一致。
- reporter 继续仅接收原有 DeepSeek/Gemini/OpenCode override，不把 display 的 Antigravity 自定义选择泄漏到 reporter。
- 当前 Antigravity tailer 直接通过 C# SQLite 读取，**不发送 sourceRead IPC**。因此本修复仅消除许可目录合同漂移，不能宣称修复已复现的 ACP 漏计，或已经接入共享 SQLite 读取缓存。
- 单文件源码审核与 diff 检查通过；对应原生回归待云端，不以源码对照代替运行验收。

### 紧凑 live timed-response：`4410b16b`

- live timed view 共享不可变响应 revision，不再保留完整重复记录；保持30分钟 reference window、全日账本和 latest-end 的既有边界。
- 精确源码的 release 速度引擎配对 `45897628817` 已成功。原汇总器和原始24个 case 独立复算一致，35项语义比较、6条各11阶段 trace 通过，容差仍为 `1e-6`。
- 这是局部响应引擎的 CPU/RSS 测量，不是整 App 或 physical footprint 验收。

### 后续内存改动：`14017db7`、`dbb2d5cb`、`9ae6a13b`

- JSONL 每行 Foundation JSON 图放入独立 autorelease pool；会话 header 状态和归一化事件跨行保留。账本先验证全部输入，再于同一事务内逐事件编码，取消整批 `(event, encoded payload)` 副本；revision 仍先保存原始 incoming payload，再进行 owner/最大计数合并。
- 新增 late-trigger failure 回归，检查前两行写入、revision sequence 和 checkpoint 一起回滚；重试后原始较小 observation 与投影较大计数分别保全，再次重放不新增 revision。另有 BOM/CRLF、坏行、换 session、重复 enrichment 和 partial tail 测试。
- `BodySpeedSampleWriter` 默认最多缓存3个 Home 的 `StoreCache`；淘汰仅回收可从 SQLite 重建的历史及 store，不移除 `tickets/latestTickets`。旧任务仍在重新开库前被拒绝；future 样本和失败 ticket 可用同 ticket 重试。cold load 仍只读取一次历史，显式 warm load 仍观察外部更新。
- 图表默认后台准备路径一次筛选 closed display/cost attribution，三个 range 共用其不可变数组。原三参数 build 与自定义 builder 的原始 input 语义保留；source 独立 cutoff、nil fallback、空 source、严格 `< end`、取消和过期请求保护均保留。
- 图表回归使用原有非空 open-tail fixture，验证价格 `23.51656288→23.59885808`、全部 range 共用 backing buffer、刷新后旧 snapshot 稳定及取消不发布。另用7组独立 cutoff 预期和自定义 builder 原始 open-tail 检查。
- 两组独立源码审查及本机 diff/vendor 检查通过；**没有本机编译**。新增原生测试及实际内存收益以最新云端结果为准。不能由这些改动推断已解释或减半已安装 App 的217 MiB footprint。

### 历史 producer 证据精度：`ff55ace1`

- 增强矩阵 `45896583064` 已核对6格通过、0.9.10 macOS失败、0.9.11 macOS仍排队。失败发生在候选实际 open/read 之前，冻结事件/schema 比较已通过，仅 checkpoint 与 JSON 保存值不等；不得记作8格通过，也不能直接归为产品迁移丢失。
- 原始失败 JSON 的 SHA 与 producer manifest 一致。其 `modified=1795729040.2679539` 在锁定 serde_json 默认十进制 parser 算法的 binary64 模拟中变为相邻值，差1 ULP（约0.238微秒）；其余6格已通过 cell 的相应值未出现该差异。此调查没有在本机运行 Rust 或读取失败数据库。
- probe 对所有 SQLite REAL 改为保留16位 `realBits`；原 frozen/checkpoint 比较仍严格相等，不引入 epsilon，不改生产 Cargo feature 或数据库。所有 consumer 已复核，无需对这些 REAL 字段做数值运算。
- 旧 producer 和候选采用同一 probe。每次入口在任何 producer 写入前运行 native codec 自检：已知失败位值和相邻值必须保持不同，并经真实 serde_json 编解码后逐位不变。新全矩阵已重新调度，运行结果尚待回收。

## 云端证据索引

| Run | 精确代码与范围 | 本次记录时状态 |
| --- | --- | --- |
| `45886213630` | `df467c8b`；0.9.8、0.9.9、0.9.10、0.9.11 × macOS/Windows 实际旧 producer 升级 | 八条路径全部成功；不是当前 SHA 验收 |
| `45891050841` | `c49bcb7b`；完整 Swift、前端、双平台 Rust、updater、Windows IPC | 最终 failure；仅Swift实质失败，均属上述已修的四类；macOS 1877通过/14忽略、Windows 1819通过/15忽略；真实schema1+2 helper IPC独立1通过 |
| `45891050771` | `c49bcb7b` vs `f9e91791`；release speed engine 配对 | 35项语义比较通过；CPU下降71.4%–95.1%，RSS基本不变 |
| `45891050711` | `c49bcb7b`；公开 0.9.7 实际数据库升级 | 最终失败；8项实际升级测试通过，支持回归有失败，不能记为整轮成功 |
| `45888923141` | `754fc77c` vs `3eadadc6`；release Rust 真实聚合路径配对 | 独立复验24 cases、48项语义比较通过；12k cold CPU 1749.50→225.43ms（下降87.1%），peak RSS仅约±2%；候选早于本次数据库修复 |
| `45888504287` whole-app job | `447deca0` vs `f9e91791`；正式 App 的静态 Claude 可见 dashboard 配对 | 最终failure，App执行及旧DB baseline聚合步骤均失败；不是性能PASS，候选早于本次增量 |
| `45894176981` | `a41657c5`；公开0.9.7实际数据库升级 | 双平台全部成功；Swift 8项升级+119项支持回归，Windows 3项importer+19种manifest场景；已核对原始小证据 |
| `45894227783` | `a41657c5` vs `f9e91791`；release speed engine 配对 | 独立复验35项语义比较通过；CPU下降72.1%–96.0%，RSS改善0%–3.9% |
| `45894177094` | `a41657c5`；正式App与Rust聚合资源配对 | 运行中；不能把尚未采样当作性能失败或通过 |
| `45895264009` | `a60544fa` vs `f9e91791`；release speed engine 配对 | 独立复验35项语义比较通过，见下表 |
| `45895269055` | `a60544fa`；正式App与Rust聚合资源配对 | 运行中，正式App构建/采样完成情况以原始产物为准 |
| `45895140604` | `a60544fa`；完整回归 | 已全部成功，覆盖前端、Swift、双平台 native、Windows updater 与证据检查 |
| `45896583064` | `1d2d980c`；增强的0.9.8–0.9.11 Rust producer × macOS/Windows | 6格已核对通过；0.9.10 macOS在candidate admission前的checkpoint证据比较失败；0.9.11 macOS排队 |
| `45897009933` | `077d5dc3`；公开0.9.7实际升级 | 双平台成功；Swift8项升级+119项支持回归、Windows3项importer+19种manifest场景，均核对小日志 |
| `45897628817` | `4410b16b` vs `f9e91791`；release speed engine 配对 | 已独立复验成功，见下表 |
| `45897628497` | `4410b16b`；完整回归 | source/frontend/updater成功；Swift及Windows native运行中，macOS native排队。frontend实际1501 tests、cloud-scripts18通过 |
| `45898313857` | `4410b16b`；正式App与Rust聚合配对 | 正式App仍构建，聚合仍测量；没有整App结果 |
| `45899772826` | `dbb2d5cb`；完整回归 | pending后已取消、没有job，不作为执行证据；未由本任务取消 |
| `45899772743` | `dbb2d5cb`；公开0.9.7升级 | Windows成功且核对原始小日志；Swift排队 |
| `45900619404` | `ff55ace1`；完整回归 | 已由push排队，包含全部新增Swift回归；不是claude_usage_only |
| `45900619154` | `ff55ace1`；公开0.9.7升级 | 已由push排队 |
| `45900789028` | `ff55ace1`；REAL codec自检及四版本×双平台增强矩阵 | `formed_only=true`专用调度；排队，不作为完整CI运行 |
| `45900792974` | `ff55ace1`；正式App与Rust聚合配对 | 已调度排队；基线和48分钟最小采样协议不变 |

最新速度引擎局部数据（`45897628817`，每case三轮中位数；CPU为200-tick loop总量，RSS为endpoint resident memory；不是整App或physical footprint）：

| Fixture | CPU降幅 | 候选endpoint RSS | RSS降幅 |
| --- | ---: | ---: | ---: |
| 2k/day | 76.46% | 27.328 MiB | 4.06% |
| 2k/dense | 85.39% | 27.344 MiB | 6.37% |
| 20k/day | 96.00% | 33.203 MiB | 18.08% |
| 20k/dense | 90.88% | 33.516 MiB | 33.43% |

局部生产聚合已复核到 `a60544fa`：12k cold每次 CPU `1296.093→192.794ms`（下降85.13%），lifetime peak RSS `49.953→49.141 MiB`（下降1.63%）；24 cases、336次checksum、48项独立算术oracle及48项paired语义检查通过。只用HTTP206取74份小报告约981KB，完整945MB artifact、二进制及SQLite seed bytes未下载；不宣称完整binary/seed provenance复验。详见忽略目录 `scratch/performance-compatibility-20261127/current-resource-review/REVIEW.md`。

整App三条已有run均仍进行中。a416采样步骤UTC21:09:48开始，a605为21:28:35；12轮各120秒warmup+120秒测量，最低48分钟加startup及归档，因此尚未上传不构成性能失败。仍保留全部测量时长，不用缩短窗口换取完成。

调度记录：`45896457825` 曾误填不存在的 candidate SHA，属于调度输入错误，已用 `git rev-parse HEAD` 的精确值重发为 `45896583064`。错误 run 不作为产品回归或性能验收证据。

DB baseline 单独采用 `3eadadc6`，因为 `f9e91791` 的现有 Rust 测试编译错误在该提交修复；两者的聚合生产源码、canonical SQL、价格表和 Cargo 清单/锁文件逐字相同。Whole-app/speed baseline 仍为 `f9e91791`。

本机轻量检查：vendor offline check；18 个 vendor Python 控制、12 个 speed Python 控制；Python AST、workflow YAML、bash 语法和 `git diff --check`。这些不代替 Swift/Rust 编译或整 App 验收。

最新源码另执行 formed probe17项、formed workflow7项、whole-app harness17项Python测试，全部通过；vendor check及diff检查通过。REAL codec的Rust实际运行仍待新矩阵，新增Swift内存回归仍待完整CI。

## 已安装程序的只读观测

2026-11-27 05:04:59 +0800，唯一正式App主进程为0.9.11/build1061：瞬时CPU 6.1%、RSS 94.67 MiB、`proc_pid_rusage` physical footprint 217.173 MiB。Info.plist没有源码提交标识，不能归属到 `a60544fa`，也不能由单次采样推算配对降幅。默认projects仅做目录元数据统计：377个JSONL、1,308,168,672字节；未读正文。

原始匿名结果保存在 `scratch/performance-compatibility-20261127/live-memory-readonly-20261127T050459+0800/`，已忽略、未上传。为避免暂停目标，未运行vmmap、heap、sample或其他进程附加诊断。

## 持续兼容边界

源码与回归合同覆盖表（不是下列所有客户端的真实账号/实机验收）：

| 客户端 | 账本与组件检查结果 | 保留的能力边界 |
| --- | --- | --- |
| Codex | 独立精确历史及状态库、Home/source identity、quota/正文速度、图表和选中scope导出；完整历史producer与公开0.9.7入口回归 | 当前选择一个有效Home；不能把发现多个Home等同于并行核算所有provider账号 |
| Claude CLI | registered账户root的历史发现、live多root、嵌套/禁用root ownership、dedupe、Swift/C# helper协议1/2、选中scope导出 | local-only；statusline/monitor quota是有freshness的本地观测，非当前登录账号认证；不外传speed reporting |
| Claude Desktop | 与CLI独立namespace/classifier、分别配置root、local agent transcript、quota完整观测选择、图表/导出 | 普通cloud-only对话未落地则不可读；不能按目录推导账号绑定 |
| DeepSeek/DSH | JSON/JSONL/header sequence及压缩frame、重扫checkpoint、live/model/task、外部reporting source policy | 单选择root，无通用多账号registry或本地订阅quota provider |
| Gemini CLI | 双默认历史路径、JSON及JSONL形状、tool/thought计数、live显式root、显示/图表/导出 | Vendor规范和reference将第二sandbox默认根限于macOS；Windows live默认单根符合该合同，ledger搜索更宽；Windows可显式选sandbox tmp；没有本地订阅quota provider |
| OpenCode | Swift/Rust SQLite行上限统一1MiB、旧checkpoint一次重放、keyset continuation、fork/unfinished过滤、legacy JSON与DB去重 | legacy JSON账本支持不等于其单独可提供live速度；单选择数据root |
| Antigravity | 空placeholder重试及诊断、standalone/Orca发现、Windows ACP和parent扩展、display/reporter读取许可、owner/model投影、quota来源和图表/导出 | 当前tailer直接C# SQLite，不走sourceRead IPC；本地store不是认证账号表，reporter不继承display自定义AGY选择 |

- 多 root 是本地源覆盖，不是已验证的 provider account 身份。当前 ledger 没有 per-account 归属列，不能据此承诺逐账号费用归因。
- Claude 仅支持实际落地的本地 Code/Agent transcript；普通 cloud-only 对话不可读。Claude 仍明确排除外部 speed reporting。
- quota 来自各客户端自己的本地观测与 freshness 规则，不因路径同属一个账号目录就获得当前登录账号绑定证明。
- schema 2 接受必需字段集合的兼容扩展；显式列名解决 nullable 追加列写入。新增 NOT NULL/无默认值列、任意新约束及未知 JSON 键的重编码无损性不在此保证内。未来影响写入或用量语义的格式应增加 schema version，使旧程序拒绝，而不能仅追加字段后假设旧程序能无损写回。
- Swift/Rust checkpoint key 和部分 continuation 表示不同，切换实现可能重扫；不能承诺直接沿用另一实现的 cursor。事件与 checkpoint 仍同事务提交，重扫依赖稳定事件身份去重。
- 首版 whole-app harness 只测主进程、静态 Claude 单源及自然可见 dashboard，不覆盖 helper 总 CPU、hidden/sidebar、切图 retention、多 Home、live replay、带账号 quota 或 Windows 整 App。无 GUI 或完整 ready/ledger/window gate 不通过会记为 NOT_RUN，不降级成局部测试冒充通过。

目标继续保持 active；没有可接纳的整 App 配对数据前，不宣称 CPU 或内存减半。
