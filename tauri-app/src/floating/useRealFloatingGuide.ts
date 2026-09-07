import { useEffect, useRef, type RefObject } from "react";
import { invoke } from "@tauri-apps/api/core";
import { listen } from "@tauri-apps/api/event";
import { currentMonitor, primaryMonitor, getCurrentWindow } from "@tauri-apps/api/window";
import { beginFloatingGeometryRehearsal, runFloatingGeometryChange } from "../platform/floatingGeometryLifecycle";
import { isDesktopRuntimeAvailable, warnPlatformFailure } from "../platform/desktopBridge";
import { createFloatingEdgeDockController, type DockRect } from "./floatingEdgeDock";

type Dock = ReturnType<typeof createFloatingEdgeDockController>;
type Point = { x: number; y: number };
export function useRealFloatingGuide(enabled: boolean, controller: RefObject<Dock | null>, onComplete: () => void, onDismiss: () => void) {
  const completeRef = useRef(onComplete); completeRef.current = onComplete;
  const dismissRef = useRef(onDismiss); dismissRef.current = onDismiss;
  const session = useRef<RealFloatingGuideSession | null>(null);
  useEffect(() => {
    if (!enabled || !isDesktopRuntimeAvailable()) return;
    let disposed = false;
    let remove: (() => void) | undefined;
    const rehearsal = new RealFloatingGuideSession(controller, markComplete => {
      if (markComplete) completeRef.current(); else dismissRef.current();
    });
    session.current = rehearsal;
    void listen<string>("floating-guide-action", event => {
      if (event.payload === "finish") void rehearsal.finish(true);
      if (event.payload === "replay") void rehearsal.replay();
    }).then(unlisten => {
      if (disposed) { unlisten(); return; }
      remove = unlisten;
      void rehearsal.replay();
    }).catch(error => { warnPlatformFailure("floating-real-guide", error); void rehearsal.finish(false); });
    return () => {
      disposed = true; remove?.();
      void rehearsal.finish(false, false);
      if (session.current === rehearsal) session.current = null;
    };
  }, [enabled, controller]);
  return { finish: () => { void session.current?.finish(true); } };
}

