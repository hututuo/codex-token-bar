# Native recovery actions and software-update ownership

## Finding

The protection view invoked retry and `SPUUpdater.checkForUpdates()` directly. The application had no common ownership state for these actions. A Sparkle window being visible is not an application-level guarantee that the other action cannot run. Its documented `canCheckForUpdates` may remain true to focus a displayed update; `sessionInProgress` can become false while a separate installer is still active.

The dependency is pinned at Sparkle 2.9.3, commit `d46d456107feacc80711b21847b82b07bd9fb46e`. The following public primary sources were checked before selecting callbacks:

- [Pinned SPUUpdater API](https://github.com/sparkle-project/Sparkle/blob/d46d456107feacc80711b21847b82b07bd9fb46e/Sparkle/SPUUpdater.h)
- [Pinned SPUUpdaterDelegate API](https://github.com/sparkle-project/Sparkle/blob/d46d456107feacc80711b21847b82b07bd9fb46e/Sparkle/SPUUpdaterDelegate.h)
- [Pinned updater callback ordering](https://github.com/sparkle-project/Sparkle/blob/d46d456107feacc80711b21847b82b07bd9fb46e/Sparkle/SPUUpdater.m)

## Change and limits

`ApplicationRecoveryOperationGate` owns synchronous main-actor state for startup migration, a pending manual update request, observed Sparkle sessions and installer handoff. The startup coordinator acquires and releases migration ownership around its actual asynchronous preparation. A blocked retry keeps the failed state. Manual requests close the interval before Sparkle changes its session flag.

The single existing software-updater owner now observes session state before starting Sparkle, including automatic sessions. Its public delegate refuses checks while migration owns preparation. `willInstallUpdate` retains installation ownership beyond a successful end-of-session notification; an error/cancellation permits recovery again. The update button can still focus an existing Sparkle session where the library allows that action. Feed selection, signature validation, automatic-update preferences and the installer protocol are unchanged.

Seven native XCTest cases cover immediate ordering, automatic-session cancellation, installer handoff, a refused/no-op check and the real startup coordinator's asynchronous retry count. An initial request that encounters an active update resumes when ownership is released; observing update changes does not start an unrequested coordinator. The pinned `checkForUpdates` implementation sets `sessionInProgress` synchronously before probing installer state, so the explicit no-op release does not create an asynchronous start window. The required native recovery workflow checks that every test in this suite actually ran and passed.

## Independent lifecycle review: continuing an existing installation

The subsequent review traced the pinned updater, core, installer and standard user driver implementations. A manual check marks its session active before its asynchronous installer probe. Completion clears the session before calling the delegate, and scheduling the next cycle happens on that same main-thread stack. The startup coordinator's deferred observation reads the resulting state on the next main-actor turn. Closing the application window does not replace its app-owned startup coordinator or the shared updater and gate.

One supported interaction had no recovery-page entry: if application termination is delayed or refused after installer handoff, Sparkle closes its status window and keeps a termination retry handler. Its public `showUpdateInFocus` operation can present that handler again. The previous application gate disabled every update action after handoff, including this presentation. The production recovery app normally replies `terminateNow`; no actual installed application termination failure has been reproduced locally.

The protection page now displays **Continue software update** during installer ownership. The action requires all of the following at the moment it executes: installer ownership, an observed active session, the actual updater's active session and `canCheckForUpdates`, and no migration or pending check request. It invokes only the existing standard user driver's public focus method. It never invokes `checkForUpdates`, starts another installer, clears installation ownership, or starts a database operation. If the session has ended, the continuation action remains unavailable; a successful handoff continues to block migration until process exit. Error completion releases ownership through the existing callback path.

The exact upstream paths inspected were:

- [SPUCoreBasedUpdateDriver](https://github.com/sparkle-project/Sparkle/blob/d46d456107feacc80711b21847b82b07bd9fb46e/Sparkle/SPUCoreBasedUpdateDriver.m): installer handoff delegate callback.
- [SPUInstallerDriver](https://github.com/sparkle-project/Sparkle/blob/d46d456107feacc80711b21847b82b07bd9fb46e/Sparkle/SPUInstallerDriver.m): installation/termination response and notification ordering.
- [SPUStandardUserDriver](https://github.com/sparkle-project/Sparkle/blob/d46d456107feacc80711b21847b82b07bd9fb46e/Sparkle/SPUStandardUserDriver.m): retained termination retry UI and public focus operation.
- [SPUUserDriver public API](https://github.com/sparkle-project/Sparkle/blob/d46d456107feacc80711b21847b82b07bd9fb46e/Sparkle/SPUUserDriver.h) and [controller public API](https://github.com/sparkle-project/Sparkle/blob/d46d456107feacc80711b21847b82b07bd9fb46e/Sparkle/SPUStandardUpdaterController.h): the focus operation and owned standard driver are public, main-thread APIs.

Four additional tests bring `ApplicationRecoveryOperationGateTests` to eleven cases. Three check stale/live session disagreement, a noninteractive driver, conflicting migration ownership, repeated focus, and both orders of session/error completion. The fourth constructs the real pinned `SPUStandardUserDriver` against a uniquely named synthetic bundle, supplies its documented application-not-terminated callback, focuses the actual retry window, invokes its button, closes/reopens it and invokes the same retained handler again. It uses the production gate's focus operation and cleans up only its own UI and preferences. It starts no updater, network request or installation, and contains no polling wait. This is an actual standard-driver interaction test when run on macOS, not an installed-update or operating-system termination test.

At authoring time, only source/API review and `git diff --check` have run for this continuation change. This Linux workspace cannot compile or execute these macOS tests. Hosted native compilation and all eleven test outcomes are still required; no native PASS is claimed here.

**At authoring, these Swift tests have not run in the Linux workspace.** Native compiler results, delegate invocation and installed-app update/cancel/failed-install interactions remain required. State tests do not prove an installation happened. No test downloads or installs an update, and no release feed has been changed.
