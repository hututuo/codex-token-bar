export function cacheCoverage(
  codex: { inputTokens: number; cachedInputTokens: number } | undefined,
  rows: {
    client: string;
    inputTokens: number;
    cacheReadTokens: number | null;
    cacheReadComplete?: boolean;
  }[],
  allowed: string[],
) {
  let input = allowed.includes("codex") ? (codex?.inputTokens ?? 0) : 0,
    cached = allowed.includes("codex") ? (codex?.cachedInputTokens ?? 0) : 0,
    unknownInput = 0;
  for (const row of rows) {
    if (!allowed.includes(row.client)) continue;
    if (
      row.cacheReadComplete === true &&
      row.cacheReadTokens !== null &&
      row.cacheReadTokens >= 0 &&
      row.cacheReadTokens <= row.inputTokens
    ) {
      input += row.inputTokens;
      cached += row.cacheReadTokens;
    } else unknownInput += row.inputTokens;
  }
  return {
    input,
    cached,
    unknownInput,
    ratio: input > 0 ? cached / input : null,
  };
}
