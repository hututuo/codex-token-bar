# Reset-credit page and dashboard shortcut

Both Swift and Tauri now give reset credits a separate detail tab. The compact credit entry opens that tab at its top; quota overview no longer duplicates the card list. The secondary view shows the count and nearest future expiry without the redundant 最近到期 label, with spacing adjusted to fit the existing canvas.

Both detail headers include an accessible 打开主界面 action beside pin and close. Swift delegates to DashboardRuntime's existing dashboard callback; Tauri invokes desktopPlatform.showDashboardWindow. No separate window-opening implementation, index migration, or scan is added.

Validation: 30 Swift sidebar tests, 49 frontend sidebar tests, TypeScript and Vite build passed. Production secondary rail and separate card-list rendering checked in the browser using synthetic data. Native click and window activation acceptance remains NOT_RUN because the Mac is locked. Final bundle/replacement evidence is recorded separately in runs/20260911-reset-page.

Final Swift and Tauri release bundles built successfully, passed signature verification, and replaced/restarted both preview applications. Built and installed executable hashes match, with one process at each exact preview executable path. Replacement JSON files retain hashes, prior PIDs and backup paths. Native visual/click acceptance remains NOT_RUN due to lock state. No public release performed.
