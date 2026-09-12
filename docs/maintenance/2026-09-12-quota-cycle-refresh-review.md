# 本期金额刷新、界面收束与应用替换

2026-09-12。分支 `codex/sync-updates-20260912`，从 `781813e2` 收束当前修改。代码分成旧数据保留及周期读取、二级菜单操作、金额区界面与刷新三个维护单元；没有推送或发布。

## 审核结论与行为

本次差异复审未发现阻止本地应用替换的问题。此次不是全项目或所有设备的无缺陷承诺。

- Swift 原先要求周期读取的索引代次与缓存主界面快照完全相等；后台先提交后，稍旧快照会读失败。现在周期查询可读取同一 provenance epoch 中更新的已提交代次；仍拒绝未来代次、异源及当前不安全来源。其他调用默认仍严格匹配。
- 两端在同周期正常刷新时保留已有金额。切换 Home、账号、周期或收窄边界时隔离旧值，真正的明细校验错误仍清除结果。
- Tauri 按来源对象的完整值判断变更，避免等值对象重建重复启动明细请求；既有后端 pending 状态仍有界重试。
- 金额区将模型费用、本期/今日/累计、历史入口、短日期和两种金额合并到标题行。日历默认折叠、展开占满宽度、选择后收起。
- 两端二级展开提供固定和打开主页面。固定二级状态不强制打开详情。
- 旧库、迁移回滚资料与旧摘要继续保留，迁移成功凭据沿用元数据键，不再增加 schema。兼容性细节见 [升级保留复审](2026-09-12-release-upgrade-retention-review.md)。

## 验证

| 检查 | 结果 |
| --- | --- |
| Swift 金额区、周期读取与侧栏定向回归 | PASS 48 |
| 前端金额区刷新、来源隔离与侧栏定向回归 | PASS 25 |
| Swift / Rust release 优化构建 | PASS |
| TypeScript / Vite | PASS（相同源码的前序构建） |
| git diff --check | PASS |
| 两端启动后本期金额显示 | PASS，无需重复手动刷新才出值 |
| 两端手动刷新期间金额保持可见 | PASS |
| Swift 安装路径重新启动、刷新 | PASS，Sparkle 加载正常 |
| Windows 实机 | NOT_RUN，按用户要求暂缓 |

此处启动验收基于本机现有索引和账号，不是首次无索引建库或全部升级设备验收。首次启动仍需取得账号资料及正常增量更新；没有把只读 SQL 微基准当成完整启动耗时。

账本读取测试确认 synchronize 调用为零。前序本机 Tauri 日志的一次增量更新枚举 2972 个文件，仅重算 2 个，full_body_bytes=0、full_rebuild_files=0。旧版升级测试沿用已完成的真实 v0.9.1 输入证据，未重做全库扫描。

## 已替换的应用

- Swift 安装版：`/Applications/Codex Token Bar.app`。
- Swift 项目预览：`dist/quota-sidebar-preview/Swift.app`。
- 跨平台现有应用：`dist/quota-sidebar-preview/Tauri.app`。

安装版与已验证 Swift 预览的可执行文件 SHA-256 完全相同。两端应用通过 `codesign --verify --deep --strict`；Swift 包内 Sparkle 文件与 `@executable_path/../Frameworks` 查找路径均已核验。停止了旧 Swift 预览进程，当前运行安装版。

旧 Swift 安装包保留于 `dist/quota-sidebar-preview/Installed-Swift-before-review-20260912.app`。本次只替换应用包，不清除任何用户索引或原始 JSONL。

如需回滚本次 Swift 安装替换，在项目目录执行：

```sh
python3 runs/20260912-cost-cycle-compact/install-reviewed-swift.py --rollback
```

脚本先核对本次安装记录和新旧二进制哈希，再退出目标 Swift 并恢复旧应用；若安装版之后被修改，会拒绝覆盖。尚未执行回滚。

证据：`runs/20260912-cost-cycle-compact/` 中的 `review-swift-tests.log`、`review-frontend-tests.log`、`review-swift-build.log`、`review-tauri-build.log`、`swift-installed-startup.txt`、`swift-installed-refresh.txt`、`tauri-replaced-startup.txt`、应用截图与 `installed-swift-receipt.json`。
