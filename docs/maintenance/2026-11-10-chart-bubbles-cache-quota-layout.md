# 图表气泡、逐模型缓存与三级额度布局

基线为 `36876d8dc96ecdfb7d4fe32bc7a74d96ed9dab91`；已安装应用仍为产品源码 `ba88596d` 的0.9.11/build1008。本批按用户最新授权进行本地定向测试和构建检查，停在替换应用及已安装应用的实机验收之前。没有改动受保护的AGENTS/HANDOFF/Windows报告、scratch、原始账本、A–D存储边界、依赖版本或更新器。

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

## 验证记录与停止线

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

本批未重新执行云端三门禁、未打包新安装器、未覆盖或重启`/Applications/Codex Token Bar.app`、未通过CUA/JXA/CGEvent操作现装界面。此前build1008的云端通过和实机报告保持历史身份，不作为本批源码的通过证据。交付后由Argon先询问用户是否在场及由谁进行实机验收，再安排后续安装/GUI检查。
