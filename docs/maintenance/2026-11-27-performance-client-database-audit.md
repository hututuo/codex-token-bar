# 性能、多客户端与数据库兼容性验收

更新日期：2026-11-27（Asia/Shanghai）。当前代码候选：`f59bc14f25c3d27c722abd4c12f2f987341a29fc`，在此前内存代码、`665efddf` 测量协议、`db16c1ee` 空源重复发布修复及 `6f54a401` 模型聚合顺序修复之上，新增未读动效离场及暂停时的帧回收、邀请视频资源延迟创建和双平台 Claude live 大记录测试，将 Claude 历史记录有界续读扩展至16MiB（含LF），并延迟分配空日账本的密集数组。最后一项生产修改为`683d0493`；`f59bc14f`只修正共享每日上限测试的午夜fixture并增加回归。最近完整CI全部通过并独立闭合的源码为 `267aa5e8ddaf1388c1a1e74d1cf2f4dc21d213e3`；最近完成速度引擎配对的源码仍为 `4410b16bbf182b90bb6cface265f698182a61039`。`d6c14da7`及`f2a48b8f`各有1个失败case，不能记为全量通过。三个目标继续保持 active。

## 验收状态

| 目标 | 已完成的工作 | 尚未通过的门槛 |
| --- | --- | --- |
| CPU、内存降低一半 | 响应排序与 latest-end 缓存；启动分窗解码及 WAL reader 回收；共享不可变响应与紧凑 timed-response；逐行导入临时对象回收；有界 Home 历史缓存；跨图表 range 共享归属数据；空源重复发布抑制；离场/暂停动效帧缓存回收；邀请视频资源延迟创建；空日账本密集数组延迟分配 | a416/a605/4410/ff55因首对窗口不同而整轮失败；665 v2首次完整通过12单轮/6配对，20k CPU下降39.53%、footprint下降6.77%，2k分别下降11.54%/2.27%；6f54因跨本地日整组NOT_RUN；均无减半结论，后续候选待测 |
| 客户端及各组件兼容 | 检查 Codex、Claude CLI/Desktop、DSH、Gemini、OpenCode、Antigravity 的发现、解析、身份、quota、live、导出、展示与 reporting；修复已确认的路径/投影差异；267完整双平台原生回归及真实 Windows helper IPC 已通过 | 最新产品 SHA 的完整双平台回归；Desktop长首条分类与历史归属；真实客户端与安装运行验收 |
| 数据库结构与后续兼容 | 聚合复用单次TEMP canonical projection；缓存revision修复；两端schema admission和旧payload合并修复；Swift显式列名写入；ff55四版本×双平台增强矩阵8/8通过，64次候选进程及64次强制重扫保全事件/revision；生产聚合独立复算至ff55 | 当前产品SHA的完整回归尚待云端；不是任意未来schema的无损写回承诺 |

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

- 增强矩阵 `45896583064` 已核对6格通过、0.9.10 macOS失败；保留证据后取消仅余且尚未执行的0.9.11 macOS，以释放更正后的全矩阵。失败发生在候选实际 open/read 之前，冻结事件/schema 比较已通过，仅 checkpoint 与 JSON 保存值不等；不得记作8格通过，也不能直接归为产品迁移丢失。
- 原始失败 JSON 的 SHA 与 producer manifest 一致。其 `modified=1795729040.2679539` 在锁定 serde_json 默认十进制 parser 算法的 binary64 模拟中变为相邻值，差1 ULP（约0.238微秒）；其余6格已通过 cell 的相应值未出现该差异。此调查没有在本机运行 Rust 或读取失败数据库。
- probe 对所有 SQLite REAL 改为保留16位 `realBits`；原 frozen/checkpoint 比较仍严格相等，不引入 epsilon，不改生产 Cargo feature 或数据库。所有 consumer 已复核，无需对这些 REAL 字段做数值运算。
- 旧producer和候选采用同一probe。每次入口在任何producer写入前运行native codec自检：已知失败位值和相邻值必须保持不同，并经真实serde_json编解码后逐位不变。
- 新矩阵`45900789028`最终success，0.9.8/0.9.9/0.9.10/0.9.11 × macOS/Windows共8格独立验证通过。64次candidate进程、32次committed-B进程、64次forced-B replay，事件/revision始终`2 / 2→2→2`，每scenario另有3次独立reopen保留检查。各格source/probe、旧payload、schema、逐位REAL、原始A/B WAL和archive manifest均核对。
- 原始DB ZIP未下载或独立重算哈希，仅核对归档存在、大小及报告/manifest。8格proof保存在忽略目录`current-producer-a416/formed-45900789028/verified-json-evidence.json`，其`matrixProofComplete=true`。
- 与6f54的源码对照：246个Rust manifest文件中245个blob相同；唯一不同`claude_local_runtime.rs`的`#[cfg(test)] mod tests`之前全部字节相同，仅新增测试。保留`ff55`为实际执行SHA，不把源码等价检查改记成6f54执行了矩阵。

### Gemini 实际发现合同：`d6c14da7`

