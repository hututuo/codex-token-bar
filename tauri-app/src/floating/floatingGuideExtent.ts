/** Logical CSS pixels, not device pixels. Guide cards sit outside the normal
 * panel, so its height alone is not the required native viewport height. */
export function floatingGuideRequiredHeight(hostTop: number, bottoms: number[], scale: number): number {
  const finiteBottoms = bottoms.filter(Number.isFinite);
  if (!Number.isFinite(hostTop) || finiteBottoms.length === 0) return 0;
  return Math.ceil(Math.max(0, Math.max(...finiteBottoms) - hostTop) + 6 * scale);
}
