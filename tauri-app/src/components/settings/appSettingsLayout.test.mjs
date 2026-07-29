import assert from "node:assert/strict";
import test from "node:test";
import { readFile } from "node:fs/promises";

const styles = await readFile(new URL("../../styles/global.css", import.meta.url), "utf8");

test("auto resume content cannot widen the settings viewport after options load", () => {
  assert.match(styles, /\.app-settings-page\s*{[^}]*min-width: 0;/);
  assert.match(styles, /\.app-settings-group\s*{[^}]*min-width: 0;/);
  assert.match(
    styles,
    /\.auto-resume-project-picker > select\s*{[^}]*min-width: 0;[^}]*width: 100%;[^}]*max-width: 100%;/,
  );
  assert.match(styles, /\.auto-resume-thread-list\s*{[^}]*min-width: 0;/);
});
