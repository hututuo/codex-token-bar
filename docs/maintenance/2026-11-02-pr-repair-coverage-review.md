# 2026-11-02 新PR与近期故障对照

本轮是读取、代码审查、隔离回归和合并模拟。没有合并main、修改正式数据库、安装或重启应用，也没有向PR提交评论。

## 固定审查基线

| 对象 | 本轮核对的SHA | 状态 |
|---|---|---|
| main | d831ae416c78f9f1950e8b4ed9755c8718a5b51d | 本轮两个开放PR的基线 |
| [PR #7](https://github.com/hututuo/codex-token-bar/pull/7) | faa06a5b9ef0d091cf06a0b2edf0e938bdd466f2 | 开放，非草稿，跨平台运行期整合修复 |
| [PR #6](https://github.com/hututuo/codex-token-bar/pull/6) | 41058ffe4b59fb921d2bdf962db1d0624aac9b87 | 开放、草稿，双端恢复/诊断/补全验证，未验收 |
| [PR #5](https://github.com/hututuo/codex-token-bar/pull/5) | 436db080ae47664cf0c67a1e676978d2e7febb00 | 关闭、未合并，由#7替代 |

PR里的F编号与此前资料包的F编号含义不同。本表使用问题名称对照。

## 旧问题覆盖情况

| 之前的问题 | #7实际改动 | #6实际改动 | 本轮结论 |
|---|---|---|---|
| 进入应用后的非法listen事件名 | 存储键保持，改用三个合法事件通道，调用既有desktopBridge | 独立useSharedChoice模块，另补存储失败、异步取消监听、卸载保护 | 两边都有修复；#5不必再单独叠加 |
| 旧额度表缺四个cycle字段 | PRAGMA检测列，缺列投影默认值；生产legacy读取使用稳定账户身份 | 对应兼容读取及生产reader探针 | 对应代码已存在；不把无稳定身份旧行猜归到当前账户 |
| 旧Tauri历史被Swift-only筛选排除 | 生产入口改用rows_since_for_legacy_store，不再按writer平台过滤 | 同类修改与测试 | 已覆盖已识别的稳定身份分支 |
| 有效旧stage对应较短边界，重启仍堵重建 | 验证旧stage自身合同，按新合同建立独立candidate；A目录中登记/枚举，重启可发现 | 验证并保留旧stage后重建，含bounded-stage生产探针 | 两套实现有冲突，不可直接叠加；哈希最早写入版本未在本轮追溯清楚 |
| state_5误走冻结旧库导入 | 专门外部只读连接；WAL签名、缓存版本和读取前后复核 | 外部只读、活跃WAL时重新读取、可选列投影 | 核心路由修复都有；#6额外兼容旧列集，#7缺这一点 |
| 数据区块一直待读取/完整曲线结果出不来 | QuotaStrip归因发布去重；完整聚合/轻量摘要分别比较谱系；保留请求订阅的reason/revision | 不含#7这组完整UI/谱系修复 | #7新增了此前未完整定位的前端反馈循环及结果拒收处理 |
| Mac补全进度每批从0开始 | 未修改原生Swift索引 | 外层累计、批次偏移与并发回调序列化，新增原生测试 | #6修了累计显示，但性能与文件内进度未闭环 |
| Mac数千来源补全长时间无进展、stage表累计 | 没有原生Swift实现改动；其SQL优化在Rust侧 | 仍每job四张持久stage表、全轮发布后清理，规模门禁尚失败 | 关键剩余项；跨平台优化不能视为已修Mac原生路径 |
| 0.9.8–0.9.11旧库/部分A/中断恢复 | 主要运行期修复，升级验证仍沿用公开0.9.3/0.9.7产库场景 | 增加固定0.9.8–0.9.11源码形成状态的探针、日志及分区内部迁移接续 | 不能把#7既有19场景等同于近期所有中间状态验收；#6说明也明确未取得完整通过矩阵 |

## 需要补充或整合的明确项目

### 1. Mac原生大规模补全仍未解决

#7没有修改`Sources/CodexTokenBar`下的Swift实现。#6的累计进度修复与规模门禁有价值，但仍保留每文件manifest/fingerprints/events/chunks四表物化到A、整轮发布后才清理的机制。复用一次验证连接没有消除逐job重开A和MAIN目录累计的成本。

核对到的实际云端产物：`backfill-scale-b5e67b621c8a29d62a9ef197b8aa28ed99047360`，artifact ID 13114990239，来自[运行41383441859](https://github.com/hututuo/codex-token-bar/actions/runs/41383441859)。下载的`report.json`记录：

| 文件数 | 补全秒数 | 最大进度空窗秒数 | 结果 |
|---|---:|---:|---|
| 13 | 1.31 | 0.84 | 完成 |
| 128 | 17.94 | 13.29 | 完成 |
| 512 | 162.89 | 128.59 | 完成但超过30秒空窗门禁，整组FAIL |
| 4124 | 无结果 | 无结果 | 未运行到该规模 |

产物绑定的是b5e67b6，不是当前41058ffe。当前草稿说明仍列为性能阻塞，没有提供当前头部4124规模通过结果。各文件只有一个合成Token事件，不能等同真实历史复杂度。

原生累计进度和存储证据：#6 `CodexUsageHistoryIndex.swift:2676–2716,7353–7372,7645–7709,8113–8132`；`BusinessStoreFiles.swift:50–70`。逐文件开始/结束之外没有文件内部进度，所以慢源与发布阶段仍可形成空窗。

### 2. #7还缺#6已有的外部state可选列兼容

#7 [`exact_usage_index.rs:12002–12015`](https://github.com/hututuo/codex-token-bar/blob/faa06a5b9ef0d091cf06a0b2edf0e938bdd466f2/tauri-app/src-tauri/src/core/usage/token_count_jsonl/exact_usage_index.rs#L12002)仍使用：

```sql
SELECT id, title, first_user_message, preview, COALESCE(updated_at_ms, updated_at)
FROM threads
```

#6已检测实际列并对可选列投影NULL，保留必需id/title/更新时间校验。其reader探针包含只有旧列的`threads`，还验证损坏替换不得发布空标题。

本轮内存SQL复现：`threads(id,title,updated_at)`已有一行时，#7查询报`no such column: first_user_message`；#6投影读取到同一行。这是查询级验证，不是完整Rust启动测试，也不代表已确认用户当下state库恰好缺这些列。

整合应保留#7的真实只读路由、A运行期只读门禁及WAL新鲜度处理，同时接入#6的旧列兼容与相应生产探针。活跃WAL缓存策略两边也不相同：#6避免仅以未变stat将活跃WAL当成不变结果，需保留对应测试语义。

### 3. #6新诊断有同步刷盘的性能风险

#6 [`BusinessMigrationDiagnostics.swift:40–58`](https://github.com/hututuo/codex-token-bar/blob/41058ffe4b59fb921d2bdf962db1d0624aac9b87/Sources/CodexTokenBar/BusinessMigrationDiagnostics.swift#L40)对每条记录持锁写入并`fsync`；[`BusinessBackfillDiagnostics.swift:36–38`](https://github.com/hututuo/codex-token-bar/blob/41058ffe4b59fb921d2bdf962db1d0624aac9b87/Sources/CodexTokenBar/BusinessBackfillDiagnostics.swift#L36)使每个源解析开始/结束各写一次。

4124个源仅这两条就约8248次同步刷盘，另有进度/发布记录。这是代码可确认的额外同步I/O风险；本轮没有测出它占上述162.89秒的具体比例，不能将其直接认定为唯一原因。整合诊断时需有日志成本预算、批量/异步明细与关键状态持久性设计，避免新增排错功能放大原卡顿。

### 4. 两条PR共用入口存在6处文本冲突和多处语义重叠

用`git merge-tree --write-tree audit/pr-6 audit/pr-7`作模拟，没有切换工作树或提交合并。冲突文件：

- `tauri-app/src-tauri/src/business_store_fixture.rs`
- `tauri-app/src-tauri/src/core/quota_history/database.rs`
- `tauri-app/src-tauri/src/core/usage/token_count_jsonl.rs`
- `tauri-app/src-tauri/src/core/usage/token_count_jsonl/exact_usage_index.rs`
- `tauri-app/src/app/BusinessStartupGate.tsx`
- `tauri-app/src/multiClient/useClientScope.ts`

不能只做文本保留一边：#7有更完整的只读路由、candidate目录与显示结果修复；#6有额外旧列、存储失败/异步unlisten保护、双端诊断、累计进度及近期版本形成状态探针。合并后的测试必须同时保留这些合同，现有各分支CI不代表组合结果。

## 新增而非重复的处理

#7还增加了Windows verbatim/UNC/特殊字符SQLite URI；原生只读不等待注册写锁；compaction/历史绑定查询走现有source索引并为TEMP incoming建立身份索引；正常追加的句柄长度验证；全部同UUID副本的增量归因范围；压缩会话首行/上下文/恢复包；自动续跑列表的state-db-only参数及有限兼容回退；子窗口只读启动状态/打开主窗口重试；快照内摘录告警去重、刷新按钮跟随真实owner。

#6增加持久迁移/运行补全尝试日志、保护页导出/软件更新操作、累计进度和近期公开版本形成状态验证。日志/UI能力是诊断辅助，不是故障恢复成功证明。

## 本轮实际验证与边界

1. GitHub API核对#7三次云端运行的`head_sha`均为faa06a5b，且均completed/success：
   - [完整检查41380388513](https://github.com/HuangArmagh/codex-token-bar/actions/runs/41380388513)
   - [旧版升级41382540166](https://github.com/HuangArmagh/codex-token-bar/actions/runs/41382540166)
   - [候选构建41384715618](https://github.com/HuangArmagh/codex-token-bar/actions/runs/41384715618)
   这三次在贡献者fork上运行。本轮核对状态和SHA，没有重跑全部原生测试或下载安装包。
2. 从同一#7 SHA抽取隔离源码和静态价表资源，复用现有依赖，Node v26.4.0执行5个相关测试文件，共67项，全部通过、0跳过。覆盖合法事件/旧设置、统计谱系、订阅生命周期、归因发布和子窗口启动门禁。首次抽取遗漏外部静态JSON资源，补齐同SHA资源后重跑通过；这些环境缺件不计作PR代码失败。
3. 下载并核对#6规模产物的report.json及sourceSha，确认上表的性能失败。
4. 内存SQL运行旧state列比较；模拟两PR合并并记录6个冲突。
5. 无正式库/原始会话写入、无实际合并/推送/PR评论、无应用替换或发布。

本地证据在`scratch/pr-review-20261102/`：PR快照、运行元数据、性能ZIP、隔离测试日志、SQL复现结果和合并模拟结果。审查结论只对应本报告固定SHA；作者继续推送后需按新增差异更新。

## 按我原排查条目对照（用户澄清后补充）

这里的基准是`2026-11-01-backfill-performance-risk-audit.md`当时记录的条目，不把新PR另外发现的问题算成原排查成果。

| 原记录位置 | 原来查到的问题 | 新提交对应处理 | 截至本轮的状态 |
|---|---|---|---|
| 第1节 | 外层逐批进度不加已完成批次，4/4124不是全局进度 | #6新增跨批偏移与单调进度框；#7无Swift改动 | 累计代码已修，有小规模原生/规模产物证据；不等于卡顿已修 |
| 第2节 | 每job四张MAIN暂存表，完整发布前持续累计 | 两条均未替换该持久暂存机制 | 未修 |
| 第3节 | seal/byteCount/observation反复新开大A，DDL使schema缓存失效 | #6局部复用一次stage校验连接；主要重复入口与逐job目录/物化仍在；#7无Swift实现改动 | 部分局部改动，原性能问题未闭环 |
| 第4节 | 已ready的Mac A发现新增旧库，先改importing，再因空间不足挡住已有runtime | #6在原迁移流程加诊断包装，未改变该状态转换和空间检查顺序；#7不改原生迁移 | 未见修复或该场景新回归；这是此前隔离复现的风险，不是对用户本机故障的既定归因 |
| 第5节 | 原始会话已缺失，重扫不能重建全部旧账 | 两条未改成清库重扫，保留旧账约束 | 保护原则保留；不是新修复，也不等于已做完整现场对账 |
| 第6/8节 | 单测原始独立SQLite与生产共享A路径不同，原规模测试不足 | 两条增加正式配置reader/恢复探针；#6增加规模及近期版本形成状态验证 | 验证入口部分补齐；512性能失败、4124无结果，完整验收仍缺 |
| 第11.1节 | Windows旧quota缺四列，生产读取又按Swift来源排除旧Tauri记录 | 两条补兼容投影及生产legacy身份读取 | 对应代码已有处理；无身份旧行继续保留不猜归属 |
| 第11.2节 | checkpoint拒绝追加后，旧完整stage边界不匹配，固定地址持续阻塞 | 两条补旧合同验证/保留与后续重建；#7另有新candidate确定地址及A目录枚举 | 已覆盖已知合同分支；旧哈希最早由哪版写入仍未确定，不能写成所有旧stage已验收 |
| 第11.3节 | state_5作为一次性旧库导入，精确扫描读到冻结副本 | 两条都分离外部实时只读入口并处理WAL更新 | 原路由问题已有对应修复；#6另补可选列兼容，整合时保留 |

非法listen事件名来自用户明确反馈，原排查资料亦记录，但不属于上述Mac数据库性能采样。两条都有事件通道修复。#7新增的渲染循环、轻量/完整结果谱系等是贡献者补查，不应归功于此前本线程已经定位。

## #7的16项 × 原排查 × #6

再次读取GitHub后，两条PR仍为本报告固定SHA。以下F编号仅使用#7说明的编号。“#6有”表示存在对应代码，不表示整个分支已通过验收；“#6无”也不表示它承诺承担了该项。

| #7项 | 问题 | 本线程此前证据 | #6对应处理 |
|---|---|---|---|
| F01 | 非法listen事件名 | 用户已反馈，资料包有记录；hook根因来自后续代码审查 | 有，另补存储和卸载失败保护 |
| F02 | 额度历史缺四列、Swift-only过滤旧Tauri记录 | 原报告11.1已定位 | 有 |
| F03 | 较短有效stage阻塞较大重建合同/重启 | 原报告11.2已定位阻塞链，旧哈希起源未定 | 有，方案与#7不同 |
| F04 | 外部state冻结、WAL-only更新漏读 | 原报告11.3已定位错误路由 | 有，另补旧列与活跃WAL兼容 |
| F05 | Windows只读SQLite URI特殊路径 | 之前未定位此URI编码问题 | 无 |
| F06 | 历史/compaction协调反复全表查找 | 原调查定位的是Mac连接/schema热点，未定位这处Rust查询 | 无 |
| F07 | QuotaStrip归因反馈循环使数据区块等待 | 有数据显示异常反馈，未定位此React循环 | 无 |
| F08 | 轻量摘要水位挡住完整结果、订阅丢失 | 之前未定位此谱系/订阅问题 | 无 |
| F09 | 未报告压缩用量说明被遮挡 | 之前未定位该CSS重叠 | 无 |
| F10 | 子窗口状态读取/重试权限被误当账本失败 | 之前未定位此子窗口入口 | 无；#6只增恢复操作和监听清理 |
| F11 | 冷摘要、计数、365日查询全量展开 | 之前未定位这组Rust查询计划 | 无 |
| F12 | 压缩会话目录/上下文/恢复包支持不完整 | 之前未定位这些读取入口 | 无 |
| F13 | 自动续跑列表触发rollout扫描超时 | 之前未定位该thread/list选项问题 | 无 |
| F14 | 正常追加被冻结长度误判为非追加变化 | 之前未定位此句柄长度问题 | 无 |
| F15 | 同一摘录源一次快照重复告警 | 之前未定位该去重问题 | 无 |
| F16 | 刷新忙状态提前清除、运行期只读注册等写锁、明细/归因慢 | 之前有锁/慢类问题，但未定位这组具体入口 | 无 |

因此，#7前四项对应此前的三条数据库读取/恢复排查及一条用户事件名反馈；其余十二项主要是贡献者新增定位。#6的主要交集也是前四项，不是#7的完整替代。

不在上述16项里的#6增补包括：原生Swift累计补全进度、归并后已知模块内部迁移接续、持久迁移/补全诊断和保护页操作、0.9.8–0.9.11形成状态探针。#6额外处理旧state可选列及设置存储/unlisten失败，整合时不能被较小修复覆盖掉。

我原排查尚未闭环的三项核心仍独立存在：A内逐job四表累计、大A连接/目录反复加载、Mac ready A遭遇迟到旧库导入失败后全局阻塞。#6性能产物失败和新增逐源fsync风险也未因#7的16项通过而消失。
