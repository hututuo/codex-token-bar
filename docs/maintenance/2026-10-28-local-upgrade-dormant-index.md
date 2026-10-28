# 本机升级：不兼容的闲置索引

## 问题与处理

首次安装多客户端候选版时，Swift 启动迁移收集当前与旧缓存目录里的全部 Exact 索引，并逐份调用当前版本的语义迁移。旧缓存里的 schema 3 索引无法被当前 Exact 引擎解释，因此把正在使用的 schema 14 Home 也挡在全局启动门外。

容器导入与语义升级分开处理：已知可升级的索引继续走既有迁移；遇到 `CodexUsageIndexUpgradeRequiredError` 时，将私有副本从只读原始备份重新恢复，按原 schema 和原始键值导入隔离分区，验证结构和逐行证明，记录 `normalizationDeferredReason`。不删除、不猜测重建、不把未知 schema 当成空库。

只有用户打开那份不兼容 Home 时，Exact 引擎才继续报版本不兼容，并拒绝写入；其他兼容 Home 可以启动。损坏、I/O、证明不一致等错误没有被此分支吞掉，仍停止激活。归并后读者现在保留具体版本错误，不用笼统的模块迁移提示遮蔽原因。

Windows/Tauri 现有 `bootstrap_legacy_indexes` → `open_store_during_bootstrap` 已按原始结构导入，语义兼容检查在对应 Exact 读者内执行；本次不复制 Swift 的全局语义升级到 Rust，不新增另一套计算。未替换 Windows EXE。

## 回归

`BusinessDatabaseMigrationTests.testUnsupportedDormantHomesArePreservedWithoutBlockingSupportedHome` 覆盖：旧缓存中空 schema 3、带原始 ID/BLOB 的未来 schema 999、正常 Home 共存、原文件与备份/导入证明一致、源级版本拒绝、容器再次启动。定向 12 项通过。

完整 Swift 回归、实际安装和迁移结果另见本次本地验收记录。截图、真实路径、备份清单只存忽略的 `scratch/local-install-*` 与用户 Application Support 备份目录，不写入公开仓库。

## 清理边界

按用户要求清理本 worktree 的可重建 Rust 编译对象。保留源码、Git、依赖锁、测试、旧安装包和所有账本/升级备份；不能因为 `sources/events` 为空就删除索引，其他表可能仍有会话目录或保留信息。
