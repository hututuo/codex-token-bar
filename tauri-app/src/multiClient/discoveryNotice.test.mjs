import assert from 'node:assert/strict';
import test from 'node:test';
import React, {act} from 'react';
import {createRoot} from 'react-dom/client';
import {Window} from 'happy-dom';
import {withSsrModules} from '../test/ssrHarness.mjs';

test('all pending discoveries are visible and each action affects only its client', async () => {
  const window = new Window({url: 'http://localhost/'});
  const keys = ['window', 'document', 'localStorage', 'Event', 'IS_REACT_ACT_ENVIRONMENT'];
  const original = keys.map(key => [key, Object.getOwnPropertyDescriptor(globalThis, key)]);
  for (const key of keys) Object.defineProperty(globalThis, key, {
    configurable: true, writable: true, value: key === 'IS_REACT_ACT_ENVIRONMENT' ? true : key === 'window' ? window : window[key],
  });
  let root;
  try {
    await withSsrModules(async load => {
      const {defaultClientPreferences, MultiClientDiscoveryNotice} = await load('/src/multiClient/MultiClientUsage.tsx');
      let preferences = defaultClientPreferences.map(p => ({...p, enabled: p.client === 'claudeDesktop'}));
      const saves = [];
      window.localStorage.setItem('multiClient.discoveryAcknowledged.v1', JSON.stringify(['opencode']));
      window.__TAURI_INTERNALS__ = {invoke: async (command, args) => {
        if (command === 'save_multi_client_usage_preferences') {
          preferences = args.preferences;
          saves.push(preferences);
          return preferences;
        }
        assert.equal(command, 'refresh_multi_client_usage');
        return {preferences, summaries: [], diagnostics: [], updatedAt: null,
          detections: defaultClientPreferences.map(p => ({client: p.client, evidence: 'local fixture'}))};
      }};
      root = createRoot(window.document.body);
      await act(async () => root.render(React.createElement(MultiClientDiscoveryNotice)));
      const rows = () => [...window.document.querySelectorAll('.multi-client-discovery')];
      assert.deepEqual(rows().map(row => row.querySelector('strong').textContent),
        ['发现 DeepSeek / DSH', '发现 Gemini CLI', '发现 Antigravity']);
      assert.equal(saves.length, 0, 'rendering never enables collection');

      await act(async () => rows()[1].querySelectorAll('button')[1].click());
      assert.deepEqual(rows().map(row => row.querySelector('strong').textContent),
        ['发现 DeepSeek / DSH', '发现 Antigravity']);
      assert.equal(saves.length, 0, 'dismissal is not opt-in');

      await act(async () => rows()[1].querySelector('button').click());
      assert.deepEqual(rows().map(row => row.querySelector('strong').textContent), ['发现 DeepSeek / DSH']);
      assert.equal(saves.length, 1);
      assert.deepEqual(preferences.filter(p => p.enabled).map(p => p.client), ['claudeDesktop', 'antigravity']);
      assert.equal(preferences.find(p => p.client === 'deepseek').enabled, false);
      assert.deepEqual(JSON.parse(window.localStorage.getItem('multiClient.discoveryAcknowledged.v1')).sort(),
        ['antigravity', 'gemini', 'opencode']);
    });
  } finally {
    if (root) await act(async () => root.unmount());
    for (const [key, descriptor] of original) {
      if (descriptor) Object.defineProperty(globalThis, key, descriptor);
      else delete globalThis[key];
    }
    await window.happyDOM.abort();
  }
});
