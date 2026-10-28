import assert from "node:assert/strict";
import test from "node:test";
import { Window } from "happy-dom";
import { withSsrModules } from "../test/ssrHarness.mjs";

test("whole rings squeeze monotonically and both sides merge into one full bar", async () => {
  await withSsrModules(async load => {
    const { squeezePoints, sidebarStrokes } = await load("/src/quota-sidebar/sidebarStrokeGeometry.ts");
    const source = { x: 21, y: 110, width: 46, height: 46 }, target = { x: 6, y: 250, width: 4, height: 24 };
    for (let step = 0; step <= 100; step++) {
      const p = step / 100, left = squeezePoints(source, target, -2, p), right = squeezePoints(source, target, 2, p);
      for (let i = 0; i < left.length; i++) {
        assert.ok(left[i].x <= right[i].x + .001);
        assert.ok(Math.abs(left[i].y - right[i].y) < .001, "opposite sides never turn over");
        if (i) assert.ok(left[i - 1].y + .001 >= left[i].y && right[i - 1].y + .001 >= right[i].y);
      }
    }
    for (const fraction of [0, .1, .49, .5, .51, .85, 1]) {
      const strokes = sidebarStrokes({ id: "codex:7d", fraction, color: "#abcdef" }, source, target);
      const tracks = strokes.filter(s => s.id.endsWith(":track"));
      assert.equal(tracks.length, 2); assert.deepEqual(tracks[0].target, tracks[1].target);
      assert.equal(tracks[0].target[0].y, 272); assert.equal(tracks[0].target.at(-1).y, 252);
      const fill = strokes.filter(s => s.id.endsWith(":fill"));
      assert.equal(fill.length, fraction ? 2 : 0);
      if (fraction) {
        assert.deepEqual(fill[0].target, fill[1].target);
        const length = Math.abs(fill[0].target.at(-1).y - fill[0].target[0].y);
        assert.ok(Math.abs(length - Math.max(0, fraction * 24 - 4)) < .001);
        assert.equal(fill[0].group, fill[1].group, "meeting sides composite opacity only once");
      }
    }
  });
});

test("model usage keeps ordered colors and shares when horizontal becomes vertical", async () => {
  await withSsrModules(async load => {
    const { sidebarStrokes } = await load("/src/quota-sidebar/sidebarStrokeGeometry.ts");
    const strokes = sidebarStrokes({ id: "models", shape: "strip", fraction: 1, color: "#888", segments: [
      { id: "a", start: 0, end: .25, color: "#a3d977" }, { id: "b", start: .25, end: 1, color: "#df7055" },
    ] }, { x: 18, y: 100, width: 52, height: 4 }, { x: 6, y: 250, width: 4, height: 24 });
    assert.equal(strokes.length, 3);
    for (const s of strokes) { assert.ok(s.source.every(p => p.y === 102)); assert.ok(s.target.every(p => p.x === 8)); }
    assert.equal(strokes[1].color, "#a3d977"); assert.equal(strokes[2].color, "#df7055");
    assert.equal(strokes[1].target.at(-1).y - strokes[1].target[0].y, 5);
    assert.equal(strokes[1].target.at(-1).y, strokes[2].target[0].y);
  });
});

test("matched SVG animation restores participants and carries a reversal snapshot", async () => {
  const w = new Window();
  try {
    await withSsrModules(async load => {
      const { animateSidebarStrokes } = await load("/src/quota-sidebar/sidebarStrokeMorph.ts");
      Object.defineProperty(w, "CSS", { configurable: true, value: { supports: () => true } });
      const root = w.document.createElement("div"); w.document.body.append(root);
      root.innerHTML = '<svg data-sidebar-stroke-source></svg><span data-sidebar-stroke-target="codex:7d"></span>';
      const source = root.children[0], target = root.children[1];
      source.dataset.strokeSpec = JSON.stringify([{ id: "codex:7d", fraction: .85, color: "#abc" }]);
      root.getBoundingClientRect = () => ({ x: 0, y: 0 });
      source.getBoundingClientRect = () => ({ x: 21, y: 110, width: 46, height: 46 });
      target.getBoundingClientRect = () => ({ x: 6, y: 250, width: 4, height: 24 });
      const pending = [], frames = [];
      w.SVGElement.prototype.animate = function(keyframes, options) {
        frames.push([keyframes, options]);
        return { finished: new Promise(resolve => pending.push(resolve)), cancel() {} };
      };
      const cancel = animateSidebarStrokes(root, false);
      assert.equal(source.style.visibility, "hidden"); assert.equal(target.style.visibility, "hidden");
      assert.equal(root.querySelectorAll(".qs-stroke-morph path").length, 4);
      assert.equal(root.querySelectorAll(".qs-stroke-morph g").length, 2);
      assert.ok(frames.every(([, options]) => options.duration === 440));
      const positions = cancel();
      assert.equal(positions.size, 4); assert.equal(source.style.visibility, "");
      assert.equal(root.querySelector(".qs-stroke-morph"), null);
      const done = animateSidebarStrokes(root, true, positions);
      assert.equal(root.querySelectorAll(".qs-stroke-morph").length, 1, "reversal replaces the overlay");
      pending.forEach(resolve => resolve());
      for (let i = 0; i < 5; i++) await Promise.resolve();
      assert.equal(source.style.visibility, ""); assert.equal(target.style.visibility, "");
      assert.equal(root.querySelector(".qs-stroke-morph"), null); assert.equal(done().size, 0);
    });
  } finally { w.close(); }
});

test("unsupported or failed WebView animation never hides the original strokes", async () => {
  const w = new Window();
  try {
    await withSsrModules(async load => {
      const { animateSidebarStrokes } = await load("/src/quota-sidebar/sidebarStrokeMorph.ts");
      const root = w.document.createElement("div"); w.document.body.append(root);
      root.innerHTML = '<svg data-sidebar-stroke-source></svg><span data-sidebar-stroke-target="models"></span>';
      const source = root.children[0], target = root.children[1];
      source.dataset.strokeSpec = JSON.stringify([{ id: "models", shape: "strip", fraction: 1, color: "#888" }]);
      root.getBoundingClientRect = () => ({ x: 0, y: 0 });
      source.getBoundingClientRect = () => ({ x: 18, y: 100, width: 52, height: 4 });
      target.getBoundingClientRect = () => ({ x: 6, y: 250, width: 4, height: 24 });
      Object.defineProperty(w, "CSS", { configurable: true, value: { supports: () => false } });
      assert.equal(animateSidebarStrokes(root, false)().size, 0);
      assert.equal(source.style.visibility, ""); assert.equal(target.style.visibility, "");
      Object.defineProperty(w, "CSS", { configurable: true, value: { supports: () => true } });
      w.SVGElement.prototype.animate = () => { throw new Error("unsupported compositor"); };
      assert.equal(animateSidebarStrokes(root, false)().size, 0);
      assert.equal(source.style.visibility, ""); assert.equal(target.style.visibility, "");
      assert.equal(root.querySelector(".qs-stroke-morph"), null);
    });
  } finally { w.close(); }
});
