# 图表气泡、逐模型缓存与三级额度布局

基线为 `36876d8dc96ecdfb7d4fe32bc7a74d96ed9dab91`；实现提交为 `c6ffe57e86c9edfb041e848eefed2bbdc495e76c`。源代码检查阶段按要求停在安装前；随后用户明确告知已询问是否在场并等待3分钟未回复，授权本机构建、备份替换和实机验收。现装为该提交的0.9.11/build1009，原build1008已独立备份并保留原包。当前结论为**部分实机验收完成，仍有发现及不可观测项，不是全部通过**，详见文末。

没有改动受保护的AGENTS/HANDOFF/Windows报告、scratch、原始账本、A–D存储边界、依赖版本或更新器。本次安装阶段没有继续改产品源码；23个非文档变更文件与已测试提交逐一校验一致。

## Loop 1：气泡几何

定位：Swift首帧用plot高度猜卡片高度，之后由preference回写；从单点变为多模型选区时，旧/估计高度不足以保证卡片下边缘处于绘图区外。原10pt间距和220pt上方显示余量也不适合更高模型列表。Tauri另写`top:-2px`，未与绘图坐标形成共享合同。

扫描：两种顶部气泡共用`chartBubblePlacement`；Swift底部选区卡是正常文档流，应保留。Tauri两种顶部气泡共用`.chart-hover-bubble`，overlay位于横向滚动容器外，底部摘要亦在正常文档流。三个时间窗口使用相同的绘图几何。

收束：在既有`recent-chart-policy.json`增加bubble策略：绘图区上方48pt/px间距、600pt/px显示余量。Swift用`ChartBubbleLayout`在布局阶段读取实际size并直接放置，删除估计高度、异步回写和旧垂直offset常量；首次出现和模型行数变化使用同一个公式。Tauri由相同JSON及plotTop生成底边CSS变量，再由`translateY(-100%)`按自身实际高度上移；overlay明确保留上方裁剪余量。左右边界仍由各端既有视口钳制规则处理，关闭按钮及模型列表滚动保留。

检查：三周期、左右边缘及90/180/340/480高度的几何断言；原生首帧像素测试直接验证卡片下沿与蓝色plot之间的48pt空隙；真实多客户端气泡离屏渲染确认标题、用量、命中率和未知边界可见。旧关闭、固定选区、滚动与时间锚点回归保留。

## Loop 2：逐模型缓存与辅助功能

定位：`ChartUsageSummary`已有整体`cacheReadComplete`，`ChartModelUsage`却丢弃了逐模型完整性；可见选区列表接入了usage，但Swift悬停及选区容器的AX摘要仍会读取旧Codex模型集合。

扫描：Swift的`ChartModelUsageList`用于悬停和选区卡，旧`ModelUsageInlineSummary`还服务热图等非图表界面；Tauri同一模型列表用于悬停、顶部选区和下方摘要。B趋势IPC已提供缓存完整性，故无需改Rust账本或重新查询数据库。

收束：逐客户端+模型携带`cacheReadComplete`；合并时按输入Token加权，只要同模型任一有输入的贡献缺缓存统计，就显示`缓存命中 —`。已知0%与无输入/未报告分开；其他模型的已知值保留。无输入贡献不污染有输入贡献的完整性。同名模型跨客户端继续独立。

每行分为两行：名称/用量占比与Token值，客户端与该模型缓存命中率。原始模型、未知原因和完整可访问名称仍可读取。Swift两种气泡的AX模型摘要优先使用usage，费用/缓存文本与可见内容共源；`chart-selection-ax-model-summary`在源码中修复。无usage的Codex兼容路径保留，并显式启用逐模型缓存展示，热图默认布局不变。顺带移除悬停气泡自己的“nil额度→0%”旁路，复用既有未知额度格式。

检查：扩充双端共享`recent-chart-usage.json`，覆盖不同客户端同名模型、不同输入权重、同模型部分缺失、无输入、已报告零、三周期六种scope。实际React悬停/正反向固定选区/下方摘要检查每行缓存文本和AX标签；Swift两个生产气泡摘要直接断言多客户端模型、未知缓存和已知费用，不再把Codex占比当汇总。

## Loop 3：额度窗口空间

定位：三级详情的90/100尺寸大圆环自适应网格没有明确铺满Swift详情容器；一两个窗口时留出大量无信息空间，窗口下方的重置与状态信息也被挤在窄列。

扫描：Swift`ClientQuotaRings`和Tauri`ClientQuotaDetailRings`是三级各scope的入口；主页面`AccountQuotaStrip.clientRows`/`QuotaStrip.ClientQuotaRows`已经用弹性轨道铺满窗口区，共用既有额度投影和名称，不应为了三级布局再复制一套额度计算。二级双半环及morph有独立紧凑合同，不改变。

收束：三级统一为全宽窗口卡片，左侧66pt/px环与百分比，右侧弹性详情区显示窗口名称、重置时间和状态。一窗口一行，Pro的5h与7d两行均铺满可用宽度；更多窗口顺序保留并随详情滚动，不留虚拟空槽。API模式用整行“订阅额度不适用”说明，不画空额度环。自定义色、预期进度刻度、来源和unknown状态保留。Swift概览及每层容器明确`maxWidth: .infinity`；测试override也走同一详情入口。

