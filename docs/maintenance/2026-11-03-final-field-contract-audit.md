# 稳定修复的字段与接口复查

日期：2026-11-03。用户要求再次检查字段名、类型和缺列等低级错误；保持本轮稳定收束范围，不实施性能结构改造，不打包、安装、替换、合并main或发布。

原产品基线40163c48；本次唯一产品增补为02c493fae3ccbf76df21524771cee4802a330d0e，仅修改QuotaHistoryStore.swift及对应PublishedModuleReadTests.swift。原基线通过不自动等于新补丁通过。

## 1. 找到并修复的一处兼容缺口

Mac的只读额度历史查询原来将四个周期列作为一组判断；任意一列缺失，就将四列全部投影为NULL／0。旧表若只缺部分列，已存在的generation或anchor也会被忽略。原测试覆盖全有／全无，未覆盖14种中间组合。Windows读取器已经逐列回退，本次无需改变Rust实现。

修复仅将Mac的兼容投影改为逐列选择：存在的列照读，缺失的列保留各自原NULL／0默认值；原fallback的NULL row-id槽位不变。稳定身份读取与历史alias读取共同使用这一投影，字段总数与getter偏移不变。没有ALTER客户端旧表、新迁移、schema版本变化或历史数据重写。

新增公开QuotaHistoryDatabase调用路径测试，枚举四列的全部16种组合，使用独立字面量g41／g73作为期望，检查当前用量、周期ID、读前后A的完整proof及schema均不变。

## 2. 本机已实际执行的复查

| 检查 | 实际结果与范围 |
|---|---|
| 前端startup／shared events／choice恢复／dashboard合并／lifecycle五个测试文件 | 63项通过，0失败、0跳过；Node执行，不是完整Tauri运行 |
| native fixture报告合同／formed旧版本报告检查 | Python3.13下5＋12项通过；使用已留存的真实nested负控报告及负面字段用例 |
| 原／新投影与真实SQLite驱动 | 从原源码抽取旧分支、从当前源码抽取生产helper，使用已有实际存储模块驱动；旧逻辑14个partial组合不符合逐列期望，新逻辑16组合全部正确，16个行typed proof不变。隔离helper验证，不冒充完整Quota应用 |
| 实际暂存DDL与pool codec列数 | 执行两端原始DDL：Swift manifest/events/fingerprints/chunks为27/13/1/3，Rust为35/16/1/3；各自与pool计数合同吻合。两端属于不同owner格式，不要求两套manifest列数相同 |
| Swift语法解析与diff | 两个修改文件parse成功，diff无空白错误；parse不等于完整类型检查 |

证据位于scratch/integrated-recovery/final-contract-check/的frontend.log、projection-audit.json、schema-columns.json；字段静态审计分别为final-wire-contract-audit.md和final-database-fields-audit.md。这些是工作区审计材料，最终执行结果仍以云端报告为准。

本机默认Python3.9缺tomllib，首次脚本加载失败；换已安装的Python3.13后17项全部通过。未为这个测试环境问题改产品或脚本兼容规则。

## 3. 双端真实字段对照

- TS生产invoke与Rust命令注册、camelCase参数、窗口授权逐项相符；startup phase、刷新原因和backfillingModel等字面值一致。
- 三个跨窗口选择事件均使用合法的连字符事件名；带点的旧名称仅作持久化键／DOM事件，不再传给Tauri listen。核对实际desktopBridge发送和接收，没有仅依赖mock。
- Quota投影的Swift21槽位及Rust20槽位、身份字段与cycle字段offset对应；外部state的updated_at／updated_at_ms兼容投影保持5个槽位。published额度／ModelTrace读取不ALTER旧表或新增claim。
- 新旧备份及迁移元数据的Codable／Serde字段名在各自owner范围内对应；schema及codec版本不相互混用。未发现新的manifest字段拼写错位。
- 当前package.json、Cargo.toml和tauri.conf.json版本均为0.9.11；尚未做新发布的版本准备。打包时仍须统一新版本及build身份，并核对最终包资源，不把当前源码检查当包级验收。

## 4. 不扩展本轮的条件性边界

Rust lineage的u64经JSON number到JS，在超过2^53−1时可能舍入。实际生产generation／revision路径为递增计数，未找到达到该边界的现场或随机大hash来源；不据理论边界修改本轮wire合同。ModelTrace的usage值类型宽窄存在差异，但尚无真实非整数payload证明解码故障；同样记录而不扩大修复。

## 5. 新补丁验证状态

- [02常规双端检查41578535879](https://github.com/hututuo/codex-token-bar/actions/runs/41578535879)：运行中；前端／更新器已通过，Swift新增用例及两端原生仍待最终结论。
- [02真实0.9.7升级41578535851](https://github.com/hututuo/codex-token-bar/actions/runs/41578535851)：运行中。保留原旧库、WAL、目标独有账目及重启断言。
- 401的0.9.8～0.9.11八条形成状态证据保留；本次Rust和相关构建输入未改，不为纯Swift字段兼容改动重启完整八路Rust压力矩阵。

后续只更新真实完成结果。如新测试或既有回归失败，先定位这个小补丁，不改大结构、不降低断言。正式应用和用户数据库未触碰。
