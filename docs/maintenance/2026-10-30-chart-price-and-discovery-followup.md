# 选区对应、共享价表、目录发现与图表引导

> 2026-10-31 实机纠正：build985 仍存在“框选最后一格导致整段金额跳涨”。此前测试及交付记录没有覆盖这个数据截止时间分叉，不能作为该故障已修复的证据。后续证据与修复见 `2026-10-31-last-bucket-price-jump.md`。

## 范围

用户要求：图表卡片删除“本机折算/差额”；全面核对顶部气泡、底部选区与详情的字段/时间/来源；核对其他客户端目录自适应；当前价共用Agent Speed价表，旧记录沿用历史价；“图表怎么用”除收起外增加持久关闭和设置恢复入口。先改跨平台并提供真实组件预览，再同步原生，集中测试；本轮尚未安装这些新改动。

## 已核查事实

- 当前唯一共享价表为`Vendor/AgentSpeed/spec/assets/prices.json`，schema 1 / version 3 / updated 2026-10-28，194个模型。Swift从它生成`BundledPriceAssets.swift`，TS直接导入，Rust直接嵌入。原Codex事件历史价另由`standard-api-price-history.json`保存，不能用当前价覆盖。
- 上游最新检查提交`d3dca1ed16c66c4c687bc8be7943b77219c64758`：197个模型。与本地相比增加3个MiMo 2.6型号，GPT-6.1 Terra只有说明文字变化；Claude及DeepSeek价格和本地一致。SDK核心继续固定`a94a67fcc78e5d8eea5f82d8d5e737bccf994e2c`，不为同步价表引入数百个解析/协议提交。
- Claude价格已与[官方价表](https://platform.claude.com/docs/en/about-claude/pricing)核对。DeepSeek已与[官方价表](https://api-docs.deepseek.com/quick_start/pricing/)核对，包含工作日UTC高峰、非高峰及节假日差异。
- 一部分“价格未知”并非价表缺项：双端多客户端计价入口主动拒绝有period/offPeak的模型，且未传入事件时间，所以DeepSeek被排除；Claude缓存写入5分钟/1小时价不同，规范事件未保存寿命分类，不能仅凭总写入数精确算出历史费用。应补证据接入及清楚的未知原因，不能强行假定TTL。
- 选区固定后，TS顶部与底部已接同一个`consumptionSelection`；Mac在983已修复固定点击误用汇总费用。顶部缺额度下降/反推额度等底部字段，底部缺Token/请求等顶部字段。进一步追到实现后确认：共享归因中的下降也来自`selection.sevenDay`，不能误称为另一套下降计算。实际需要区分完整选区和用于反推的同周期可比区间；可比金额与本段总金额并不必然相同，“账号实降”若没有同时展示观测区间就容易误解。顶部可被独立关闭；固定后`shouldReopenPreviewOnHoverMove`始终返回false，底部缺显式恢复对应气泡的入口。
- 自动发现已有当前用户home、`CLAUDE_CONFIG_DIR`及手动路径；Claude CLI/Desktop共用projects目录并按日志来源分类。DSH、Gemini、OpenCode分别识别对应环境变量。GUI不天然继承终端临时环境变量；当前多客户端发现还拒绝符号链接根目录，这与Codex近次放宽合法根链接的行为不完全一致。仍需核对双端、默认/手动路径和实时SDK的根目录是否一致；不能先宣称完全自适应。

## 进行中的实现/验证

- 已修改双端引导：新增独立×、隐藏状态单独持久化、设置中“重新显示引导”。保留原有收起/重播行为，关闭时卸载动画并断开可见性观察器。关闭→重启/重挂载→恢复、展开时关闭的观察器清理前端回归已通过；原生源文件语法检查通过，完整编译尚待集中验证。真实组件预览截图位于`scratch/20261030-price-and-chart-audit/guide-close-preview.png`，为2026-10-30 10:18本地快照的跨平台渲染；不是当前本机原生界面。
- 双端主图下方卡片已去掉“本机折算/差额”及对应辅助功能内容；计算/原始数据和独立的详细归因尚保留。相关22项前端定向回归通过。原生“自动发现”原为280px居中且带额外内边距，已改为与跨平台一致的靠左紧凑文字行；尚未装入正式版。
- 跨平台新增`selectionAnchors.ts`，存起止Unix时间而非滚动数组下标，按精确时间二分重定位，范围过期或桶宽改变不钳制到无关点。已接到真实图表状态与点击/关闭路径；新回归和原图表DOM共17项通过、TypeScript通过。Mac已有`RecentChartSelectionTimeAnchor`及`restoreConsumptionSelection`保护，保留复用，不再另写一套。已补完整React组件的同长度滚动刷新、失效提示及旧时间段不复活回归。
- 余项：字段矩阵和统一选区展示；当前/历史计价证据接入；目录发现兼容性修复与双端用例；真实组件预览；集中Swift/Rust/TS/UI回归。

## 上一候选的独立记录

984已于2026-10-30 21:46替换983并启动，源码`50e52fbdc55a53699dbdfef7807818b46a5df41b`。完整CI[41063389522](https://github.com/hututuo/codex-token-bar/actions/runs/41063389522)通过，Swift2191项、28跳过、零失败；双端数据库/前端/更新器检查均通过。候选构建[41063450801](https://github.com/hututuo/codex-token-bar/actions/runs/41063450801)双端现均成功，Windows未替换EXE。二进制SHA256`63670a295ab98409c3426794640b3adda1de6e0e053afb7e88b8560deaa7024f`，启动进程17476。

回滚目录`~/Library/Application Support/CodexTokenBar-InstallBackups/20261030-214638-build983-before984`；启动前576个历史分区、528382事件、85710961852 Token一致，4093条正文测速、1367汇总桶、84145旧活动速率、482活动桶及客户端记录均无缺失/改变。984只包含任务独立合计等既有修复，不包含本文新改动。侧栏实际圆环视觉验收因用户正在操作界面尚未完成，不将代码/启动核对冒称整体验收。983实际固定右边界曾显示$15.9、API整期等值约$423；未完成同一静态数据下物理hover→固定→重选全流程。普通滚动执行后进程保持；macOS27特殊AXScrollToTop/Bottom崩溃仍未解决，继续避用该辅助功能动作。


## 本批收尾（源码，未替换）

### 选区对应策略

| 字段 | 气泡 | 下方卡片 | 来源 |
| --- | --- | --- | --- |
| 起止时间、金额、命中率 | 显示 | 显示 | 同一个选区对象；聚合图的Codex额度选区明确标Codex |
| Token、请求数 | 显示 | 补齐 | 完整选区的用量 |
| 5h/7d反推采用的时间段 | 补齐 | 补齐 | 实际同周期可比区间，不能拿完整选区范围代替 |
| 反推分子、额度下降和结果 | 补齐 | 补齐 | 保存计算实际使用的comparisonCostUSD，不从结果倒推分子 |
| 本机折算、差额 | 无 | 移除 | 历史归因计算/数据和原生独立明细仍保留 |

上下两处共用可比区间呈现组件；Mac的辅助功能值也包含这些字段。下方增加“显示区间气泡”，只恢复对应预览，不改选区、起止点和关闭状态代际。跨平台选区过期时清空并提示，避免数据重新出现后旧选择自动复活。

生产计算夹具用完整金额201、可比金额51.48和下降12%，验证反推429且展示分子51.48而非201；这是明确的测试夹具，不是真实账单。真实组件的只读快照交互验证了关闭顶部仍保留下方、点击恢复原选区，截图selection-correspondence-preview.png；该快照选择到的跨周期段没有足够可比用量，没有强行制造反推金额。

### 价格表

继续只用Vendor/AgentSpeed/spec/assets/prices.json；没有升级SDK核心和复制第二份当前价表。上游最新核对版d3dca1ed的Claude/DeepSeek数值与当前内置表相同；新增的三个MiMo条目不混入此次SDK升级。原Codex历史standard-api-price-history.json和冻结账本不改。

补上此前读取遗漏：双端每条用量的事件时间传入共享价格规则，按periods、UTC峰/谷、周末和节假日计价；以前把所有有时间规则的模型直接留作未计价。参考价展示也按相同事件/当前时间规则，显式Fast独立处理。DeepSeek无独立缓存写入收费项时，缺写入计数不会再无故阻止唯一可确定的费用；Claude缺少5m/1h写入分类时仍保留未计价，不猜测TTL。

官方核对来源：[Claude定价](https://platform.claude.com/docs/en/about-claude/pricing)、[DeepSeek定价](https://api-docs.deepseek.com/quick_start/pricing/)、[Agent Speed源码](https://github.com/zoefix/agent-speed)。研究仅访问公开文档，没有向Anthropic服务发起认证/推理/额度请求。

### 自动发现与目录

主页Mac旧DataSourceBadge为280px默认居中并带图标/额外padding；改成leading紧凑文字行，与跨平台已有左对齐一致。浏览器DOM实测数据源按钮与所在Codex区域均为x=150、padding=0、text-align=left。header-alignment-reference.png是只读快照的跨平台参考，不能称为已替换后的Mac截图。

目录仍以当前用户home、进程环境变量和设置覆盖为基础：Claude使用CLAUDE_CONFIG_DIR/projects；DSH使用DSH_HOME/sessions；Gemini使用GEMINI_CLI_HOME下标准tmp路径；OpenCode使用OPENCODE_DATA_DIR/XDG_DATA_HOME或标准目录。手动目录保留；GUI不能自动继承终端里临时export的变量。Mac仅放宽已选中的有效目录根链接，以物理根枚举、逻辑路径保留checkpoint身份，仍跳过内部链接；Windows原有read_dir已能进入指定根链接，新增同等夹具回归。未扩大到任意目录递归，也不更改现有数据源路径。

Claude CLI/Desktop默认共用projects并按entrypoint区分；如用户给二者配置互相冲突的独立目录，当前单个本地实时监视器会明确报冲突，不能宣称所有特殊配置均无差别支持。Claude订阅额度仍从独立本地缓存读取，不因本次目录修复增加联网行为。

### 验证记录

- TypeScript检查通过；图表/引导/时间锚点定向71项通过；完整React滚动刷新和参考价等定向18项通过（有重叠，不叠加计数）。
- Rust实际生产计价与SQL查询源代码的小型编译夹具3/3通过，含UTC边界、周末、节假日、历史阶段、未计价保留和不修改查询源记录；这不替代全量Rust测试。
- 所改Swift及测试源文件语法检查通过；全量Swift/Rust/前端交由冻结提交的云端CI，结果另附。
- 新增设置无额外计时器；关闭引导时移除动效观察，价格查询不加网络。原始JSONL、两个业务库、历史价格文件均未进行生产写入/迁移。
- 本批不打包、不替换正式版、不重启、不动Windows EXE。


### 冻结提交第一次云端反馈

[3f2004b6 / 41083785367](https://github.com/hututuo/codex-token-bar/actions/runs/41083785367)：Mac和Windows完整Rust回归、Windows更新器通过。前端1375项中1374通过，唯一失败是仍硬匹配旧“账号实降”的源代码文案断言；已移除重复的文案断言，保留对应语义标识、DOM读数和不显示折算/差额的验证。Swift2196项（28跳过）中仅两处旧辅助功能整串期望未包含新加入的Token/请求数，已更新为精确完整期望；新增计价、根链接、选区分子和气泡恢复用例全部通过。修正后本地相关22项通过，仍需新冻结SHA的完整云端复验，不把首次失败写成全绿。

将反推芯片原先含糊的“无 token”改成“无可比用量”：完整选区有用量，并不保证同周期可比段也有用量。价格版本使用内置共享book，AgentSpeedReportingController上报的priceVersion也取PriceBook.bundled.version。


## 最终云端复验与交付边界（2026-10-31）

源码冻结SHA：`dd165a05aad8d1658358702d596ec240cbb478ec`。
[完整CI 41087231519](https://github.com/hututuo/codex-token-bar/actions/runs/41087231519)全部通过：前端1375/1375、云端脚本11/11；Swift XCTest2196项（28跳过、0失败）、Swift Testing665项；发布脚本105项（104通过、1跳过、0失败）。Mac与Windows的完整Rust回归、原始压力案例、Windows打包自检/上报隐私自检及更新器检查均通过。未调度正式候选打包。

本机CFBundleVersion再次只读确认仍为984；本批没有替换、重启、操作Windows EXE或生产数据库。本节为文档补记，不改动上述已测试源码。其余旧预览文件未跟进提交或清理。

本地证据：scratch/20261030-price-and-chart-audit/cloud-dd165a05-results.json、cloud-dd165a05-swift.log、cloud-dd165a05-frontend.log。header-alignment-reference.png为真实跨平台组件的只读快照局部，左边缘数据源和所属区域均x=150；它是Mac改动的样式参考，不能代替已安装原生界面的验收。
