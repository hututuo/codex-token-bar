import bundled from "../../../Vendor/AgentSpeed/spec/assets/prices.json";

type Prices = { input: number; output: number };
type PeakRule = { peakUtc: string[]; peakWeekdays?: number[]; offPeakDates?: string[]; prices: Prices };
type Period = { from?: string; to?: string; prices: Prices; offPeak?: PeakRule | null };
type Model = Period & { id: string; aliases?: string[]; free?: boolean; periods?: Period[]; fast?: { prices: Prices } };
const models = bundled.models as Model[];

/** Local shared price asset only. Does not initialize reporting or make any request. */
export function referencePrice(raw: string, at: Date = new Date()): string {
  const key = raw.trim().toLowerCase().split("/").at(-1) ?? "";
  let entry = models.find((model) => model.id === key || model.aliases?.includes(key));
  const fast = !entry && key.endsWith("-fast");
  if (fast) {
    const base = key.slice(0, -5);
    entry = models.find((model) => model.id === base || model.aliases?.includes(base));
  }
  if (entry?.free) return "免费模型";
  if (!entry || !Number.isFinite(at.getTime())) return "未计价";
  let prices: Prices | undefined;
  if (fast) {
    prices = entry.fast?.prices;
  } else {
    const active = entry.periods?.find((period) =>
      (period.from === undefined || at.getTime() >= Date.parse(period.from))
      && (period.to === undefined || at.getTime() < Date.parse(period.to))) ?? entry;
    const rule = active.offPeak;
    if (rule) {
      const weekday = at.getUTCDay() || 7;
      const minute = at.getUTCHours() * 60 + at.getUTCMinutes();
      const peakDay = rule.peakWeekdays === undefined || rule.peakWeekdays.includes(weekday);
      const holiday = rule.offPeakDates?.includes(at.toISOString().slice(0, 10)) ?? false;
      const peakTime = rule.peakUtc.some((window) => {
        const [start, end] = window.split("-").map((clock) => {
          const [hour, minute] = clock.split(":").map(Number);
          return hour * 60 + minute;
        });
        return start <= minute && minute < end;
      });
      prices = peakDay && !holiday && peakTime ? active.prices : rule.prices;
    } else prices = active.prices;
  }
  if (!prices || typeof prices.input !== "number" || typeof prices.output !== "number"
    || !Number.isFinite(prices.input) || !Number.isFinite(prices.output)) return "未计价";
  return `$${prices.input.toFixed(2)} / $${prices.output.toFixed(2)}`;
}
