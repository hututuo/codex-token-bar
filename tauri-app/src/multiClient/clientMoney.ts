export function clientMoney(value: number | null | undefined): string {
  if (typeof value !== "number" || !Number.isFinite(value) || value < 0)
    return "未计价";
  return value > 0 && value < 0.01 ? "<$0.01" : `$${value.toFixed(2)}`;
}
