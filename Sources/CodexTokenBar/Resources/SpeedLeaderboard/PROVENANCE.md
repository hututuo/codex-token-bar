# Leaderboard invitation media

Recorded from the public https://deng.codexradar.com/ leaderboard on 2026-10-25, at the user's request, using browser Page.screencastFrame. The recording shows public leaderboard entries as they appeared; it is not live data, synthetic rankings, or Token Bar user data.

14.233333-second silent H.264 MP4, 1684 × 1100, CRF 16; 10,666,450 bytes (about 10.67 MB), 60 fps playback (854 frames). Captured from the public site at two device pixels per CSS pixel (900 × 700 viewport), cropped to the table without upscaling. The original 20-second capture yielded 610 real browser frames (30.6 fps); 496 source frames fell within the original first 16 seconds. Browser timestamps were sorted before encoding. Constant-rate 60 fps playback repeats frames; this is not a claim of native 60 fps source capture.

On 2026-10-25, removed 106 surplus near-identical hold frames (1.766667 seconds) from that 16-second recording, including refresh stalls near 0.9–1.6 s and 5.3–5.8 s, and shorter holds later. The numerical leaderboard frames and their order are preserved; no invented content, interpolation, crossfade or speed-up of moving frames. Cuts retain the start of each hold to avoid a scene jump. Detailed original frame/time ranges and the exact ffmpeg selection filter are in `docs/maintenance/assets/20261025-leaderboard-trim/edit-report.json`. Post-encode frame analysis finds no near-identical hold longer than 83.3 ms (previous longest about 267 ms).

`poster.jpg` remains the original first frame. Both client MP4 copies are byte-identical (SHA256 `2478cda2d2782f73df2e64e0a67ac07e437cd1c127cea97bf247cf07b55f78fd`). Both clients play the bundled asset locally, once per invitation; no remote iframe, video URL, analytics or service request is needed to render the invitation.

Swift preserves the poster/manual playback when Reduce Motion or Low Power Mode is enabled. Web respects Reduce Motion and pauses when hidden; both stop playback on dismissal. UI labels the asset as a recorded demonstration, not current data.

Agent Speed's MIT license is included separately in this directory; it applies to the vendored Agent Speed core, not a new license grant for the recorded website.
