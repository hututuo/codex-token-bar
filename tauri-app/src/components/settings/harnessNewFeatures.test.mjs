import assert from 'node:assert/strict';
import test from 'node:test';
import React from 'react';
import { act } from 'react';
import { createRoot } from 'react-dom/client';
import { Window } from 'happy-dom';
import { withSsrModules } from '../../test/ssrHarness.mjs';

async function withNotice(render) {
  const w = new Window();
  const keys = ['window', 'document', 'navigator', 'HTMLElement', 'IS_REACT_ACT_ENVIRONMENT'];
  const saved = keys.map(key => [key, Object.getOwnPropertyDescriptor(globalThis, key)]);
  for (const key of keys) {
    Object.defineProperty(globalThis, key, {
      configurable: true,
      writable: true,
      value: key === 'IS_REACT_ACT_ENVIRONMENT' ? true : w[key],
    });
  }
  w.HTMLMediaElement.prototype.play = () => Promise.resolve();
  w.HTMLMediaElement.prototype.pause = () => {};
  const root = createRoot(w.document.body);
  try {
    await withSsrModules(async load => {
      const { HarnessNewFeatures } = await load('/src/components/settings/HarnessNewFeatures.tsx');
      await act(async () => render({ w, root, HarnessNewFeatures }));
    });
  } catch (error) {
    await act(async () => root.unmount());
    for (const [key, descriptor] of saved) {
      if (descriptor) Object.defineProperty(globalThis, key, descriptor);
      else delete globalThis[key];
    }
    w.close();
    throw error;
  }
  return async () => {
    await act(async () => root.unmount());
    for (const [key, descriptor] of saved) {
      if (descriptor) Object.defineProperty(globalThis, key, descriptor);
      else delete globalThis[key];
    }
    w.close();
  };
}

test('new features keeps leaderboard and local statistics as separate choices', async () => {
  let localEnables = 0;
  let joins = 0;
  let cleanup;
  try {
    await withNotice(async ({ root, HarnessNewFeatures }) => {
      root.render(React.createElement(HarnessNewFeatures, {
        offerLeaderboard: true,
        localClient: 'Claude',
        onEnableLocal: () => { localEnables += 1; },
        onJoin: () => { joins += 1; },
        onDismiss() {},
      }));
    }).then(fn => { cleanup = fn; });

    const dialog = document.querySelector('[role="dialog"]');
    assert.ok(dialog);
    const features = [...dialog.querySelectorAll('.harness-feature')];
    assert.equal(features.length, 2);
    assert.match(features[0].querySelector('h3').textContent, /排行榜/);
    assert.match(features[1].querySelector('h3').textContent, /Claude/);
    assert.match(features[1].textContent, /本地/);
    assert.match(features[1].textContent, /不产生任何网络请求/);
    assert.match(features[1].textContent, /不会自动参加排行榜/);

    const localButton = [...dialog.querySelectorAll('button')].find(button => button.textContent === '启用本地统计');
    const leaderboardButton = [...dialog.querySelectorAll('button')].find(button => button.textContent === '了解并参加');
    assert.ok(localButton);
    assert.ok(leaderboardButton);
    await act(async () => localButton.click());
    assert.equal(localEnables, 1);
    assert.equal(joins, 0, 'enabling local statistics must not start leaderboard participation');
    await act(async () => leaderboardButton.click());
    assert.equal(joins, 1);
    assert.equal(localEnables, 1);
  } finally {
    await cleanup?.();
  }
});

test('local-enabled state disables only the local statistics action', async () => {
  let localEnables = 0;
  let joins = 0;
  let cleanup;
  try {
    await withNotice(async ({ root, HarnessNewFeatures }) => {
      root.render(React.createElement(HarnessNewFeatures, {
        offerLeaderboard: true,
        localClient: 'Claude',
        localEnabled: true,
        onEnableLocal: () => { localEnables += 1; },
        onJoin: () => { joins += 1; },
        onDismiss() {},
      }));
    }).then(fn => { cleanup = fn; });

    const buttons = [...document.querySelectorAll('.harness-new-features button')];
    const localButton = buttons.find(button => button.textContent === '已启用');
    const leaderboardButton = buttons.find(button => button.textContent === '了解并参加');
    assert.ok(localButton?.disabled);
    assert.ok(leaderboardButton);
    assert.equal(leaderboardButton.disabled, false);
    await act(async () => localButton.click());
    await act(async () => leaderboardButton.click());
    assert.equal(localEnables, 0);
    assert.equal(joins, 1);
  } finally {
    await cleanup?.();
  }
});

test('leaderboard can be omitted while local statistics remain available', async () => {
  let cleanup;
  try {
    await withNotice(async ({ root, HarnessNewFeatures }) => {
      root.render(React.createElement(HarnessNewFeatures, {
        offerLeaderboard: false,
        localClient: 'Codex',
        onEnableLocal() {},
        onJoin() {},
        onDismiss() {},
      }));
    }).then(fn => { cleanup = fn; });

    assert.equal(document.querySelectorAll('.harness-feature').length, 1);
    assert.match(document.querySelector('.harness-feature h3').textContent, /Codex/);
    assert.equal(document.querySelector('video'), null);
    assert.equal([...document.querySelectorAll('button')].some(button => button.textContent === '了解并参加'), false);
    assert.ok([...document.querySelectorAll('button')].some(button => button.textContent === '启用本地统计'));
  } finally {
    await cleanup?.();
  }
});

test('both close controls dismiss the new-features notice', async () => {
  let dismissals = 0;
  let cleanup;
  try {
    await withNotice(async ({ root, HarnessNewFeatures }) => {
      root.render(React.createElement(HarnessNewFeatures, {
        offerLeaderboard: false,
        localClient: null,
        onEnableLocal() {},
        onJoin() {},
        onDismiss: () => { dismissals += 1; },
      }));
    }).then(fn => { cleanup = fn; });

    await act(async () => document.querySelector('button[aria-label="稍后了解新特性"]').click());
    await act(async () => [...document.querySelectorAll('button')].find(button => button.textContent === '知道了').click());
    assert.equal(dismissals, 2);
  } finally {
    await cleanup?.();
  }
});
