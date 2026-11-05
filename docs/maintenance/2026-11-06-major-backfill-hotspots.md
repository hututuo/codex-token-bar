# 回填主要热点定位

本轮从 `6101769e` 继续调查。优先方向已经收敛为：**逐来源导入与对账、暂存池的串行查询/写入、最终发布的批量更新与等待**。单次旧目录 DDL 规范化与小来源 ordinal 索引均不足以解决这些大块耗时，未再围绕它们做产品修改。

这是诊断记录，不是新修复版本。临时产品探针已撤出，源码恢复到 `6101769e`。两位既有普通 Astra Max 会话分别独立核对 import/ledger 和 stage/finalize，根会话负责插桩、规模场景运行、机制实验、恢复与证据绑定。

## 测量口径与完整性

使用新的隔离合成夹具，仍为4,124个来源、每来源122条事件，共503,128条事件、2,515,640 tokens，另有6,250个保留的旧空候选。原生产解析、阶段池、导入、对账、聚合、发布和并发写探针保持执行。source字节与此前规模测试逐文件复核；不读写正式用户数据库。

只在“历史字段补全 + 随后一次普通sync + summary”窗口启用临时计时，记录每项wall、同线程CPU、扣除同线程子项的own、次数和最大单次。发布长batch在原整批绑定后，用原statement splitter和同一事务逐条执行原SQL以计时。回填开始后约60、160、260秒各做2秒调用栈采样，避免只凭开头冷目录窗口归因。

运行正常结束，`status=PROFILED`、`exitCode=0`、`sourceStable=true`。前后原事件ID/数值/类型摘要均为 `442df884874a33dc15d2c5a07ef61c7aae3a52d35de9863d7459e290e4716e3d`；4,124条补全回执、6,250个旧空候选、源文件字节及MAIN/store零增长检查通过，warnings=0。

本轮窗口469.455秒，包含探针与采样影响，也没有新旧版交替控制环境；它**不能替换此前无额外探针的367.702秒产品测量，不能用来再宣布产品变慢或变快**。整个进程1,413.747秒包含数据准备和最终核验。诊断特意省略规模场景之后的另外几项恢复场景，不能称完整产品门禁PASS。此前1,784项库测试与16个完整生产场景通过属于前一轮证据，本轮没有冒充重跑。

144个(parent,name)统计项经独立核对，按同名入口合并后的父子wall与CPU守恒；最大残差约2.84e-14秒。跨线程worker wall和Mutex等待会重叠，以下只用MAIN串行阶段分解总窗口。

## 三个主要阶段占整段约90%

| 非重叠MAIN阶段 | 次数 | wall | 占469.455秒 |
| --- | ---: | ---: | ---: |
| 等待每批暂存完成 | 1,031批 | 132.470秒 | 28.2% |
| 逐来源导入 | 4,124 | 184.873秒 | 39.4% |
| 与旧事件比较 | 4,124 | 23.081秒 | 4.9% |
| 最终发布 | 2 | 106.777秒 | 22.7% |
| 其他及未细分间隙 | — | 22.254秒 | 4.7% |

补全函数本身448.818秒；第一次finalize104.028秒，后续普通sync里的第二次仅2.749秒。不能把两个不同入口的子项各加一遍。其他项中包括消息关联修复12.627秒。

## 1. 暂存池：任务查询全扫与持锁写入

这里已经形成“实际调用栈 + 累计耗时 + 真实查询计划/VM步”的证据链。`stage_pool::Pool::candidates` 按owner、source_path、base_proof和sealed状态找可复用任务，但jobs只有job_id主键及logical_path唯一索引。回收保留job header与manifest，因此历史任务持续增加查询工作量。

本轮4,124次查询在共享Mutex内实际占用27.600秒（CPU10.744秒）。60秒中段样本直接落在该查询的BtreeNext/pread，其他worker同时等pool Mutex；这不是之前一次性的DDL规范化。

运行结束后，用相同bundled SQLite 3.50.2只读核对同一夹具：jobs共8,272条（8,253 consumed、18 reclaimed、1 sealed）。三个代表case均是`SCAN jobs`和临时排序，查询返回0或1行都产生8,271个FullscanStep；零结果case约41,325个VM步。重复查询仍发生约1,260次SQLite页缓存缺失，零cache writes。页统计表明1,260个internal/leaf页，与这些缺失次数接近；不能因此宣称每次也读了全部overflow manifest页，更不能把SQLite cache miss直接当物理磁盘读次数。

