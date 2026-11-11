# build 1013 替换与下一版额度刷新设置接线

用户要求先替换已验证的额度修复，再把本地额度自动刷新接到主页面已有时间设置；后者留下一版一起打包。额度读取仍必须离线。

## 已安装：build 1013

产品源码固定为 `cba17c63fc376fd3e03221fe10256149327b5992`，包含 Claude 2 MiB zstd 窗口与查询参数适配，不包含下述刷新频率接线。此前完整 CI 与双平台 Public097 门禁均通过。

[Prepare hosted installers 43046305040](https://github.com/hututuo/codex-token-bar/actions/runs/43046305040) 的 macOS、Windows x64/ARM64 和汇总任务全部通过。两个 candidate manifest 的 source/run/lane、精确资产集合、大小与 SHA256 已核对；Windows build manifest 的版本、两种架构、平台及资产 hash 与外层清单一致。macOS 另通过 checksum、ZIP 路径/符号链接、深度严格签名、DMG、包内资源检查；从 `/private/tmp` 执行资源校验，未启动候选 GUI。共享资源字节与该源码一致。

`/Applications/Codex Token Bar.app` 已由 build 1012 替换为 `0.9.11 / 1013`。主程序 SHA256：`1de453a06cd66f4e7766bc07c10780a638cc9d8e53d376afa4ccf4618f79357e`。Bundle ID、designated requirement、Sparkle feed/公钥与旧版一致；依赖为系统库及包内 Sparkle，无新增运行时安装要求。保持既有 ad-hoc、未公证、未发布公开更新策略。

替换前完整备份并校验 132 个文件/符号链接及签名，旧进程正常退出，新包同卷暂存后替换。备份与旧 App 原体均保留。新进程启动、startup ready、4,424 文件处理完成、pending 0、schema 14、published generation 27918、numeric/detail ready 及安装确认均已观察到。

同一次启动另有一条通用 `frontend.failed` 诊断事件，journal 未记录来源与内容；未进入 GUI 日志页，不能据此宣称整个界面无异常。后续存储/首次刷新完成与安装确认已独立验证。界面效果由用户查看，未做鼠标、窗口或 GUI 自动化验收。

本机证据：`~/Library/Application Support/CodexTokenBar-Maintenance/2026-11-11-quota-investigation-7shd8xj3/build1013/`。入口 `candidate-validation.json`、`installation.json`、`runtime-validation.json`；备份索引 `installation-preparation.json`。旧版保存在该索引指向的 `install-build1013.bwwg0hio/`。没有改写用户设置、provider 缓存或业务账本。

## 下一版源码：已有设置作为单一入口

设置已经存在：Swift `AccountQuotaRefreshCadence.storageKey` 与 Tauri `quotaRefreshIntervalMs`，支持 30 秒、1/2/3/5/10 分钟，默认 1 分钟。安装时用户保存值为 60 秒。本轮不新增设置键，不改变用户保存值。

- Swift 本地额度周期和读取限频都使用已有 cadence；复用额度计时器接口和 common run-loop 调度。设置变化替换旧计时器，无关设置不重启计时；停止后旧回调不能重新建立计时器。会话用量扫描保持原调度，额度读取不依赖采集开关。
- Tauri 本地额度有独立共享时钟，读取并订阅同一个设置；保持用量扫描时钟不变。订阅者共享轮询，隐藏页面不读文件，最后一个订阅者退出时清理计时器与设置订阅。晚到的启动设置和旧用量结果不能覆盖新选择/新额度读数。
- Rust CLI、Desktop、Antigravity 的读取缓存均使用现有设置导出的间隔，消除底层写死 60 秒吞掉 30 秒选择的问题。手动刷新只跳过本地文件读取复用；Swift 主页面和 Tauri 手动入口也接入同一提供者读取，不调用额度 API 或语言服务 RPC。
- 自动计时触发复用主额度现有的“半周期、最多 30 秒”短期去重策略，避免稍早到达的 tick 因完整周期限频而整轮跳过；用量扫描附带读取仍使用完整选择间隔，不能将 10 分钟额度设置缩短成每分钟读文件。手动读取优先级最高，异步短期读取不能吞掉随后到达的手动刷新。
- 设置说明同步明确本地客户端仅重读已有缓存。账号、客户端与来源边界保持；旧 Antigravity 缓存不会因此成为实时余额。

新增 Swift 可控时钟/计时器回归、Rust 六档间隔和手动读取回归，以及实际 React 订阅回归，检查设置变更、30 秒不被旧限频吞掉、10 分钟不被用量扫描缩短、手动读取、晚到结果及订阅清理。保留原有默认 60 秒回归和用量读取失败时的额度独立回退。

本机仅做 Swift/Rust/JS 语法检查与 diff 检查，完整运行交云端。此部分未打包、未安装；不将源码接线写成 build 1013 的已安装行为。后续云端结果待追加。
