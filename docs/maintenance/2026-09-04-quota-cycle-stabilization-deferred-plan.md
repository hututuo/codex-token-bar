# v0.9.2 额度周期与反弹保护备选方案（暂缓）

更新时间：2026-09-04（Asia/Shanghai）

状态：**保留备选，不是当前产品行为，不得据此直接实施。**

当前用户决策是：Swift 与跨平台端的当前额度读数以成功接口响应为准，接口读到多少就显示多少；本文件只保存此前讨论过的复杂周期判断方案，供未来确有需要时重新评估。

## 目标与边界

这套备选方案试图在以下两类现象之间做区分：

1. 5h / 7d 额度发生真实周期重置；
2. 同一周期内接口乱序或临时返回异常的满额读数。

内部数据语义始终保持 `usedPercent`；界面使用 `remainingPercent = 100 - usedPercent`。不得把存储和判断改成第二套“剩余百分比”语义。

本方案只涉及账号额度读取、当前额度展示、额度历史和周期元数据，不涉及 token 统计索引、JSONL 扫描、Provider Sync、会话删除或项目移动。

## 备选判断树

### 1. 读取失败

- 同一数据源存在 `lastGood` 时继续显示旧值，前几次失败静默处理。
- 后台渐进重试；失败不得变成 0%，不得覆盖上一条成功数据。
- 没有任何成功数据时保持“正在读取”，超过静默阶段后才能显示“暂不可用”。
- 成功后清零连续失败计数。

### 2. 账号与窗口隔离

- 账号变化时，当前有效响应作为新账号基线。
- 5h 只与此前接受的 5h 比较，7d 只与此前接受的 7d 比较。

### 3. 周期 ID 的定位

- 当前 Swift/Tauri 原始额度解析并不取得服务器周期 ID。
- 现有 `g0`、`g1` 等 `cycleID` 是额度历史层依据本地 `cycle_generation` 派生的结果。
- 因此本地 `cycleID` 应当是周期判断的输出和历史分组键，不能作为否决新 resetAt 事实的唯一输入。
- 旧记录、首次读取、历史库不可用或稳定账号身份缺失时允许没有 `cycleID`。

### 4. resetAt 周期证据

使用方向明确的推进量：

```text
resetAdvance = currentResetAt - acceptedResetAt
```

- `resetAdvance > 30 分钟`：确认新周期。
- 正好 30 分钟：不确认新周期。
- resetAt 倒退、缺失或推进不超过 30 分钟：不确认新周期。
- 不再要求确认新周期的同一条样本必须满足 `usedPercent == 0`；重置后的第一条样本已经是已用 1% 或 2% 时仍可接受。

如果观察时间已经越过旧的 `acceptedResetAt`，但接口仍未提供可信的新 resetAt，则仅在内部保留边界待确认状态；界面继续原样显示旧数字和旧时间，不增加提示文字，也不擅自显示 100%。

### 5. 同周期百分比规则

- `currentUsed >= acceptedUsed`：视为正常继续消耗，接受当前值。
- `currentUsed < acceptedUsed`：视为接口乱序或同周期反弹，保留上一可信值。
- 删除实时判断中 `previousUsed - currentUsed >= 20` 就直接接受的宽泛兜底；百分比幅度不能替代周期证据。

已有历史图表的三点异常序列修复可继续作为事后显示清洗，但不得参与新周期确认。

## 相关但必须分开的时间常量

- 新周期 resetAt 推进阈值：严格大于 30 分钟。
- resetAt 微小抖动容差：继续为 5 秒。
- 稳定候选观察跨度：继续为 5 分钟。
- 历史异常跳变恢复窗口：现有 30 分钟，语义独立于新周期阈值。

即使两个规则碰巧都是 30 分钟，也必须使用不同名称和测试，不能共用一个含义模糊的常量。

## 双端潜在修改点

Swift：

- `Sources/CodexTokenBar/AccountQuotaStore.swift`
- `Sources/CodexTokenBar/AccountQuotaReader.swift`
- `Sources/CodexTokenBar/QuotaHistoryCyclePolicy.swift`
- `Sources/CodexTokenBar/QuotaMonotonicNormalizer.swift`
- `Sources/CodexTokenBar/QuotaHistoryStore.swift`
- `Sources/CodexTokenBar/SharedAccountUsageAttribution.swift`

Tauri：

- `tauri-app/src-tauri/src/core/quota.rs`
- `tauri-app/src-tauri/src/core/quota_history.rs`
- `tauri-app/src-tauri/src/core/quota_history/database.rs`
- `tauri-app/src-tauri/src/core/quota_history/series.rs`
- `tauri-app/src/state/useDeferredQuotaLoad.ts`
- `tauri-app/src/surfaces/useCompactPanelQuota.ts`

## 兼容与安全要求

- 不改变额度历史 SQLite schema。
- 不修改 exact index schema 11。
- 不迁移、删除或重建现有额度历史数据库。
- 不触发 JSONL 扫描或 token 索引刷新。
- v0.9.1 和当前 v0.9.2 工作线产生的额度历史继续原样可读。
- 旧周期元数据不得成为自动删除或全量重写历史数据的理由。

## 若未来重新启用，最低测试门禁

- resetAt 正好推进 30 分钟不换期，推进 30 分 01 秒换期。
- resetAt 倒退超过 30 分钟不能误判为新周期。
- 旧已用 12%、新已用 1%、resetAt 推进约 5 小时时接受新值。
- resetAt 不变时，旧已用 12%、新已用 0% 保留旧值。
- 同周期旧已用 84%、新已用 62% 不再因超过 20 个百分点而放行。
- 5h 与 7d 独立判断，Swift 与 Rust 使用相同向量。
- 读取失败保留 lastGood，静默重试不改变悬浮窗数字和状态文案。

## 重新启用条件

只有用户以后明确要求恢复额度反弹保护，并重新确认以上判断树时，才允许从本文件转成实施计划。在此之前，当前成功接口响应原样显示的简单策略优先。