export class RealFloatingGuideSession {
  private original: DockRect | null = null;
  private attached = false;
  private workArea: DockRect | null = null;
  private scale = 1;
  private lastDisplayCheck = 0;
  private cursorPoint: Point = { x: 0, y: 0 };
  private abort = new AbortController();
  private closed = false;
  private finished = false;
  private releaseGeometry: (() => void) | null = null;
  private playback: Promise<void> | null = null;
  private preparing: Promise<unknown> | null = null;
  constructor(private controller: RefObject<Dock | null>, private complete: (markComplete: boolean) => void) {}
  private get dock() { const dock = this.controller.current; if (!dock) throw new Error("Floating dock is unavailable"); return dock; }
  private check() { if (this.closed || this.abort.signal.aborted) throw new DOMException("Cancelled", "AbortError"); }
  private async wait(ms: number) {
    await new Promise<void>((resolve, reject) => {
      const signal = this.abort.signal;
      const stop = () => { clearTimeout(timer); reject(new DOMException("Cancelled", "AbortError")); };
      const timer = setTimeout(() => { signal.removeEventListener("abort", stop); resolve(); }, ms);
      signal.addEventListener("abort", stop, { once: true });
      if (signal.aborted) stop();
    }); this.check();
    await this.validateDisplay();
  }
  private update(args: Record<string, unknown>) { return invoke<void>("update_floating_guide_overlay", args); }
  private async geometry() {
    const win = getCurrentWindow();
    const [position, size, monitor, scale] = await Promise.all([win.outerPosition(), win.outerSize(), currentMonitor(), win.scaleFactor()]);
    const display = monitor ?? (this.closed ? await primaryMonitor() : null);
    if (!display) throw new Error("No display for the floating guide");
    return { frame: { x: position.x, y: position.y, width: size.width, height: size.height },
      area: { x: display.workArea.position.x, y: display.workArea.position.y, width: display.workArea.size.width, height: display.workArea.size.height }, scale };
  }
  async validateDisplay() {
    if (this.closed || !this.workArea || performance.now() - this.lastDisplayCheck < 250) return;
    this.lastDisplayCheck = performance.now();
    const live = await this.geometry();
    if (live.scale !== this.scale || (Object.keys(this.workArea) as (keyof DockRect)[]).some(key => live.area[key] !== this.workArea![key])) {
      throw new Error("Display configuration changed during the floating guide");
    }
  }
  private grab(frame: DockRect): Point { return { x: frame.x + frame.width / 2, y: frame.y + 20 * this.scale }; }
  private cursorOrigin(point: Point): Point { return { x: point.x - 18 * this.scale, y: point.y - 26 * this.scale }; }
  private async moveFrame(frame: DockRect, tracksCursor = true) {
    const cursor = tracksCursor ? this.grab(frame) : null;
    await runFloatingGeometryChange(() => this.update({ frame, ...(cursor ? { cursor: this.cursorOrigin(cursor) } : {}) }));
    if (cursor) this.cursorPoint = cursor;
  }
  private async message(step: number, title: string, detail: string, finished = false) {
    await this.update({ message: { step, title, detail, finished } });
  }
  private async animate(duration: number, action: (t: number) => Promise<void>) {
    const reduced = window.matchMedia("(prefers-reduced-motion: reduce)").matches;
    const start = performance.now();
    do {
      this.check();
      const p = Math.min(1, (performance.now() - start) / (reduced ? 40 : duration));
      await action(p * p * (3 - 2 * p));
      this.check();
      if (p >= 1) return;
      await this.wait(16);
    } while (true);
  }
  private async moveWindow(to: Point, duration: number, tracksCursor = true) {
    const { frame } = await this.geometry();
    await this.animate(duration, t => this.moveFrame({ ...frame, x: frame.x + (to.x - frame.x) * t, y: frame.y + (to.y - frame.y) * t }, tracksCursor));
  }
  private async moveCursor(to: Point, duration: number) {
    const start = this.cursorPoint;
    await this.animate(duration, async t => {
      const point = { x: start.x + (to.x - start.x) * t, y: start.y + (to.y - start.y) * t };
      await this.update({ cursor: this.cursorOrigin(point) }); this.cursorPoint = point;
    });
  }
  async replay() {
    if (this.closed || (this.playback && !this.finished)) return;
    this.finished = false;
    this.abort = new AbortController();
    // Store the raw playback: cleanup can await it without awaiting its own catch.
    this.playback = this.play();
    try {
      await this.playback;
    } catch (error: unknown) {
      if (!(error instanceof DOMException && error.name === "AbortError")) {
        warnPlatformFailure("floating-real-guide", error);
        await this.finish(false);
      }
    }
  }

