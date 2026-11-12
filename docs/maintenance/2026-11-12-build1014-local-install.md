# 1014 本机替换与后续额度语义问题

用户明确要求“替换”，随后要求“继续”。已将 `/Applications/Codex Token Bar.app` 从 0.9.11 / 1013 正常退出后替换为 0.9.11 / 1014，并重新启动。旧版 App 完整复制、验签后保留原件；设置、账本与历史没有重置。

- 源码：`023e28ced2512874721477b31543d27e0dcd3aa7`，既有全量 CI 和 Public097 双端通过。
- 云端构建：[43167762087](https://github.com/hututuo/codex-token-bar/actions/runs/43167762087)，macOS 与 Windows 打包 job 均成功。本机只安装 macOS arm64。
- macOS artifact 外层 SHA256：`b519a43043d5b77f2a871a1e40603de54943b961acb1648d0d5f038ac2735c6a`。
- 安装后可执行文件 SHA256：`a228769ac688333e77edf7b3d63f3e00fbe8b73b6336ca4ce8e4f353a9345e7f`。
- Manifest 源码/run/asset 校验、App ZIP 路径与 symlink 检查、DMG 校验、codesign deep/strict、内置资源验证通过。Bundle ID、designated requirement、Sparkle feed 与公钥均与 1013 一致；使用既有 ad-hoc 签名，没有发布 tag、Release 或更新源。
- 现有 Agent Speed 锁定版本、patch manifest 保持不变，云端手动构建记录本次私有替换的固定依赖原因；未混入无关上游改动。

实机确认：启动后 Claude Desktop 的两个采样窗口及缓存/采样时间提示可见；Antigravity 能从当前本机服务读取并在界面显示，小数也已生效。新 session 记录 startup.ready 与 index.ready；当时完整刷新尚未 ready，不将额度显示当作全部历史扫描验收。众测推荐和 Claude CLI 的显式隐藏、主页面汇总范围保持。原先存在的 generic frontend.failed 也在新 session 出现，未定位来源，不宣称全界面零异常。

用户随后指出 Antigravity 的界面展示了 16 个模型行，正确额度应是两个池各自 5h/7d 的四个窗口。进一步只读 `RetrieveUserQuotaSummary` 已确认两个明确 group、四个明确 bucket；1014 的 macOS 读取器仍使用 `GetUserStatus.clientModelConfigs`，因此“本机读取链路接通”并不代表“额度池语义识别正确”。此问题单独跟进，不能按相同比例/重置时间对模型行去重来代替官方四桶。

私有证据根目录：`~/Library/Application Support/CodexTokenBar-Maintenance/2026-11-11-quota-investigation-7shd8xj3/build1014/`，包含候选 manifest、安装记录、运行复查和完整 1013 备份；汇总接口脱敏结构见同级 `antigravity-open-source/pool-windows-2026-11-12.json`。真实额度、身份字段和截图不提交到仓库。
