# Sidebar spacing and detail actions follow-up

Swift secondary rail group spacing increased from 3 to 7 points, keeping the existing centered content and fixed window geometry. Tauri pin text is now an SVG pin, outlined when unpinned and filled/highlighted when pinned, with dynamic accessible labels.

The dashboard shortcut failure came from window_auth: quota-sidebar-detail had an early return allowing only record_startup_event, overriding the generic surface-safe command list. Add only show_dashboard_window to this detail-specific allowlist; existing dispatch and dashboard activation are reused. Regression coverage verifies access and continued rejection of data, geometry and settings operations.

PASS: 30 Swift sidebar tests, 49 frontend sidebar tests, 18 Rust window authorization tests, both release builds and signatures. Both preview apps replaced, installed hashes match built executables, one process per exact preview path. Evidence in runs/20260911-sidebar-followup. Native sidebar click/visual acceptance remains NOT_RUN: CUA could inspect main/floating windows but did not reach the nonactivating sidebar detail window. No index or migration changes.
