import test from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { Window } from 'happy-dom';
import { sidebarCanvasClasses } from './canvas.ts';

test('only native rails use a fixed canvas; detail cards keep their own viewport', () => {
  assert.deepEqual(sidebarCanvasClasses('quota-sidebar', 'Win32'), ['quota-sidebar-fixed-canvas', 'quota-sidebar-windows-canvas']);
  assert.deepEqual(sidebarCanvasClasses('quota-sidebar', 'MacIntel'), ['quota-sidebar-fixed-canvas']);
  assert.deepEqual(sidebarCanvasClasses('quota-sidebar', 'Linux x86_64'), []);
  for (const surface of ['main', 'floating', 'quota-sidebar-detail']) {
    for (const platform of ['Win32', 'MacIntel']) assert.deepEqual(sidebarCanvasClasses(surface, platform), []);
  }
});

test('Windows black rail and summary retain layout through narrow, intermediate and expanded clips', async () => {
  const css = await readFile(new URL('./QuotaSidebar.css', import.meta.url), 'utf8');
  const window = new Window();
  try {
    window.document.documentElement.classList.add('quota-sidebar-document', ...sidebarCanvasClasses('quota-sidebar', 'Win32'));
    window.document.body.innerHTML = `<style>${css}</style><div id="root"><main class="qs-rail qs-right"><div class="qs-bars"></div><div class="qs-summary"></div></main></div>`;
    for (const side of ['left', 'right']) {
      const rail = window.document.querySelector('main');
      rail.className = `qs-rail qs-${side}`;
      for (const [width, height] of [[16, 192], [40, 300], [88, 470], [88, 560], [16, 250]]) {
        window.happyDOM.setWindowSize({ width, height });
        window.document.documentElement.style.setProperty('--qs-native-width', `${width}px`);
        window.document.documentElement.style.setProperty('--qs-native-height', `${height}px`);
        const style = window.getComputedStyle(rail);
        assert.equal(style.width, '88px');
        assert.equal(style.height, '560px');
        assert.equal(style.backgroundColor, '#080a09');
        const summary = window.getComputedStyle(window.document.querySelector('.qs-summary'));
        assert.equal(summary.top, '280px');
        assert.equal(summary.width, '88px');
        assert.equal(summary.transform, 'translateY(-50%)');
      }
    }
  } finally { window.close(); }
});
