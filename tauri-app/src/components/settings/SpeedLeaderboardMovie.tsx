import { useEffect, useRef, useState } from "react";

/** A local recording: displaying the invitation does not contact the leaderboard. */
export function SpeedLeaderboardMovie() {
  const video = useRef<HTMLVideoElement>(null);
  const intent = useRef<"automatic" | "play" | "pause">("automatic");
  const [playing, setPlaying] = useState(false);
  useEffect(() => {
    const element = video.current;
    if (!element) return;
    const reduced = window.matchMedia?.("(prefers-reduced-motion: reduce)");
    const reconcile = () => {
      if (!document.hidden && intent.current !== "pause" && (intent.current === "play" || !reduced?.matches)) {
        void element.play().catch(() => {});
      } else element.pause();
    };
    reconcile();
    document.addEventListener("visibilitychange", reconcile);
    reduced?.addEventListener("change", reconcile);
    return () => {
      element.pause();
      document.removeEventListener("visibilitychange", reconcile);
      reduced?.removeEventListener("change", reconcile);
    };
  }, []);
  return <div className="speed-report-movie">
    <video ref={video} src="/speed-leaderboard/leaderboard.mp4" poster="/speed-leaderboard/poster.jpg"
      muted loop playsInline preload="metadata" aria-label="速蹬排行榜真实录屏"
      onPlay={() => setPlaying(true)} onPause={() => setPlaying(false)} onEnded={() => setPlaying(false)} />
    <div className="speed-report-movie-caption"><span>排行榜实录 · 非当前实时数据</span>
      <button type="button" aria-label={playing ? "暂停排行榜演示" : "播放排行榜演示"} onClick={() => {
        const element = video.current;
        if (!element) return;
        intent.current = playing ? "pause" : "play";
        if (playing) element.pause();
        else if (!document.hidden) { if (element.ended) element.currentTime = 0; void element.play().catch(() => {}); }
      }}>{playing ? "Ⅱ" : "▷"}</button>
    </div>
  </div>;
}