**首个范围可控的修复目标：让这条查询按条件定位任务。** 一个固定pool的partial covering index可保留原查询、全部候选、codec拒绝与排序语义。但现有pool启动按对象数量和SQL精确识别契约，不能直接加索引就结束：需要识别旧完整契约、原子升级及正确的catalog index类型、新契约校验和旧binary拒绝新契约的回退边界。不能删除历史任务或长期缓存“没有候选”来换速度。

暂存另一大块是`Pool::persist`：20,620次锁内写事务合计占共享通道70.549秒（CPU27.100秒）。其中init事务25.851秒、payload事务40.987秒、seal事务1.845秒。20,620次A COMMIT仅14.278秒、BEGIN仅0.153秒，其余事务内SQL/prepare/payload与页工作合计54.253秒。**不能把132秒暂存归咎于解析器，或把70秒持锁全部叫fsync。** 优先继续减少锁内重复查询/写入工作；增加worker并不能消除这个串行通道。

worker parser+sinks合计CPU28.797秒，wall36.481秒；fixture-only并发probe合计worker wall15.896秒。它们与各worker的Mutex等待及MAIN暂存wall重叠，不可相加。全窗口worker Mutex等待319.123秒只是多人同时排队的工作量，不是可再节省319秒。restore私有work库8,248次COMMIT仅0.027秒，也不能混入A持久化成本。

## 2. 导入：以CPU工作为主，账本与兼容层重复处理最值得改

184.873秒导入中，线程CPU165.311秒。主要子段如下，均已包含在184.873秒内：

| 导入子段 | wall | CPU |
| --- | ---: | ---: |
| 逐事件对账 | 58.568秒 | 52.135秒 |
| 验证和单文件聚合 | 32.016秒 | 29.847秒 |
| 旧pending快照与清理 | 19.412秒 | 17.820秒 |
| 恢复并验证stage | 18.426秒 | 16.200秒 |
| 分块/checkpoint/凭据 | 14.917秒 | 13.580秒 |
| 写入事件与计数 | 12.431秒 | 11.534秒 |
| 来源登记与指纹写入 | 12.173秒 | 11.355秒 |
| 单来源COMMIT | 7.207秒 | 3.756秒 |
| TEMP挂载 | 6.984秒 | 6.490秒 |

对账自身58.555秒，其中write_pending8.276秒、bind_pending8.391秒；这些helper的时间包含生成SQL、绑定、缓存取还、SQL执行，不能都归为SQLite写入。

### 已验证的重复语句取还

原`prepare_cached`确实缓存计划，翻译cache命中也不tokenize；sequence guard已有字符串快路径。因此“每事件重新解析整个SQL”不是当前根因。但每次仍经历SQL哈希、bound String复制、rusqlite statement cache移出及Drop放回，部分helper还反复构造同一SQL。

根运行了独立探针，使用实际抽取的StoreConnection方法、原binder、原sequence guard及七条热SQL。每变体2个来源×122事件，三个交替对照，计时与计数构建分开：debug热分支中位数11.518→3.457毫秒；小型优化探针8.142→2.440毫秒（依赖仍为现有debug构建，不能视为产品release数据）。输出typed摘要、FullscanStep和VM工作完全相同。audit确认普通分支translation命中1,708→14，miss/tokenize/sequence-tokenize均为0。

debug分解中，原取出与放回缓存合计5.664毫秒；实际bind/step/decode/reset3.301毫秒。按来源持有语句后，前者降至约0.053毫秒，实际执行仍3.540毫秒。**这是重复缓存管理的实证，不是以调用次数猜收益。** 但这只是244事件的共同热分支，不能将差值线性放大并当作58.555秒的确定节省。候选需保留原查询、原逐行判断、参数和事务，只在一个来源内持有句柄，并在TEMP删除之前释放。

### 清理与双遍写入

`delete_file_version_rows`单独18.616秒、CPU17.075秒。它对events/file_fingerprints/file_chunks/files兼容view分别DELETE；中段采样的48个该helper独占栈中，42个进入SQLite prepare/compiler路径。这是反复编译view和trigger程序的直接证据；样本计数不等于精确耗时占比。

独立审查提出的首个清理候选，是在同一IMMEDIATE事务内证明没有目标view行后跳过这四条DELETE：`snapshot_pending_import`返回false，且该来源`last_seen_generation != generation`，两次读取与删除之间没有对该来源写入。在当前schema11 view合同中，前者排除pending分支，后者排除目标代次的published分支；已有pending、代次匹配或旧table-backed路径继续原删除。**本轮尚未记录该条件的实际命中次数，也未验证候选实现；不能假定4,124次全为空而直接跳过。** 后续需核对目标view行数、各pending模式、恢复残留、孤儿行原行为及失败回滚。单纯缓存DELETE还可能因TEMP schema变化而重新编译，因此优先验证这个范围更明确的候选，再评估缓存。