- 仅添加 Rust/C# 测试，未改变生产行为。Rust 覆盖 `GEMINI_CLI_HOME` 是 base、空值回退 profile、display/reporter 同根、显式 sandbox tmp 独占且不追加后缀。
- C# 经真实 `SourceLocations.Resolve → MonitorCore.Seed → snapshot` 验证 JSONL/JSON：Windows 默认主目录11 output/1 request；显式 sandbox17/1；误选 `.gemini` 父目录读取0。macOS 保留双默认根28/2的既有合同。
- 源码与 diff 检查通过；原生运行以对应 SHA 云端结果为准，不将 CLI 参数接受测试当作实际会话发现通过。

### 整 App 测量视口与诊断：`665efddf`

- a416 的12个单轮均完成，但首个2k baseline 窗口1080×812、candidate1240×812；整轮严格配对 gate 拒绝。其余5对仅作为有边界的诊断，不能记为完整协议通过。
- 选取的三个原生 defaults 小文件显示首轮 `NSWindow Frame dashboard` 携带1024×737屏幕信息，小于 App 最小尺寸；后两轮没有该 key。这不是已确定的 SwiftUI 根因，只证明需要控制测量条件。
- 新协议 summary schema2、`fixed-native-frame-fully-visible-v2`：仅在 disposable Actions host/GUI guard 通过后选择已有的足够大 display mode，由 harness 持有并于 finally 恢复；每轮同样 seed1240×812原生 frame。首次 ready 即验证实际尺寸和完整 visibleFrame，之后每秒保留 x/y/width/height，异常样本先落盘再拒绝。不足模式返回 NOT_RUN，无额外 App 预跑。
- 120秒 warmup、120秒 measurement、三次双角色配对全部保留。每轮最后一次资源采样和统计完成后才运行非提权 `vmmap -summary`、`heap -s --noContent`；原始输出/hash/时间边界单独保存，工具不可用记 UNAVAILABLE，不改变资源采样结果。
- 24项 stdlib harness 测试、9项 workflow 检查和 vendor/diff 检查通过；独立源码审查发现的首个拒绝样本遗漏已修并加负控。没有在本机执行 display 切换、App 或原生编译。665云端whole-App已success，12轮/6配对独立复算通过；24份vmmap/heap字节/hash及诊断晚于最后metric边界已核对，具体测量见下文。
- 当前fixture只启用Claude采集，但没有seed `multiClient.displayScope.v1`，Dashboard默认仍为Codex页。因此会覆盖Claude importer/live monitor及空Codex轮询，不构成Claude/汇总图表、排名或跨range共享收益的测量。不可把“存在Claude数据且窗口可见”写成“Claude图表UI已测”。
- 单独切换scope也不足以证明图表已render：主页为LazyVStack，图表在`onAppear`准备数据；需要云端AX/scroll及图表矩形/可访问内容的共同gate，目前没有已验证的免额外权限路径。原fixture每请求100–116输入、无cache-read，达不到非空排行榜门槛；仅20会话、单模型、2–3个非空五分钟桶，且Claude-only的Codex attribution为空。后续活跃图表或非空榜单必须单列workload，不能悄悄改旧fixture或复用旧结果。
- display恢复目前记录API返回值，没有独立的恢复后几何读回；屏幕内窗口几何也不证明无遮挡截图内容。两项作为协议证据边界保留，不提升为已验收能力。

### 空源状态发布：`db16c1ee`

- 已确认Codex目录没有state DB或threads时，每秒正常重试会反复赋值相同的`@Published snapshot.status`，产生不必要观察者失效。
- 仅在`resetToLatestThread`的缺失源、空threads及读取失败三条分支比较状态后发布。读取和重试频率、generation检查与恢复行为不变。
- 两个新增测试分别覆盖真实缺失state DB的三次poll、以及`A,A,B,B,empty,empty,A`的七次loader调用；重复相同状态不发布，错误变化与恢复仍发布。fixture固定临时`sqlite_home`并关闭precise warmup，不读用户DB。
- 独立源码审核无阻断；14项test-execution gate、9项workflow Python及vendor/diff检查通过。原生执行以对应SHA云端结果为准，尚不能据此给出CPU降幅。

### 模型聚合确定性：`6f54a401`

- `d6c14da7`全量Swift的`testDefaultPreparationSharesClosedAttributionAndKeepsRetainedPriceAcrossRefresh`失败。22个prepared-data字段中只有`modelBreakdowns`不同：5个bucket中的3个仅模型顺序颠倒，记录multiset完全相同；成本仅有约`1e-15`的求和尾差。
- 根因是`combinedRows`直接输出字典遍历结果。生产侧现在按canonical model key排序外层行，组内首个raw model及pricing period原始身份、时间和顺序全部保留。
- 新增32次分组重建/输入排列检查，覆盖alias合并、nil、零用量过滤和非时间排序的period保真。新测试及原失败case均加入CI必执行清单；原快照/成本严格相等断言没有放宽。
- 独立源码审查无阻断，本机14+9项轻量检查及vendor/diff检查通过；6f54完整CI的2571项Swift通过、80项mandatory实际执行，原失败共享图表及新增模型排序case均通过；旧d6失败run仍记失败。

