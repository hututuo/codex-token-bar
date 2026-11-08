# 升级与运行诊断包：build 997 验收

日期：2026-11-09（Asia/Shanghai）。产品版本 0.9.11，macOS build 997。产品源码候选为 `1fad508c1afddcbac281d4a3c4b286b3064fc9d2`，分支 `codex/storage-responsibility-split-20261106`。后续文档提交不改变该安装产物的源码身份。

## 交付范围

双端新增默认开启的固定字段持久事件、有限轮转、单次启动隔离和首个失败保留；观察安装/更新、启动迁移、索引与首次刷新。后端进度和 UI 收到进度分别记录，异步写盘不改变事件的实际观察时间。Sparkle 和 Windows 安装器的启动/重启不是升级确认；macOS 新版本在同一安装位置成功刷新后才确认，Windows 沿用目标版本与同一安装目录的运行确认。

独立采集工具生成 `SUMMARY.md`、结构化快照、允许的历史事件与恢复记录 ZIP。采集模块不依赖 SQLite 或业务库打开/恢复路由，仅对固定数据库文件取元数据。每个探针 3 秒预算、UI 导出有外层超时；缺失或超时明确标记。文件读取拒绝用户软链接、硬链接、FIFO 等非普通文件；Darwin 根目录 `/var`、`/tmp` 仅在确认 root 所有和系统目标后准入。

导出入口包括 macOS 帮助/设置/日志及启动迁移、失败页，Windows 设置/帮助及启动/降级页，主程序 `--export-diagnostics`，以及随安装包附带的独立工具和离线脚本。详细操作见 [诊断包使用说明](../diagnostics.md)。

脱敏采用字段白名单重建及归档边界二次投影，不复制原始日志、认证、正文、原始用户路径或任意错误字符串；不自动上传。旧版本没有记录的历史无法补造。它提供排障证据，不是自动修复器。

## 最终源码云端验证

