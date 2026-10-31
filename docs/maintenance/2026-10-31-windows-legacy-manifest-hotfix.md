# Windows 旧迁移凭据启动误拦修复

## 已定位的故障

0.9.7 的 schema9/10→11→14 升级成功后仍保留 `.schema11-migration.json`（`Retained`）及回滚材料。0.9.8 新 A 启动扫描将任何这类文件都判为未恢复，直接阻断。不是这条提示能证明旧库损坏，也不能删 JSON 绕过检查。

## 候选修复

- 新 A 的发现阶段完整核验清单 v1、阶段、源/候选/回滚的同目录绑定；有主库就只导入已提交的主库，从不导入 candidate。
- 只有 `Switching` 的主库缺失窗口可以选已存在的 rollback，并保持主库的逻辑分区身份。已完成的主库缺失不回退，避免复活较旧账目。未归位且非空的 WAL/journal 仍阻断，不能忽略其记录。
- 复用原 A 导入器的 SQLite 一致性备份、完整逻辑摘要、导入日志和重试机制；原清单及所有旧库不改写、不删除。可接续 0.9.8 失败启动留下的未初始化 A。
- 在 A 的既有元数据表中登记原凭据归属，无需更改数据库 schema 或增加业务数据库。被导入的物理凭据与新 A 的 manifest/candidate/rollback 三项全部隔离，保留原始恢复证据。
- 首次启动与 A 已激活后再打开旧 Home 共用来源选择及凭据核验；已有 A 原始库删除后仍读取已保存的账目。已登记但还没有表的空分区不算成功导入。
- 已激活的 0.9.8 A 保留全部已提交的规范账目；旧的迁移凭据及派生候选/回滚原样保留，在新隔离路径上重新准备派生结构。A 内替换是原子提交，未提交候选不作为新账目来源。这样不依靠猜测物理凭据属于哪个旧版本，也不会改写混合归属的旧凭据。旧物理 candidate 不能冒充 A 候选参与切换。
- Windows 生产回归另捕获了 A 命名空间复制时的外键建表顺序错误。复制器沿用已验证导入器的连接级 FK 开关策略：仅在私有复制连接上暂缓约束执行，提交前检查目标全部外键及完整逻辑摘要，所有出口恢复原约束设置；失败事务回滚，不改变既有目标账目。
- 在计算新 Exact 分区身份前先准备目标目录，避免 Windows 首次创建目录后 canonical 路径前缀改变，使同一逻辑账本得到不同 ID。已有源库不变。
- 未知格式、路径越界、链接/重解析点、缺库、损坏和导入中来源变化继续保护性报错，不降级为空库。

## 验证范围

本地新增的恢复选择、真实 A 导入器重试和保留证据测试；既有完整 Rust 测试；扩展公开 0.9.7 升级云端 lane，使用真正的公开版本 schema14 合成数据和非 cfg(test) Windows 启动路径。新增保留凭据、当前目录碰撞、切换中断、回滚选择、缺失/未知/WAL 异常、既有 A 迁移路径，以及 A 初始化后再接入旧 Home 场景。

修复在 `codex/fix-windows-legacy-migration-recovery`；验证结果另记。此记录不是打包、替换或发布回执；已发布 0.9.8 安装包未改变。

## 最终验证回执（2026-10-31）

验证提交：`5869283758e5957b3091a439f412b29b4e739fb8`。最终生产逻辑为 `776d22670d1b4d0d477f3b964703fda85a94ac9a`；之后仅为既有 Home 缓存隔离测试固定测试时钟，避免测试期间跨越聚合时段造成误失败，未改变生产缓存策略。

- [全量 CI 41198042490](https://github.com/hututuo/codex-token-bar/actions/runs/41198042490)：全部成功。Mac Rust 1567 通过、14 忽略；Windows Rust 1511 通过、14 忽略。平台条件编译导致数量不同。
- Swift：XCTest 执行 2221 项（36 跳过），0 失败；Swift Testing 667 项通过。前端测试、类型/构建检查、上报隐私自检、更新器和打包脚本自检均通过。打包脚本自检不等于生成或发布安装包。
- [公开 0.9.7 旧库升级 41198042531](https://github.com/hututuo/codex-token-bar/actions/runs/41198042531)：Mac、Windows 均成功。旧输入由公开版本 `0219554ce444b0013987da7b82e3c2e891f4afdb` 的代码生成，使用合成数据，未接触用户账本。
- Windows 非 `cfg(test)` 恢复入口 13/13 通过：retained、current-retained、switched、switching、rollback、missing、unknown、stray-wal、existing-a、late-retained、late-switching、late-rollback、late-mixed。逐项核对旧文件散列未变、未导入候选库、已存在的 A 账目保留。missing、unknown、stray-wal 预期仍保护性阻断，其余正常接续。
- 同一生产逻辑的前一轮 [41197650505](https://github.com/hututuo/codex-token-bar/actions/runs/41197650505) 亦通过。失败探索日志保留在本地 scratch，未通过删除数据或跳过保护检查使测试变绿。

本地日志：`scratch/legacy-migration-hotfix/final-{mac-rust,windows-rust,swift,windows-upgrade}.log`；Windows 13 项结构化回执：`scratch/legacy-migration-hotfix/final-windows-recovery-receipts.json`。云端工作流另保留合成输入和校验材料。

## 受影响用户如何恢复

补丁覆盖安装后，程序自动核验并接续可信旧账本，无需先卸载或删除 `.schema11-migration.json`、旧库或回滚文件。该截图本身不能确认用户清单的具体阶段，也不能证明原库完整；若新版核验发现真正缺库、损坏或未知格式，继续保留全部材料并给出具体诊断，不能承诺任意损坏状态都能自动修复。

截至此回执仅推送修复分支；没有合并 main、修改已发布 0.9.8 安装包、安装替换、重启正式应用或发布更新。后续补丁需使用新版本号，不能覆盖原 0.9.8 发布物。
