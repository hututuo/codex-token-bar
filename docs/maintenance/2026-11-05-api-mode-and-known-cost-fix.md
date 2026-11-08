# API 模式额度与已知费用修复

日期：2026-11-05。基线：`7e9d88d20758e53f959b496e3abb867ac337fd0e`，分支 `codex/legacy-debt-20261104`。对应排查：`2026-11-05-client-accounting-and-api-mode-audit.md`。

## 修复后的行为

- Codex 根据选定 Home 的 provider、active profile、认证方式判断 API / 订阅 / 未知。明确的自定义 provider 或 API 配置优先于残留的 ChatGPT 登录。
- API 模式显示“API 接入 · 订阅额度不适用”，不启动额度 app-server，不请求 `account/rateLimits/read` 或重置卡；终止既有失败重试并清除当前展示中的旧订阅额度、重置卡和相关错误。
- 保留按既有刷新频率执行的本地模式检查。Tauri 的 `readAccountQuota` IPC 在 API 模式只返回本地“不适用”快照，不访问订阅服务；这使同一 Home 切回订阅后能够自动恢复。不是把额度功能永久关闭。
- 配置/认证/Home 变化使旧请求、旧成功缓存失效；API 认证替换订阅认证时，即使 auth 文件里还留着原账号 Token，也不能复用旧请求结果。订阅内的 Token 轮换仍保留原有稳定账号语义。
- Claude Code 从本地 settings 的 API 配置和当前进程可见环境判断明确的 API 接入，此时屏蔽 statusLine 中的旧订阅额度。Claude Desktop 的独立本地历史来源保持原样。
- Tauri 的多客户端费用行保留 `knownPartialCostUSD`。例如已知 $0.37 加一笔未定价请求，显示 `$0.37 + 未定价`，小计保留 $0.37；全未知仍显示未知，不伪装成 $0。累计、今日、近七天均适用。

Token 采集、压缩计数、历史数据库 schema 和迁移逻辑没有修改。Rust 数处既有 `QuotaSnapshot` 构造器增加缺省字段，仅为兼容新增的可选 `connectionMode`，没有改变各业务库的读写路径。压缩后的首笔普通请求沿用已验证的计费实现。

## 识别边界

Codex 读取的是 Token Bar 选定的 Home，支持配置的 active profile、普通/点式/引号键、常见 inline provider 表，以及 file/keyring/auto 认证存储。Swift 与 Rust 共用 21 个输入案例；不从客户端名称或历史 Token 用量推断订阅身份。原始凭据不会进入日志或前端；只使用本地字段识别模式及现有账号身份边界。

Claude Code 支持 `CLAUDE_CONFIG_DIR` 下的 `settings.json`、`apiKeyHelper`、`ANTHROPIC_API_KEY` / `ANTHROPIC_AUTH_TOKEN` / `ANTHROPIC_BASE_URL`，以及 Bedrock / Vertex / Foundry 开关。既不执行 helper，也不调用提供方接口。

独立客户端进程的临时命令行覆盖、只在该进程中存在的环境变量、不可见的代理连接设置不一定反映在这些本地配置中。没有证据时保留未知或原有订阅读取兼容行为；本次没有新增手动模式覆盖或第三方余额接口。也没有声称模型价表的参考费用等于中转站账单。

## 验证

| 检查 | 结果 | 关键覆盖 |
| --- | --- | --- |
| Swift 定向回归 | 172 通过，0 失败 | API 多个刷新周期零 reader 调用；已有失败重试停止；API→订阅恢复；旧响应拒绝；实际持久服务假 transport 验证无启动；Claude 缓存屏蔽；压缩后首笔计价及多客户端账本 |
| Rust 重新编译后的定向回归 | 192 通过，0 失败，0 忽略 | 共享模式案例；quota/reset loader 禁用；模式/配置切换；账号缓存隔离；额度服务、压缩和多客户端原有用例 |
| 前端定向回归 | 90 通过，0 失败，0 跳过 | 部分已知费用、API 文案无订阅条/重置工具、迟到重置卡不能覆盖 API 状态、既有数据合并和紧凑面板 |
| TypeScript 与 Vite 生产构建 | 通过 | 类型检查与生产资源构建 |
| Rust 非 test 配置及业务 fixture 编译检查 | 通过 | 只编译，不执行 fixture，不接触真实库 |

证据目录：`scratch/integrated-recovery/api-mode-fix-20261105/`。`swift-final`、`rust-final`、`frontend-final` 的 JSON 记录命令、退出码与日志哈希；`verified-source-files.json` 固定受测文件哈希；最终 manifest 汇总结果及提交。

开发过程中先修正了 Swift 对条件闭包表达式的编译诊断问题，并撤回了会阻止自动恢复订阅的“直接停前端定时器”试写。最终实现采用本地检查加原生接口拦截；最终回归才是验收依据。

本轮完成源码修复和本地验证，未安装、重启或发布应用，未执行真实历史回补或数据库迁移。Windows 真机与已安装 0.9.11/build 992 的升级验收尚未执行。
