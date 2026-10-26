import test from 'node:test';
import assert from 'node:assert/strict';
import {
  DEFAULT_SIDEBAR_LAYOUT,
  arrangedSidebarItems,
  isSidebarItemVisible,
  migrateSidebarLayout,
  moveSidebarItem,
  normalizeSidebarLayout,
} from './sidebarLayoutModel.ts';

test('default layout has the shared canonical order and hides client usage', () => {
  assert.deepEqual(DEFAULT_SIDEBAR_LAYOUT.order, [
    'modeltrace', 'speed', 'tps', 'quota:codex', 'quota:claudeCode',
    'models', 'tasks', 'radar', 'credits', 'clientUsage',
  ]);
  assert.deepEqual(DEFAULT_SIDEBAR_LAYOUT.hidden, ['clientUsage']);
  assert.deepEqual(normalizeSidebarLayout({ version: 2 }), {
    version: 1,
    order: [...DEFAULT_SIDEBAR_LAYOUT.order],
    hidden: ['clientUsage'],
  });
});

test('normalization deduplicates, rejects invalid IDs, appends defaults, and preserves hidden unavailable groups', () => {
  const layout = normalizeSidebarLayout({
    version: 1,
    order: ['quota:later', 'tasks', 'quota:later', 'quota:bad/name', 'bad', 'models'],
    hidden: ['quota:future', 'quota:future', 'quota:', 'models'],
  });
  assert.deepEqual(layout.order, [
    'quota:later', 'tasks', 'models', 'modeltrace', 'speed', 'tps',
    'quota:codex', 'quota:claudeCode', 'radar', 'credits', 'clientUsage',
  ]);
  assert.deepEqual(layout.hidden, ['quota:future', 'models']);
  assert.deepEqual(normalizeSidebarLayout({ version: 1, hidden: [] }).hidden, []);
});

test('legacy migration expands modules and derives quota group order from the first window occurrence', () => {
  const layout = migrateSidebarLayout(
    ['tasks', 'overview', 'speeds', 'modeltrace', 'credits', 'radar'],
    { overview: false, speeds: false, tasks: true },
    ['claudeCode:7d', 'codex:7d', 'deep_seek:5h', 'claudeCode:5h', 'invalid/:5h'],
  );
  assert.deepEqual(layout.order, [
    'tasks', 'quota:claudeCode', 'quota:codex', 'quota:deep_seek', 'models',
    'speed', 'tps', 'modeltrace', 'credits', 'radar', 'clientUsage',
  ]);
  assert.deepEqual(layout.hidden, [
    'clientUsage', 'quota:claudeCode', 'quota:codex', 'quota:deep_seek',
    'models', 'speed', 'tps',
  ]);
});

test('legacy migration accepts hidden-module names and restores missing quota clients in codex-then-claude order', () => {
  const layout = migrateSidebarLayout(['overview'], ['overview'], ['gemini:7d']);
  assert.deepEqual(layout.order.slice(0, 4), ['quota:gemini', 'quota:codex', 'quota:claudeCode', 'models']);
  assert.deepEqual(layout.hidden, ['clientUsage', 'quota:gemini', 'quota:codex', 'quota:claudeCode', 'models']);
});

test('arrangement adds newly available quota clients while retaining unavailable groups in saved order', () => {
  const config = normalizeSidebarLayout({
    version: 1,
    order: ['models', 'quota:offline', 'quota:codex', 'quota:claudeCode'],
    hidden: ['quota:offline'],
  });
  assert.deepEqual(arrangedSidebarItems(config, ['gemini', 'claudeCode', 'gemini', 'bad/client']), [
    'models', 'quota:offline', 'quota:codex', 'quota:claudeCode', 'quota:gemini',
    'modeltrace', 'speed', 'tps', 'tasks', 'radar', 'credits', 'clientUsage',
  ]);
  assert.deepEqual(config.order.slice(0, 4), ['models', 'quota:offline', 'quota:codex', 'quota:claudeCode']);
});

test('visibility and drag moves preserve hidden state and use before/after targets', () => {
  const config = normalizeSidebarLayout({ version: 1, hidden: ['tps', 'quota:unavailable'] });
  assert.equal(isSidebarItemVisible(config, 'speed'), true);
  assert.equal(isSidebarItemVisible(config, 'tps'), false);
  assert.equal(isSidebarItemVisible(config, 'quota:unavailable'), false);
  assert.equal(isSidebarItemVisible(config, 'clientUsage'), true);
  assert.equal(isSidebarItemVisible(normalizeSidebarLayout(null), 'clientUsage'), false);

  const moved = moveSidebarItem(config, 'speed', 'models', true);
  assert.deepEqual(moved.order.slice(0, 7), [
    'modeltrace', 'tps', 'quota:codex', 'quota:claudeCode', 'models', 'speed', 'tasks',
  ]);
  assert.deepEqual(moved.hidden, config.hidden);
  assert.deepEqual(moveSidebarItem(moved, 'speed', 'modeltrace', false).order.slice(0, 3), [
    'speed', 'modeltrace', 'tps',
  ]);
  assert.deepEqual(moveSidebarItem(config, 'missing', 'models', false), config);
});

test('a newly detected client can be moved before its first persisted placement',()=>{
 const config=normalizeSidebarLayout(null);
 const moved=moveSidebarItem(config,'quota:gemini','quota:codex',false);
 assert.equal(moved.order.indexOf('quota:gemini')+1,moved.order.indexOf('quota:codex'));
 assert.deepEqual(moved.hidden,config.hidden);
});
