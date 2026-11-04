# 稳定修复门禁的独立反向审查

日期：2026-11-04（Asia/Shanghai）。起点为 `0a125e15d692ce9233b54a464eca3dea475e5c4d`，工作树为 `/Users/huyiyang/.codex/worktrees/tokenbar-integrated-recovery/codex-token-dashboard`，分支为 `codex/stabilize-recovery-20261104`。本报告对应尚未提交的联合工作树；不是该起点 SHA 已含本轮补丁的声明。

独立审查会话只编辑工作流、检查器、脚本测试、新建的 `RecoveryDiagnosticsPrivacyTests.swift` 和 `diagnosticFailureIsolation.test.mjs`。state 兼容、刷新占用、错误文本脱敏等产品代码由接手会话负责。没有覆盖双方原有修改，没有触及正式数据库、原始会话、账号凭据、已安装应用或发布系统。本轮没有推送、触发 hosted job、安装或发布。

本轮结论：确认并修补了生产报告不完整仍被接收、失败后留下 PASS 文件、零项/跳过测试冒充执行、请求矩阵未执行仍可能封存成功、既有工作流合同漂移等问题。负控能使这些门禁失败。另以实际源码变异验证旧账覆盖、等待通知和结构化日志字段保护；这不是所有产品路径或所有用户环境的完整证明。

## 已确认的问题与处理

| 问题 | 修补前实际证据 | 本轮处理 |
|---|---|---|
| 生产报告只核对两条并发检查 | 删除其他恢复检查，仅保留顶层 PASS 和两条并发检查，旧 runner 成功返回 | 要求 15 个既有场景各出现一次并为 PASS；核对关键类型、账目、只读和保留字段；八个崩溃阶段每个必须有三次恢复 |
| 校验前写出 PASS JSON | 旧 runner 在并发/压力校验前已写成功文件，后续异常不撤销它 | 原始 stdout/stderr 保留在 log；独立 validation 文件记录 PASS/FAIL 和子进程退出码；全部校验通过才生成成功 JSON；已有证据拒绝覆盖 |
| 空过滤器也返回退出码 0 | Rust/XCTest 的成功命令并不必然执行用例；测试负控覆盖空输出、零项、跳过、错误摘要和非零子进程 | `check_test_execution.py` 同时检查命令结果、逐项通过记录和最终计数；关键兼容、旧账、日志与通知用例必须实际通过；记录源码 SHA、工作树是否有未提交修改和日志摘要 |
| Node 空文件算成功 | 独立空 `.test.mjs` 被 Node 作为文件级测试报告通过 | 新 reporter 区分真实声明的测试与空文件；拒绝无测试、全跳过、TODO、取消和失败。前端/cloud 检查要求零跳过；Mac 发布脚本允许其明确的平台跳过，并记录数量 |
| CI 汇总缺少失败解释/可接受可选任务被跳过 | 旧 evidence 条件接受 formed/scale 的 skipped，未核对它是否被请求；失败时汇总任务本身也跳过 | 标准运行总是保留各任务判定；必需任务全部 success，请求的额外矩阵也必须 success；未请求项目明确记 skipped。Claude/formed-only/scale-only 不产生完整 CI 成功封条 |
| 工作流合同落后于 Claude 定向模式 | 未修改起点工作流回放已有 5 个失败、2 个错误；不是本轮新门禁造成 | 用解析后的条件验证普通、scale、formed、Claude 模式；同时核对执行门禁、必跑用例和失败产物上传接线。成功封条的文件结构保持签名消费者原合同 |
| 报告类型过宽、性能只信布尔值 | Python 的 `0 == False`/`1 == True`；压力报告只需自行宣称 budgetPassed | formed 报告严格区分布尔与数字、要求整数 totals；native scale 独立核对原 600 秒/1 秒限值，拒绝改阈值、NaN、负值及自报成功但超时 |
| 错误文本可能包含凭据 | 合成 NSError 的 access_token 字段未输出，但 description/reason/path 中的 Bearer 哨兵原样输出 | 报给接手会话后，由其最小修改 Swift/TS 文本脱敏；独立复测同四输入均不再输出哨兵。没有检查真实凭据，也没有证据表明曾发生真实泄漏 |
| 前端日志观察者异常向业务调用传播 | journal 和 command 通知直接调用观察者；故意抛错后异常逃逸，后续观察者调用为 0。API 成功路径调用该日志函数，存在覆盖操作结果风险；未声称实机已发生 | 独立新增三项测试，旧实现 3/3 失败；接手会话完成逐观察者/首次回放/console sink 隔离后，同三项 3/3 通过。记录及后续通知保持，验证范围不外推为全部前端异常均能隔离 |

报告字段不能一律要求 true。`published-recovery-reads.catalogActionsVerified=false` 与 `catalogParserCalled=false` 保留其未验证 UI 操作的原义；formed interrupted 的 `oldBPreserved=false` 仍表示该输入没有形成 B。原始报告没有改写。