导入还有真实的重复数据流：stage先经events兼容view分配ID、写pending；reconcile再将其复制到incoming TEMP、删除pending，然后保留旧ID或接纳新ID重写pending。此重复结构已确认，相关事件写入12.431秒、清理/对账CPU已测；但尚未证明能安全一次性去掉哪一遍。若后续做“纯补字段”的专用批量路径，必须以已验证prefix、指纹/稳定ID的一一映射为前提，异常和不确定分支保留原算法，不能以ordinal相等替代身份。

compare和import跨调用各自恢复/挂载stage，比较阶段23.081秒中有16.563秒属于这些已测子项。它与已修好的“import内复用同一验证快照”是不同边界。可研究同一来源内承接同一个已验证快照，但收益上限受23秒阶段约束，不能超过阶段本身，更不能绕过seal/source身份复核。

## 3. 发布：大批量事实更新与非CPU等待

两次finalize合计106.777秒，线程CPU35.680秒；约71秒未在该线程CPU上执行，可能包含页读、写回、checkpoint、同步或调度。当前证据不支持将差值全部叫磁盘I/O或fsync。

| finalize直接子段 | wall | CPU |
| --- | ---: | ---: |
| 发布pending | 53.709秒 | 21.302秒 |
| attribution同步 | 20.981秒 | 7.632秒 |
| 最终COMMIT | 18.404秒 | 2.630秒 |
| 缺失聚合补齐 | 4.904秒 | 2.521秒 |
| 轮次候选 | 2.218秒 | 0.755秒 |

53.709秒publish内部，事件upsert24.953秒、ledger关联发布9.875秒、pending级联删除9.679秒、旧事件反查删除4.123秒、fingerprint合入3.932秒。23条SQL各执行2次，合计43.634秒，再加ledger发布和自身余量，恰好还原父项。

发布应优先研究实际写放大与大发布等待，保留稳定事件ID、历史账目、published generation与stage receipt同事务的原子性。没有依据通过关闭外键、降低durability、或把可见发布拆成中间批次来提速。原先怀疑的整代missing aggregate仅4.904秒，现阶段优先级低于上述20秒级路径。

## 优先顺序与未解决边界

1. 暂存任务查询的条件索引及旧pool契约兼容：已有27.600秒锁占用和全扫描证据，机制最明确。
2. 导入CPU路径：先验证有事务内空目标证明的清理快路径与来源内持有热语句，再评估双遍pending写入；全阶段184.873秒是最大的串行项。前两项已有明确成本证据，双遍写入尚需更广的身份与恢复语义验证。
3. 暂存persist的init/payload锁内工作：不能只盯14秒COMMIT，剩余54秒事务工作需要净收益验证。
4. 发布事实upsert、关联/级联处理与一次18秒COMMIT：分别验证，避免混成一个“数据库慢”。

ordinal索引在当前122行/source的小实验仅净省约0.222毫秒/source，线性约0.91秒且不是产品实测；DDL memo在前轮同库试验仅省约1.28秒/冷扫描。两者不再作为主要推进方向。

本轮完成了主要路径定位和两个机制验证，**没有实施新产品修复，也未证明此前323.102→367.702秒的44.600秒差值由哪个改动引起**。该问题仍需同一冻结数据库状态的新旧版交替运行；当前诊断可以指导选大热点，但不允许把全部热点时间承诺为可节省时间。后续每项候选都应以无探针整段回填净耗时和原账目/恢复门禁共同判断，而非只过600秒上限。

## 证据

根目录：`scratch/backfill-major-hotspots-20261105/`。主要文件：`execution.json`、`producer.json`、`profile.log`、`phase-summary.json`、`middle-samples-summary.json`、`pool-candidates-proof.json`、`diagnostic.patch`、`profile-sources.tar`、`business-store-fixture-profile`。按来源持有语句实验为`ledger-review/binding-probe/scheduled-run-e5iqavm1/execution.json`；独立收束报告为`ledger-review/final-ledger-sorting.md`和`stage-review/measured-priorities.md`。

撤探针后，源码与前轮产品摘要`be149baca342eb5f3e42868427c959e1549fd6b9d94e0d3402b036c5898bc4dd`一致；关闭证据记录在`closed-evidence.json`。恢复构建曾因磁盘空间不足失败，空间恢复后同命令重试通过，两次日志均保留；没有删除用户文件、账本或合成夹具来腾空间。这次构建失败发生在测量结束后，不能用于解释回填的既有耗时差值。本轮未安装、重启应用、推送或发布，既有无关工作树改动保持原样。
