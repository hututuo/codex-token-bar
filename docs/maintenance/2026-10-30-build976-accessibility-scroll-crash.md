# build 976 本机辅助功能整页跳转崩溃

2026-10-30 01:02:33 +0800，macOS 27.0.1（26A434），正式安装路径的 0.9.7 build 976。在验收时向主页根 LazyVStack 的辅助功能列表发送 AXScrollToBottom，进程 PID 5452 主线程 SIGTRAP。报告保存在本机 scratch/local-install-build976/crash-010239.ips，原始位置 ~/Library/Logs/DiagnosticReports/CodexTokenBar-2026-10-30-010239.ips。

栈：AGAttribute.syncMainIfReferences → ForEachState.item/forEachItem → LazyScrollable.applyCollectionViewIDs → AccessibilityNode.scrollToBeginning → AccessibilityLazyLayoutNode.accessibilityPerformAction。触发时没有数据库写入栈。不能仅凭此宣称普通滚轮操作已复现同一问题，也不能把避免这个测试动作当作修复。

## 处理

DashboardView 中每个客户端此前在外层 LazyVStack/ForEach 直接展开可变数量的标题、活动图、用量图、排行榜。改为每个客户端一个具体 VStack 容器，保留 18pt 间距和内部图表 ID，客户端块仍由外层懒加载。客户端排序改为严格比较，Codex 固定优先，其他保持独立身份。未删除图表、未修改 TPS/速率算法、未改账本或 Windows 解析器。

这属于对已定位结构风险的修正，需新候选版实机复测相同辅助功能路径后才能宣布解决。云端普通单元测试通过不替代该验收。

## 数据与已完成门槛

build 976 对应提交 75f27810e8bac104c3c510f43d506b6cbc645ea5，云端检查 40910525503 全绿，候选 40910653753 双端构建成功。备份：~/Library/Application Support/CodexTokenBar-InstallBackups/20261030-005633-build974-before976。576 个旧命名空间、526316 条基线事件、客户端账本、4093 条旧正文测速记录及 84145 条活动速率旧样本均已校验无丢失。启动时一次索引资源忙和一次额度库锁已在后续刷新恢复，01:00:03 的最新精确统计已显示。没有公开发布。

参考 Apple 官方懒加载指导： https://developer.apple.com/videos/play/wwdc2026/321/ ，尤其动态子视图数量和懒加载身份的注意事项。官方指导是结构改进依据，不等于官方确认了本次崩溃的最终根因。

## 最终调查补充：容器实验失败，已撤回

build 977（64b84d4c9b84dcdfff17d6298272abf21a84f33e）全量 CI 通过，仍在 01:35:09 相同动作、相同 SwiftUICore 指令地址下 SIGTRAP。Cua 的后续 getAXState 会自动重启崩溃的应用，因此必须单独检查 PID 和新增 ips，不能仅凭返回界面判通过。现场在 scratch/local-install-build977/accessibility-check.json 与 crash-013511.ips。

独立最小复现（scratch/ax-scroll-probe/Probe.swift）：40 个纯测试文本区块，ScrollView + LazyVStack + ForEach，1 秒更新时间，无数据库、用量解析、价格、网络或 Token Bar 模块。01:38:40 对其 AX 列表执行 AXScrollToBottom，同样 SIGTRAP、相同 AGAttribute.syncMainIfReferences/ForEachState/LazyScrollable/AccessibilityNode 栈。增加 accessibilityScrollAction 仍在 01:42:09 同栈失败；accessibilityElement(children:.contain) 仍在 01:43:59 失败。非懒加载 VStack 对照没有暴露此项整页跳转动作，普通滚动正常。

该证据把范围缩小到 macOS 27.0.1 的 SwiftUI 懒列表与辅助功能整页跳转调用链；不足以在操作系统实现和自动化工具映射之间最终归责。不能把停止调用当成产品修复，也不能泛称所有普通滚动会崩溃。原先 build 968 的 Charts/GeometryReader 崩溃栈不同，不能混为同一次问题。

决定：撤回未经验证有效的客户端容器/排序实验，恢复 75f27810 对应生产代码与 build 976；保留已批准的页头、配色、近3分钟原始速度图、内存存储和停止旧速率落库的功能。暂不以牺牲性能、隐藏辅助内容或私有 API hook 规避此系统路径。正式应用普通滚动和数据读取已验证；该辅助功能动作保持未修复、未关闭。最小程序和 ips 留在本机供后续复核，没有向 Apple 或外部发送报告。