## 实际源码变异与负控

所有源码变异只在 `scratch/integrated-recovery/stabilization-20261104/gate-audit/` 下的隔离副本编译，未写回产品文件。

| 保护点 | 正控 | 反控实际结果 |
|---|---|---|
| `RefreshClaimGuard::drop` 清除占用并通知已等待 reader | 抽取实际 Drop 体和接手会话的实际测试，使用同样 Mutex/Condvar 所需状态，退出 0 | 删 `notify_all`：退出 101；删 `refresh_in_flight = None`：退出 101。仍使用原两秒通知预算，不涉及冷读取其他工作 |
| Swift 导入的反向旧历史覆盖 | 当前 `BusinessSnapshotRetryTests` 六项正控通过，实际存储代码参与 | 仅移除 `snapshot(source, covers: retained, ...)` admission：破坏性重试测试报六个断言失败；合成账目从 300 变成 100/299，证明不是只数测试名 |
| 结构化恢复日志字段边界 | 新 `RecoveryDiagnosticsPrivacyTests` 使用实际日志 writer，验证 header/event/latest-failure 的固定字段集合，通过 | 给隔离 Header 增加 `debugPath` 字符串：编译成功，新增字段集合断言失败，进程退出 1 |
| 恢复报告完整性 | 真实历史 Mac、Windows `c09-2344` 报告均被新门禁接受 | 每个场景逐个删除、重复、改 SKIP/FAIL；删除崩溃阶段/恢复次数；破坏账目、只读、保留和嵌套证明，均拒绝 |
| 命令与证据一致性 | 真实子进程输出完整测试摘要，退出 0，被接收 | 成功摘要配退出 7、空输出配退出 0、缺必跑用例、源码 SHA 不同、旧输出已存在，均失败；不覆盖原证据 |
| 性能延期的记录真实性 | 维持原性能数值与测试入口 | 历史 `c09-cb-native-macos` 性能报告仍被拒绝；未把延期改写成性能通过 |

guard 抽取探针不替代完整 Rust 应用编译。Swift 小模块保留实际迁移/SQLite/日志实现，但资源定位与未用 Exact 依赖使用已记录 stub；它不替代完整 App 启动或所有 Exact 语义。

## 本轮实际执行

| 范围 | 结果与边界 |
|---|---|
| Python 检查器与工作流测试 | 最终 90 项通过，0 跳过；包含原有 formed、压力、归档证明测试和本轮负控。`python-audit-final.log` |
| Node cloud 脚本 | 15 项通过，0 跳过，采用新执行门禁；包含 candidate 内容/源码绑定及签名/发布合同的隔离测试 |
| Node 全前端 | 最终 1,419 项通过，0 跳过、无空测试文件；运行前后全部 `tauri-app/src` 文件摘要一致（`frontend-verified-source.json`）。先前 1,412 项为脱敏前结果，另一次 1,418 项虽通过但源码在运行中变化，保留为不绑定最终源码的中间证据 |
| 接手会话脱敏后的前端定向复核 | `errorDetails.test.mjs` 5 项通过；同四个 Swift NSError 合成输入复测均没有哨兵值 |
| 前端日志故障隔离新回归 | `diagnosticFailureIsolation.test.mjs` 三项在原实现失败，接手会话产品修补后由独立审查复测三项全通过。旧红灯日志保留 |
| Node 全 scripts | 109 项中 108 通过、1 跳过；跳过的是 Windows 环境 PowerShell fixture，在本机 Mac 上未执行。cloud 的 15 项包含于这组，不应相加冒充不同测试 |
| Swift 日志/迁移 | 实际存储小模块 7 项中 6 通过、1 性能 profile 明确跳过；新日志字段测试另 1 项通过 |
| Rust 日志 | 复用接手会话已经编译的本机产品测试二进制，11 项通过；性能 profile 在未设置环境开关时早退，不能由“11 passed”宣称性能已经测试 |
| 静态工作流接线 | YAML 实际解析、模式表达式/门禁接线测试和 `git diff --check` 通过；没有把字符串检查称为 hosted 执行 |
| Windows/完整 hosted CI/升级矩阵/安装 | 本独立审查没有重跑，仍为 NOT_RUN；历史 PASS 和历史 failure 保留各自来源 |

本机 Node 为 26.4.0，Python 为 3.13.13，Rust 为 1.93.1。工作流配置 Node 24；新 reporter 尚需 hosted Node 24 和 Windows 实际执行确认。本轮不会因本机门禁通过宣称云端必定通过。

## 门禁范围核对

当前 `.github/workflows/ci.yml` 是标准运行与成功封条的入口。Swift、Rust 两平台、前端、Windows updater，以及按需额外矩阵必须按其各自条件完成；生产 fixture 的失败仍会单独挡住整组，不因随后库测试通过被覆盖。关键旧 state、旧账覆盖、日志故障隔离、结构化日志隐私及等待通知测试已经接入必跑清单。压力/性能任务仍按用户决定单独执行、如实失败。

