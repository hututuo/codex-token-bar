/** Expected values use percentage points (0–100), unlike native remaining ratios (0–1). */
export function sidebarExpectedFraction(actual: number | null, expected: number | null | undefined, stale = false): number | null {
  return actual !== null && !stale && typeof expected === "number" && Number.isFinite(expected) && expected >= 0 && expected <= 100 ? expected / 100 : null;
}
const flashes = new WeakMap<HTMLElement, Animation>();
export function flashSidebarButton(target: EventTarget | null) {
  if (!(target instanceof Element)) return;
  const button = target.closest<HTMLButtonElement>("button");
  if (!button || typeof button.animate !== "function") return;
  flashes.get(button)?.cancel();
  const flash = button.animate([{ backgroundColor: "rgba(255,255,255,.22)" }, { backgroundColor: "rgba(255,255,255,0)" }], {
    duration: window.matchMedia("(prefers-reduced-motion: reduce)").matches ? 120 : 380,
    easing: "cubic-bezier(.2,.8,.2,1)",
  });
  flashes.set(button, flash);
}