### 动效帧离场回收及 Claude 记录边界：`460fbff4`

- 默认未读动效实际 surface 为258×120 pt；Retina 2×时，98帧ripple按项目像素公式估计46.2964MiB，63帧shimmer约29.7620MiB。此前view退出只清本地引用，static NSCache仍可保留帧，已提交的后台render也可重新填入。这是源码所有权及预算证据，**不是已测footprint节省**。
- 新增锁保护的consumer lease。view实际请求render前注册，清理本地帧时释放；最后lease退出清共享cache，晚到的render仅在尚有consumer时入cache。其他consumer与新加入的single-flight请求继续复用，活动动效分辨率、帧数和generation规则不变。
- 四个新测试覆盖最后退出、共享使用者、离场后render完成及in-flight重新加入；CGDataProvider回调另检查图片实际backing storage释放。默认尺寸预算测试改用真实`FloatingTokenPanelMetrics.baseSize`。这还不是NSView/CALayer或进程footprint测量；仍attach但被遮挡/隐藏的view持有本地帧和lease的边界保留。
- 新增历史scanner的64KiB、1MiB、精确4MiB及4MiB+1边界测试，保留usage/cache lifetime、checkpoint、mtime重放不重复、前缀保全和同inode修复检查。live新增两种内容形状、两个参数化方法，经真实`FileTailer → ClaudeLineExtractor → ClaudeParser`检查跨chunk、跨append、LF前等待、后继行和restart更新。
- 这些是合成正确性边界：历史scanner的完整record含LF超过4MiB仍拒绝、checkpoint不推进，后继记录可能被阻塞；live为4MiB块、32MiB行。未改变生产上限或宣称复现原视频故障。现有whole-App fixture最大行仅305B；真实匿名统计只有文件尺寸，没有单行分布。
- 本机14项execution-gate、16项workflow Python检查、vendor offline check及diff检查通过；90个唯一mandatory Swift名称均能定位声明。云端完整CI为`45910021172`，新增XCTest及vendor四次参数化invocation仍待实际日志。独立缓存源码审核无阻断；没有本机编译。

### 暂停动效及媒体生命周期：`cac71d3b`、`f2a48b8f`

- 未读ripple/shimmer仍挂在窗口但收到inactive时，先取消render并停止CA动画，再清本地帧组和consumer lease；保留原有单帧poster与边框。恢复时按既有generation重新render；detach仍清poster。新增3项原生生命周期测试检查attach暂停/恢复、poster身份及其他使用者继续动画。
- 邀请视频此前每次构造SwiftUI View值都会先构造`AVPlayer`，poster还在body重复读取。现在由lazy `StateObject`媒体owner持有一次player/poster；未挂载值不分配、同identity父层更新复用、移除释放、重新挂载重建。新增2项实际NSHostingView生命周期测试；播放策略、静音、可见性、Reduce Motion及low-power行为保持。
- Windows新增真实`FileTailer → ClaudeLineReader → ClaudeParser`合成测试：普通长字符串/嵌套tool_result、跨1MiB块的4MiB+257记录、4MiB+1分次追加、完整JSON无LF仍等待、后继短行和重放不重复。仅保留长度与响应元数据；精确成功marker须从云端日志核实。
- 本机14项execution-gate、16项workflow Python、vendor offline及diff检查通过；95个唯一mandatory XCTest名称均能定位。focused Claude路径另外强制5个历史scanner case，filter补上`ClaudeRecordBoundaryTests`。
- `460fbff4`云端Swift在编译vendor边界测试时，`#expect(allSatisfy(\.isCompletion))`宏展开报告未处理throw；尚无XCTest或vendor执行。`f2a48b8f`只将该谓词改为显式closure并同步vendor hash，等待云端重验。不能把源码复核或静态帧预算写成已测节省。

### Claude 历史记录有界续读：`267aa5e8`

- 只在Claude首个4MiB读窗完全没有LF时继续同一个记录；每次仍经现有共享broker读取最多4MiB，到首个LF即停止，后继记录下一轮处理。普通批次及其他客户端4MiB规则不变。
- 完整记录含LF上限为16MiB，沿用现有parser输入上限；低于上限但没有LF继续等待，达到上限无LF或超限仍诊断并保留旧账/断点。16–32MiB仍不覆盖，未采用live的丢弃超限行策略。
- extended路径在读取前后，以及解析/前缀校验后、持久化前，比较已打开句柄与命名路径的身份、尺寸和change/mtime witness。原parser/normalizer、事件ID、TTL、namespace、schema、checkpoint prefix和同事务写入保持；没有新增元数据投影，也没有声称解决Foundation单行DOM峰值。
- Swift 11项历史scanner测试、Rust 6项方法覆盖64KiB/1MiB/精确4MiB/4MiB+1/精确16MiB、16MiB+1拒绝、到cap无LF、分次追加/重建、无usage大行、后继记录、完整payload/计数/TTL/时间/ID、revision与checkpoint重放保全；Gemini/DeepSeek为4MiB负控。Rust Desktop fixture先提交短分类头，明确不突破现有64KiB文件分类边界。
- full CI新增强制101个唯一XCTest与84个Rust方法；focused路径分别强制11/6项。14项execution-gate、16项workflow Python、vendor及diff检查通过；独立生产与测试源码复核无阻断。原生编译/执行尚待新SHA云端结果，读取期间rotation的witness行为仍无新增动态测试证明。

