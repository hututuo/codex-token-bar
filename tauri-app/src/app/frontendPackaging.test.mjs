import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";

test("packaged frontend keeps CSS as stylesheet assets instead of JS-injected styles", async () => {
  const config = await readFile(new URL("../../vite.config.ts", import.meta.url), "utf8");

  assert.equal(
    config.includes('format: "iife"'),
    false,
    "IIFE output inlines global.css into JavaScript, which can leave packaged Tauri surfaces unstyled",
  );
  assert.equal(
    config.includes('type="module"'),
    false,
    "packaged HTML should keep Vite module scripts so CSS stays linked as a stylesheet asset",
  );
});