`release-upgrade-compatibility.yml` 是公开 0.9.7 源码生产输入及升级验证；`formed-release-upgrade.yml` 是锁定 0.9.8–0.9.11 的 Rust 历史 producer、committed/interrupted 和三次独立重开。这些是单独证据，标准 CI 成功不自动代表它们已执行。本轮仅复测其报告/工作流合同，未重跑 producer 矩阵。

`check_startup_admission.py` 是有边界的独立 Swift 探针。`index-regression.yml` 是旧分支的定向 Windows 回归；其普通 filtered cargo 命令仍没有本轮执行包装，不能作为本分支标准完整验收或发布封条的替代。不会把遗留工作流的一个绿色 run 外推为当前新门禁通过。

prepare/sign/publish 流程本轮只检查源文件与本地隔离合同：候选 manifest 的源码/运行身份和字节摘要、成功 CI 证据的精确结构、签名包的文件集合，以及公开发布确认仍保留。`run-guard.py` 验证运行来源并非单独证明 source SHA；精确源码绑定依赖后续 candidate/checked-source/packet 校验。未调用受保护环境、签名密钥、发布 API 或线上更新。

## 可重跑入口与原始证据

在该工作树中运行：

```sh
python3 -m unittest discover -s scripts/tests
node scripts/cloud/run-node-tests.mjs scripts/cloud --no-skips
node scripts/cloud/run-node-tests.mjs tauri-app/src --no-skips
node scripts/cloud/run-node-tests.mjs scripts
```

Node 运行可以通过 `TOKENBAR_NODE_EXECUTION_REPORT` 指定一个尚不存在的输出文件。Swift/Rust 常规命令已在 CI 中使用 `check_test_execution.py` 包装，保留逐项日志及 `.execution.json`；执行失败不会生成成功结论。门禁要求证据路径不存在，重跑时应使用新的输出位置，不清除旧失败。

本机证据根目录为 `scratch/integrated-recovery/stabilization-20261104/gate-audit/`，不入 Git。关键文件：

- `baseline-ci.yml`、`baseline-workflow-tests.log`：未修改起点的合同漂移。
- `../production-report-gate-before.log`：仅两条检查的旧门禁实际错误接收；其中其他新接口缺失错误只是缺接口证据，不算产品负控命中。
- `refresh-guard-mutations.json` 与三份 Rust 变异日志：通知/占用正负控及源体摘要。
- `accounting-mutation/result.json`、`mutated.log`：旧账保护变异。
- `diagnostic-mutation/result.json`、`mutated.log`：日志字段泄露变异。
- `error-privacy.json`、`error-privacy-after.json`：同输入在接手会话修补前后对比，仅存合成值存在与否。
- `diagnostic-isolation-before.log`、`diagnostic-isolation-after.log`：三项日志观察者/console sink 故障隔离反例及同测试复测，保留真实失败。
- `swift-diagnostics.log`、`swift-diagnostics-privacy.log`、`rust-diagnostics.log`：实际日志/隔离结果，保留跳过与早退边界。
- `frontend-verified.execution.json`、`frontend-verified-source.json`、`cloud-node.execution.json`、`release-node.execution.json`、`python-audit-final.log`：门禁自身及回归结果；早期 frontend-node/frontend-final 证据一并保留，不替代最终稳定源码结果。
- `review-evidence-manifest.json`：本审查负责文件和关键原始证据的 SHA-256，工作树 HEAD/未提交状态单列；不把联合工作树宣称为已提交 SHA 的结果。

最终集成仍由接手会话负责固定提交并复核。此报告的完成意味着上述独立审查与负控已交付，不意味着已经发布稳定版，也不保证所有未覆盖错误、异步回调或未知凭据编码均已消除。

## 接手会话最终复核补注

独立交付后，根接管 `check_test_execution.py` 及对应测试，修正实际日志显示的 Swift 多 bundle／空尾包和 stdout／stderr 交错行问题，补 Rust ignored 计数一致性，以及指定 SHA 前后 tracked 源码一致性。新增四个测试方法在修改前产生实际失败；修后 Python 全套从本报告独立阶段的 90 项增加为 94 项并全部通过。`execution-gate-real-logs-final.json` 记录完整产品真实日志正控，不能只用人工摘要证明解析器可用。

根另在实际 `command.ts` 三种 API 路径验证坏观察者／警告输出端不改变成功、fallback／null 与原始拒绝；成功 payload 中 diagnostics／warnings 的 JSON.stringify 旁路已替换为同一有界脱敏 formatter，并保留循环对象反例。最终源码、验证结果和本地提交以 [统一接手记录](2026-11-04-stabilization-takeover.md) 及其 `final-verification.json` 为准。本报告交付清单仍保留独立阶段的原始摘要，不冒称根随后修改属于独立阶段证据。
