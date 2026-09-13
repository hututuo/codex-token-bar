# 侧栏刷新与周期日历修复（2026-09-13）

基线 main@53a2eb2a；工作分支 codex/sidebar-refresh-20260913。

- 跨平台移除条件 return 后的 useCallback，避免侧栏启停改变 Hooks 调用顺序。
- 已有刷新按钮改为触发 useCompactPanelQuota 的统一强制刷新，发布额度和重置卡结果，沿用来源隔离、在途去重和错误保留策略。原实现丢弃接口返回值。
- Swift 二级摘要增加刷新按钮，复用 AccountQuotaStore.refresh(force: true)。双端顶部操作均为固定、刷新、打开主页面，三个按钮各宽 24，适配 88 宽侧栏。
- 双端选择历史周期后保持日历展开；日期行高统一 26，缩小内边距与行间距，默认折叠行为保留。
- 更新先前显示开关改版遗留的文案断言，继续验证独立开关回调与 aria-pressed。

## 验证

PASS：前端额度刷新/摘要生命周期 10 项；费用周期与日历 15 项；Swift 侧栏 30 项。侧栏全组 54 项初次 53 通过、1 条旧文案断言失败；更新该断言后单项重跑通过。
PASS：TypeScript/Vite、Swift release、Tauri release 构建与双端应用签名验证。
PASS：最新应用中双端选中历史后仍显示展开日历，截图见 runs/20260913-sidebar-refresh/*calendar-selected.jpg；跨平台侧栏开关关闭/重新开启无 Hooks 崩溃。
刷新结果发布及重复点击去重通过可控接口回归验证；未将此结果冒充为双端实际点击刷新按钮的网络验收。

Swift 安装版 /Applications/Codex Token Bar.app 和跨平台 dist/quota-sidebar-preview/Tauri.app 已替换。Swift 回滚副本、签名和哈希收据在本轮 runs 目录的 installed-swift-receipt.json 中登记。
本轮未改索引格式或迁移逻辑。未推送或发布；保留已有未跟踪 HANDOFF.md。
