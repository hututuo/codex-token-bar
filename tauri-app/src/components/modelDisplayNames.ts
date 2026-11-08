import catalog from "../../../Sources/CodexTokenBar/Resources/model-display-names.json" with { type: "json" };
import prices from "../../../Vendor/AgentSpeed/spec/assets/prices.json" with { type: "json" };

/** Display text only: never use labels as accounting, grouping or pricing keys. */
export const modelDisplayNames: Readonly<Record<string, string>> = Object.freeze(catalog.names);
const normalized = (value: string) => value.trim().toLowerCase().replaceAll("_", "-");
const untyped = new Set(["gpt-5.6", "gpt5.6", "gpt56"]);
const byAlias = new Map<string, string>();
const ambiguous = new Set<string>();
for (const model of prices.models as { id: string; name: string; aliases?: string[] }[]) {
  const label = modelDisplayNames[model.id];
  if (!label) continue;
  for (const value of [model.id, model.name, ...(model.aliases ?? [])]) {
    const key = normalized(value);
    if (untyped.has(key) || ambiguous.has(key)) continue;
    const previous = byAlias.get(key);
    if (previous && previous !== label) { byAlias.delete(key); ambiguous.add(key); }
    else byAlias.set(key, label);
  }
}

/** Only known IDs/aliases and documented wrappers are shortened. Preserve
 * unknown future variants and Fast/free markers; this does not resolve prices. */
export function catalogModelLabel(raw: string): string | null {
  let key = normalized(raw);
  const exact = byAlias.get(key);
  if (exact) return exact;
  key = key.split("/").at(-1) ?? key;
  const rules = prices.normalize;
  for (const region of rules.bedrockRegions) if (key.startsWith(region + ".")) {
    const rest = key.slice(region.length + 1);
    if (rules.bedrockVendors.some(vendor => rest.startsWith(vendor + "."))) key = rest;
    break;
  }
  for (const vendor of rules.bedrockVendors) if (key.startsWith(vendor + ".")) {
    key = key.slice(vendor.length + 1).replace(/-v[0-9]+(?::[0-9]+)?$/, "");
    break;
  }
  key = key.replace(/@(?:default|[0-9]{8})$/, "");
  const routed = byAlias.get(key);
  if (routed) return routed;
  let suffix = "";
  const free = rules.freeSuffixes.find(marker => key.endsWith(marker));
  if (free) { key = key.slice(0, -free.length); suffix = " Free"; }
  if (key.endsWith("-fast")) { key = key.slice(0, -5); suffix = " Fast" + suffix; }
  const mode = byAlias.get(key);
  if (mode) return mode + suffix;
  for (const rule of rules.rewrites) if (key.startsWith(rule.prefix)) {
    key = rule.to + key.slice(rule.prefix.length); break;
  }
  if (rules.dateSuffixPrefixes.some(prefix => key.startsWith(prefix))) key = key.replace(/-[0-9]{8}$/, "");
  for (const rule of rules.modifierSuffixes) if (key.startsWith(rule.prefix)) {
    let marker: string | undefined;
    while ((marker = rule.suffixes.find(value => key.endsWith(value)))) key = key.slice(0, -marker.length);
    break;
  }
  const modified = byAlias.get(key);
  if (modified) return modified + suffix;
  if (rules.dotHyphenPrefixes.some(prefix => key.startsWith(prefix))) key = key.replaceAll(".", "-");
  const label = byAlias.get(key);
  return label ? label + suffix : null;
}

/** Benchmark effort is a separate word, never an accounting model suffix. */
export function catalogModelLabelWithEffort(raw: string): string | null {
  const exact = catalogModelLabel(raw);
  if (exact) return exact;
  const parts = raw.trim().split(/ +/);
  const effort = parts.at(-1)?.toLowerCase() ?? "";
  if (parts.length < 2 || !["ultra", "max", "xhigh", "high", "medium", "low", "minimal", "none"].includes(effort)) return null;
  const label = catalogModelLabel(parts.slice(0, -1).join(" "));
  return label ? label + " " + effort : null;
}
