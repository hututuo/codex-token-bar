# 稳定版第二独立审查

日期：2026-11-04（Asia/Shanghai）。第二普通审查线程 `01a1a6aa-7d49-7380-a278-2d37054dc8dd`；接手/整合线程 `01a1a61c-5332-7a00-8298-fe2b988600ca`。这是用户授权的普通线程互审，不是子代理。

本轮初始源码为 `4aba703cdc4d786c7472c97de2a07649a6fe4787`，分支 `codex/stabilize-recovery-20261104`；审查开始时工作树干净。全程显式使用 `/Users/huyiyang/.codex/worktrees/tokenbar-integrated-recovery/codex-token-dashboard`。没有编辑默认旧工作区、产品、已有测试、脚本或工作流；没有操作分支、暂存区、共享提交、真实数据库/凭据、运行应用、云端、安装或发布。本报告是唯一新增的受版本控制文档，写前已通知接手线程；实验仅位于 `scratch/integrated-recovery/stabilization-20261104/second-audit/`，Rust 实验复用已有 target。

## 当前结论

在原 `4aba703c` 独立复现五组 P2 遗漏。接手线程已明确接手最小修复；本报告首写时**尚未独立复核修后结果**，故不能把下表状态写成已关闭。未发现新的可复现账目丢失或 build991 timer 修复回退。该表不是对全部产品路径、Windows 或正式安装的完整保证。

| 发现 | 可复现输入与实际结果 | 最小修复建议与责任 |
|---|---|---|
| P2 · Node 整组跳过绕过禁止跳过 | `node-execution-reporter.mjs` 排除 suite 后才计 skip。一个普通通过测试，加 `describe.skip` 包含必跑测试，以 `run-node-tests --no-skips` 启动，Node 26.4.0 和 24.13.1 均退出 0，报告 PASS、skipped=0；Node summary 自身 skipped 也为0。空 `describe` 文件加另一正常文件同样通过。 | 接手线程修。分别计 suite 的 skip/todo，以及每文件真正执行的声明测试；不能只读 summary 总数。已查当前前端未使用 describe/suite，未据此指称既有1419项有隐性跳过。 |
| P2 · Swift 不完整日志可被接受 | `check_test_execution.py` 只有见到完成 bundle 才读取 bundle starts。日志包含 `Main.xctest started`、一个通过 case 和通过 class summary，却没有 bundle/top-level completion，仍回退到最后 class 并 PASS。完整日志后加一个悬空 case start 也 PASS。 | 接手线程修。任何 bundle start 均须有对应完成记录，case 也不能悬空。此为脚本合成日志负控；没有把它说成真实 Swift 产品失败或现有日志失真。 |
| P2 · exact SHA 可夹带未跟踪测试源码 | 微型隔离 Git/Cargo 项目仅提交 Cargo.toml 和 lib.rs，唯一 `required_safety` 在未跟踪 tests/safety.rs。真实 cargo test 经 `--source-sha` 运行通过，报告 PASS 且 trackedDirty=false；workingTreeDirty=true 仅被记录。 | 接手线程修。exact 模式拒绝未许可的未跟踪输入，同时显式允许 CI 产生的日志/预览等输出，避免正常 CI 误拒。此反例为真实 Cargo 微型工程，不是产品测试。 |
| P2 · 已知凭据标记和键文本未完全脱敏 | TS 和实际 Swift formatter 均将合成 `OPENAI_API_KEY=哨兵`、`ANTHROPIC_AUTH_TOKEN=哨兵` 原样输出。TS 对象键为含 `access_token=哨兵` 的URL时保留键而涂黑value。普通 token、X-Api-Key、URL query 负敏感正控正常。 | 接手线程修。限定已知服务商前缀赋值语法和输出键文本，保留普通 token 数量/路径/错误码；不扩成任意编码解析。只测试合成值，没有真实泄漏证据。 |
| P2 · 缺 threads 表被当成成功空读取 | 有效 SQLite 只有 unrelated 表时，Rust `ThreadColumns::read` 返回空列；`read_recent_rollout_threads` 因缺 rollout_path 直接 `Ok([])`。真实模块探针4项中3通过、该项失败。合法空 threads、显式小毫秒/旧秒一致性、BLOB preview拒绝均通过，来源文件未变。 | 接手线程修。空 columns 视为缺必需表错误，保留合法空表与原缺可选 rollout_path 合同。调用者 rollout cache 和 completed-body reader 原会把此空结果视为成功，因此是错误可见性遗漏，不是账目丢失证据。 |

## 独立路径和实际审阅代码

先读原始故障/提交及代码，形成旧schema与NULL、时间单位、panic等待同步、诊断副作用、运行证据身份、完整报告与历史来源六类风险，再对照第一独立报告。本报告不复制第一报告的“已通过”作为自己的运行结果。