### 空日账本的延迟分配：`683d0493`

- `DayLedger`的两条90,000元素Double数组先保持为空，仅在第一个有正重叠的有效测量区间到来时分配原有密集数组。计数、cost、unfinalized、valid output和duration仍先更新；分配后逐桶分配、减法、clamp、缓存和Array值语义保持，删除最后一条记录后仍保留原buffer至换日或teardown。
- 空账本的peak查询直接缓存零，避免首次90,000桶扫描；未改变Double精度、25小时容量、时间分桶、schema或采集频率。
- 665 heap的四个704KiB分配与两个monitor/session、Double总量高度一致，结合fixture支持空Codex与有数据Claude各一账本的解释；没有地址级所有权图。单个空账本可避免1,440,000B元素载荷，分配类别推算约1,441,792B；这是上界算术，**不是实测footprint节省，更不是减半**。
- 新增7项原生测试，检查零分配、首个分配、精确totals/average/peak及时间、替换/删除与fresh ledger对照、subset cache扫描、Array copy和25小时/非整秒边界。全部加入正常CI的108项required；独立源码与算术审查、14项execution-gate、16项workflow Python及vendor/diff检查通过，尚待云端原生执行。

### 空去重表与价格别名索引：`03ee0bac`（待新 SHA 云端验收）

- `Deduper` 的精确键 `owners` 表从初始化时预留改为第一次 exact claim 时预留；`contains`、`isOwnedByOtherFile`、hashed history 模式和原有 FIFO/容量语义不变。新增 7 个 XCTest 回归覆盖空实例、首次分配、65,536 边界、容量夹紧、值复制隔离与 hashed 分离。
- Swift 多客户端账本的 exact bundled price alias 表由复制完整 `PriceModel` 改为保存不可变 bundled catalog 的模型索引；同 ID 重复 alias 保留首个索引，跨 ID 冲突继续 `ambiguous`，计费结果和原始账本字段不变。新增全量 alias 独立分组及冲突/重复 ID 测试。
- 这两项是局部存储优化，最大静态分配估计仍只有 Deduper 空表约 180,224B 与价格字典原分配上限约 180,224B，不能替代整 App 减半验收。`Vendor/AgentSpeed/UPSTREAM.json` 已记录精确 patch/addition hashes；编译、原生测试及新整 App 测量必须在后续 SHA 通过 cloud workflow 后才可记为接受。

### 共享每日上限测试午夜fixture：`f59bc14f`

- f2的唯一失败case实际在2026-11-27 00:00:43 UTC执行，测试传入当天00:00的dayStart，却将已占用请求时间设为`now-60`，即前一天23:59:43。生产按`claimedAt >= dayStart`计入当日预算，因此允许新一天请求符合现有合同；并非已证明的生产每日上限故障。
- 仅将该fixture的预置claim改为`now`，保留原七项失败涉及的全部断言。新增固定`dayStart=86400, now=86443`回归：前日86383的claim不占当日预算、当日首次允许、另一个owner再次请求被拒绝，且拒绝前后账本逐字节相同。
- 旧失败case及新回归均加入正常CI强制实际通过清单，Swift共110项，Claude focused仍11项、Rust84/6不变。14项execution-gate、16项workflow Python、YAML/声明/vendor/diff检查与独立源码复核通过；未在本机运行Swift或原生测试。旧controller case仍依赖wall clock，setup与触发恰好跨日的极窄原有边界保留；固定coordinator回归独立于实时时钟和时区。

### 测量结束后的可选引用树：`b858e2b9`

