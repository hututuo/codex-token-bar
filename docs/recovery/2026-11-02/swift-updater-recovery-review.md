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

**At authoring, these Swift tests have not run in the Linux workspace.** Native compiler results, delegate invocation and installed-app update/cancel/failed-install interactions remain required. State tests do not prove an installation happened. No test downloads or installs an update, and no release feed has been changed.
