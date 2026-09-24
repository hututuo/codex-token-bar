/** Closing a drawer may race one native frame update. Retry only that close,
 * not on an idle timer, and stop as soon as a newer layout owns the window. */
export async function restoreFloatingWindowFrame(
  resize: () => Promise<boolean>,
  isCurrent: () => boolean,
  wait: (milliseconds: number) => Promise<void> = ms => new Promise(resolve => setTimeout(resolve, ms)),
): Promise<boolean> {
  for (const delay of [0, 75, 180]) {
    if (!isCurrent()) return false;
    if (delay) await wait(delay);
    if (!isCurrent()) return false;
    if (await resize()) return isCurrent();
  }
  return false;
}