- 新增默认关闭的 `retained_graph` dispatch input 与 `--retained-graph` 参数。启用时，在最后一条资源采样和统计完成之后、已有 vmmap/heap 之后运行 `leaks --noContent --nostacks --groupByType --referenceTree`；不改变 App 环境、fixture、配对顺序、120秒 warmup 或120秒 measurement。
- 保留原始文本、字节数、SHA256、返回码和采集时间边界；工具退出0或1表示扫描完成，1另外记录工具发现leaks。超时/错误仅为补充证据UNAVAILABLE，不据此更改已完成的资源结果。
- 引用树只为每个allocation猜测一个parent，不代表所有保留路径，也不把工具扫描完成当作“没有泄漏”或实测内存节省。尚未取得当前候选的云端引用树，不能据此选择新的架构改动。
- 28项whole-App harness、14项execution-gate、9项backfill workflow、7项formed workflow及vendor/diff轻量检查通过；独立复核确认Bash 3.2关闭开关时始终非空的参数数组可用。没有在本机运行诊断附加、App、display操作或原生编译。

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
| `45894177094` | `a41657c5`；正式App与Rust聚合资源配对 | whole-App最终failure：12单轮完成，首对窗口不同；其余5对诊断已独立复算，见下文；聚合已独立复核 |
| `45895264009` | `a60544fa` vs `f9e91791`；release speed engine 配对 | 独立复验35项语义比较通过，见下表 |
| `45895269055` | `a60544fa`；正式App与Rust聚合资源配对 | whole-App最终failure：12单轮完成，首对窗口不同；其余5对诊断已独立复算，20k CPU下降36.31%、footprint下降12.72%；聚合已独立复核 |
| `45895140604` | `a60544fa`；完整回归 | 已全部成功，覆盖前端、Swift、双平台 native、Windows updater 与证据检查 |
| `45896583064` | `1d2d980c`；增强的0.9.8–0.9.11 Rust producer × macOS/Windows | 6格通过、0.9.10mac证据精度失败；root保留证据后取消仅余的queued 0.9.11mac以释放新矩阵，非8格通过 |
| `45897009933` | `077d5dc3`；公开0.9.7实际升级 | 双平台成功；Swift8项升级+119项支持回归、Windows3项importer+19种manifest场景，均核对小日志 |
| `45897628817` | `4410b16b` vs `f9e91791`；release speed engine 配对 | 已独立复验成功，见下表 |
| `45897628497` | `4410b16b`；完整回归 | 最终success，exact checked-source/evidence gate PASS；Swift2562通过/38跳过、macOS1878/14忽略、Windows1820/15忽略；全部0失败，required76/78/78均实际通过 |
| `45898313857` | `4410b16b`；正式App与Rust聚合配对 | whole-App最终failure：12单轮通过，首个2k配对宽度不同；其余5对独立复算仅诊断，20k CPU下降34.71%、footprint下降12.01%；聚合success且独立复算 |
| `45899772826` | `dbb2d5cb`；完整回归 | pending后已取消、没有job，不作为执行证据；未由本任务取消 |
| `45899772743` | `dbb2d5cb`；公开0.9.7升级 | 双平台success；Swift8项实际升级+120项支持回归、fixture前后byte-identical和exit86恢复证明；Windows3项importer+19种manifest+27PASS均独立核对 |
| `45900619404` | `ff55ace1`；完整回归 | 最终cancelled、jobs=[]，没有执行证据，后续由d6回归覆盖 |
| `45900619154` | `ff55ace1`；公开0.9.7升级 | 最终cancelled、jobs=[]，没有执行证据 |
| `45900789028` | `ff55ace1`；REAL codec自检及四版本×双平台增强矩阵 | 最终success、8/8格独立核验PASS；64candidate/32committed-B进程及64forced-B replay，逐位REAL与事件/revision保全；`formed_only=true`，不是完整CI |
| `45900792974` | `ff55ace1`；正式App与Rust聚合配对 | whole-App最终failure：12单轮通过、首2k配对窗口不同；其余5对独立复算仅诊断，20k CPU下降40.33%、footprint下降6.72%；聚合24cases、336checksums、48oracle+48paired均独立复验 |
| `45902475385` | `d6c14da7`；完整回归 | 最终failure；Swift2567通过/1失败/38跳过，Swift Testing698/80suites通过；新增6个内存case中5通过、共享图表case失败；Windows1822通过/15忽略、macOS1880通过/14忽略，均78required与新2个Gemini测试通过；16production checks、双负控及18个log hashes核实；Swift失败后的release-script contracts未执行，checked-source gate亦FAIL |
| `45902475222` | `d6c14da7`；公开0.9.7升级 | 双平台success且独立验收闭合：Swift8实际升级+120支持、fixture字节保全/accounting/exit86恢复，Windows3importer+19去重manifest+27PASS |
| `45903736199` | `665efddf`；v2完整视口与独立内存诊断 | whole-App最终success（23:50:56Z），12单轮/6配对独立复算PASS，2907条bootstrap/warmup/measure几何记录均1240×812且完整在屏幕内；20k CPU下降39.53%、footprint下降6.77%；24份诊断hash/时序已核；ledger job success但未复算新aggregate |
| `45903736269` | `665efddf`；完整回归 | pending后被取代、cancelled且jobs=[]，没有执行证据；不能复用d6结果 |
| `45905527470` | `db16c1ee`；完整回归 | 最终success且独立核验闭合：Swift2570通过/38跳过、78required及两项空源发布case实际通过；vendor698/80suites、release scripts112/0/1skip；Windows1822/0/15ignored、macOS1880/0/14ignored，各78required与16production checks、保全负控/hash均核实；真实helper IPC1通过且schema1+2标记齐全，frontend1501/cloud scripts18及updater通过 |
| `45905527709` | `db16c1ee`；公开0.9.7升级 | 最终success，Swift8实际升级+120支持、fixture字节保全/accounting/exit86恢复；Windows3importer/19唯一manifest/27PASS均独立核验 |
| `45906455848` | `6f54a401`；完整回归 | 最终success且exact-source执行/seal独立闭合：Swift2571/0/38、80required；vendor698/80suites、release scripts112/0/1skip；Windows1822/0/15、macOS1880/0/14，各78required、16production checks及双负控/hash；frontend1501/cloud18/updater通过 |
| `45906455801` | `6f54a401`；公开0.9.7升级 | 最终success且独立核验：Swift8实际升级+120支持、fixture字节保全/accounting/exit86恢复；Windows3importer/19唯一manifest/27PASS；不外推为完整CI |
| `45906789715` | `6f54a401`；v2完整视口与空源发布修复后的整App配对 | 整组NOT_RUN：`local calendar day changed during run`；10单轮通过，20k第2对candidate在午夜前、baseline在午夜后，排除后仅4个同日诊断对，不是12轮/6对接受通过；20份诊断hash/时序及2422条几何记录核对，恢复API返回0 |
| `45910021172` | `460fbff4`；完整回归 | Swift编译失败：vendor `#expect(allSatisfy(keyPath))`宏展开报throw，XCTest/vendor均未执行；前端/cloud脚本及updater成功；macOS1880/0/14及Windows1822/0/15，两端78required、16production checks及双负控/hash已独立闭合；整体仍FAIL |
| `45912095794` | `cac71d3b`；完整回归 | pending被后续修复push自动取代，最终cancelled、jobs=[]、artifacts=0；无执行证明 |
| `45912504640` | `f2a48b8f`；完整回归 | 最终FAIL独立闭合：Swift2584通过/1失败/38跳过，唯一失败为午夜daily-limit fixture的7条断言，95required均实际通过；vendor700tests/81suites及四次两shape大记录invocation通过；release scripts因Swift退出1未运行；macOS1880/0/14及Windows1822/0/15、两端78required/16production checks/双负控/hash闭合，Windows真实helper IPC1通过、C#两shape两边界marker已核，frontend1501/cloud18及updater通过 |
| `45913791756` | `267aa5e8`；完整回归 | 最终success且独立闭合：Swift2591/0/38，101mandatory及11focused逐案通过；vendor700tests/81suites及四次两shape调用；macOS1886/0/14、Windows1828/0/15，两端84mandatory/6focused、16production checks、双负控及原始hash；Windows IPC1通过，frontend1501/cloud18、release112通过/1既有skip及updater均通过；checked-source/evidence gate PASS |
| `45913791600` | `267aa5e8`；公开0.9.7升级 | 最终success且独立闭合：Swift8实际升级+120支持、fixture字节保全/accounting/exit86恢复；Windows3importer/19唯一manifest/27PASS；不外推为完整CI |
| `45916052825` | `f59bc14f`；空日账本数组及午夜fixture后的完整回归 | 2026-11-27T00:39:25Z source实际启动，原生/前端/Swift在00:39:30–32Z启动，in_progress；正常Swift110required、Claude focused11、Rust84/6，结果须按此SHA独立验证 |
| `45916052402` | `f59bc14f`；公开0.9.7升级 | 最终success且按exact source独立闭合：Swift8实际升级+120支持、fixture字节保全/accounting/exit86恢复；Windows3importer/19唯一manifest/27PASS；不外推为完整CI |

