# build 991 首次维护回调崩溃

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
- 加速首次触发的旧代码命令行探针未触发trap，不能作为旧代码复现成功；原始完整App的系统崩溃报告才是现场依据。保留该探针原始退出码，不改成红基线。
- 完整同源码云端测试、release包和本机超过首次30秒回调的运行验证在修正版生成后另记，不使用991原有绿灯覆盖新增代码。
- 无数据库schema、parser、费用规则、Windows实现或更新源修改；不删除或用备份覆盖原账。旧程序与升级前数据快照保留。没有发布更新。
