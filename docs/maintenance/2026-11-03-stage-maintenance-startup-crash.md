# build 991 首次维护回调崩溃

**最终状态：修复源码 `c5e3714d615c891f4e0d5d7a3a918c46c794c2b1` 已推送。本机已换为0.9.11/build992，同一进程持续运行超过原首次回调崩溃窗口，精确统计恢复更新；没有新增992崩溃报告。未合main、未替换Windows、未发布。**

## 现场证据

2026-11-03 用户授权本机替换后，安装云端 run [41607923759](https://github.com/hututuo/codex-token-bar/actions/runs/41607923759) 产出的 macOS 0.9.11/build991。包的源码为 `28a0dc6a7411b1caf8962bd11d5e180472f92139`，安装前已核对 artifact、全部四项 manifest 资产、arm64、应用签名、稳定 designated requirement 和随包资源；旧程序及升级前数据快照保留。首次窗口和历史账目显示不能证明其后定时器运行正常。

本机原始系统报告 `CodexTokenBar-2026-11-03-173519.ips`：事件 `DAAF076C-DAC7-4E7A-BEEB-4641CE3032A5`，PID22721；17:34:24 启动，17:34:58 崩溃，运行约34秒。系统为 macOS27.0.1/26A434，异常 `EXC_BREAKPOINT/SIGTRAP`，不是正常退出。

崩溃线程是 `tokenbar.exact-stage-maintenance`，关键栈：

```text
_dispatch_assert_queue_fail
dispatch_assert_queue
_swift_task_checkIsolatedSwift
swift_task_isCurrentExecutorWithFlagsImpl
closure #1 in ExactStageMaintenance.start()
_dispatch_source_invoke
```

## 定位和最小修改

维护器由 `23cfb3ee` 引入，默认首次执行在30秒后。`start()` 标记 `@MainActor`，其 `DispatchSource.setEventHandler` 闭包未显式标记 `@Sendable`；该闭包带入主actor隔离检查，却在私有utility队列调用，现场在首次回调入口触发检查而trap。

仅给这个后台回调显式加 `@Sendable`，保留其在utility队列执行、30秒初始延时、错误退避、回执校验和维护逻辑；不将维护搬到主线程、不关闭actor检查。新增DEBUG限定的初次延时和观察注入，以便两项回归实际触发同一计时器，验证后台执行及重复start不创建多个回调；release没有这些测试入口。

只读核对了其它DispatchSource回调：RecoveryDiagnostics及AutoResumeThreadLease不在MainActor上下文构造；LiveRateMonitor的source使用main队列并显式进入MainActor。未发现另一处同类冲突，未借此重构。

## 验证与数据边界

- 本机用实际维护器源码及新增测试编译独立小模块，两项真实timer测试通过；账务依赖为无操作stub，不冒称整包验证。
- 实际修复源码另以优化编译、无DEBUG、保留默认30秒首轮间隔运行34秒，观测到 `DEFAULT_RELEASE_TIMER count=1 ranOnMain=false`、退出0；只替换账务依赖，不进入用户数据库。这仍是计时器模块证据，不能代替修正版整包启动。
- 加速首次触发的旧代码命令行探针未触发trap，不能作为旧代码复现成功；原始完整App的系统崩溃报告才是现场依据。保留该探针原始退出码，不改成红基线。
- 完整同源码云端证据使用文末c5结果，不使用991原有绿灯覆盖新增代码。
- 无数据库schema、parser、费用规则、Windows实现或更新源修改；不删除或用备份覆盖原账。旧程序与升级前数据快照保留。没有发布更新。
- 崩溃后原地只读检查：A/B的 `PRAGMA quick_check` 均为 `ok`；A仍 `activation_state=ready`、root schema1、929个store，B user_version2。它证明检查时的SQLite结构完整性，不宣称未逐值核对的所有账务数值。

## 修正版的同源码与本机证据

- [标准回归41615246239](https://github.com/hututuo/codex-token-bar/actions/runs/41615246239)：c5，success。XCTest2354 executed（含37 skipped）、0 failures；新增实际timer两项通过。Rust Windows1673 passed、14 ignored、0 failed；双端生产存储fixture保持。
- [Public097升级41615246166](https://github.com/hututuo/codex-token-bar/actions/runs/41615246166)：同c5，双端success。原0.9.8–0.9.11八路Rust形成状态保留28的记录；c5相对28未改Rust、形成器或数据库算法，不冒称重跑八路。
- [候选构建41615273400](https://github.com/hututuo/codex-token-bar/actions/runs/41615273400)：**整组failure，Mac job125847167892 success**。Windows打包job的 `panic_after_refresh_claim_releases_cold_waiter` 在2秒等待超时，1672 pass／1 fail／14 ignored；相同源码的标准Windows回归中该项pass。两条结果均保留，未放宽时限或改Rust；Windows包仍须后续复核，不称双端安装包全通过。
- Mac artifact13221873412，85,040,383 bytes，外层SHA256 `9ba3aca24469be358b1a84e75a1b21d35ea822fd333802df98bf3f849d21387a`。根复核run head、实际manifest源码均为c5，全部四项资产哈希、992版号、签名、随包资源及更新公钥一致。未改更新源或调用更新签名密钥。
- 已安装 `/Applications/Codex Token Bar.app`，主可执行SHA256 `810258c2f95820fe1889aaff8c73e959253fd713b808d918c0a585690b0428f7`。PID72571在首次UI读出后再持续观察45.15秒仍为同一启动／同一可执行；新build992系统崩溃报告为0。最终再次检查同一PID时进程已运行5分22秒。AX读到统计“数据更新于18:31:55 · 图表至18:30”、累计918.5亿Token，额度和主页可见。该证据限本机本次启动，不扩大为全App／所有用户环境验收。
- 990原程序、991故障程序、原始ips及升级前APFS数据快照保留，未恢复覆盖或删除当前账本。详细本机身份及观测保存在本worktree `scratch/integrated-recovery/local-install-20261103/build992/installed-identity.json`。