最新速度引擎局部数据（`45897628817`，每case三轮中位数；CPU为200-tick loop总量，RSS为endpoint resident memory；不是整App或physical footprint）：

| Fixture | CPU降幅 | 候选endpoint RSS | RSS降幅 |
| --- | ---: | ---: | ---: |
| 2k/day | 76.46% | 27.328 MiB | 4.06% |
| 2k/dense | 85.39% | 27.344 MiB | 6.37% |
| 20k/day | 96.00% | 33.203 MiB | 18.08% |
| 20k/dense | 90.88% | 33.516 MiB | 33.43% |

局部生产聚合已复核到 `a60544fa`：12k cold每次 CPU `1296.093→192.794ms`（下降85.13%），lifetime peak RSS `49.953→49.141 MiB`（下降1.63%）；24 cases、336次checksum、48项独立算术oracle及48项paired语义检查通过。只用HTTP206取74份小报告约981KB，完整945MB artifact、二进制及SQLite seed bytes未下载；不宣称完整binary/seed provenance复验。详见忽略目录 `scratch/performance-compatibility-20261127/current-resource-review/REVIEW.md`。

整 App 的 a416 已完成但未通过整轮配对。原始 telemetry 已独立复算：20k 三对中位 measured CPU `0.212271044→0.115449353秒`（下降45.61%），按实际时间归一的单核 CPU% `0.175447→0.096177`（下降45.18%）；physical footprint `118.127930→109.221619 MiB`（下降7.54%），RSS `223.328125→213.921875 MiB`（下降4.21%）。2k仅2个等尺寸对，中位 CPU下降17.63%、footprint下降0.072%。这些视口没有完整屏幕内可见性证明、绝对CPU负载很低，且只代表静态单Claude主进程，不能外推当前源码、活跃流式或整体进程族；完整binary/SQLite/state bytes未复核。

