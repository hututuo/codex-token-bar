import assert from "node:assert/strict";
import { execFile } from "node:child_process";
import { mkdtemp, readFile, rm, unlink, writeFile } from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import test from "node:test";
import { fileURLToPath } from "node:url";
import { promisify } from "node:util";

const execFileAsync = promisify(execFile);
const scriptsDir = path.dirname(fileURLToPath(import.meta.url));
const signatureScript = path.join(scriptsDir, "read_appcast_signature.py");
const publishScript = path.join(scriptsDir, "publish_appcast.py");

function item(version, signature) {
  return [
    "<item>",
    `<sparkle:shortVersionString>${version}</sparkle:shortVersionString>`,
    `<enclosure length='1' sparkle:edSignature='${signature}' url='https://example.invalid/${version}.zip'/>`,
    "</item>",
  ].join("");
}

function appcast(items) {
  return [
    "<?xml version='1.0'?>",
    "<rss xmlns:sparkle='http://www.andymatuschak.org/xml-namespaces/sparkle'>",
    "<channel>",
    ...items,
    "</channel>",
    "</rss>",
  ].join("");
}

test("signature reader selects the requested version without formatting assumptions", async () => {
  const root = await mkdtemp(path.join(os.tmpdir(), "appcast-signature-"));
  try {
    const file = path.join(root, "appcast.xml");
    await writeFile(file, appcast([
      item("1.2.0", "new-signature"),
      item("1.1.0", "old-signature"),
    ]));

    const result = await execFileAsync("python3", [signatureScript, file, "1.1.0"]);

    assert.equal(result.stdout.trim(), "old-signature");
  } finally {
    await rm(root, { recursive: true, force: true });
  }
});

test("signature reader rejects a missing release instead of using another item", async () => {
  const root = await mkdtemp(path.join(os.tmpdir(), "appcast-signature-"));
  try {
    const file = path.join(root, "appcast.xml");
    await writeFile(file, appcast([item("1.2.0", "new-signature")]));

    await assert.rejects(
      execFileAsync("python3", [signatureScript, file, "1.1.0"]),
      /exactly one item for version 1\.1\.0/,
    );
  } finally {
    await rm(root, { recursive: true, force: true });
  }
});

test("publisher atomically replaces an unchanged appcast snapshot", async () => {
  const root = await mkdtemp(path.join(os.tmpdir(), "appcast-publish-"));
  try {
    const staged = path.join(root, "staged.xml");
    const snapshot = path.join(root, "snapshot.xml");
    const output = path.join(root, "appcast.xml");
    const oldValue = appcast([item("1.1.0", "old")]);
    const newValue = appcast([
      item("1.2.0", "new"),
      item("1.1.0", "old"),
    ]);
    await writeFile(staged, newValue);
    await writeFile(snapshot, oldValue);
    await writeFile(output, oldValue);

    await execFileAsync("python3", [publishScript, staged, snapshot, output]);

    assert.equal(await readFile(output, "utf8"), newValue);
  } finally {
    await rm(root, { recursive: true, force: true });
  }
});

test("publisher preserves a competing appcast change", async () => {
  const root = await mkdtemp(path.join(os.tmpdir(), "appcast-publish-"));
  try {
    const staged = path.join(root, "staged.xml");
    const snapshot = path.join(root, "snapshot.xml");
    const output = path.join(root, "appcast.xml");
    const oldValue = appcast([item("1.1.0", "old")]);
    const competing = appcast([item("1.1.1", "competing")]);
    await writeFile(staged, appcast([item("1.2.0", "new")]));
    await writeFile(snapshot, oldValue);
    await writeFile(output, competing);

    await assert.rejects(
      execFileAsync("python3", [publishScript, staged, snapshot, output]),
      /destination changed after the existing-history snapshot/,
    );
    assert.equal(await readFile(output, "utf8"), competing);
  } finally {
    await rm(root, { recursive: true, force: true });
  }
});

test("publisher treats destination deletion after the snapshot as a conflict", async () => {
  const root = await mkdtemp(path.join(os.tmpdir(), "appcast-publish-"));
  try {
    const staged = path.join(root, "staged.xml");
    const snapshot = path.join(root, "snapshot.xml");
    const output = path.join(root, "appcast.xml");
    const oldValue = appcast([item("1.1.0", "old")]);
    await writeFile(staged, appcast([item("1.2.0", "new")]));
    await writeFile(snapshot, oldValue);
    await writeFile(output, oldValue);
    await unlink(output);

    await assert.rejects(
      execFileAsync("python3", [publishScript, staged, snapshot, output]),
      /destination changed after the existing-history snapshot/,
    );
    await assert.rejects(readFile(output));
  } finally {
    await rm(root, { recursive: true, force: true });
  }
});
