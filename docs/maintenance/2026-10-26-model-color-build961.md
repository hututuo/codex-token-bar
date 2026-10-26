# 模型费用颜色入口 / 本机 build961

2026-10-26，按用户要求将颜色编辑入口移入「模型费用 → 累计」。功能源码 `abfd8de8`，分支 `codex/speed-display-modes-20261026`。

- 累计范围双击模型卡片可打开颜色编辑器，支持恢复默认；底部提示「在累计界面双击模型，即可修改该模型颜色」。其他费用范围不启用双击编辑。
- 速度区原颜色面板移除；客户端颜色以小入口放在累计费用区。沿用已有持久配色及全局颜色映射。
- macOS 原生与 Windows/Tauri 前端同步修改；本轮没有改测速、上报、费用账本或数据库结构。

## 验证与安装

- Swift 相关回归：41 项 XCTest（1 项可选预览跳过，0 失败），8 项 Swift Testing 通过；Web 30 项测试通过；TypeScript/Vite 构建通过。
- Release 构建及深度严格签名验证通过。版本 0.9.7 / build961，Bundle ID、指定签名要求、更新 feed 和公钥保持一致。
- 已替换 `/Applications/Codex Token Bar.app` 并启动，安装文件 SHA256：`827bfeba84a5f39c3984ffc426a6d1e9a2ba889c9057a4f70d0140b100631f3f`。
- 实机进入累计费用并实际双击 Sol 卡片，颜色编辑器正常打开和关闭，提示可见；没有修改用户颜色。
- 旧 events 511112 行、source_fingerprints 1004708 行、保留事件与指纹各52行、额度快照54248行、测速样本及去重各2206行无旧行缺失或改写；可变 safety 投影键完整。上报身份、传输配置、颜色与显示设置保留。
- 未发布更新；Windows 安装版本轮未替换。未合入或操作独立多客户端预览。

## 证据与回滚

证据目录：`/Users/huyiyang/AI agent/Codex/_keep/projects/codex-token-dashboard/runs/20261026-model-color-build961/`。含构建/测试日志、安装回执、数据保留核对及 `installed-color-editor.png`。

回滚目录：`/Users/huyiyang/AI agent/Codex/_keep/projects/codex-token-dashboard/backups/20261026-model-color-build961/`。含旧 build960 App、偏好设置、四个 SQLite 一致性备份及 `rollback-app.py`。先正常退出正式 Bar 后运行回滚脚本，只换 App，不覆盖数据或设置。
