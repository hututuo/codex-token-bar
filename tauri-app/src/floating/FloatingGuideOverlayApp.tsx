import { useEffect, useState } from "react";
import { invoke } from "@tauri-apps/api/core";
import { listen } from "@tauri-apps/api/event";
import "./FloatingRealGuide.css";
interface GuideMessage { step: number; title: string; detail: string; finished: boolean }
export function FloatingGuideOverlayApp({ cursor }: { cursor: boolean }) {
  const [message, setMessage] = useState<GuideMessage>({ step: 1, title: "准备演示贴边吸附", detail: "", finished: false });
  const [pressed, setPressed] = useState(false);
  const [error, setError] = useState<string | null>(null);
  useEffect(() => {
    document.body.classList.add("floating-guide-overlay-body");
    let disposed = false;
    let unlisten: (() => void) | undefined;
    void listen<{ message: GuideMessage | null; pressed: boolean | null }>("floating-guide-update", event => {
      if (event.payload.message) setMessage(event.payload.message);
      if (event.payload.pressed !== null) setPressed(event.payload.pressed);
    }).then(async remove => {
      if (disposed) { remove(); return; }
      unlisten = remove;
      await invoke("floating_guide_overlay_event", { action: "ready" });
    }).catch(e => setError(String(e)));
    return () => { disposed = true; unlisten?.(); document.body.classList.remove("floating-guide-overlay-body"); };
  }, []);
  function action(action: "replay" | "finish") {
    void invoke("floating_guide_overlay_event", { action }).catch(e => setError(String(e)));
  }
  if (cursor) return <div className="real-guide-cursor" aria-hidden="true">
    {pressed && <><span className="real-guide-cursor-halo"/><b>按住</b></>}
    <svg viewBox="0 0 20 28" width="20" height="28"><path d="M1 1 3 21 8 15 13 26 17 23 11 13 19 11Z" fill={pressed ? "#155187" : "#182d41"} stroke="white" strokeWidth="1.2"/></svg>
  </div>;
  return <section className="real-guide-callout" aria-label="真实悬浮窗演示">
    <header><span>{message.finished ? "悬浮窗使用指南" : `贴边演示 · ${message.step}/5`}</span>
      {message.finished && <button onClick={() => action("replay")}>重播</button>}</header>
    <strong>{message.title}</strong>
    <footer><span>{error ?? message.detail}</span><button onClick={() => action("finish")}>{message.finished ? "开始体验" : "跳过"}</button></footer>
  </section>;
}
