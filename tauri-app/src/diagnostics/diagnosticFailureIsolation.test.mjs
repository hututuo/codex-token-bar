import test from 'node:test';
import assert from 'node:assert/strict';
import { createDiagnosticJournal } from './diagnosticJournal.ts';
import { clearCommandFailure, getCommandDiagnosticsSnapshot, recordCommandFailure,
  subscribeCommandDiagnostics } from './localDiagnostics.ts';

test('a failed journal observer cannot stop recording or other observers', () => {
  const journal = createDiagnosticJournal();
  journal.subscribe(() => { throw new Error('synthetic observer failure'); });
  let notifications = 0;
  journal.subscribe(() => { notifications++; });
  assert.doesNotThrow(() => journal.update('audit', 'read failed', 'synthetic diagnostic'));
  assert.equal(journal.getSnapshot().current[0].detail, 'synthetic diagnostic');
  assert.equal(notifications, 1);
  assert.doesNotThrow(() => journal.update('audit', '', ''));
  assert.equal(journal.getSnapshot().history[0].outcome, 'recovered');
  assert.equal(notifications, 2);
});

test('command diagnostic initial replay isolates a failing subscriber', t => {
  let enabled = true;
  let stop;
  t.after(() => { enabled = false; stop?.(); });
  assert.doesNotThrow(() => {
    stop = subscribeCommandDiagnostics(() => {
      if (enabled) throw new Error('synthetic initial replay failure');
    });
  });
  assert.equal(typeof stop, 'function');
});

test('command recording and recovery survive a failing observer and console sink', t => {
  const key = 'audit_diagnostic_sink_isolation';
  let initial = true;
  const stops = [];
  const oldWarn = console.warn;
  t.after(() => { for (const stop of stops) stop(); console.warn = oldWarn; clearCommandFailure(key); });
  stops.push(subscribeCommandDiagnostics(() => {
    if (initial) { initial = false; return; }
    throw new Error('synthetic update observer failure');
  }));
  let seen = [];
  stops.push(subscribeCommandDiagnostics(snapshot => { seen = snapshot; }));
  console.warn = () => { throw new Error('synthetic console sink failure'); };
  assert.doesNotThrow(() => recordCommandFailure(key, new Error('synthetic business failure')));
  assert.equal(getCommandDiagnosticsSnapshot().find(item => item.command === key)?.message,
    'synthetic business failure');
  assert.ok(seen.some(item => item.command === key));
  assert.doesNotThrow(() => clearCommandFailure(key));
  assert.ok(!seen.some(item => item.command === key));
});
