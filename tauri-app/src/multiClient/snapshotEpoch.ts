/** A local asynchronous observation may only publish into the source/lifetime
 * that requested it. This carries no data and does not initiate a reader. */
export class SnapshotEpoch {
  private revision = 0;
  private key: string | undefined;
  select(key: string): boolean {
    if (this.key === key) return false;
    this.key = key; this.revision++; return true;
  }
  invalidate() { this.revision++; }
  capture() { return this.revision; }
  accepts(ticket: number) { return this.revision === ticket; }
}
