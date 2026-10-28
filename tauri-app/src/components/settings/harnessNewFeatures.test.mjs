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

async function withInvitationApp(invoke, run) {
  const w = new Window();
  const keys = ['window', 'document', 'navigator', 'HTMLElement', 'Event', 'localStorage', 'IS_REACT_ACT_ENVIRONMENT'];
  const saved = keys.map(key => [key, Object.getOwnPropertyDescriptor(globalThis, key)]);
  for (const key of keys) {
    Object.defineProperty(globalThis, key, {
      configurable: true,
      writable: true,
      value: key === 'IS_REACT_ACT_ENVIRONMENT' ? true : key === 'localStorage' ? w.localStorage : w[key],
    });
  }
  Object.defineProperty(w.document, 'hidden', { configurable: true, value: false });
  w.__TAURI_INTERNALS__ = { invoke };
  w.HTMLMediaElement.prototype.play = () => Promise.resolve();
  w.HTMLMediaElement.prototype.pause = () => {};
  let root;
  try {
    await withSsrModules(async load => {
      const { AgentSpeedReportingInvitation } = await load('/src/components/settings/AgentSpeedReporting.tsx');
      root = createRoot(w.document.body);
      const render = () => root.render(React.createElement(AgentSpeedReportingInvitation, { onOpenSettings() {} }));
      await act(async () => render());
      await run({ w, root, render });
    });
  } finally {
    if (root) await act(async () => root.unmount());
    for (const [key, descriptor] of saved) {
      if (descriptor) Object.defineProperty(globalThis, key, descriptor);
      else delete globalThis[key];
    }
    w.close();
  }
}

function claudeUsageFixture() {
  return {
    detections: [{ client: 'claudeCode', evidence: 'fixture local Claude directory' }],
    preferences: [
      { client: 'claudeCode', enabled: false, showSidebar: false, showQuota: false, showMenuBar: false, color: '#D97757', order: 0, style: 'compact', path: '' },
      { client: 'claudeDesktop', enabled: false, showSidebar: false, showQuota: false, showMenuBar: false, color: '#D97757', order: 1, style: 'compact', path: '' },
      { client: 'deepseek', enabled: false, showSidebar: false, showQuota: false, showMenuBar: false, color: '#4D6BFE', order: 2, style: 'compact', path: '' },
      { client: 'gemini', enabled: false, showSidebar: false, showQuota: false, showMenuBar: false, color: '#4796E4', order: 3, style: 'compact', path: '' },
      { client: 'opencode', enabled: false, showSidebar: false, showQuota: false, showMenuBar: false, color: '#B7B1B1', order: 4, style: 'compact', path: '' },
    ],
    summaries: [],
    diagnostics: [],
    updatedAt: null,
  };
}

function disabledReportingStatus() {
  return {
    enabled: false,
    transport: 'http',
    invitationHandled: true,
    username: '',
    phase: 'off',
    message: '未开启',
    liveOutputTps: 0,
    estimatedShare: 0,
    lastReportAt: null,
    profileUrl: null,
    sources: [],
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

test('discovered Claude local enable saves usage preferences only, and dismissal persists', async () => {
  const calls = [];
  let usage = claudeUsageFixture();
  await withInvitationApp(async (command, args) => {
    calls.push({ command, args });
    if (command === 'refresh_multi_client_usage') return usage;
    if (command === 'read_agent_speed_reporting_status') return disabledReportingStatus();
    if (command === 'save_multi_client_usage_preferences') {
      usage = { ...usage, preferences: args.preferences };
      return args.preferences;
    }
    if (command === 'dismiss_agent_speed_invitation') return null;
    throw new Error(`Unexpected mocked command: ${command}`);
  }, async ({ w, root, render }) => {
    let localButton = [...w.document.querySelectorAll('button')].find(button => button.textContent === '启用本地统计');
    assert.ok(localButton, 'detected Claude should produce the local-only prompt');
    assert.ok([...w.document.querySelectorAll('h3')].some(heading => /参加速蹬排行榜/.test(heading.textContent)));
    assert.ok(calls.some(call => call.command === 'read_agent_speed_reporting_status'));

    await act(async () => localButton.click());
    localButton = [...w.document.querySelectorAll('button')].find(button => button.textContent === '已启用');
    assert.ok(localButton?.disabled);
    const saveIndex = calls.findIndex(call => call.command === 'save_multi_client_usage_preferences');
    const refreshAfterSaveIndex = calls.findIndex((call, index) => index > saveIndex && call.command === 'refresh_multi_client_usage');
    assert.ok(saveIndex >= 0, 'local enable must save multi-client preferences');
    assert.ok(refreshAfterSaveIndex > saveIndex, 'local enable must refresh the local usage snapshot after saving');
    const savedClaude = calls[saveIndex].args.preferences.find(preference => preference.client === 'claudeCode');
    assert.equal(savedClaude.enabled, true);
    assert.equal(savedClaude.showSidebar, true);
    assert.equal(savedClaude.showQuota, true);
    assert.equal(calls.some(call => call.command === 'set_agent_speed_reporting_enabled'), false);

    await act(async () => w.document.querySelector('button[aria-label="稍后了解新特性"]').click());
    assert.equal(w.localStorage.getItem('product.newFeatures.localClientsSpeed.v1'), 'true');
    assert.match(w.localStorage.getItem('multiClient.discoveryAcknowledged.v1'), /claudeCode/);
    assert.ok(calls.some(call => call.command === 'dismiss_agent_speed_invitation'));
    const readsBeforeRemount = calls.filter(call => call.command === 'read_agent_speed_reporting_status').length;

    await act(async () => root.render(null));
    await act(async () => render());
    assert.equal(w.document.querySelector('[role="dialog"]'), null, 'handled and acknowledged discovery must stay dismissed after remount');
    assert.equal(calls.filter(call => call.command === 'read_agent_speed_reporting_status').length, readsBeforeRemount);
    assert.equal(calls.some(call => call.command === 'set_agent_speed_reporting_enabled'), false);
  });
});

test('a reporting-status read failure still offers detected Claude local statistics', async () => {
  const calls = [];
  const usage = claudeUsageFixture();
  await withInvitationApp(async (command) => {
    calls.push(command);
    if (command === 'refresh_multi_client_usage') return usage;
    if (command === 'read_agent_speed_reporting_status') throw new Error('fixture status unavailable');
    throw new Error(`Unexpected mocked command: ${command}`);
  }, async ({ w }) => {
    assert.ok(calls.includes('read_agent_speed_reporting_status'));
    assert.ok([...w.document.querySelectorAll('button')].some(button => button.textContent === '启用本地统计'));
    assert.equal(w.document.querySelector('video'), null, 'failed status read should not block or fabricate the leaderboard offer');
    assert.equal([...w.document.querySelectorAll('button')].some(button => button.textContent === '了解并参加'), false);
    assert.equal(calls.includes('set_agent_speed_reporting_enabled'), false);
  });
});