- 原始历史：双旧库诊断、0.9.10现场状态、PR7的16项保全映射、PR8增补、build991/992记录及本轮接手文档。复核了 `02c493fa`、`28a0dc6a`、`c5e3714d`、`f5b7358e`、`b82c042c` 和本轮三组实质提交都是起始HEAD祖先。没有再次访问GitHub，也不以本地ref推断远端当前PR状态。
- state读取：Swift `LiveRateMonitor+Database.swift`、`CodexUsageAnalyzer+StateSQLite.swift`；Rust `live_rate/state.rs`、读者 `rollout.rs`/`completed_body.rs`，并对照外部state正式快照读取 `external_state.rs`。列名来自固定已知列表，Swift同只读事务查看schema/行；当前时间表达式保留显式毫秒值，并在NULL时回退旧秒/毫秒。没有引入迁移写入或把metadata token列用于重新计账。
- panic/timer：实际 `RefreshClaimGuard::drop`、`snapshot_with_loaded_unread_after_claim`、panic两组测试、`ExactStageMaintenance.start/tick`。持锁发送同步信号后进入condvar等待，防止清理先于等待；原生产等待预算未变。`@Sendable`仍在utility timer回调，未发现回退。没有复演真实App崩溃。
- 账目保全抽查：Swift `CodexBusinessDatabase.importSnapshot`/`verifiedReplacementPreimage`/`snapshot(covers:)`、`ExactRetryAppendCoverage`，Rust `ledger` pending布局校验/缺原文保留测试、`business_store_route/path_identity.rs`。旧账反向覆盖、目标原像、事务内复核、typed行/隐藏rowid/序列、未知字段拒绝及有限路径归属仍在；这是定向源码检查，未自称重跑所有旧producer或每条数据库算法。
- 诊断：实际两端 formatter、TS journal/localDiagnostics、`command.ts` 三种调用方式和新增隔离测试。逐观察者异常隔离及不改返回/拒绝路径的改动合理；本次补充关注字符串边界与对象键，没有要求重构诊断系统。
- 门禁：执行解析器、生产报告检查器、formed报告类型、CI成功封条、Node reporter/runner及工作流接线。生产报告校验15场景、8强退阶段和每阶段3次恢复；清单中未验证UI动作的false保留原义。正常CI封条与单独升级/压力矩阵没有混为一个结论。

## 本线程实际正负控

| 实验 | 实际结果及范围 |
|---|---|
| Rust state附加边界 | 直接编译当前 `sqlite.rs`、真实models、`live_rate/state.rs`；仅模块接线是夹具。4项：3通过、缺threads表1失败；不是完整产品编译/启动。`state-edges.log`。 |
| panic guard再次独立抽取变异 | 从当前monitor源码重新抽取实际Drop与等待测试。原样退出0；去notify退出101；去claim clear退出101。仅state/condvar构造用最小接线，未重新跑完整Rust产品。`guard-independent-mutations.json`及三份log。 |
| Node事件门禁 | 真Node子进程，各有普通通过、整组skip、todo、空suite四例；26和24均复现上述skip/空suite遗漏，todo有leaf时正确拒绝。`gate-edges.json`、`node24-gate-edges.json`及每例完整stdout/stderr。 |
| Swift日志解析 | 正常最小bundle日志接收；截断bundle、悬空case两负控错误接收。是合成日志调用实际检查器，不是伪造产品执行证据。 |
| exact源码身份 | 真Cargo微型项目的未跟踪required test通过；实测调用实际包装脚本。`source-gate-untracked.json`、console及隔离git项目保留。 |
| 文本脱敏 | TS直接导入实际模块；Swift直接编译实际formatter+合成NSError入口。env与key URL复现，普通token/header/query及数量保留正控。`privacy-ts.json`、`privacy-swift.json`。初次TS入口相对路径写错后修正；那次import失败没有算产品负控。 |
| 历史/证据关联 | 核对本地祖先及根清单的79项文件和日志SHA-256，核对时全部匹配。`history-and-evidence-check.json`。随后根会因处理本审查而修改源码，旧清单仍只代表其对应时点。 |

原始失败不覆盖；修后复核应写新输出并追加本报告。本线程没有重跑根已完成的完整产品定向277 Rust、Swift各组合、前端1419、Python94或历史日志兼容正控，不将根报告数量计成本线程执行数量。根后来报告本机Node24 cloud15/前端1419通过，也不能外推为hosted或Windows结果。

## 残余风险与收束建议

- 新修复后须重新绑定源码和相关测试，再关闭上表条目；未运行Windows、hosted、完整历史producer矩阵、本轮安装/完整App验收。历史Windows包装冷读取超时仍是历史FAIL，不能由本机guard通过解释成已排除平台问题。
- Swift双重JSON转义错误文本仍可能含已知key的原值。已复现语法边界，但未找到固定产品输入路径；本轮不扩大为任意嵌套编码解析。无标签秘密、未知协议文本等同样不能由有限语法过滤保证识别。
- Rust schema查看与后续查询不在同一显式事务；目前已知旧schema演进为追加列，查询会失败或在下一刷新更新，未复现账目错误。同步DDL变动不是本线程已验收场景。
- guard负控使用OS条件变量，偶发无因唤醒的理论可能不等同该次收到了notify；实际删除notify反例已失败。本轮不为消灭理论调度噪声改生产同步架构。
- 性能/写锁/功耗、物理旧库清理继续按用户决定延期；原性能FAIL和缺测不改写为绿灯。已有覆盖证明、完整快照与有限恢复例外比任选新库或重写迁移体系更符合本版修旧错边界。

审查发现范围已收敛。没有证据支持“所有bug已消失”，也没有必要因上述5组窄缺口扩大本轮架构或清理范围。

交付时状态补记：HEAD仍为 `4aba703cdc4d786c7472c97de2a07649a6fe4787`；接手线程已并行修改五个既有测试文件以加入上述回归。它们不是本审查线程的编辑，尚未表示产品修复通过。本线程新增内容仍仅为本报告及约定scratch证据。最终修后源码身份待接手线程固定并复核。