- [完整 CI 42494441555](https://github.com/hututuo/codex-token-bar/actions/runs/42494441555)：全部必需 job `completed/success`。
- [Release Packaging 42494444216](https://github.com/hututuo/codex-token-bar/actions/runs/42494444216)：macOS arm64、Windows x64/arm64 与汇总全部成功。
- 两个工作流均绑定完整 SHA `1fad508c1afddcbac281d4a3c4b286b3064fc9d2`。下载时验证 GitHub artifact SHA-256，展开后重新核对产物 manifest、每个资产大小及 SHA-256、CI seal、测试日志摘要及源码前后状态。

| 验证 | 结果 |
| --- | --- |
| macOS Rust 完整库 | 1,820 通过，0 失败，14 项既有 ignored |
| Windows Rust 完整库 | 1,763 通过，0 失败，14 项既有 ignored |
| Swift XCTest | 2,403 通过，0 失败，38 项既有条件跳过 |
| Swift Testing | 674 tests / 79 suites 通过 |
| 前端 | 1,446 通过，0 失败、0 跳过 |
| 生产存储场景 | 双平台各 16 项通过 |
| 备份清理负控 | 双平台 baseline / 禁用保护 / restored 的退出码 0 / 101 / 0 |
| 物理 A 替换负控 | 双平台 6 个生产入口；baseline / 禁用身份保护 / restored 为 0 / 1 / 0 |
| 诊断专项 | 脱敏诱饵、真实 SQLite exclusive 锁、损坏文件、零业务写入、超时、重启保留、拒绝覆盖、旧回执无新目录、观察时间与写盘时间分离通过 |
| Windows 更新器 | 安装失败、目录/版本确认、成功启动后的退出前记录与保留 Tauri cleanup 通过 |

本次未重新触发可选四版本历史矩阵、Public097 专项或规模性能测试；本轮完整 CI 和负控不能替代这些专项。保留既有存储基线测试的名称与通过/ignored 状态做了交叉核对。

真实独立采集器也在云端打包流程内运行：Windows x64 的完整 job 日志明确保留 PASS JSON，验证源码目录不变、真实 SQLite 独占锁、敏感诱饵排除、允许的错误码保留和拒绝覆盖（0.359 秒）。macOS 打包脚本将该工具的 stdout 重定向，但命令位于 `set -e` 的必经路径，打包成功；下载后另用同一已签名工具在隔离夹具直接复核，五项均通过（0.535 秒）。没有把缺失的 macOS 云端 stdout 当成可见测量记录。

Windows arm64 已编译打包并核对 manifest；没有声称在本机完成 Windows 桌面 UI 或 ARM64 硬件实测。所有编译、库测试和打包均在云端完成。本机仅做源码/日志/产物核验，以及下载工具和已安装应用的运行验收。

## 本机安装与实测

已将 `/Applications/Codex Token Bar.app` 从 build 996 替换为 build 997。候选与旧版的 bundle ID、Sparkle feed/key、designated requirement 保持一致；两者与独立 helper 均通过严格签名校验。签名沿用 ad-hoc，未新增公证或公开发布。

| 对象 | SHA-256 |
| --- | --- |
| 候选 macOS App ZIP | `975f3923855f493436119cbf3120eddfdc718dcfe38d696aa9a498457664b45f` |
| build 997 主程序 | `485e46eaca48e4be4fc1762d7d599b5aef6e85ed4829105cc4e8dcd33949fc26` |
| 回滚 build 996 主程序 | `ad4ffb022d9b9a5b6daa708c7dae6be4fac4fc35ee54c93969491f19304dea1c` |

回滚副本位于工作区 `scratch/diagnostic-bundle-20261108/local-install-997-jknem5of/rollback-build996/Codex Token Bar.app`。替换前完整保留旧目录；备份与候选的全部文件、符号链接、权限及内容清单分别复核，未覆盖任何已有回滚目录。安装记录和每个验收产物保存在同一 `local-install-997-jknem5of` 目录，云端证据在 `scratch/diagnostic-bundle-20261108/1fad508c`，不提交原始本机日志或诊断 ZIP。

首轮真实启动 PID 72720，界面和统计加载正常。帮助菜单实点导出得到有效 ZIP（318,236 字节）；独立 helper（0.636 秒）及主程序 CLI（0.788 秒）也成功导出。三个入口保留同一主进程，未触发第二个正常业务实例。包内确认 build 997、签名有效、采集未打开数据库；未发现原始 Home/用户名、Bearer、认证/Cookie/正文等敏感字段。新版本确认事件出现在首次成功刷新之后，启动初期导出的包没有提前确认。

第二次启动 PID 75559，启动和该次刷新均完成。重启前的两份事件文件 SHA-256 逐一保持一致，文件数由 2 增至 3；0.598 秒导出新的有效包，完整保留之前的安装确认和首次刷新记录。随 App 的 `Export-Diagnostics.command` 也实际运行并导出成功。最终主窗口截图、保存对话框截图和各入口校验 JSON 已保存在同一验收目录。

重启验收曾在进程刚退出后立即调用 LaunchServices，首次 `open` 返回瞬时 `-600`；稍后重试正常启动，无应用崩溃证据。未修改产品代码或系统设置，也没有以该系统瞬时返回值误记产品启动失败。首次运行与第二次运行中较早导出的快照保留为“当时尚未完成刷新”的证据；最终判定使用刷新完成后的包。

## 发现并修正的问题

首轮新测试拦住 Darwin 系统路径别名被误拒绝；Swift 和安装脚本分别修正，保留对用户链接的拒绝。Windows 打包自测夹具补齐新增独立工具文件；真实生产打包仍要求工具存在且可实际导出。复核还修正 Windows 成功启动安装器后立即退出造成的不可达日志记录，保留原有 cleanup；旧版没有新诊断目录时仍能采集既有更新回执；Rust 时间戳移到入队前，避免日志排队将旧进度伪装为新进度。上述修正均包含在最终通过的源码中。

文档之外的既有用户改动保持原样：`2026-10-03-windows-incomplete-scan-report.md` SHA-256 仍为 `63801116c53adee10cb0692cdad6553e6187906f7659ae0aea67b69d4f24ecef`。本轮没有 main 合并、tag、GitHub Release 或 appcast 发布。
