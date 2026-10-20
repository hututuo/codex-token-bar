# 测速进度存档：切换至用户显示问题排查前

记录日期：2026-10-20。用户要求先保存测速进度，再排查用户端显示 bug。此记录保存已完成状态，不新增测速需求，也不代表公开发布。

## 代码与部署基线

- 测速代码提交：`20389a7a`（Resolve observed speed models and publish live weighted reference summaries）。之前两次 Desktop 接收修复为 `1ba58e22`、`fb018cbf`。
- 分支：`codex/observed-speed-and-rate-20261020`。
- 实际源码：`runs/20261015-local-handoff/source`。工作区原有 `README.md` 修改保持原样，未纳入本次存档。
- macOS 已安装 `/Applications/Codex Token Bar.app`，0.9.5 build 912，严格 ad-hoc 签名 PASS。可执行文件 SHA256：`9f4020c75068ac1e56f27360dfa6ded766c1c32bc8a0a4838d67e178bb44c067`。
- Windows 已安装至 HTTWIN 的 `C:\Users\HTT\TokenBarReleaseGate20260921\InstalledAppRemaining\codex-token-bar.exe`，SHA256：`83C768C57FEA513D85B8D94224472230F2E0943B4781401FD8A1A1B2A0D2D48C`。安装时进程已运行；这不是 Windows 实际正文采样验收。
- 没有推送、创建发布标签或更新公开更新源。后续部署前需重新检查实际运行版本。

## 已完成的测速行为

1. Desktop 正文追加事件按会话、轮次、输出项采样，修复 pending turn 和大型历史快照导致的漏接；不重播历史正文。
2. 精确按 thread/turn 的 rollout 上下文补齐模型，冲突时保留未知；磁盘扫描后台、有界、增量缓存，未知归属重试下限 30 秒。
3. 侧栏和主页共享最近 15/30 分钟模型参考均速，约每秒更新。完整、无警告的短片段可以合并；中断、覆盖不全或明显接收停顿仅保留明细。明确显示模型、接收中状态及空汇总原因。
4. 参考均速为 Σ本地估算 token / Σ正文采样时长，扣除首块；与活动动画曲线分开。不是服务端生成速度，也不含隐藏思考或工具 stdout 的实测速度。当前本机精确分词开关关闭。
5. 进行中的片段使用已有增量计数，结束后用完整样本文本校准。只持久化数值和归属，不保存输出正文。

## 验证及实测快照

- PASS：Swift 最终针对性回归 32 项；前端 TypeScript/Vite 构建；实际 Windows Desktop 测试 14 项、live-rate 测试 95 项及 MSVC release 构建。
- PASS：安装后的 Mac 主页显示 `gpt-6.1-sol 32.3 tok/s 参考均速`（16:09 快照）。Codex 未重启，正在执行的会话未被主动打断。
- NOT_RUN：安装后侧边额度栏的独立视觉验收；原生非激活面板未出现在本次 CUA 可操作窗口中。绑定代码与主页使用同一 monitor，不能将它代替侧栏截图验收。
- NOT_RUN：本次 Windows 安装后的真实流式正文采样及用户多屏环境验收。
- PASS：补模型前 49 条原有样本 ID 全部保留，除模型字段外无字段变化。16:08 的 30 分钟 Sol 参考值为 12 段、926 token / 28.676106 秒 = 32.291692 tok/s；15 分钟为 6 段、609 / 19.950582 = 30.525426 tok/s。数据会随窗口移动，不是永久固定值。
- 性能快照：10,000 条记录一次汇总约 0.11 ms；真实两会话初次模型查找约 1.06 秒（后台），之后缓存查找约 26 ms。不是每秒全量扫描历史。

## CC Switch 对照结论

官方固定提交 `f92ff0b03964188f1cd011d9302ab8869d7a8219`：代理口径为 outputTokens / (latency − TTFT)，会话导入口径为 outputTokens / latency。两者分别加权汇总。

本机 CC Switch 数据库快照含 74,989 条 codex_session、0 条 proxy。最近四条合格导入样本来自 10 月 18 日，合并为 2673 / 61.664 = 43.347820 tok/s；与 Bar 10 月 20 日正文片段不是同批数据，不能按差值判断误差。Bar 没有可靠请求起点，当前不能反推出可靠 TTFT。

## 证据与回滚

仓库根目录下 `runs/20261020-rate-implementation/desktop-stream-probe/` 保存：

- `mac-speed-summary-install-receipt.json`
- `windows-speed-summary-build-receipt.json`
- `windows-speed-summary-install-receipt.json`
- `mac-speed-summary-runtime-evidence.json`
- `cc-switch-local-speed-comparison.json`
- `speed-summary-real-data-and-performance.log`
- Mac 回滚包 `installed-before-speed-summary-911.app`；Windows 回滚位于 `C:\Users\HTT\TokenBarSpeedSummary20261020\before-speed-summary.exe`。

详细实现记录见 [Desktop 观察器](../desktop-stream-observer-20261020.md) 与 [活动曲线和测速](2026-10-20-rate-and-observed-speed.md)。其中较早构建/验证段落属于历史记录，当前部署以此存档和安装回执为准。

## 下一步：用户端显示 bug

测速功能保持此基线，先收集具体显示异常、截图、操作系统及软件版本、屏幕数量/缩放和复现操作，再定位对应窗口、布局或数据状态。当前尚未获得本次用户 bug 的具体表现，不能预设与测速、吸附或多屏属于同一个问题。复现与修复时保留账本、索引、采样和回滚包。
