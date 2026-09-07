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
