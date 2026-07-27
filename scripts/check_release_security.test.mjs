import assert from "node:assert/strict";
import { execFile } from "node:child_process";
import { chmod, mkdtemp, rm, writeFile } from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import test from "node:test";
import { fileURLToPath } from "node:url";
import { promisify } from "node:util";

const execFileAsync = promisify(execFile);
const script = path.join(
  path.dirname(fileURLToPath(import.meta.url)),
  "check_release_security.sh",
);

async function makeExecutable(file, body) {
  await writeFile(file, `#!/usr/bin/env bash\n${body}\n`);
  await chmod(file, 0o755);
}

test("blocking FAIL status exits nonzero", async () => {
  const root = await mkdtemp(path.join(os.tmpdir(), "release-security-test-"));
  try {
    const bin = path.join(root, "bin");
    await import("node:fs/promises").then(({ mkdir }) => mkdir(bin));
    await makeExecutable(path.join(bin, "security"), "exit 1");
    await assert.rejects(
      execFileAsync("bash", [script], {
        env: {
          ...process.env,
          APP_DIR: path.join(root, "missing.app"),
          CODE_SIGN_IDENTITY: "Developer ID Application: Missing",
          PATH: `${bin}:${process.env.PATH}`,
        },
      }),
      (error) => {
        assert.equal(error.code, 1);
        assert.match(error.stdout, /\[FAIL\].*signing identity is missing or untrusted/);
        assert.match(error.stderr, /failed with 1 blocking finding/);
        return true;
      },
    );
  } finally {
    await rm(root, { recursive: true, force: true });
  }
});

test("warning-only ad-hoc preflight remains successful", async () => {
  const root = await mkdtemp(path.join(os.tmpdir(), "release-security-test-"));
  try {
    const run = await execFileAsync("bash", [script], {
      env: {
        ...process.env,
        APP_DIR: path.join(root, "missing.app"),
        CODE_SIGN_IDENTITY: "-",
      },
    });
    assert.match(run.stdout, /\[WARN\].*ad-hoc/);
    assert.doesNotMatch(run.stderr, /failed with/);
  } finally {
    await rm(root, { recursive: true, force: true });
  }
});

test("missing requested DMG is a blocking failure", async () => {
  const root = await mkdtemp(path.join(os.tmpdir(), "release-security-test-"));
  try {
    await assert.rejects(
      execFileAsync("bash", [script, path.join(root, "missing.dmg")], {
        env: {
          ...process.env,
          APP_DIR: path.join(root, "missing.app"),
          CODE_SIGN_IDENTITY: "-",
        },
      }),
      (error) => {
        assert.equal(error.code, 1);
        assert.match(error.stdout, /\[FAIL\].*DMG file does not exist/);
        return true;
      },
    );
  } finally {
    await rm(root, { recursive: true, force: true });
  }
});
