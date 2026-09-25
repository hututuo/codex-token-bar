# 二次复审后的修复与验收

基线：`6a9d9fa8`。工作分支：`fix/v092-audit-sidebar`。目标版本：`0.9.2`。

## 代码修复

1. Windows 窗口提交闭包明确使用 `Result<(), String>`，修复原样候选在 Windows 下的 E0282/E0283 编译错误。
2. Swift 完整快照缓存与底层索引共享 `SourceFileObservation`。一次 stat/fstat 同时取得长度、mtime、device/inode 和 ctime；稳定刷新没有新增正文读取或哈希。旧快照字段可缺省，旧缓存仍可解码为最后可信结果；未知物理基线只触发上层缓存失效，不要求全历史重扫，不改变账本身份或 schema。
3. 浮窗引导仅在显示期间观察卡片实际尺寸，按内容最下缘申请高度，关闭时撤销观察。合法的自定义布局中，离屏 WebKit 测得指引卡片最下缘为 310px，而旧固定窗口只有 284px。新实现给该布局申请 316px，并提高原生临时布局高度上限；没有新增常驻轮询。
4. 原有拖动、详情恢复、侧栏动画回执、历史未报价和显示偏好修复保留。Swift 源码已有固定、刷新、主页三项动作，不重复添加；新包核验与旧运行副本分开记录。

## 发布范围与版本

Tauri、npm、Cargo、锁文件及 Swift 打包默认版本统一为 `0.9.2` / build `902`。本轮不创建 tag、GitHub Release，不改线上 appcast 或 updater 清单。

Windows 构建默认仍为 `-Arch both`；本轮 x64 候选可明确指定 `-Arch x64`。构建清单中的 `windowsArch` 必须与资产集合一致。旧清单没有该字段时仍必须提供两个架构，缺失 ARM64 不会被自动解释为合法单架构发行。

```powershell
./scripts/build_tauri_windows_release.ps1 -Version 0.9.2 -Arch x64
```

签名脚本根据已验证的清单处理所选架构，仍执行逐资产真实密码学验签、摘要对账和不可覆盖发布；更新 JSON 仅包含实际构建的架构，不能将 x64 安装器标记为 ARM64。统一校验和合并也必须明确范围：

```sh
node scripts/merge_release_checksums.mjs --version 0.9.2 --release-dir PATH --windows-arch x64
```

不传 `--windows-arch` 仍要求原有双架构完整资产。单架构候选不等于 ARM64 用户自动更新已验收；ARM64 自动更新策略和正式覆盖安装仍需在发行前单独验收。

## 验证边界

源代码回归、编译、离屏布局、安装运行和正式更新是不同门禁。Windows 界面探针启动在本轮被工具安全检查阻止，不绕过，不把离屏 WebKit 测量或源码测试等同为 Windows 实机视觉验收。

正式仓库之外的日志、合成数据与本地验证包保存在 `~/tmp/ctb-finish-fixes-20260925/`。验证包通过独立且不可覆盖的 `APP_OUTPUT_DIR` 输出；未要求用户删除账本，也未增加降级兼容。

后续空文件压力回归的 Git 历史原因、已提交的批处理修复、自动回归与最终接手清单见同目录 `2026-09-25-empty-source-performance-repair.md`。旧 `0d60821d` 验证包不含后续索引修复，接手时应按最终代码候选重新构建；本文件本身不表示正式发行放行。
