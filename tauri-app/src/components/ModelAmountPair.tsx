import { floatingModelUsageMoneyText, floatingModelUsageValue, type FloatingModelUsageItem } from "../floating/floatingModelUsage.ts";
import { PLAN_COST_NORMALIZATION_EXPLANATION } from "../settings/quotaPriceModel.ts";
export function ModelAmountPair({ item }: { item: FloatingModelUsageItem }) {
  if (item.costUSD === null) return <span>{floatingModelUsageValue(item, "cost")}</span>;
  return <span className="model-amount-pair" title={PLAN_COST_NORMALIZATION_EXPLANATION}>
    <span>{floatingModelUsageMoneyText(item.costUSD)}</span>
    <span className="model-amount-pair-normalized">均一化 {floatingModelUsageMoneyText(item.normalizedCostUSD ?? item.costUSD)}</span>
  </span>;
}