a605同样因首个2k配对1080×812与1240×812而整轮失败；12个单轮完成，其余5对仅作诊断。20k三对中位 measured CPU `0.192394384→0.122531335秒`（下降36.31%），按实际时间归一单核CPU% `0.160267→0.102050`（下降36.33%）；physical footprint `117.190430→102.284180 MiB`（下降12.72%），RSS `222.343750→207.531250 MiB`（下降6.66%）。20k三个CPU ratio均大于0.5；2k两个有效对CPU下降20.67%、footprint下降1.80%。已从29份小报告及原始JSONL约191KB独立复算，完整binary/SQLite/state bytes未下载。不同run的绝对idle CPU很低，不能将a416与a605百分比之差视作精确回归。

4410整App也完成12单轮，因同一首2k窗口不一致而整轮失败。其余5对已逐JSONL独立复算：20k三对CPU `0.207942384→0.135767030秒`（下降34.71%，时间归一34.71%），physical footprint `116.706055→102.690430MiB`（下降12.01%），RSS `222.218750→207.078125MiB`（下降6.81%）；2k两对CPU下降7.33%（时间归一7.59%）、footprint下降1.58%。没有有效pair的CPU或内存ratio达到0.5。29份小报告共190,774B，实际binary/DB/state bytes未下载；不是完整协议或当前6f54验收。

4410生产聚合也已独立复算：12k cold CPU `1349.558333→214.987333ms`（下降84.07%），peak RSS `50.250→49.563MiB`；小负载cache-hit `0.08528→0.09268ms`（增加8.68%），不能只报告有利case。24cases/336checksums/48独立算术oracle/48paired语义检查均通过，约981KB小报告被读取，945MB包及binary/seed bytes未下载。

ff55生产聚合已独立复算到24cases/336checksums/48oracle/48paired全部通过。1200 cold CPU `108.298667→16.808667ms`（下降84.48%）；12000 cold `1268.401→186.188ms`（下降85.32%）、peak RSS `50.313→49.406MiB`。1200 cache-hit `0.09716→0.10936ms`（增加12.56%），12000 cache-hit `0.10380→0.09008ms`（下降13.22%）。这是局部聚合测量，没有整App或physical footprint验收，也未从完整binary/SQLite原始字节复验其哈希。

ff55整App同样完成12单轮，首个2k baseline1080×812、candidate1240×812导致整轮配对gate失败。剩余五对仅诊断：20k三对CPU中位`0.228177615→0.136158177秒`（下降40.3280%，时间归一40.6979%），footprint`108.518494→101.221680MiB`（下降6.7240%），RSS`222.625→205.59375MiB`（下降7.6502%）。20k三对CPU ratio为0.664205/0.600950/0.566643，均未减半；2k两个有效对CPU下降3.9669%、footprint下降1.7864%。29份小报告及12条原始telemetry独立复算，累计读取190,535B；binary/DB/state字节未下载。不同run的低绝对idle CPU不用于推断精确跨run回归。

665 v2是首次通过整轮配对的whole-App结果：12单轮/6配对全部PASS，三次双角色、每轮120秒warmup+120秒measurement原样保留。独立复算原始metrics的CPU/phase/PID/birth/UUID、fixture账本算术、2907条可见几何记录，以及24份vmmap/heap字节/hash与严格晚于最终metric的时序均通过。20k三轮中位CPU `0.230191395→0.139194346秒`（下降39.53%；时间归一单核占用 `0.191655%→0.115065%`，下降39.96%），footprint `113,707,968→106,007,552 B`（下降6.77%），RSS `234,045,440→215,433,216 B`（下降7.95%）；2k CPU `0.136512537→0.120758765秒`（下降11.54%），footprint `90,983,424→88,919,040 B`（下降2.27%），RSS `202,424,320→198,443,008 B`（下降1.97%）。结果不满足减半，且仍受默认Codex页/实际内容未观测边界限制。完整binary/DB/state字节未下载；逐行复算记录在忽略目录 `current-resource-review/665-whole-app-small-recomputed.json`。

首对2k诊断中heap已分配 `52,088,830→49,301,492 B`；20k首对候选保留20,000个`ResponseStorage`共4,480,000 B，response字典2,113,536 B，baseline完整record字典15,679,488 B。两角色各15个Double数组合计2,884,288 B；首对2k的IOSurface 6,400 KiB和SQLite pagecache 64 KiB均未减少。类别说明固定分配与响应副本仍值得检查，但单一诊断不是可加总的因果节省，也不把类别名推断为确切分配调用栈。

4410/ff55已按原协议结束；665已按新视口协议完整结束，6f54已因跨本地日结束为NOT_RUN。每轮120秒warmup+120秒measurement，12轮最低48分钟加startup、诊断、归档和构建，不混合新旧绝对值。

所有现有whole-App seed均仅设置旧`agentSpeedReporting.invitationShown.v1`，未设置邀请实际使用的`product.newFeatures.localClientsSpeed.v1`。源码允许邀请创建`SpeedLeaderboardMovie`/AVPlayer，但没有观察实际画面或播放状态，因此既不能保证仪表盘无遮挡，也不能断言视频实际播放。几何可见gate不等同于UI内容gate。若后续加入明确scope/邀请状态或实际图表验证，必须独立命名新workload，不能覆盖本轮结果或静默改协议。

