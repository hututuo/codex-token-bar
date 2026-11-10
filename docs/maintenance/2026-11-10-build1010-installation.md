# 离线额度与客户端四列布局：build 1010 安装记录

2026-11-10，Asia/Shanghai。用户在完成离线额度和主页排列方案后明确要求“替换”。本次使用 GitHub Actions 构建的候选包，不在本机进行 Swift/Cargo/前端编译，不发布 Release、tag 或 appcast。

## 源码与本批范围

- 产品源码：`372a70d6d8cf3fcc8f794ead9177831f3cf6e55a`，分支 `codex/storage-responsibility-split-20261106`。
- 版本：`0.9.11`；目标 build：`1010`；原已安装 build：`1009`。
- 包含 [Claude / Antigravity 离线额度](2026-11-10-offline-client-quotas.md) 和 [按客户端四列模型费用](2026-11-10-client-model-four-slots.md)。额度读取不发 HTTP、localhost RPC 或 CLI 刷新请求；旧额度只显示缓存状态，不伪装为当前余额。
- 包含 Fable 5.2 显示名、标准/Fast PriceBook 与缓存写入 TTL 计价；不改变原有模型价格、账本和存储职责 A–D。
- `607220d6` 修复首次云端发现的额度预留标题与旧测试契约差异；`372a70d6` 仅修正三份 Swift 测试的旧分组/旧 Fable 最新模型断言。最终三门统一绑定 `372a70d6`。

## 云端检查

