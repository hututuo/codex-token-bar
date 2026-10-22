# Sidebar module visibility and ModelTrace entry

Each third-level page has a persistent “显示在二级菜单” checkbox. Overview controls quota rings and model share; speeds controls the estimated-rate ring and body TPS; tasks controls running counts; radar controls recommendations and window status; credits controls reset cards. All default visible, including existing installations.

Hidden pages remain available through the always-present “菜单” entry and the third-level tabs. ModelTrace has an independent “模型检测” entry beneath TPS. It opens the existing central panel without starting a probe. Data collection, cache reminders and historical accounting are unchanged.

Explicit visibility changes rebase the measured height budget, so an already expanded rail can shrink through the existing native frame animation. When TPS is hidden, its extra row of headroom is removed. Normal live TPS additions retain the prior one-row policy. Short displays retain scrolling and reduced motion remains supported.

macOS persists hidden module names through the controller's UserDefaults; both native panels observe that controller. Tauri uses an atomic per-module mutation of app settings and a native change event shared by the two sidebar windows. No new polling or database schema is introduced. Only the ModelTrace opener is allowed from the rail; paid probe/data commands remain restricted to the main window.

Validation: 72 native sidebar/chart tests, 78 frontend sidebar tests, 45 Rust sidebar tests and the frontend production build passed. The native production NSPanel fixture verifies hiding TPS shrinks while its detail stays selected, all-hidden reaches 192pt, re-enabling grows again, and settings reload correctly. UI screenshots use synthetic 50 TPS layout samples. This does not constitute Windows runtime or physical multi-monitor acceptance.

Local deployment and rollback evidence is recorded outside the release tree in `runs/20261022-sidebar-module-toggles/`. No public release is part of this change.
