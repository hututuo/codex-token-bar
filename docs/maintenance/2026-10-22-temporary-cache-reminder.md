# 过渡期恢复低缓存命中提醒

仅恢复近期请求的低命中提示、开关、侧栏二级提醒及关闭交互；不恢复续问建议、间隔图、retention scanner、侧库读写或相关 IPC。沿用原规则：输入≥20000 token，缓存命中率<30%，新/压缩上下文首条观察不提醒，120秒过期；保持请求去重、文件重写/数据源切换清理。只使用既有增量实时读取，不额外扫描历史。

## 结构和撤除

- Swift：TemporaryCacheReminder/ 拥有模型、tracker、主界面提示；CacheMissReminderFeature.isEnabled 是停用门。
- Rust：core/live_rate/cache_reminder.rs 拥有 parser、tracker、过期、snapshot adapter，CACHE_MISS_REMINDER_ENABLED 是停用门；rollout 只留增量接线。
- React：components/cacheReminder/ 拥有提示、开关和有效性过滤，feature.ts 是停用门；主界面/侧栏复用同一开关与单条关闭标记。
- 与账本、费用、主扫描和正文 TPS 没有写入依赖。不开新侧库，不变更索引 schema，不删除旧库。侧栏指针观察仅在提醒显示时轮询，不重启历史扫描；Windows点击计数器沿用原实现。
- 将本次功能保持为独立提交，未来可以整提交 revert；停用门关闭后不显示旧缓存 payload。主索引/统计无需迁移。

## 验证

Swift 定向136项（1环境跳过）0失败；前端全套1212通过；Rust tracker10、集成4、窗口授权20通过。三个新增异步fixture测试在清理前等待exact-scope读取空闲，保留9fa3c667修复。

本机候选0.9.5/927（更新配置及身份不变）；部署/数据对照以外层 runs/20261022-cache-reminder-restore/ 的最终回执为准。PR#3只读审查分开保存，未合并。本次未发布新公开版本。
