# 业务库访问准入：调查与本批方案

基线`a7f16792407ac0ffb4e3231985c53df3329b6633`，受测产品为`4e43517d`，工作树`f97f/codex-token-dashboard`。本笔接续[剩余模块方案](2026-11-07-exact-next-decoupling-plan.md)，用户再次要求继续后，先复查迁移切换、暂存导入和路由的边界，再选一块实施。

实施已完成：产品`05b23d54`归位准入函数及唯一身份状态，路由主文件净减少207行至2182行；双平台完整库、非test生产入口、Public097和四版本接续均通过，原始证据已核对，见[执行与验收记录](../maintenance/2026-11-07-route-admission-separation.md)。导入journal、协调器和Exact调用方保持原实现。

## 调查与选择

优先归位路由的访问准入。`business_store_route.rs`把初始化、导入journal、Exact路径/所有权、维护和访问检查放在一起；准入检查可独立，且只有一个运行时物理身份状态。目标`business_store_route/admission.rs`，不增加服务层、连接池或第二套状态。

迁移切换暂不移动：持久化Validated恢复必须重验，Switched允许合法pending；生产在A内clone/replace，单测使用物理文件及sidecar重命名，还存在仅本次锁内有效的验证凭据。已复读关键阶段，尚未完成每个入口的锁/句柄/返回点清单，不能当作整个迁移链已充分调查。

暂存导入暂不移动：已复读入口和事务/退出部分，必须核验并挂载同一个不可变快照，保留导入事务、pending关联、卸载及错误优先级。它仍依赖来源类型、checkpoint、ledger和聚合；没有把约1771行暂存全链逐行复审完，不能顺带搬迁。

## 本笔范围

1. 移动`ContainerFileIdentity`及唯一`ACTIVE_CONTAINER_IDENTITY`，状态保持私有，无额外缓存或重置入口。
2. 移动`initialized_marker_path`至`container_file_identity`的完整准入函数组，保留函数体、cfg分支、错误及平台文件身份算法。
3. 移动`admit_published_reads`和它的路径辅助，把已发布账本的只读准入与写准入归到同处。
4. 父模块显式私有导入内部入口，按原`pub(crate)`范围重新导出三个既有公共入口：`admit_published_reads`、`published_reads_only`、`validate_exact_stage_container`。不修改外部调用方或扩大其他辅助函数可见范围。

新模块仅依赖父模块`container_path`、原`Container`类型、原启动协调器、文件系统及平台身份API。身份辅助、类型、静态状态不向父模块暴露。父模块所有既有调用点、bootstrap流程、导入journal/收据、维护策略、Exact owner解析及测试继续原样保留。

## 真实行为合同

| 入口 | 保留行为 |
| --- | --- |
| 启动`verify_initialized` | 标记检查→原`Container::open`→记住本进程身份；该open可能执行原有PRAGMA/初始化，不能误称纯只读或换成另一个open |
| 普通writer | 原协调器`ensure_ready`，打开前后的标记/身份复核保持；不缓存ready布尔值 |
| 恢复期已发布读取 | 原只读打开和catalog验证，`ReadyWithPendingRecovery`允许读但不允许写；不由admission修改协调器状态 |
| Exact暂存保留句柄 | 原ready、标记及身份复核；不为每次调用重新打开A或扫描整个catalog |
| 文件身份 | Unix dev/inode、Windows volume/FileId原实现，静态状态仍是一个OnceLock/Mutex；不按路径或大小替代身份 |
| 根版本、分区身份和pending所有权 | 仍由原Container、path_identity及路由入口校验；admission不替代这些检查 |

模块提取本身不改数据结构、索引、迁移格式、事务、锁持续时间或连接次数，不宣称性能提升。原代码的操作顺序直接从固定基线重建整个文件验证。

## 验收与停止条件

复用已检查的路由只读测试、启动协调器恢复/重试测试、stage池标记/身份/owner保护及旧输入导入回归。生产fixture的`public-read-only-routing`、`published-recovery-reads`、`held-owner-lookup`和`rerun-and-fail-closed`分别验证真实入口；其中缺失A拒绝不是“有效但不同物理A”的专用替换负控，单测关闭进程全局身份分支，证据不混称。

本笔只有模块边界变更，保持既有测试源码及身份；不为搬家添加与实现同构的新测试。云端在精确产品SHA运行双平台完整库、非test生产入口及既有备份负控、Swift/前端；运行Public097与0.9.8–0.9.11双平台形成状态矩阵。核对原始日志、源码清单包含新模块、旧账和恢复材料、独立重开；各类证据分别记录。

本机仅源码编辑及轻量检查，不编译、不访问正式库。发现必须改变算法、事务或准入政策才能提取时重新评估；完成这一模块及验收后收束，不继续移动迁移状态机、暂存导入或旧输入策略。不合并、安装或发布。
