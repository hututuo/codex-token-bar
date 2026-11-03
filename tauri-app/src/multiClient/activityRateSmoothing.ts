/** Display only; matches the rise/fall gain of Codex's Bar curve. */
export function activityRateStep(previous: number, target: number, seconds = 1) {
  const gain = target >= previous ? .28 : .18;
  return previous + (target - previous) * (seconds === 1 ? gain : 1 - (1 - gain) ** seconds);
}
export function activityRateTail(age: number) {
  const x=Math.min(1,Math.max(0,(5-age)/2));
  return x*x*(3-2*x);
}
export function claudeBarAgentActive(agent: {phase:string; lastActivity:string; displayStopped?:boolean}, time: number) {
  const age=time-Date.parse(agent.lastActivity)/1000;
  return !agent.displayStopped && ["generating","tools","idle"].includes(agent.phase)
    && age>=-2 && age<(agent.phase==='idle'?5:20);
}
export class ActivityModelRateSmoother {
  private values = new Map<string, {rate:number; positiveAt:number}>();
  private lastTime: number | undefined;
  clear() { this.values.clear(); this.lastTime = undefined; }
  update(raw: ReadonlyMap<string, number>, time: number, active: boolean): Map<string, number> {
    if (!Number.isFinite(time) || !active) { this.clear(); return new Map(); }
    if (this.lastTime !== undefined && time <= this.lastTime) return this.rates();
    if (this.lastTime !== undefined && time - this.lastTime > 3.5) this.clear();
    const seconds = this.lastTime === undefined ? 1 : time - this.lastTime;
    this.lastTime = time;
    const clean = new Map([...raw].filter(([,rate]) => Number.isFinite(rate) && rate > 0));
    for (const model of new Set([...this.values.keys(), ...clean.keys()])) {
      const target = clean.get(model) ?? 0, old = this.values.get(model) ?? {rate:0, positiveAt:time};
      const positiveAt = target > 0 ? time : old.positiveAt;
      const rate = activityRateStep(old.rate, target, seconds);
      if (time - positiveAt < 5 && Number.isFinite(rate) && rate > .001) this.values.set(model, {rate,positiveAt});
      else this.values.delete(model);
    }
    return this.rates();
  }
  private rates() { return new Map([...this.values].map(([model,value]) => [model,value.rate*activityRateTail((this.lastTime??value.positiveAt)-value.positiveAt)])); }
}
