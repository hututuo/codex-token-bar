# 升级与运行诊断包 / Upgrade and runtime diagnostics

遇到升级失败、启动迁移停住、数字或进度不更新时，可导出一个 ZIP 文件供自己检查或发送给支持人员。诊断不会修复、重建、打开业务数据库或上传文件。它不能还原旧版本没有记录的事件，也不能保证自动定位所有问题。

## 应用能打开

- macOS：在「帮助 → 导出升级与运行诊断包…」或设置页点击导出，选择一个新的 ZIP 保存位置。
- Windows：在设置/帮助区域点击「导出升级与运行诊断包」，文件保存到系统下载目录。
- 启动迁移中、迁移失败和降级页面也有导出入口，无须先重试迁移或恢复数据库。

导出结束后先阅读 `SUMMARY.md`。`timeout` 或 `unavailable` 表示该项没有采集到证据，不能理解为正常、零用量或数据丢失。文件只保存在本机，由你决定是否发送。

## 应用打不开

macOS 安装包的 `Diagnostics` 文件夹包含独立工具和 `Export-Diagnostics.command`，可复制整个文件夹到可写位置后双击脚本。工具不依赖主界面或 Sparkle。若已安装的工具完整，也可在终端运行：

```sh
"/Applications/Codex Token Bar.app/Contents/MacOS/TokenBarDiagnostics" --export-diagnostics
```

默认导出到下载目录；指定位置时，目标必须是尚不存在的文件：

```sh
"/Applications/Codex Token Bar.app/Contents/MacOS/TokenBarDiagnostics" \
  --export-diagnostics --output "$HOME/Desktop/TokenBar-Diagnostics-new.zip"
```

Windows 安装目录的 `Diagnostics` 文件夹含 `Export-Diagnostics.cmd`、PowerShell 脚本和独立的 `tokenbar-diagnostics.exe`。双击 CMD 即可导出；主界面打不开时不需要 WebView2。也可在 PowerShell 中指定新文件：

```powershell
& 'C:\你的安装目录\Diagnostics\tokenbar-diagnostics.exe' --export-diagnostics `
  --output "$env:USERPROFILE\Desktop\TokenBar-Diagnostics-new.zip"
```

主程序同样支持 `--export-diagnostics`，在业务启动前执行。独立工具也损坏或被系统阻止时，从可信安装包重新取出诊断工具；不要关闭系统安全保护。采集不需要编译器或开发环境。

## 包内信息与隐私

包含可读摘要、结构化环境/安装/存储文件元数据、固定字段的历史事件、允许的恢复事件和错误码。事件区分后端推进与 UI 收到进度；`launched` 仅表示安装器或重启已发起，`confirmed` 才表示新版本在原安装位置得到运行确认。macOS 的确认还等待一次成功刷新。

不会打包 API Key、Cookie、认证文件、对话正文/标题、原始用户路径、完整配置、环境变量、数据库内容、原始错误文本或内存转储。默认不采集截图。崩溃信息限于允许的元数据；文件经过字段白名单重建，导出前再次脱敏。

新事件默认持久化。每次启动使用新文件，单段约 256 KiB，整体按约 8 MiB、120 个文件或 30 天清理，首个失败另存小文件；在保留期内重启不会覆盖上一轮失败。安装回执独立保留。日志不能写入时不会阻断正常业务。

每个采集探针有 3 秒超时；界面导出还有约 30 秒的外层超时。锁住、损坏或尚未完成迁移的数据库不会被采集器打开。存储内部状态来自正常业务已记录的事件，缺失时不会通过恢复/迁移补查。

## English

Export a diagnostic ZIP when an update fails, startup migration stalls, or usage/progress stops updating. On macOS, use **Help → Export upgrade and runtime diagnostics** (the current UI label is Chinese) or Settings and choose a new ZIP file. On Windows, the export button saves to Downloads. Startup migration, failure and degraded screens also provide the button without retrying recovery.

If the UI cannot open, run the standalone helper above. The macOS DMG supplies a `Diagnostics` folder with a double-clickable `.command` launcher. Windows installs a `Diagnostics` folder with a `.cmd` launcher, PowerShell script and standalone EXE. These helpers do not require the main UI, WebView2 or a developer toolchain. The main executable also accepts `--export-diagnostics` before business initialization.

Read `SUMMARY.md` first. The archive contains approved metadata and fixed-schema events, including separate backend-progress and UI-receipt timestamps. `launched` is not installation confirmation; `confirmed` requires the expected version at the expected installation location. macOS also waits for a successful refresh. `timeout` and `unavailable` mean missing evidence, not a clean bill of health. Events absent from older versions cannot be reconstructed.

The exporter does not open SQLite, recover/migrate/repair business data, access the network, or upload anything. Credentials, cookies, conversation content, raw user paths, configuration/environment dumps, free-form errors and memory dumps are excluded. The archive is projected through a strict field allowlist twice. Review and share it at your discretion.

Events persist across restarts in bounded segments (approximately 256 KiB each, 8 MiB / 120 files / 30 days in total); a first failure is retained separately within that budget. Installation receipts are separate. Each probe has a 3-second deadline and UI exports have an outer deadline of about 30 seconds. A diagnostic bundle is evidence, not an automatic repair or a guarantee that every issue can be identified.
