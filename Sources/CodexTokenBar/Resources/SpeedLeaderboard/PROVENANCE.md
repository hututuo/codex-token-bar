# Leaderboard invitation media

Recorded from the public https://deng.codexradar.com/ leaderboard on 2026-10-25, at the user's request, using browser Page.screencastFrame. The recording shows public leaderboard entries as they appeared; it is not live data, synthetic rankings, or Token Bar user data.

18-second silent H.264 MP4, 1128 × 826, CRF 14; 3,129,537 bytes (about 3.1 MB). Re-recorded at two device pixels per CSS pixel from a 600-pixel responsive viewport, then cropped without upscaling. Encoded at 30 fps using the captured event timestamps; repeated frames preserve timing between browser screencast frames (174 captured frames over 17.8 seconds), without invented motion interpolation. Cropped to the leaderboard only, with no browser chrome or other apps. `poster.jpg` is its first frame. Copies in `tauri-app/public/speed-leaderboard/` are byte-identical. Both clients play the bundled asset locally, once per invitation; no remote iframe, video URL, analytics or service request is needed to render the invitation.

Swift preserves the poster/manual playback when Reduce Motion or Low Power Mode is enabled. Web respects Reduce Motion and pauses when hidden; both stop playback on dismissal. UI labels the asset as a recorded demonstration, not current data.

Agent Speed's MIT license is included separately in this directory; it applies to the vendored Agent Speed core, not a new license grant for the recorded website.