调度记录：`45896457825` 曾误填不存在的 candidate SHA，属于调度输入错误，已用 `git rev-parse HEAD` 的精确值重发为 `45896583064`。错误 run 不作为产品回归或性能验收证据。

DB baseline 单独采用 `3eadadc6`，因为 `f9e91791` 的现有 Rust 测试编译错误在该提交修复；两者的聚合生产源码、canonical SQL、价格表和 Cargo 清单/锁文件逐字相同。Whole-app/speed baseline 仍为 `f9e91791`。

本机轻量检查：vendor offline check；18 个 vendor Python 控制、12 个 speed Python 控制；Python AST、workflow YAML、bash 语法和 `git diff --check`。这些不代替 Swift/Rust 编译或整 App 验收。

此前源码执行formed probe17项、formed workflow7项Python测试；665 whole-app harness24项、workflow9项全部通过，vendor check及diff检查通过。REAL codec新矩阵8格均已实际通过；d6的6个新增Swift内存case有5通过、1失败，6f54完整云端回归已通过且原失败case闭合。f2的新增生命周期及vendor边界case已实际通过，整套仍因另一午夜fixture失败；后续SHA继续独立验收。

6f54的whole-App跨日拒绝保留，不以部分完成的20k双pair中位数替代整组结果。按当前fixture回溯70分钟的规则，下一次实际fixture步骤须在runner本地日01:10后开始；本次观察时区为UTC，即2026-11-27 01:10 UTC / 上海09:10后。日末另需至少48分钟纯采样及启动、诊断和清理。dispatch/build的开始时间不等于fixture开始时间；基线、workload和原采样时长保持。

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
- Claude 历史Swift/Rust的JSONL完整record含LF上限在267aa5e8源码扩展至16MiB，原4MiB normal batch保留；267完整CI的两端边界测试已实际通过。超过16MiB会保留断点并阻塞后继行，不能把它描述为与live的32MiB内容上限一致。macOS live读取块4MiB；Windows普通文件live读取块1MiB、注入backend的请求上限4MiB。历史文件最初64KiB内没有完整entrypoint-bearing行时，还存在Desktop分类不完整的独立边界。新源码及合成测试不代表解决16–32MiB或Desktop分类上限，原视频漏计的已确认根因仍为隔离账号目录未覆盖。
- 已用源码和纯Python合成反例进一步分清Desktop分类缺口：无短header且首条含LF恰为65,537B时回退CLI；显式Desktop usage被拒绝而漏计，后继省略entrypoint的usage才可能误归CLI。现有Swift大记录fixture固定CLI显式path、Rust Desktop fixture先写短header，不能证明此反例已兼容。修复还需处理Swift总64MiB分类预算的公平进度、线性delimiter扫描、旧EOF checkpoint契约迁移，以及events无source provenance时旧CLI错账的保全；直接扩常量或replay可能造成漏扫/跨namespace双计。调查文件为忽略目录 `current-resource-review/claude-classifier-boundary-investigation.md`；没有读取真实transcript或声明受影响规模，尚未修改生产分类行为。
- 现有 checkpoint 只有 source 最终游标，revision 只有规范化 payload 和捕获时间，无法证明旧 CLI 隐式条目的文件或字节范围。后续分类修复应先保全旧账并把冲突重放放入 pending；若要正式激活可逆跨 namespace 归属，需要带 source generation/range 的 observations、append-only attribution action、统一 effective-events CTE、action generation cache stamp，并将改变数字的读写格式升级为 schema 3 使旧 reader fail-closed。候选设计见忽略目录 `current-resource-review/claude-attribution-provenance-options.md`，当前未改 schema 或历史数据。
- quota 来自各客户端自己的本地观测与 freshness 规则，不因路径同属一个账号目录就获得当前登录账号绑定证明。
- schema 2 接受必需字段集合的兼容扩展；显式列名解决 nullable 追加列写入。新增 NOT NULL/无默认值列、任意新约束及未知 JSON 键的重编码无损性不在此保证内。未来影响写入或用量语义的格式应增加 schema version，使旧程序拒绝，而不能仅追加字段后假设旧程序能无损写回。
- Swift/Rust checkpoint key 和部分 continuation 表示不同，切换实现可能重扫；不能承诺直接沿用另一实现的 cursor。事件与 checkpoint 仍同事务提交，重扫依赖稳定事件身份去重。
- whole-app harness只测主进程、静态Claude单源后台采集及默认Codex dashboard，不覆盖Claude/汇总图表UI、helper总CPU、hidden/sidebar、切图retention、多Home、live replay、带账号quota或Windows整App。v2另增加完整屏幕内视口gate；无GUI或ready/ledger/window gate不通过记为NOT_RUN，不降级成局部测试冒充通过。

目标继续保持 active；已接受的665整App配对尚未达到CPU或内存减半，不能用局部引擎降幅、估计分配节省或其他SHA的结果代替当前整App验收。
