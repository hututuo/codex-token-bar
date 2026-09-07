import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { Window } from "happy-dom";

for (const edge of ["left", "right"]) {
  for (const side of ["below", "above"]) {
    test(`${edge}/${side}: content uses one scale and only horizontal travel`, () => {
      const window = new Window();
      const doc = window.document;
      const style = doc.createElement("style");
      style.textContent = readFileSync(new URL("../styles/global.css", import.meta.url), "utf8");
      doc.head.append(style);
      const inset = "2.4px";
      const travel = edge === "left" ? "-258px" : "258px";
      doc.body.innerHTML = `<div class="floating-edge-host" data-edge="${edge}" data-collapsed="false" style="--dock-content-scale:.96;--dock-content-offset-y:${inset};--dock-content-origin:center top;--dock-travel-x:${travel};--dock-travel-y:0px"><div class="floating-edge-content"></div></div>`;
      const host = doc.querySelector(".floating-edge-host");
      const content = doc.querySelector(".floating-edge-content");
      const expanded = window.getComputedStyle(content).transform;
      host.dataset.collapsed = "true";
      const collapsed = window.getComputedStyle(content).transform;
      assert.equal(expanded, `translate(0px, calc(${inset} + 0px)) scale(.96)`);
      assert.equal(collapsed, `translate(${travel}, calc(${inset} + 0px)) scale(.96)`);
      window.happyDOM.abort();
    });
  }
}

for (const edge of ["left", "right", "top", "bottom"]) {
  test(`${edge}: black rail stays opaque while only quota contents crossfade`, () => {
    const window = new Window();
    const doc = window.document;
    const style = doc.createElement("style");
    style.textContent = readFileSync(new URL("../styles/global.css", import.meta.url), "utf8");
    doc.head.append(style);
    doc.body.innerHTML = `<div class="floating-edge-host" data-edge="${edge}">
      <div class="floating-edge-base"></div><div class="floating-edge-shell"></div>
      <button class="floating-edge-reveal"><div class="floating-edge-quota"></div></button></div>`;
    const host = doc.querySelector(".floating-edge-host");
    const button = doc.querySelector("button");
    for (const [collapsed, ready, compact] of [[true, false, false], [true, false, true], [true, true, true], [false, false, false]]) {
      Object.assign(host.dataset, { collapsed: String(collapsed), railReady: String(ready), compact: String(compact) });
      button.setAttribute("aria-hidden", String(!collapsed));
      button.disabled = !collapsed;
      const css = name => window.getComputedStyle(doc.querySelector(name));
      assert.equal(css(".floating-edge-base").opacity, "1");
      assert.match(css(".floating-edge-base").backgroundColor, /^(#000|rgb\(0, 0, 0\))$/);
      assert.equal(css(".floating-edge-shell").opacity, "1");
      assert.equal(css(".floating-edge-reveal").opacity, "1");
      assert.equal(css(".floating-edge-quota").opacity, collapsed && ready ? "1" : "0");
      if (!collapsed) assert.match(css(".floating-edge-quota").transition, /opacity 80ms ease-out 40ms/);
    }
    window.happyDOM.abort();
  });
}

for (const side of ["below", "above"]) {
  test(`${side}: closing details preserves the main card alignment until native resize`, () => {
    const window = new Window();
    const doc = window.document;
    const style = doc.createElement("style");
    style.textContent = readFileSync(new URL("../styles/global.css", import.meta.url), "utf8");
    doc.head.append(style);
    doc.body.innerHTML = `<div class="floating-edge-host" data-collapsed="false" style="--dock-height: 400px"><div class="floating-edge-content"><main class="floating-window-shell floating-window-shell--running-model-details${side === "above" ? " floating-window-shell--running-model-details-above" : ""}"></main></div></div>`;
    const shell = doc.querySelector("main");
    const alignment = () => window.getComputedStyle(shell).placeItems;
    const opened = alignment();
    shell.classList.remove("floating-window-shell--running-model-details");
    assert.equal(alignment(), opened);
    assert.equal(alignment(), side === "above" ? "end center" : "start center");
    // Happy DOM cannot evaluate calc division. Check the viewport rule here;
    // actual above/below dimensions are verified with the offscreen WebKit probe.
    assert.match(style.textContent, /\.floating-edge-host\[data-collapsed="false"\] > \.floating-edge-content\s*\{\s*height: calc\(var\(--dock-base-height, 100vh\) \+ \(100vh - var\(--dock-base-height, 100vh\)\) \/ var\(--dock-content-scale, 1\)\);/);
    window.happyDOM.abort();
  });
}
