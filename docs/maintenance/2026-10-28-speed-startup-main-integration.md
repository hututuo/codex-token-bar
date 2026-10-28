# 测速分支与启动/本地额度分支合并

## 输入与边界

- 原本地 main：`203954d747bbab1b215ff62fa75aa2ef3316a8cc`。
- 启动/本地额度：`codex/startup-and-local-quota`，`3a945511a6a52efcc219bf381bd980f5db0d6471`。
- 测速：`codex/speed-display-modes-20261026`，`70b0af4d42c65ffd0e5179e0c94f0830216e2e68`。
- 独立集成工作树：`/Users/huyiyang/.codex/worktrees/integrate-speed-startup/codex-token-dashboard`。
- 集成分支：`codex/integrate-speed-startup-20261028`。处理 31 个冲突文件，保留双方提交历史。
- 仅源码合并与测试；未安装、重启、替换正式应用，未发布、未推送远端，未修改代理规则。其他工作树和分支未改动。正式安装验收仍为 NOT_RUN，不能用旧 build 963 代替本次验收。

## 合并取舍

1. 保留新版 main 的 A/B 数据库归并、历史分区、备份与启动门禁；窗口先显示，业务 owner 在门禁完成后创建。没有删除旧账或回退共享读取架构。
2. 保留本地 Claude 额度独立探测和来源过滤。Claude 会话可供本地速度显示，仍不进入速蹬上报；Swift、Rust 启动参数和 C# 报文白名单均保留限制。
3. 保留测速分支的 HTTP/可选 WebSocket、签名/ACK/退避、费用字段、昵称与邀请视频、P25–P75 分布带/中位数/重置标记、自定义配色和 6.1 Terra 价格。
4. 显示算法统一到现有共享模式。旧测速配置仅在新配置不存在时迁移；各端保存入口保持同步。侧栏不显示两个重复的算法选择器。
5. 使用按来源/root 共享的采集器和现有本地 IPC；不因选择榜单显示模式启动第二个日志 reader。Claude 使用既有独立本地 runtime。浮窗、主页与侧栏保留模型/客户端分组；本地停止/过期截止不改上报计数与原始费用。
6. 采用逐响应模型归属，避免把旧响应尾部计到会话新切换的模型；保留来源过滤和超时归零。
7. 当前价格使用共享 Agent Speed PriceBook；历史使用冻结价格表。新增 Terra 生效分区，不覆盖旧模型的历史价格。
8. Vendor pin 不变；provenance schema 2 区分上游补丁与 4 个本地新增文件，均记录理由和 hash。只忽略 C# 构建输出目录，不放宽源码漂移检查。

## 本次验证

- Swift 相关 XCTest：88 项，3 项条件跳过，零失败；Swift Testing：本地显示 10 项及 AgentSpeedCore 655 项通过。
- Rust 全量：1499 通过、11 ignored、零失败；随后新增配置迁移回归 1 项通过。
- Windows Rust 目标 `cargo xwin check --target x86_64-pc-windows-msvc --lib --offline --locked`：PASS。
- C# AgentSpeedReporter `--self-test`：PASS，含本地共享读取管道、来源限制、HTTP/WS、时间元数据和费用测试。
- C# ClaudeLocalReader `--self-test`：PASS，含显式停止与过期仅影响显示、不改原始速度/计数的回归。
- C# LiveProbe `--self-test-fixture`：PASS，仅合成数据；本次未注册设备或发送真实上报。
- Vendor checker、13 项 provenance 测试：PASS；价格规范：194 模型、80 测试 PASS。
- TypeScript `tsc --noEmit`：PASS；前端最终全量 1307/1307 通过。
- 最后显示桥接与算法入口调整后，Swift 增量编译和所选回归再次 PASS（详见 `swift-last.log`）。

## 测试证据

当前工作树忽略目录 `scratch/`：`swift-final.log`、`swift-last.log`、`rust-tests.log`、`rust-merge-settings.log`、`windows-check-final.log`、`typescript-final.log`、`node-tests-final.log`、`csharp-reporter.log`、`csharp-reader.log`、`csharp-liveprobe.log`、`prices.log`。日志和临时 SDK 不提交。

Windows GUI/拖拽、真实网络/睡眠、安装后界面验收本次未运行；这里只合并源码，不把交叉编译和离线自测当成正式包验收。
