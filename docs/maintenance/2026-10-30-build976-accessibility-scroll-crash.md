# build 976 本机辅助功能整页跳转崩溃

2026-10-30 01:02:33 +0800，macOS 27.0.1（26A434），正式安装路径的 0.9.7 build 976。在验收时向主页根 LazyVStack 的辅助功能列表发送 AXScrollToBottom，进程 PID 5452 主线程 SIGTRAP。报告保存在本机 scratch/local-install-build976/crash-010239.ips，原始位置 ~/Library/Logs/DiagnosticReports/CodexTokenBar-2026-10-30-010239.ips。

栈：AGAttribute.syncMainIfReferences → ForEachState.item/forEachItem → LazyScrollable.applyCollectionViewIDs → AccessibilityNode.scrollToBeginning → AccessibilityLazyLayoutNode.accessibilityPerformAction。触发时没有数据库写入栈。不能仅凭此宣称普通滚轮操作已复现同一问题，也不能把避免这个测试动作当作修复。

## 处理

DashboardView 中每个客户端此前在外层 LazyVStack/ForEach 直接展开可变数量的标题、活动图、用量图、排行榜。改为每个客户端一个具体 VStack 容器，保留 18pt 间距和内部图表 ID，客户端块仍由外层懒加载。客户端排序改为严格比较，Codex 固定优先，其他保持独立身份。未删除图表、未修改 TPS/速率算法、未改账本或 Windows 解析器。

这属于对已定位结构风险的修正，需新候选版实机复测相同辅助功能路径后才能宣布解决。云端普通单元测试通过不替代该验收。

## 数据与已完成门槛

build 976 对应提交 75f27810e8bac104c3c510f43d506b6cbc645ea5，云端检查 40910525503 全绿，候选 40910653753 双端构建成功。备份：~/Library/Application Support/CodexTokenBar-InstallBackups/20261030-005633-build974-before976。576 个旧命名空间、526316 条基线事件、客户端账本、4093 条旧正文测速记录及 84145 条活动速率旧样本均已校验无丢失。启动时一次索引资源忙和一次额度库锁已在后续刷新恢复，01:00:03 的最新精确统计已显示。没有公开发布。

参考 Apple 官方懒加载指导： https://developer.apple.com/videos/play/wwdc2026/321/ ，尤其动态子视图数量和懒加载身份的注意事项。官方指导是结构改进依据，不等于官方确认了本次崩溃的最终根因。
