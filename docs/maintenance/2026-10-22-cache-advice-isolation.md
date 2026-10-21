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

## 验证

- Swift全套1772项，10项环境跳过，0失败。
- 前端255项通过，包含保留的缓存排行、近期命中率图、费用、TPS、侧栏行为，以及旧提醒payload不能唤回提醒的回归。
- tsc/Vite生产构建通过；主扫描、缓存排行和价格等27份基础源码与保留分支逐文件摘要一致。
- macOS 0.9.5/925候选构建、deep/strict签名与版本检查通过，稳定designated requirement/更新配置保持不变；产物不含专用scanner/store/tracker及提醒文案。
- Rust最终串行回归：cache 74通过/1忽略、live_rate 101通过、window_auth 20通过、pricing guard 1通过。首次并发共享缓存锁超时已串行复验通过；中途磁盘不足的失败编译亦单独留证。
- Windows局域网SSH超时，悠悠2222映射拒绝连接，Windows设备构建/安装未验收。双端代码同步不等于Windows实机验收。

证据目录：外层 `runs/20261022-cache-advice-isolation/`。925已安装并运行；保留924回滚包和数据库快照。升级前492168条账本事件的数值字段全部保留，缺失/改写均为0；634条旧测速记录无缺失/改写。续问侧库SHA256和各表行数不变；主索引DDL及版本/会计修订不变，扫描代际和扫描证书按正常新扫描更新。

## English

Low-cache reminders and the complete follow-up recommendation pipeline are isolated from both clients. Dedicated scanning, analysis, side-store writes, timers, IPC commands and automatic reminder presentation are removed. The full feature remains on the retained branch above.

Usage scanning, cached-input accounting, rankings, hit-rate charts, prices, retained ledger facts, fork-owned rounds and body TPS remain. Existing databases and preference values are preserved. Swift passes 1772 tests with 10 environment skips; frontend checks pass 255 tests. Windows device acceptance remains pending because neither LAN SSH nor the mapped SSH endpoint is reachable. See the local run receipt for final Rust and macOS deployment evidence and rollback instructions.
