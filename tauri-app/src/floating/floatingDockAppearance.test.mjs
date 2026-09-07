import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { Window } from "happy-dom";

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
