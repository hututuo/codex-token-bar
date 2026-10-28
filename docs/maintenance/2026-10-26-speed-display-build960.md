# 本机替换：0.9.7 / build960

2026-10-26 20:46（Asia/Shanghai），用户明确要求“替换”后，已将 `/Applications/Codex Token Bar.app` 从build959替换为build960并启动。功能源码为 `ea6ce938`，位于 `codex/speed-display-modes-20261026`。未发布、未合入多客户端分支，Windows安装版未替换。

## 验证

- Release构建通过，深度严格签名检查通过；Bundle ID、指定要求、Sparkle feed与公钥保持一致。分词词表和ModelTrace参考库SHA256与旧版相同。
- 新进程实际从 `/Applications/Codex Token Bar.app/Contents/MacOS/CodexTokenBar` 运行。安装可执行文件SHA256：`d1fe94f5cc2196e67f5752b70375ee0a63dfb9ec65e8554b0b3600570796bab2`。
- 安装版UI已确认精确统计1/1、额度正常读取，并手动选择“榜单口径”、看到实际本地速度读数、切换“按客户端”、展开“彩条颜色”。读数随真实活动变化；截图不是演示fixture，也不代表网络链路延迟或榜单端到端验收。
- 检查后恢复“活动估算／按模型”和100%界面大小，保留原有上报开关、传输方式、设备身份和公开昵称。颜色未修改。
- 安装前备份四个生产SQLite库及偏好设置。510,876条events、1,004,472条source_fingerprints、保留事件/指纹各52条、54,226条额度快照、测速样本/去重各2,178条均无旧行缺失或改写；正常新记录继续追加。
- shared-account safety库的3个记录键全部保留。其payload及committed_at为正常运行更新的观察/缓存投影，初次全行比较会将这种刷新报告为变化；最终按记录键保留核对，不当成不可变旧账丢失。
- 另一条多客户端预览进程64729保持运行，未重启或替换。

## 回滚与证据

回滚目录：`/Users/huyiyang/AI agent/Codex/_keep/projects/codex-token-dashboard/backups/20261026-speed-display-build960/`。含旧959 App、偏好设置、四库一致性备份及 `rollback-app.py`。回滚脚本要求先正常退出正式Bar，只换App，不覆盖数据库或偏好设置。

本机回执及实机截图：`/Users/huyiyang/AI agent/Codex/_keep/projects/codex-token-dashboard/runs/20261026-speed-display-build960/`，包含 `install-receipt.json`、`data-preservation.json`、`build.log`、`verify-candidate.log`、`installed-agent-speed.png`。私有配置和数据库备份不纳入Git。
