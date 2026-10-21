# 低命中提醒与续问建议隔离 · 2026-10-22

## 范围与保留

按用户确认的方案，双端剥离低命中提醒和续问建议的完整运行链路。

- 移除低命中判断、tracker、近期缓存提醒样本解析、提醒开关/标记、自动展开与专用指针轮询。
- 移除续问横条、间隔图、推荐时间分析、专用文件扫描、后台刷新、SQLite侧库读写和跨窗口命令。
- 专用实现与测试保存在 `codex/cache-advice-retained-20261022`，提交 `57ddfea3d7213f0eac58ce7b6f255ade1201a8df`。当前实施分支为 `codex/cache-advice-isolation-20261022`。
- 保留主用量扫描、输入/缓存输入/输出事实、归档/删除保留、fork自有轮次、缓存排行、命中率曲线、费用计算和TPS。
- 原主索引及续问侧库不删除、不迁移、不重建；旧提醒设置值不主动清理。续问侧库留在原位置，另有一致性备份。
- Swift正文reader此前借用了续问parser的子Agent判定，已迁入等价本地helper，并覆盖子Agent分页、自有轮次与共享rollout去重。

这次不涉及软件读写缓存和历史压缩功能。

## 验证与部署

- macOS 最终候选 0.9.5/926：Swift 全套 1772 项，10 项环境跳过，0 失败；本机已安装运行，并验证 15/30 分钟正文 TPS 切换。
- 前端完整 1204 项通过，生产构建通过；专用提醒旧 payload 不能唤回提醒，TPS 和常规侧栏行为保留。主扫描、缓存排行及价格等 27 份基础源码与保留分支逐文件摘要一致。
- Rust 本机重点回归通过；实际 Windows 完整测试及 x64/ARM64 安装包使用同一最终提交重新生成。Windows 完整测试 1231 通过、0 失败、10 忽略，双架构安装包、Tauri 签名和本机 x64 进程检查通过；最终云端门禁全部通过（run 39650978556）。
- 云端早期门禁发现 Swift 6.2.1 Binding 方法引用编译器崩溃，改用等价闭包后已通过；另发现 Windows 测试在后台正文读取结束前删除 fixture，新增仅 cfg(test) 的按来源等待后重新验证。未跳过原业务断言，生产代码不含该等待设施。
- macOS deep/strict ad-hoc 签名、稳定 designated requirement、Sparkle 配置及更新签名检查通过。最终 DMG 已打开目视检查，安装说明和拖拽入口完整。
- 发布授权：用户明确要求“搞完直接发布即可我去睡了”。因此完成门禁和安装包检查后直接发布，无需再次等待确认。

证据目录：外层 `runs/20261022-cache-advice-isolation/`。926 已安装运行，并保留 925 回滚包及一致性数据库快照。升级前 492418 条账本事件的数值字段全部保留，缺失/改写均为 0；668 条旧测速记录无缺失/改写。续问侧库 SHA256 和表行数不变；主索引 DDL 及版本/会计修订不变，扫描代际和扫描证书按正常新扫描更新。

Windows 旧索引当时均为空，不能作为非空旧账保留的实机证据；Windows 已有 6 条测速记录和停用侧库分别核对，非空历史账本由 macOS 实机对照与缺失来源回归共同验证。Windows ARM64 为真实 Windows 工具链构建，尚未在 ARM64 硬件运行；Windows 可交互进程已核对，最终 UI 目视验收未运行。

## English

Low-cache reminders and the complete follow-up recommendation pipeline are isolated from both clients. Dedicated scanning, analysis, side-store writes, timers, IPC commands and automatic reminder presentation are removed. The full feature remains on the retained branch above.

Usage scanning, cached-input accounting, rankings, hit-rate charts, prices, retained ledger facts, fork-owned rounds and body TPS remain. Existing databases and preference values are preserved. The final macOS build is 0.9.5/926, installed and checked locally. Swift passes 1772 tests with 10 environment skips; the full frontend suite passes 1204 tests. The release locator records final Windows/CI results and asset digests. The Windows ARM64 package has not been run on ARM64 hardware. Local evidence distinguishes compilation, process startup and visual acceptance.
