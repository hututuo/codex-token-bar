# 后台升级、本地 Claude 额度与速蹬状态：合并交接

## 范围和分支

- 工作树：`/Users/huyiyang/.codex/worktrees/multi-client-tokens/codex-token-dashboard`。
- 本批分支：`codex/startup-and-local-quota`，起点为本地 main `203954d7`。
- 可拆分合并：`7a233b37` 后台启动门禁；`88d99626` 独立 Claude 本地额度扫描/显示；本文件所在的后续提交补主页上报状态与说明。
- main 已有：`d07ebf84` 多客户端整合与新版额度排布；`2e7692b7` 不兼容闲置索引原样保留；`203954d7` 普通启动跳过重复迁移及无用目录解析。合并方应先核对自己是否已包含这些提交，不能只复制本批 UI 文件。
- 本批按用户最新要求只交源码与测试，不打包、不安装、不重启正式应用、不替换 Windows EXE、不推送远端。此前生成的 build 964 不包含本批完整改动，也未安装；本机仍为 build 963。

## 1. 先显示窗口，再后台准备账本

macOS 的 App 初始化只做轻量设置，初始窗口显示 `ApplicationStartupView`。`ApplicationStartupCoordinator` 启动异步门禁，实际迁移在 utility 后台任务执行；显示准备、导入数量、核对和激活阶段。所有业务 owner 都留在 `CodexReadyApplicationRuntime`，只有门禁成功、路由和写锁就绪后才构造。失败显示原因和重试按钮，不启动业务写入；准备/失败期间退出也不会为了 shutdown 意外构造额度服务。保留原来的菜单、更新、自启、悬浮窗和账号流程。

Tauri 先创建桌面窗口，再在线程池执行原 bootstrap。前端 `BusinessStartupGate` 在 ready 前不挂载 Dashboard/其他业务表面。ModelTrace、自动续跑、侧栏、悬浮窗及 live/status owner 延迟到 ready。独立的进程就绪状态不等同于磁盘 marker；维护阶段也结束后才放行。普通 A 读写、已登记分区和维护入口都受门禁约束，内部 bootstrap 使用专用路径。等待者使用广播通知，避免多个 owner 中只有一个被唤醒。

新增 IPC：`read_business_startup_state` 返回 `{phase:"preparing"|"ready"|"error",message:string|null}`；`retry_business_startup` 仅在失败后接受一次任务，且限主窗口。状态查询不等待迁移锁；前端可轮询并接收 `business-startup-state-changed`，其他窗口也能在一次重试成功后恢复。

## 2. 数据与旧版兼容边界

- 长期业务库仍为 A `codex-ledger.sqlite`、B `multi-client-usage.sqlite`，本批不增加业务数据库或更改其 schema 号。
- 首次归并仍执行原来的在线备份、结构及逐行证明、变更复核和原子激活。原始 Codex 数据、各 Home 的账本、删除/归档后保留的历史与 fork 新轮次不因后台化而清理或重建。
- 中途退出依靠 SQLite 事务和候选库重试机制恢复；失败不绕过门禁。旧 schema 3/4/5 等当前读者不支持的来源按原样归档到分区，实际打开那份 Home 时仍拒绝不兼容写入，不阻断其他兼容 Home。
- **兼容不等于双向同步。** 旧版程序不能直接读统一 A 的命名空间；保留的旧库/升级备份可恢复升级前状态，但迁移后仅写入 A 的新增记录不会自动反向写回旧库。回退前须保留最新 A/B，若要求旧版也展示迁移后的全部记录，需要另做经验证的导出/回迁。不能直接删除 A 后让旧版覆盖。
- 本次本机首次迁移已经完成：713 个分区，原主库 518,068 条事件导入前后相同，随后正常接收新增记录。本批后台启动 UI 和新逻辑尚未做安装验收。

## 3. Claude 自动读本地，读不到则隐藏

启动即探测已有本地额度缓存，之后最多每分钟读取一次并复核有效期。不依赖用户开启会话采集，也不依赖速度监控。没有自动启用 transcript 采集、自动安装 statusLine、读取账号凭据、启动 Claude 或请求 Anthropic；Claude 也仍不参与上报。