检查：共享`quota-detail-cards.json`涵盖1/2/4窗口、混合客户端不可用与API；Swift在320pt/384pt实际渲染并验证卡片右侧有内容区域，React生产组件验证窗口集合、unknown、reset、自定义色、刻度及整行布局。主页面quota SSR、客户端scope和二级配对环回归同步通过。

## 源代码验证记录

本地证据：`/Users/huyiyang/Library/Application Support/CodexTokenBar-Maintenance/2026-11-10-chart-quota-6NiHMm/`。

| 验证 | 结果与证据 |
| --- | --- |
| React生产组件、共享fixture、侧栏/配色/scope | 40/40通过；`frontend-targeted-final.log` |
| 图表模型/滚动/归因/价格、主页面额度、模型显示名 | 94/94通过；`frontend-consumers.log` |
| TypeScript + Vite生产构建 | 通过；`frontend-build-final.log` |
| Swift编译、共享fixture、气泡布局与额度渲染、既有图表交互 | 28项中27通过、1项既有opt-in截图测试跳过、0失败；`swift-targeted-second.log` |
| 最终Swift定向复验 | 6/6通过、无跳过；仅逻辑与离屏渲染，见`swift-targeted-final.log`和`validation.json` |

Swift初轮像素测试使用动态系统红色，暗色模式下通道阈值不适用；改为固定RGB测试色后首帧间距断言通过，未放宽几何要求。前端首轮少了旧`chart-hover-row`分类，已恢复共享列表的该类，原断言保持并通过。原生图片保存在证据目录，包括`bubble-multi-client-cache.png`、三种高度的气泡图、十张额度窗口组合图。

需要明确的执行边界：早期选择整个既有`RecentChartSelectionInteractionTests`类时，其中三项会调用`orderFrontRegardless`短暂显示独立测试窗口并发送测试事件；未操作已安装Token Bar。发现后最终复验过滤为纯逻辑和不创建NSWindow的离屏渲染，不再运行显示窗口的用例。不能把这些本地组件结果当成已安装应用的实机验收。

以上为安装授权前的源代码检查记录；原`validation.json`保留当时的停止线，不回写成实机通过。此前build1008的云端通过和实机报告仍保持历史身份，不作为本批源码的云端通过证据。

## 授权后的本机安装与运行核验

安装及实机证据目录：`/Users/huyiyang/Library/Application Support/CodexTokenBar-Maintenance/2026-11-10-chart-quota-6NiHMm/local-install-1009-QrcS3k/`。

用户明确批准本机替换后，沿用`release-macos-app`的候选包、签名、资源和运行身份核验流程。使用官方打包脚本的独立副本，仅固定仓库路径并把Swift构建限制为2个任务、关闭索引及调试信息；生成release/arm64候选包，未生成公开DMG或发布更新。preflight、vendor、资源完整性、诊断门禁及ad-hoc深层签名检查通过。

| 项目 | 实测结果 |
| --- | --- |
| 安装位置 | `/Applications/Codex Token Bar.app`，0.9.11/build1009 |
| 产品源码 | `c6ffe57e86c9edfb041e848eefed2bbdc495e76c` |
| 可执行文件SHA-256 | `cbe5933f9c885dce7d65770f51ef7ed8e4360d42c1624bb3391d78b8658d4c57` |
| 候选包与安装包 | 201个清单项逐一比对，包含122个普通文件；字节、模式和链接目标一致 |
| 回滚备份 | 证据目录下`backup-build1008/Codex Token Bar.app`；另保留`replaced-original-build1008.app`，两份均通过原198项清单核验 |
| 原build1008可执行文件SHA-256 | `baad6e73a97de1760234bed5e4f011f57ba1ad7879ae25d1ea1ffbbf8db9fdce` |
| 正在运行的程序 | PID57205，`ps`与`lsof`均指向安装位置，磁盘签名deep/strict通过 |
| 运行回执 | 新session`be71027e-6880-4f82-8290-cba9a9262c29`具有startup ready、storage completed、refresh ready与updater confirmed |
| 存储完成记录 | 首次4386完成、pending=0、generation27446、schema14；验收后保留的最新完成记录仍为4386/pending=0，generation27471 |
| 安装确认 | attempt`d501bf90-0527-4550-b49e-5498a1dd7a16`对应confirmed receipt为true |

`runtime-validation.json`记录实际进程、签名、备份与回执校验。`post-refresh-diagnostics.zip`保留首次就绪证据，`post-gui-diagnostics.zip`保留实机检查后的有界诊断事件；导出器未打开数据库，不能把该记录扩大为完整账本审计。bundle ID、签名要求与Sparkle更新源/公钥保持原身份。本次没有执行该提交的新云端三门禁，没有推送或发布。

## 已安装应用的GUI结果与边界

