/** Protect the native resize boundary from WebKit's previous narrow backing
 * surface. This is a short visible fade, not a delayed-hover debounce. */
export async function fadeBeforeNativeDockReveal(host: HTMLElement | null, reducedMotion: boolean): Promise<() => void> {
  if (!host || typeof host.animate !== "function") return () => {};
  const outgoing = host.animate([{ opacity: 1 }, { opacity: 0 }], {
    duration: reducedMotion ? 0 : 40, easing: "ease-out", fill: "forwards",
  });
  try { await outgoing.finished; } catch { outgoing.cancel(); return () => {}; }
  // Animation completion runs before paint. Let its transparent final frame
  // reach the compositor before moving the native window's origin.
  await new Promise<void>((resolve) => {
    let frame = 0;
    const fallback = window.setTimeout(() => { cancelAnimationFrame(frame); resolve(); }, 50);
    frame = requestAnimationFrame(() => { window.clearTimeout(fallback); resolve(); });
  });
  let restored = false;
  return () => {
    if (restored) return;
    restored = true;
    outgoing.cancel();
    if (host.isConnected && !reducedMotion) {
      const incoming = host.animate([{ opacity: 0 }, { opacity: 1 }], { duration: 80, easing: "ease-out" });
      void incoming.finished.catch(() => {});
    }
  };
}

/** Native setFrame completing does not imply WebKit has resized its viewport. */
export async function waitForDockViewport(width: number, height: number): Promise<void> {
  await new Promise<void>((resolve, reject) => {
    const matches = () => Math.abs(window.innerWidth - width) <= 1 && Math.abs(window.innerHeight - height) <= 1;
    const finish = () => {
      window.clearTimeout(deadline);
      window.removeEventListener("resize", changed);
      resolve();
    };
    const changed = () => { if (matches()) finish(); };
    const deadline = window.setTimeout(() => {
      window.removeEventListener("resize", changed);
      reject(new Error("Floating webview did not reach the requested dock viewport"));
    }, 500);
    window.addEventListener("resize", changed);
    changed();
  });
}


/** Allow one layout paint at the new viewport before exposing the window. */
export function waitForDockPaint(): Promise<void> {
  return new Promise((resolve) => {
    let frame = 0;
    const finish = () => { window.clearTimeout(deadline); cancelAnimationFrame(frame); resolve(); };
    const deadline = window.setTimeout(finish, 50);
    frame = requestAnimationFrame(() => { frame = requestAnimationFrame(finish); });
  });
}