| 门禁 | Run | 结果 |
| --- | --- | --- |
| Hosted project checks | [42825443610](https://github.com/hututuo/codex-token-bar/actions/runs/42825443610) | 全部通过；第二次 attempt 重跑了第一次环境故障的 Windows 任务及最终检查封口 |
| Public v0.9.7 database upgrade | [42825443622](https://github.com/hututuo/codex-token-bar/actions/runs/42825443622) | macOS、Windows 全部通过 |
| Prepare hosted installers | [42825490219](https://github.com/hututuo/codex-token-bar/actions/runs/42825490219) | macOS arm64、Windows x64/arm64 全部通过，安装包已下载并验证 |

已核对最终 SHA 的执行报告与原始日志：

- Frontend：1,474 通过，0 跳过；cloud scripts：18 通过。
- Swift XCTest：2,457 通过、38 个既有跳过、0 失败；Swift Testing：676 通过。release scripts：112 通过、1 个 Windows 专属案例在 macOS 跳过，由 Windows lane 执行。
- Rust macOS：1,835 通过、14 个 ignored；Rust Windows 两次均为 1,778 通过、14 个 ignored，0 失败。生产 fixture、备份清理与数据库文件身份负向对照均通过；最终 `ci-execution.json` 为 PASS。
- 新的五项 Swift 离线额度测试、四项 Rust 离线缓存测试、共享四槽位/周期隔离案例、Fable 5.2 标准/Fast/写缓存 TTL 案例均实际执行通过。
- Swift 报告的受检源码为干净 `372a70d6`。Rust 工作目录包含允许的合成运行报告，`trackedDirty=false`、`untrackedInputs=[]`；不能把这些报告误记成产品源码污染。
- Public 0.9.7 升级：使用实际旧版本生产夹具；macOS 8 项升级、107 项辅助回归通过；Windows 旧生产器、0.9.3→0.9.7→当前链及非 test 生产启动路径通过。

第一次 Windows 失败发生在原生回归之后的 packaging self-test：`community.chocolatey.org/api/v2` 对 NSIS 3.13.0 查询返回 HTTP 504，随后 NSIS 缺失检查报错。在原 SHA 上重跑失败任务后，NSIS 安装、packaging self-test 和后续全部检查均通过；没有修改业务实现或跳过检查。

标准 CI、public 0.9.7 升级及双平台打包是本次要求的门禁。可选 formed-upgrade / scale 扩展矩阵未在本次额外运行，不能由标准 CI 的成功推导出其本轮已执行。

## 已验证的 macOS 候选包

manifest 的 source/run/lane、资产集合、文件大小和 SHA256 全部验证通过。App 为 arm64、ad-hoc 签名，`codesign --verify --deep --strict` 与 `hdiutil verify` 通过；未做 Apple notarization，未签署或发布 Sparkle 更新包。`spctl` 对未公证候选的拒绝与既有签名政策一致。

| 资产 | SHA256 |
| --- | --- |
| `CodexTokenBar-v0.9.11-macos-arm64.app.zip`（与兼容名称 zip 相同） | `31ccbb4d872e9a1efd2826340243e39bc47a7c32987b0994320312449c725843` |
| `CodexTokenBar-v0.9.11-macos-arm64.dmg` | `657ed9406fd9c225f5e3106d218a5855f140e6784f2210721e83f763d07f1a82` |
| `Contents/MacOS/CodexTokenBar` | `bd29b1d89f01f6ba4878db104404f5718e3e26ee0cd245e9cc55f5561d773ad2` |

`local.codex.token-bar`、designated requirement、Sparkle feed/公钥与 1009 完全一致；三个模型 JSON 资源与源码逐字一致。主程序和两个 helper 均为 arm64，动态依赖为系统库及包内 Sparkle。

Windows 两个安装器也已通过同一 manifest 校验：arm64 `b9c6442a2244843d91892ee27f21dcbc88b074b7ba390490a351785c55a65020`；x64 `aae697301bcb934b8142bd8120c3823de6852046eb28c6fb3e8651769b57c16a`。本机只安装 macOS 应用。

## 安装状态与证据位置

北京时间 **2026-11-10 22:28** 已将经过验证的 1010 替换到 `/Applications/Codex Token Bar.app` 并启动。安装后的主程序 hash、版本号和 code signature 与已检候选一致；进程路径指向该系统 Applications 目录，PID 为 `85964`。

- 1009 原进程通过正常退出路径完成 `shutdown/completed`，时间 22:27:09.629；没有强杀或直接修改业务数据库。
- 1010 启动于 22:28:07.687，22:28:12.688 达到 `startup/ready`。
- 首次刷新于 22:28:13.193 开始，22:29:42.735 发布 `numeric_ready=1`、`detail_ready=1`，22:29:42.849 达到 `refresh/ready`。
- 22:29:42.871 记录 `updater/confirmed`，匹配本次安装 attempt `c26dde8e-c2fe-4a0e-9540-7b6b926582e8`、目标版本 0.9.11/build 1010 及安装路径；相应 confirmed receipt 已存在。此确认由成功刷新触发，不只是启动命令返回成功。
- 运行 session：`246d049f-9fd5-445c-a89a-faf10dd90a76`；首次刷新期间没有 `failed` 诊断事件。上述是启动与刷新验证，**不是完整交互式 GUI 验收**。

本机证据根目录：`~/Library/Application Support/CodexTokenBar-Maintenance/2026-11-10-local-quotas-four-slots-Q8xEEt/`。

- `backup-build1009/Codex Token Bar.app`：已校验的原版备份，主程序 SHA256 为 `cbe5933f9c885dce7d65770f51ef7ed8e4360d42c1624bb3391d78b8658d4c57`。
- `replaced-build1009.app`：退出后移入证据目录的原安装包，另行完整保留；如需回退，应先正常退出 1010，再恢复已验证的 1009 App，不清理或回写用户数据库。
- `final/`：最终 SHA 的测试报告、升级夹具/日志、候选包与云端渲染图。
- `final-validation.json`：`installed=true`、`guiTested=false`，含候选/安装 hash、门禁、原版备份、诊断事件时间和回执路径；此前尝试保留于 `attempt-0/`、`attempt-1/`，不冒充最终 SHA 门禁。

安装操作没有更改用户设置或 provider 缓存，没有直接编辑业务数据库；应用重启后按原生产路径执行正常刷新。`AGENTS.md`、`HANDOFF.md`、受保护 Windows 报告的 hash 与接手基线一致；其他原有 dirty/untracked 材料保留。没有执行实机 GUI 点击、展开、截图或视觉验收，也未发布公共更新。
