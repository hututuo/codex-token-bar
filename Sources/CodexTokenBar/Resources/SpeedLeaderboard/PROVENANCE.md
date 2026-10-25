# Leaderboard invitation media

Recorded from the public https://deng.codexradar.com/ leaderboard on 2026-10-25, at the user's request, using browser Page.screencastFrame. The recording shows public leaderboard entries as they appeared; it is not live data, synthetic rankings, or Token Bar user data.

16-second silent H.264 MP4, 1684 × 1100, CRF 17; 10,550,916 bytes (about 10.6 MB), 60 fps playback. Re-recorded from the public site at two device pixels per CSS pixel (900 × 700 viewport), cropped to the table without upscaling. The 20-second capture yielded 610 real browser frames (30.6 fps versus the old recording's 9.8 fps); 496 source frames fall within the used first 16 seconds. Browser event timestamps were sorted before encoding. Constant-rate 60 fps playback repeats frames to preserve capture timing; no synthetic motion interpolation, rankings, or speeds were invented. `poster.jpg` is the new first frame. Copies in `tauri-app/public/speed-leaderboard/` are byte-identical (SHA256 `5383953fdcc8db8280fdd7f4d9d89d5a0b468bcd827334332e5e2b57bf59616a`). Both clients play the bundled asset locally, once per invitation; no remote iframe, video URL, analytics or service request is needed to render the invitation.

Swift preserves the poster/manual playback when Reduce Motion or Low Power Mode is enabled. Web respects Reduce Motion and pauses when hidden; both stop playback on dismissal. UI labels the asset as a recorded demonstration, not current data.

Agent Speed's MIT license is included separately in this directory; it applies to the vendored Agent Speed core, not a new license grant for the recorded website.
