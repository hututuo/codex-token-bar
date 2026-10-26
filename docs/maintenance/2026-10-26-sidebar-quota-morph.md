# Mac候选侧栏：圆环收成对应色带（2026-10-26）

分支 `codex/multi-client-tokens`；上个可回退源码基线 `8833d68a`。只在独立worktree改动，不合并测速主线程、不安装正式App、不处理Windows EXE，不请求Anthropic。独立候选保持left，正式测速版right及引导窗口均未由本分支改动。

## 实现

- `ClientQuotaMorph.swift`：原环/原条布局锚点、同拓扑路径、原生瞬时CA层。整环分成两个凸半弧再压合为同一条，双半环分别对应自己的条；插值描边区间，保持起止剩余值；未知不虚构彩色用量。
- `IntegratedClientViews.swift`：仅给原二级额度环增加源锚点。保留46pt、单值14pt、窗口左右对应及客户端单行说明。
- `QuotaSidebarViews.swift`：原竖条目标锚点、可视区域过滤、原生动画覆盖层与淡入淡出。滚动区用transformAnchorPreference追加自己的锚点，避免覆盖子环锚点。没有另写菜单或复制布局。
- `QuotaSidebarGeometry.swift` / `QuotaSidebarController.swift`：宽度与变形240ms，之后高度120ms，非线性分阶段；不逐帧setFrame缩放原生窗口，保留已有固定包络与原生clip路径。减少动态效果、拖动、快速反向采用原交互逻辑。
- 完成/卸载/减少动态效果会取消动画并释放层。CA完成回调缺失时，一个可取消的单次截止任务清理；没有永久刷新或轮询。

## 验证

PASS：定向Swift 60项、0失败，日志 `scratch/sidebar-morph-swift-final.log`。含半弧方向、凸形不打卷、等长路径、最终完整竖条、未知额度、左右屏幕边界、先宽后高、快速反向、原QuotaSidebarRail锚点实际解析、静止重复更新不启动动画、完成后层归零，以及原侧栏/高度预算/多客户端投影回归。

为避免临时原生测试面板遮挡另一个线程的引导，未运行会orderFront测试面板的 `testProductionRailSpendsOneMeasuredRowBeforeResizing`；其余6个高度预算测试已通过。未重跑无改动的Rust/TS全量；Windows动效尚未实现。

三额度100次准备测试：中位1.285ms、p95 1.340ms，瞬时8层，收尾0层。此数只含主线程路径/动画准备，不是实机单帧时间或GPU功耗。

独立候选后台8秒短样本：修改前4.24% CPU，修改后4.37% CPU。输入为隔离数据副本，实时速率关闭；这只是短采样，不能据此宣称整体CPU下降、无耗电或60/120FPS已验收。记录在 `scratch/launch-preview/morph-before-cpu.json`、`morph-after-cpu.json`。人工连续悬停的视觉手感/实机帧率仍由候选运行交互验收。

候选实际进程已重启至本次二进制；用nm核对包含ClientQuotaMorphView.update符号，依赖与86MB主执行文件位于候选bundle内；新逻辑已在实际运行的候选中。正式应用未由本分支替换/重启。

24号图为同一路径函数的原生分镜渲染，非屏幕录像。候选在屏幕左侧，用户移入/移出即可查看；可直接回到上个源码基线重建候选，不影响真实账本。
