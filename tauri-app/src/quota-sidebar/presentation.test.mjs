import assert from 'node:assert/strict';
import test from 'node:test';
import { createSidebarPublisher, sidebarVisualPercent } from './presentation.ts';
import { createSidebarNativeCoordinator } from './nativeCoordinator.ts';
const tick = () => new Promise(resolve => setTimeout(resolve, 0));
test('hidden updates send nothing; opening and ready receive the latest snapshot; unchanged visible data is deduplicated', () => {
  const sent = []; const publisher = createSidebarPublisher(value => sent.push(value));
  for (let i = 0; i < 100; i++) publisher.update({ value: i }, false);
  publisher.ready(); assert.equal(sent.length, 0);
  const latest = { value: 101 }; publisher.update(latest, true);
  publisher.update(latest, true); assert.deepEqual(sent, [latest]);
  publisher.ready(); assert.deepEqual(sent, [latest, latest]);
  publisher.update(latest, false); publisher.ready(); assert.equal(sent.length, 2);
  publisher.update(latest, true); assert.equal(sent.length, 3);
});
test('unchanged render intents issue one native call; explicit environment refresh issues one more', async () => {
  const calls = []; const queue = createSidebarNativeCoordinator(async (...args) => calls.push(args), () => {});
  queue.setEnabled(true); await tick();
  for (let i = 0; i < 100; i++) queue.update('rest', false);
  await tick(); assert.deepEqual(calls, [['rest', false, false]]);
  queue.refresh(); await tick(); assert.deepEqual(calls[1], ['rest', false, true]);
  queue.setEnabled(false); queue.refresh(); await tick(); assert.equal(calls.length, 2);
});
test('sub-display noise has a stable visual target and unknown does not become zero', () => {
  assert.equal(sidebarVisualPercent(19.01), sidebarVisualPercent(19.04));
  assert.equal(sidebarVisualPercent(NaN), null); assert.equal(sidebarVisualPercent(null), null);
  assert.equal(sidebarVisualPercent(0), 0); assert.equal(sidebarVisualPercent(101), 100);
});