沿用已知路径：本机 TokenBar statusLine capture 与已有 `.claude-monitor/statusline/latest.json`。读取有大小上限，旧/无效缓存不作为有效额度。有效额度只影响显示可用性，不修改采集偏好。

主界面和各级侧栏只投影真正读到的 Claude 窗口：缺失、未接入、过期、非法值均不生成占位；测得剩余 0% 仍显示。只读到一项就显示一项完整环，不补造第二项。设置中保留接入状态供排查。Codex 既有显示保持原口径。

用量库读取失败不阻止独立额度探测；前端保留最后可信用量，仅更新本地 Claude 额度读数。两端均有相应测试。

## 4. 速蹬错误在主页可见

已开启上报时主页有一条紧凑状态行：连接/上报状态、最近上报时间、错误及重试/设置入口；关闭时隐藏。设置页错误状态不再显示绿点。Windows 主页与设置共用一个状态订阅，每个 WebView 可见时 5 秒、隐藏时 30 秒查询一次缓存状态，无新增测速、扫日志或上报请求；取消订阅释放定时器，旧查询不能覆盖刚修改的开关状态。

macOS 对发现阶段的连接/超时、安全连接、格式不兼容、停服分别说明。未调整 Agent Speed 协议、签名、接收地址或 15 秒发现超时，也没有修改代理规则。

本机诊断为同样的 URLSession 请求 15 秒报 `-1001`，另一只读 GET 约 19.5 秒返回 200，不能据此宣称服务器停机。用户正在自行调整规则：

```text
deng.codexradar.com
speed-api.codexradar.com
https://deng.codexradar.com/.well-known/agent-speed-report
https://speed-api.codexradar.com/api/agent-speed
```

## 验证与合并注意

- Swift：应用全量 2066 项（20 项条件跳过）、本地采集 8 项、上游 Agent Speed 649 项，零失败。日志 `scratch/source-only-swift-final-full.log`。
- Rust：全量 1486 通过、11 ignored、零失败。日志 `scratch/source-only-rust-final-full2.log`。新就绪状态测试使用隔离 coordinator，不修改全局状态；覆盖失败重试去重、所有等待 owner 被唤醒。
- 最后 owner 启动顺序调整后再次检查启动状态 3 项、窗口鉴权 26 项，全部通过；日志 `scratch/source-only-startup-final-regression.log`、`scratch/source-only-window-auth-final-regression.log`。
- Rust 非 cfg(test) 生产路径夹具 PASS，所有路径限定临时根并在结束后回收。包括旧文件保留、不同 Home 隔离、TEMP 阶段、重复启动与缺失 A 故障关闭。日志 `scratch/source-only-production-fixture.log`。
- Windows：`cargo xwin check --target x86_64-pc-windows-msvc --lib --offline --locked` PASS；未生成/运行正式 EXE。日志 `scratch/source-only-windows-check-final.log`。
- 前端 TypeScript `--noEmit` PASS；最终全量 1297/1297，日志 `scratch/source-only-ui-final-complete.log`。就绪前不挂业务组件、主页错误可见、共享订阅、Claude 无效窗口隐藏及独立探测均有用例。
- 首次 Rust 全量出现既有 marker 测试把 `performance-trace.log` 当成原子临时文件残留的误报；断言现只检查目标 marker 的临时残留，保留真正的临时文件检查，未改产品写盘逻辑。最终全量已通过。
- 新源码的正式包/GUI 安装验收为 NOT_RUN，按用户要求留给后续合并后的统一测试打包。不要把 build 963 的截图当成本批背景迁移 UI 的实测截图。

冲突重点：`CodexTokenBarApp.swift` 的业务 owner 构造必须留在门禁之后；`lib.rs` 的窗口先创建、后台 bootstrap、后置 owner 顺序必须保留。客户端显示过滤和全局范围选择要一起合并；不要只隐藏 UI 却重新让额度依赖 transcript 开关。新增 IPC 的窗口鉴权与前端 gate 也必须一起合并。Agent Speed vendor pin 未改，改动仅在 Token Bar 适配层。
