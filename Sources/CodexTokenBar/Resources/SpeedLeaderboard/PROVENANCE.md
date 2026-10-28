# Leaderboard invitation media

Recorded from the public https://deng.codexradar.com/ leaderboard on 2026-10-25, at the user's request, using browser Page.screencastFrame. The recording shows public leaderboard entries as they appeared; it is not live data, synthetic rankings, or Token Bar user data.

9.7-second silent H.264 MP4, 1684 × 1100, CRF 16; 7,911,340 bytes (about 7.91 MB), 60 fps playback (582 frames). Originally captured from the public site at two device pixels per CSS pixel (900 × 700 viewport), cropped to the table without upscaling. Source capture averaged 30.6 fps; CFR 60 fps playback repeats frames and is not native 60 fps capture.

After user review, removed entire refresh regions using the original 16-second recording timeline: [0, 2.1), [5.1, 6.1), [9.9, 11.1), [14.0, 16.0). Kept [2.1, 5.1), [6.1, 9.9), [11.1, 14.0), concatenated in that order without crossfade, synthetic motion interpolation or altered leaderboard content. The two joins are at 3.0 s and 6.8 s in the new clip. This supersedes the earlier 14.233333-second duplicate-frame-only edit; its report is kept as historical evidence. Current report: `docs/maintenance/assets/20261025-leaderboard-trim/segment-edit-report.json`.

`poster.jpg` is the new first frame. Both clients' MP4 copies are byte-identical (SHA256 `069f626653d0ca43594cb7ef54ae36733cd9263cfd1450b8c5d1ad535adb4a6c`). Both clients play the bundled asset locally, once per invitation; no remote iframe, video URL, analytics or service request is needed to render the invitation.

Swift preserves the poster/manual playback when Reduce Motion or Low Power Mode is enabled. Web respects Reduce Motion and pauses when hidden; both stop playback on dismissal. UI labels the asset as a recorded demonstration, not current data.

Agent Speed's MIT license is included separately in this directory; it applies to the vendored Agent Speed core, not a new license grant for the recorded website.
