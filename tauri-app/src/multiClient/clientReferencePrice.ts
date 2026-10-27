import bundled from "../../../Vendor/AgentSpeed/spec/assets/prices.json";
/** Local reference card only: does not initialize the reporter, sync prices or quote billing. */
export function referencePrice(raw: string): string {
  const key = raw.trim().toLowerCase().split("/").at(-1) ?? "";
  const models = bundled.models as {
    id: string;
    aliases?: string[];
    free?: boolean;
    prices?: { input: number; output: number };
  }[];
  const entry = models.find((m) => m.id === key || m.aliases?.includes(key));
  if (entry?.free) return "免费模型";
  if (!entry?.prices) return "未计价";
  return `$${entry.prices.input.toFixed(2)} / $${entry.prices.output.toFixed(2)}`;
}
