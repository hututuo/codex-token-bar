# Independent startup recovery UI review

Reviewed initial UI change `0c1c32dc` and follow-up `e92b3a64`.

The preparing screen now exposes migration diagnostics and full-log export
while keeping business owners unmounted. The preview loop schedules its next
read after the prior frontend promise settles and removes its timer on
unmount or phase change. Startup-state reads use a generation counter so a
late result from an older request cannot replace a newer native event or
explicit retry result. A synchronous pending flag prevents two retry clicks
from scheduling duplicate retry commands.

## Reproduced interaction race and verified correction

The initial Actions component did not synchronously share its installer
interlock with its retry button. After finding an available update, invoking
`retryButton.click(); installButton.click()` in one React `act` before the
next render issued both `retry_business_startup` and `install_app_update`.
An independently added regression failed with **2 commands observed versus
1 expected**, while the existing five recovery tests passed.

The integration owner's `e92b3a64` changes retry to acquire the same
synchronous ref used by check/install and awaits the parent's RPC promise.
The parent returns that promise, allowing an immediate failure to restore
controls. Re-running the independent regression against that correction
passed. The five preceding recovery tests and the basic owner-mount startup
test also passed: seven executed tests, zero skips or failures in this
independent check. UI copies used for the reproduction were not committed.

Native startup remains the actual database operation owner; this ref prevents
frontend overlap and is not a substitute for native ownership. These tests
use the project SSR/happy-dom harness with controlled native command promises;
they do not prove installed Windows/macOS webview behavior or real updater
installation.

## Slow native diagnostic reads

`callCommandStrict` uses a four-second default timeout without cancelling the
underlying native invocation. The initial polling change therefore could
start another native diagnostic read while its first read still waited for
the journal lock. The recovery component now retains that promise without a
frontend timeout and shares it across preparing/error effect changes. Other
controls remain usable. A regression holds the frontend/native bridge
promise beyond the old timeout, changes startup phase, exports diagnostics,
then settles the original read and checks its visible result. This proves the
component's request bound, not cancellation or global native-worker limits.

## Rendered long-error recovery controls

The integration owner rendered the actual Vite application in Linux Chromium
156.0.8078.80 with Chinese fonts, 35 synthetic independent source failures and
a controlled native IPC bridge. The connected Browser extension reported
that it lacked the originating browser context; the cloud browser could not
reach the build container's localhost. A separate local Playwright browser
was therefore used under the task's autonomous validation authorization. The
project's dependencies were not changed for this check.

The flow was: open failed startup → check software update → see available
version → export full diagnostics → expand the diagnostic preview. No
installer or actual database operation was called.

| Viewport and surface | Before | After |
|---|---|---|
| 900 × 640 main | Update button began at y=2634, outside the first viewport | Update button at y=343 and visible immediately |
| 560 × 480 main | Update button began at y=2610, outside the first viewport | Update button at y=336 and visible immediately |
| 320 × 200 status | The recovery content had no own scroll container inside the window's hidden document overflow | Recovery container is bounded to 200px with native scrolling; opening the main window succeeds |

Long error details now have a keyboard-focusable scroll region, preserve
line breaks and wrap long paths. The recovery container itself also scrolls
inside the small auxiliary windows. Full error text remains available; it is
not truncated to a summary.

All three after-change cases had the correct title/content, no runtime or
framework error overlay, no console errors, and successful target controls.
The two main-window cases displayed the update/install option, exported the
mock diagnostic path and expanded the preview. The status window sent exactly
one `show_dashboard_window` command. No retry or install command was sent.
Screenshots, JSON measurements and the temporary runner are retained with the
progress checkpoint. This is browser-rendered web UI evidence with mocked
IPC, not installed Windows/macOS updater acceptance. Native Swift rendering
and its separate diagnostic-lock fix still require macOS execution.