使用真实本地数据，未注入模拟账户、额度或缓存缺失数据。CUA截图原图为3024×1794、2倍缩放；以下约96物理像素净空等于约48pt，是截图抽样观察，不代表任意窗口和滚动位置均已穷尽。`gui-validation.json`区分可见结果、AX结果和未验收项；`gui-evidence-manifest.json`为18张原图及配套AX文本保存SHA-256。中间失败截图也保留，文件名不能单独作为通过依据。

| 验收项 | 结果与关键证据 |
| --- | --- |
| 24h悬停 | 气泡完整可见，底边与plot约48pt净空；Astra6/Codex缓存100%、Argon4/Antigravity缓存98%。`chart-aggregate-24h-hover.jpg` |
| 24h固定选区 | 11月9日23:20至11月10日11:05，三模型缓存88%/96%/97%，可见行与AX摘要一致；底边与plot约48pt净空。`chart-aggregate-24h-confirmed-selection.jpg/.txt`；该滚动位置标题越过窗口顶边，属于下述未关闭问题 |
| 24h同选区完整气泡 | 向页面上方滚动后，同一选区气泡标题及三行均可见，仍约48pt净空；图表仅上部在视口内。`chart-aggregate-24h-fixed-full-bubble.jpg` |
| 7d悬停与固定选区 | 实机显示1小时粒度；两种气泡完整可见且约48pt净空。固定选区包含Codex/Antigravity/Claude Desktop，逐模型缓存87%/95%/98%，AX一致。`chart-aggregate-7d-hover.jpg`、`chart-aggregate-7d-fixed.jpg/.txt` |
| 30d悬停 | 实机显示6小时粒度；气泡完整可见且约48pt净空，Codex/Antigravity逐模型缓存89%/94%。`chart-aggregate-30d-hover.jpg` |
| 30d长选区 | 10月24日20:00至11月10日08:00；气泡约48pt净空，已显示的Sol6.1/Astra6/Luna6/Argon4/Opus5.5各行缓存为99%/87%/96%/94%/98%，与AX一致；AX包含13个客户端+模型条目，同名Opus5.5跨客户端分开，亦保留已报告0%。`chart-aggregate-30d-fixed.jpg/.txt`。长列表尾部的视觉访问尚未确认 |
| 缓存诚实边界 | 真实抽样没有`cacheReadComplete=false`或无输入模型；未知显示、加权和已知0%的双端夹具通过仍只是源代码验证，不能标为已安装缺失数据实测通过 |
| 主页真实额度 | Codex与Claude CLI均为API模式，显示“订阅额度不适用”。`dashboard-real-api-quota.jpg/.txt` |
| 侧栏三级额度 | AX已展开二级并触发Codex额度详情，CG窗口列表记录detail窗口3902、420×600；CUA只返回二级rail，故没有三级卡片截图。`sidebar-tier3-codex-real-api.jpg`实际是二级菜单，**不得作为三级通过证据** |
| Pro两窗口 | 真实账户无Pro的5h/7d额度读数，实机不可观测；320pt/384pt的真实组件离屏Pro夹具通过单列保留 |

尚未关闭的发现：

1. 气泡相对绘图区已经上移，但页面滚动使plot靠近窗口上缘时，气泡标题仍会被应用窗口顶边裁掉；48pt净空并不能保证气泡完整留在视口中。24h截图同时保留裁切状态及重新取景后的完整状态，不能报告“所有位置完全通过”。
2. 30d长选区有13行模型，气泡只显示其中一部分。尝试在气泡模型区滚动时实际滚动了整个主页，未确认顶部气泡尾部模型的可访问性。`chart-aggregate-30d-fixed-model-list-tail.jpg`是失败尝试后的主页截图，不是尾部列表证据；13行完整内容来自其前一份AX摘要。
3. 非激活三级NSPanel不能被当前CUA接口独立选择。用户已授权的JXA备选路径实测`AXIsProcessTrusted=false`，`screencapture -l3902`返回`could not create image from window`；未修改系统权限或绕过限制。三级卡片的实机视觉检查因此仍受阻，再叠加无Pro数据，不能把源码或离屏图替代真实验收。

## 设置恢复与交付状态

图表恢复`24h`与`all`，清除临时选区，主页面/侧栏scope及所有曲线开关保持原值。侧栏回到未固定的16pt收起状态，三级窗口已消失；主窗口关闭，build1009继续运行。`sidebar-restored-collapsed.jpg/.txt`和CG窗口记录对应最终状态。

逐键比对安装前备份与当前偏好域，仅系统色板的分栏frame发生5pt变化，已只恢复该键；最终偏好域无差异，没有导入覆盖整个域。`settings-restoration.json`记录恢复前后键差异与19项显式检查。三个受保护文件SHA-256均与基线一致，原dirty/untracked材料保持原样。

最终`final-validation.json`为`installed=true`、`guiTested=true`、`allRequestedGuiChecksPassed=false`，总状态`PARTIAL_ACCEPTANCE_WITH_FINDINGS`。可确认安装身份、运行就绪、抽样绘图区净空及多客户端模型/缓存/选区AX一致；气泡视口裁切、长列表尾部、三级卡片视觉验收和真实缺失缓存/Pro场景仍须分别收尾。Tauri本批保留此前组件与构建通过结果，没有进行Windows或Tauri已安装运行态验收。
