import { useEffect, useRef, useState } from "react";
import { createPortal } from "react-dom";
import { modelUsageColor, modelUsageLabel, DASHBOARD_OTHER_MODEL_COLOR } from "../modelUsagePresentation";
import { readSpeedColors, writeSpeedColor } from "./speedDisplay";
import { useSpeedPalette } from "./useSpeedPalette";

export interface ColorEditTarget { model: string; x: number; y: number; grayDefault?: boolean }
export function ModelColorEditor({ target, onClose }: { target: ColorEditTarget | null; onClose: () => void }) {
  useSpeedPalette();
  const panel = useRef<HTMLDivElement>(null);
  useEffect(() => {
    if (!target) return;
    const outside = (event: PointerEvent) => { if (!panel.current?.contains(event.target as Node)) onClose(); };
    const key = (event: KeyboardEvent) => { if (event.key === "Escape") onClose(); };
    document.addEventListener("pointerdown", outside); document.addEventListener("keydown", key);
    return () => { document.removeEventListener("pointerdown", outside); document.removeEventListener("keydown", key); };
  }, [target, onClose]);
  if (!target) return null;
  return createPortal(<div ref={panel} className="model-color-popover" role="dialog" aria-label="修改颜色"
    style={{ left: Math.max(8, Math.min(window.innerWidth - 256, target.x)), top: Math.max(8, Math.min(window.innerHeight - 160, target.y)) }}>
    <strong>{modelUsageLabel(target.model)}</strong>
    <label>颜色 <input autoFocus type="color" aria-label="选择颜色" value={readSpeedColors()[target.model] ?? (target.grayDefault ? DASHBOARD_OTHER_MODEL_COLOR : modelUsageColor(target.model))} onChange={event => writeSpeedColor(target.model, event.target.value)}/></label>
    <div><button type="button" disabled={!readSpeedColors()[target.model]} onClick={() => writeSpeedColor(target.model, null)}>恢复默认</button><button type="button" onClick={onClose}>完成</button></div>
  </div>, document.body);
}

export function ClientColorSettings() {
  const [open, setOpen] = useState(false);
  const [target, setTarget] = useState<ColorEditTarget | null>(null);
  useSpeedPalette();
  return <span className="client-color-settings">
    <button type="button" onClick={() => setOpen(!open)}>客户端颜色…</button>
    {open && <span className="client-color-menu">
      {["client:codex", "client:claudeCode", "client:deepseek"].map(model => <button type="button" key={model} onClick={event => {
        setOpen(false); setTarget({ model, x: event.clientX, y: event.clientY });
      }}><i style={{ background: modelUsageColor(model) }}/>{modelUsageLabel(model)}</button>)}
    </span>}
    <ModelColorEditor target={target} onClose={() => setTarget(null)}/>
  </span>;
}