  private async play() {
    await this.wait(450);
    await runFloatingGeometryChange(async () => {});
    const live = await this.geometry(); this.check();
    if (!this.original) { this.original = this.dock.state().anchor?.frame ?? live.frame; this.attached = this.dock.state().anchor !== null; }
    this.workArea = live.area; this.scale = live.scale;
    this.releaseGeometry ??= beginFloatingGeometryRehearsal();
    this.preparing = invoke("prepare_floating_guide_overlay");
    await this.preparing; this.check();
    let ready = false;
    for (let i = 0; i < 100; i++) {
      ready = await invoke<boolean>("floating_guide_overlay_ready");
      if (ready) break;
      await this.wait(50);
    }
    if (!ready) throw new Error("Guide overlay did not become ready");
    const original = this.original, area = this.workArea, s = this.scale;
    const right = original.x + original.width / 2 >= area.x + area.width / 2;
    const target = { x: right ? area.x + area.width - original.width : area.x,
      y: Math.min(Math.max(original.y, area.y + 90 * s), Math.max(area.y + 90 * s, area.y + area.height - original.height - 120 * s)) };
    const distance = Math.min(260 * s, Math.max(90 * s, (area.width - original.width) * 0.4));
    const free = { x: right ? target.x - distance : target.x + distance, y: target.y };
    await this.dock.beginGuide(this.grab(original));
    await this.dock.guideBeginDrag(); this.check();
    await this.moveFrame({ ...original, ...free });
    const below = target.y + original.height + 10 * s;
    const card = { x: Math.min(Math.max(target.x + (original.width - 286 * s) / 2, area.x + 8 * s), area.x + area.width - 294 * s),
      y: Math.min(Math.max(below + 100 * s <= area.y + area.height ? below : target.y - 110 * s, area.y + 8 * s), area.y + area.height - 108 * s) };
    await this.update({ card, visible: true, pressed: false });
    await this.message(1, "拖到边缘，自动吸附", "演示鼠标会带着这个悬浮窗移动");
    await this.wait(950);
    await this.update({ pressed: true }); await this.wait(200);
    await this.moveWindow(target, 1700); await this.wait(200);
    await this.update({ pressed: false });
    this.dock.guideHover(this.grab((await this.geometry()).frame));
    await this.dock.guideEndDrag(); await this.wait(350);
    const away = { x: target.x + original.width / 2, y: target.y + original.height + 24 * s };
    await this.message(2, "松手后吸附，移开后收起", "真实面板会收成屏幕边缘的色条");
    await this.moveCursor(away, 400); this.dock.guideHover(away); await this.wait(1150);
    await this.enterHandle(3, "鼠标移入色条，自动展开"); await this.wait(700);
    await this.message(4, "鼠标移开，再次收起", "需要时再移入，就能重新展开");
    await this.moveCursor(away, 400); this.dock.guideHover(away); await this.wait(1100);
    await this.enterHandle(5, "按住面板，拖出来还原");
    await this.moveCursor(this.grab((await this.geometry()).frame), 350);
    await this.update({ pressed: true }); await this.wait(200);
    await this.dock.guideBeginDrag();
    await this.moveWindow(free, 1700); await this.wait(200);
    await this.update({ pressed: false });
    this.dock.guideHover(this.grab((await this.geometry()).frame)); await this.dock.guideEndDrag();
    await this.message(5, "已恢复普通悬浮窗", "脱离边缘后，可以自由摆放"); await this.wait(1100);
    await this.update({ visible: false }); await this.dock.guideDetach();
    await this.moveWindow((await this.restorableFrame()), 450, false);
    this.dock.endGuide();
    if (this.attached) this.dock.initialize();
    await this.message(5, "演示完成", "窗口已回到原位，可以重播或开始体验", true);
    this.finished = true;
  }
  private async enterHandle(step: number, title: string) {
    await this.message(step, title, step === 5 ? "拖离屏幕边缘，就能恢复自由悬浮" : "使用的是平时的真实展开效果");
    const { frame } = await this.geometry();
    const point = { x: frame.x + frame.width / 2, y: frame.y + frame.height / 2 };
    await this.moveCursor(point, 500); this.dock.guideHover(point); await this.wait(450);
  }
  private async restorableFrame() {
    if (!this.original) throw new Error("Missing original window frame");
    const { area } = await this.geometry();
    const original = { ...this.original, width: Math.min(this.original.width, area.width), height: Math.min(this.original.height, area.height) };
    return { ...original, x: Math.min(Math.max(original.x, area.x), area.x + area.width - original.width),
      y: Math.min(Math.max(original.y, area.y), area.y + area.height - original.height) };
  }
  async finish(markComplete: boolean, notify = true) {
    if (this.closed) return;
    this.closed = true; this.abort.abort();
    await this.playback?.catch(() => {});
    try {
      if (this.original) {
        await this.controller.current?.guideDetach();
        const frame = await this.restorableFrame();
        await runFloatingGeometryChange(() => invoke("set_floating_dock_frame", { frame }));
      }
    } catch (error) { warnPlatformFailure("floating-real-guide-restore", error); }
    finally {
      this.controller.current?.endGuide();
      if (this.attached) this.controller.current?.initialize();
      await this.preparing?.catch(() => {});
      await this.update({ close: true }).catch(error => warnPlatformFailure("floating-real-guide-close", error));
      this.releaseGeometry?.(); this.releaseGeometry = null;
      if (notify) this.complete(markComplete);
    }
  }
}
