# 15 项索引兼容与刷新性能修复报告

状态：`implemented / targeted-validation-complete / release-gate-pending`

日期：2026-08-19

## 边界与基线

- 修复基线：`main@2144cb68031af6c985380e7927d04bb66b72c757`。
- 实现分支：`codex/index-compat-15-fixes`。
- 本轮只处理已确认的 P1-1 至 P1-7、P2-1 至 P2-8；没有引入第二套 parser、计价或索引真相。
- 原始 JSONL、Codex `state_5.sqlite` 和 canonical token events 均不由迁移删除或覆盖。
- 未执行 push、tag、正式构建、打包、发布、部署或真实用户索引重建。

## 最终产品口径

- 精确页面的总会话数：只统计已发布 Token 事件中的 distinct session；元数据兜底页仍可显示 state DB thread 数。
- latest 缓存候选：不使用 `input_tokens >= 1000` 门槛；1000 Token 门槛只属于低命中/大请求排行。
- 索引结构升级与历史 model/reasoning 补齐必须先于该 Home 的日常增量扫描，完成 marker 只在全部来源提交后写入。
- 右上角状态指示器显示“索引升级”或“历史模型补全”、真实 `completed/total`、进度条，以及“首次升级可能需要几分钟，可能短暂占用 CPU 和磁盘，原始数据不会丢失”。

## 15 项处理结果

| 问题 | 结果 | 主要提交 |
|---|---|---|
| P1-1 Tauri no-op 仍创建 generation | 无变化刷新复用 published generation，不复制或清理空代次 | `120c662e` |
| P1-2 Swift 每次读取全部历史聚合 | 改为按今日、7d、30d、图表与排行需要做有界 SQL 读取 | `aff96f3b` |
| P1-3 Swift 排他锁覆盖长任务 | 数值快照读取与 DTO/详情派生分离，busy/locked 保留 last-good | `aff96f3b` |
| P1-4 Tauri metadata 失败清空 last-good | state metadata 先完整 staging，失败不替换旧行或签名 | `120c662e` |
| P1-5 旧事件 model 未补齐 | 双端一次性、来源级、可续跑地补齐；Tauri 同轮补 model + reasoning；完成前不写最终 revision | `aff96f3b`, `9d108f15`, `0c27bb86`, `183d2693` |
| P1-6 发布身份仍可能是 0.8.3 | 保留为发布门禁；本轮不改版本号，不生成正式资产 | 待正式发布流程执行 |
| P1-7 Swift future provenance 被旧逻辑覆盖 | future/unknown 在任何破坏性写入前 fail-closed | `aff96f3b` |
| P2-1 future session catalog 被 DROP | 双端只迁移已知旧形状；未知/更高版本拒绝写入并保留 last-good | `aff96f3b`, `941a081c`, `670f7841` |
| P2-2 Swift 重复 state DB/discovery | 单次 refresh 复用 context/discovery；每候选只进入一次，追加尾部留待下一轮 | `aff96f3b` |
| P2-3 Swift 稀疏删除扩大 dirty 范围 | 使用精确 bucket/session/date 集合，只更新真实受影响投影 | `aff96f3b` |
| P2-4 Swift compact today 无下一日上界 | 使用日历计算的 `[todayStart, tomorrowStart)` 半开区间 | `aff96f3b` |
| P2-5 summary/full 覆盖边界不一致 | 双端补齐 Home、coverage、boundary、generation lineage，按来源水位合并 | `d884596f`, `b8c40cdf`, `e58c4b4c` |
| P2-6 Tauri 用启动固定 offset 算历史日期 | 按事件时刻对应的本地时区规则分日，UTC 五分钟事实不变 | `1883b5d7` |
| P2-7 Tauri 丢 reasoning output | canonical event、staging、writer 和历史补齐链路均保留 nullable reasoning | `941a081c`, `9d108f15` |
| P2-8 双端会话数/latest 口径不同 | Swift 精确会话数改为 token-bearing distinct session；Tauri latest 去除 1000 门槛，低命中仍保留；派生候选 v4 从现有 events 重建 | `fc1ce707`, `ec5ec868` |

## 迁移与进度安全边界

1. 结构迁移只做 DDL/marker，JSONL 正文读取为 0。
2. 历史 model/reasoning 补齐使用当前唯一 parser，边界固定在旧索引已发布 checkpoint；活跃文件的新尾部由迁移后的首次增量追上。
3. 每个来源先写 staging、核对事件身份与 Token 不变量，再短事务提交；中断后依据 durable receipt 续跑。
4. 缺失来源、Home 替换、未知 catalog/enrichment revision 或部分失败都不推进 published/final revision。
5. Tauri dashboard aggregate v3→v4 只重建可丢弃的派生候选表；定向测试确认 canonical events 数不变且 JSONL scan bytes 为 0。

## 定向验证

- Swift：P2-8 精确 token-bearing session 测试通过；metadata-only fallback 测试通过。
- Swift：迁移缓存绕过、不完整 enrichment、replay 进度和 model backfill 进度定向测试通过。
- Swift UI：右上角 header presentation 14/14 通过。
- Tauri：历史迁移/缺失来源续跑/future revision 等直接相关迁移测试通过。
- Tauri P2-8：`cache_usage` 3 项、低命中排行 1 项、派生升级不读 JSONL 1 项通过。
- Tauri UI：进度/layout 6/6，SSR header/model 12/12 通过。
- Rust：`cargo check --lib` 通过；仅有仓库既存 warning。
- Git：`git diff --check` 通过，工作树干净。
- 未运行无关全量回归；`cargo fmt` 未执行，因为当前 toolchain 未安装 `rustfmt`。

## 发布前仍需执行的 P1-6 门禁

正式发布时必须从单一版本清单统一生成并核对 package、Tauri、Cargo、Swift bundle、Windows、更新器和 release metadata；版本、build number、storage/parser capability 必须完全一致。完成门禁前不得以公开 `0.8.3` 身份覆盖现有安装。
