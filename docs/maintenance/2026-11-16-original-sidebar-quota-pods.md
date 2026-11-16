# 原版侧栏中的紧凑额度组

用户最终确定的范围是：在原版一级菜单中，仅将中间的一组组额度竖条改成 A「异形微舱」的紧凑构型，用软件小图标区分客户端。顶部实时速度、底部模型占比和任务仍使用原有组件；悬停展开、二三级菜单及设置继续沿用原版。

实现源码为 `00851238542f06699c6d8ca45be2e4189a916605`，分支为 `codex/production-rail-20261116`。原版交互恢复到 `4ea94fa2` 的实现。此前 build 1016 的分组圆环一级栏和独立悬停摘要已撤回。

- `ClientQuotaCompactPod.swift` 将同一额度池的 5h / 7d 放在左右两列。Antigravity 固定 Gemini 在上、第三方模型在下，缺失周期留空，避免跨池配对。额外未知窗口继续单独显示。
- 顶部采用 demo 的本地矢量软件标记：Codex 终端符号、Claude 星号、Antigravity 四角星。两条额度柱均为 4pt，单组 36pt、双组 52pt，侧栏总宽 20pt。
- 设置中的一级预览与真实侧栏复用组件、可见性和颜色设置。隐藏全部周期不会留下空额度组。API 显示状态文字，未知读数不绘制余额。
- 继续使用 `ClientQuotaProjection`、`ClientQuotaSelection`、已有刷新周期和额度账本。数据库、采样、网络读取路径没有新增或修改。

完整检查 `43817859541` 全部成功：Swift、前端、原生 macOS/Windows 和 Windows 更新器。Swift XCTest 执行 2519 项、38 项跳过、0 失败；Swift Testing 的 676 项、79 组通过。本次测试覆盖池与周期顺序变化、缺失周期、原版功能条高度、实际组件渲染，以及额度圆环与双竖条之间的原有往返动效。

macOS 候选来自 `43817859511`，清单对应同一源码。来源清单、ZIP 路径与内部链接、DMG、应用签名和打包资源校验均通过。2026-11-16 15:08（北京时间）替换 `/Applications/Codex Token Bar.app` 为 **0.9.11 / build 1017**，安装程序确认、启动及后续刷新均已观察到。可执行文件 SHA-256：

`90059694e7e05c7c030bb1b07613657cd7d0ec2732661557af83bffdcf5185a7`

真机已看到原版速度/模型/任务长条、Claude 图标双竖条、Antigravity 图标与上下两组双竖条，以及主页中的小数读数。Antigravity 曾在已知重置后短暂显示旧采样状态，后续既有刷新恢复四条读数。运行日志中的通用 frontend 诊断来自 Radar / RadarBench 获取失败；主雷达已恢复。CUA 对非激活浮窗的指针操作不稳定，完整悬停路径未通过工具做真机验收；相关交互恢复了原版控制器，并通过云端回归。

安装前后两份额度数据库 `quick_check=ok`，表结构与版本保持一致；安装前 26,055 条多客户端用量修订内容摘要完全相同。数据库未回写或恢复旧副本。

安装证据位于 `~/Library/Application Support/CodexTokenBar-Maintenance/2026-11-16-original-quota-pods/`，保留被替换的 build 1016 App；原版 build 1015 App 仍在 `2026-11-16-production-rail/rollback-build1015/`。本次没有创建公开发布、标签、更新源或合并主分支。
