import test from 'node:test';
import assert from 'node:assert/strict';
import { modelAwareAPICostUSD } from './quotaPriceModel.ts';
const breakdown = { inputTokens: 1_000_000, cachedInputTokens: 0, outputTokens: 0, calls: 1 };
test('mixed models preserve original amount and normalize before summation', () => {
  const rows = ['gpt-5.6-sol', 'gpt-6-astra', 'gpt-5.6-luna', 'gpt-5.6-terra'].map(model => ({ model, breakdown }));
  const result = modelAwareAPICostUSD(rows, { ...breakdown, inputTokens: 4_000_000, calls: 4 }, 'gpt56Sol');
  assert.ok(Math.abs(result.costUSD - 16.2) < 1e-9);
  assert.ok(Math.abs(result.normalizedCostUSD - 21.4) < 1e-9);
});
test('dated auto-review routing, fallback and unknown pricing remain intact', () => {
  for (const [date, original, normalized] of [['2026-07-29', 2.5, 2.5], ['2026-08-01', 0.2, 0.4]]) {
    const result = modelAwareAPICostUSD([{ model: 'codex-auto-review', eventStartUnix: Date.parse(date) / 1000, breakdown }], breakdown, 'gpt56Sol');
    assert.equal(result.costUSD, original);
    assert.equal(result.normalizedCostUSD, normalized);
  }
  assert.equal(modelAwareAPICostUSD([], breakdown, 'gpt6Astra').normalizedCostUSD, 15);
  const unknown = modelAwareAPICostUSD([{model:'future-model', breakdown}], breakdown, 'gpt6Astra');
  assert.equal(unknown.costUSD, 0);
  assert.equal(unknown.normalizedCostUSD, 0);
  assert.deepEqual(unknown.unpricedModels, ['future-model']);
});
