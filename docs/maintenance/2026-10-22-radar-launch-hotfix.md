# v0.9.6 双端紧急修复

## 根因与修复

1. Windows0.9.5 的 NSIS POSTINSTALL 把已有桌面/开始菜单快捷方式直接重建为 EXE，丢失代理脚本、参数和工作目录。现在先保留原链接、恢复原字节，只对无参数/无工作目录的标准产品 EXE 链接修复旧路径；GUI Finish 页也保护已有桌面链接。
2. Windows 开机自启的旧路径引号修复会重写参数。现在保留已有参数，只有无参数时补 --autostart；wrapper 注册项不认领。
3. 线上 RadarBench 改用 radar-bench-public-summary-v6-150-details，新增 source_scores/detail_metrics；评分版本、规则、150 分量纲、题池身份未变。Swift、Rust、TypeScript 同步接受精确的 v5/v6 schema，同时保留原有评分/身份校验。真实 v6 payload 作为共享回归 fixture，34 个线上模型档位通过解析。

Mac 源码未发现重建自定义启动器的路径。额度 app-server 继承主进程环境；Finder/登录项/Sparkle 新启动不等于执行 shell 代理启动脚本，临时代理环境不能据此保证保留。本次不保存代理凭证、不添加网络代理。

旧版已经覆盖的快捷方式无法凭空恢复未知脚本参数，需恢复一次原入口；后续更新受保护。覆盖安装保护不代表用户明确选择卸载后仍保留旧安装器删除的入口。

## 验证边界

- Swift1773项，0失败，10环境跳过；前端1205通过；Windows原生1237通过、0失败、10忽略。
- Windows真实NSIS故障夹具：锁定文件中止、标准旧路径修复、wrapper/customargs/workdir/unrelated/NS/manual-wrapper字节保留通过；夹具模拟POSTINSTALL后的GUI Finish调用。
- Mac安装928、真实v6雷达读取和账本保留通过。Windowsx64安装进程/哈希/交互Session1及旧测速记录保留通过。
- Windows视觉UI和ARM64真机运行 NOT_RUN。Windows历史账本基线为空，不能当成非空账本保留验收。
- 最终云端CI及发布状态见 release locator。

## 保留的工作

缓存提醒恢复工作在 codex/temporary-cache-miss-reminder-20261022 的36067fa提交保留，ModelTrace PR未合入。本次紧急版本从已发布0.9.5主线修复，未带入暂停功能。

证据在项目外层 runs/20261022-radar-updater-hotfix/，不随公开资产上传。原索引、退役建议库、费用账本均不删不迁移。

## 测试时钟修复

首轮CI39715123272在Windows启动缓存往返测试中于UTC03:20:15失败。聚合签名在每五分钟点后15秒切换，测试跨界时按设计无法命中旧时间轴。测试现在冻结聚合时钟，并保留“跨界后应返回None”的额外断言。四处时间替换均为cfg(test)影子绑定，测试模块整体cfg(test)；去除四处测试绑定后的生产模块与已打包的64d453aa逐字节相同。正式程序的时间、缓存失效和持久数据逻辑不变。

完整最终门禁通过：CI39718035045；固定时钟聚合专项13项、五次重复边界检查通过。发布状态与哈希见相邻版本 locator。
