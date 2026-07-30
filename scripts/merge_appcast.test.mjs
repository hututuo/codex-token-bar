import assert from "node:assert/strict";
import { execFile } from "node:child_process";
import { access, mkdtemp, readFile, writeFile } from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import test from "node:test";
import { fileURLToPath } from "node:url";
import { promisify } from "node:util";

const execFileAsync = promisify(execFile);
const mergeScript = path.join(
  path.dirname(fileURLToPath(import.meta.url)),
  "merge_appcast.py",
);
const pythonExecutable =
  process.env.PYTHON ?? (process.platform === "win32" ? "python" : "python3");

function appcastItem(version, marker) {
  return [
    "        <item>",
    `            <title>Version ${version} ${marker}</title>`,
    `            <sparkle:shortVersionString>${version}</sparkle:shortVersionString>`,
    `            <enclosure url="https://example.invalid/CodexTokenBar-${version}.zip" sparkle:edSignature="sig-${version}-${marker}" length="1"/>`,
    "        </item>",
  ].join("\n");
}

function appcastXml(items) {
  return [
    '<?xml version="1.0" encoding="utf-8"?>',
    '<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">',
    "    <channel>",
    "        <title>Codex Token Bar</title>",
    ...items,
    "    </channel>",
    "</rss>",
    "",
  ].join("\n");
}

async function runMerge({ version, generated, existing, outputExisting, env = {} }) {
  const root = await mkdtemp(path.join(os.tmpdir(), "merge-appcast-"));
  const generatedPath = path.join(root, "generated.xml");
  const existingPath = path.join(root, "existing.xml");
  const outputPath = path.join(root, "appcast.xml");
  await writeFile(generatedPath, generated);
  if (existing !== undefined) {
    await writeFile(existingPath, existing);
  }
  if (outputExisting !== undefined) {
    await writeFile(outputPath, outputExisting);
  }
  const baseEnv = { ...process.env };
  delete baseEnv.ALLOW_APPCAST_REPUBLISH;
  try {
    await execFileAsync(
      pythonExecutable,
      [mergeScript, version, generatedPath, existingPath, outputPath],
      { env: { ...baseEnv, ...env } },
    );
    return { code: 0, stderr: "", outputPath };
  } catch (error) {
    return { code: error.code ?? 1, stderr: `${error.stderr ?? ""}`, outputPath };
  }
}

function shortVersionTag(version) {
  return `<sparkle:shortVersionString>${version}</sparkle:shortVersionString>`;
}

test("fresh merge without an existing appcast publishes the generated items verbatim", async () => {
  const generated = appcastXml([appcastItem("1.1.0", "fresh")]);
  const run = await runMerge({ version: "1.1.0", generated });
  assert.equal(run.code, 0, run.stderr);
  assert.equal(await readFile(run.outputPath, "utf8"), generated);
});

test("merge keeps previously published versions after the fresh item", async () => {
  const generated = appcastXml([appcastItem("1.1.0", "fresh")]);
  const existing = appcastXml([appcastItem("1.0.0", "published")]);
  const run = await runMerge({ version: "1.1.0", generated, existing });
  assert.equal(run.code, 0, run.stderr);
  const output = await readFile(run.outputPath, "utf8");
  const freshIndex = output.indexOf(shortVersionTag("1.1.0"));
  const publishedIndex = output.indexOf(shortVersionTag("1.0.0"));
  assert.ok(freshIndex >= 0, "merged appcast is missing the fresh item");
  assert.ok(publishedIndex > freshIndex, "published item must follow the fresh item");
});

test("republishing an already published version is rejected without writing output", async () => {
  const generated = appcastXml([appcastItem("1.1.0", "fresh")]);
  const existing = appcastXml([appcastItem("1.1.0", "published")]);
  const run = await runMerge({ version: "1.1.0", generated, existing });
  assert.notEqual(run.code, 0);
  assert.match(run.stderr, /already contains version 1\.1\.0/);
  assert.match(run.stderr, /ALLOW_APPCAST_REPUBLISH=1/);
  await assert.rejects(access(run.outputPath), "rejected merge must not write the appcast");
});

test("ALLOW_APPCAST_REPUBLISH=1 replaces the published item for the version", async () => {
  const generated = appcastXml([appcastItem("1.1.0", "fresh")]);
  const existing = appcastXml([
    appcastItem("1.1.0", "published"),
    appcastItem("1.0.0", "published"),
  ]);
  const run = await runMerge({
    version: "1.1.0",
    generated,
    existing,
    env: { ALLOW_APPCAST_REPUBLISH: "1" },
  });
  assert.equal(run.code, 0, run.stderr);
  const output = await readFile(run.outputPath, "utf8");
  assert.ok(output.includes("Version 1.1.0 fresh"));
  assert.ok(!output.includes("Version 1.1.0 published"), "stale item must be replaced");
  assert.ok(output.includes("Version 1.0.0 published"));
});

test("merged appcast keeps at most five items, dropping the oldest", async () => {
  const generated = appcastXml([appcastItem("1.1.0", "fresh")]);
  const existing = appcastXml(
    ["1.0.4", "1.0.3", "1.0.2", "1.0.1", "1.0.0"].map((version) =>
      appcastItem(version, "published"),
    ),
  );
  const run = await runMerge({ version: "1.1.0", generated, existing });
  assert.equal(run.code, 0, run.stderr);
  const output = await readFile(run.outputPath, "utf8");
  for (const version of ["1.1.0", "1.0.4", "1.0.3", "1.0.2", "1.0.1"]) {
    assert.ok(output.includes(shortVersionTag(version)), `missing ${version}`);
  }
  assert.ok(!output.includes(shortVersionTag("1.0.0")), "oldest item must be dropped");
  assert.equal((output.match(/<item>/g) ?? []).length, 5);
});

test("generated appcast without the current version is rejected", async () => {
  const generated = appcastXml([appcastItem("1.0.0", "fresh")]);
  const run = await runMerge({ version: "1.1.0", generated });
  assert.notEqual(run.code, 0);
  assert.match(run.stderr, /generated appcast missing current version 1\.1\.0/);
});

test("structured merge accepts compact XML and noncanonical indentation", async () => {
  const generated = appcastXml([appcastItem("1.1.0", "fresh")])
    .replaceAll("\n", "")
    .replaceAll("        ", "");
  const existing = appcastXml([appcastItem("1.0.0", "published")])
    .replaceAll("        ", "\t");
  const run = await runMerge({ version: "1.1.0", generated, existing });
  assert.equal(run.code, 0, run.stderr);
  const output = await readFile(run.outputPath, "utf8");
  assert.ok(output.includes(shortVersionTag("1.1.0")));
  assert.ok(output.includes(shortVersionTag("1.0.0")));
});

test("malformed published XML fails closed without writing output", async () => {
  const generated = appcastXml([appcastItem("1.1.0", "fresh")]);
  const run = await runMerge({
    version: "1.1.0",
    generated,
    existing: "<rss><channel><item>",
  });
  assert.notEqual(run.code, 0);
  assert.match(run.stderr, /published appcast is not well-formed XML/);
  await assert.rejects(access(run.outputPath));
});

test("duplicate generated versions fail closed", async () => {
  const generated = appcastXml([
    appcastItem("1.1.0", "first"),
    appcastItem("1.1.0", "second"),
  ]);
  const run = await runMerge({ version: "1.1.0", generated });
  assert.notEqual(run.code, 0);
  assert.match(run.stderr, /generated appcast contains duplicate version 1\.1\.0/);
  await assert.rejects(access(run.outputPath));
});

test("forbidden entity declarations fail closed", async () => {
  const generated = appcastXml([appcastItem("1.1.0", "fresh")])
    .replace("<rss ", '<!DOCTYPE rss [<!ENTITY xxe SYSTEM "file:///etc/passwd">]><rss ');
  const run = await runMerge({ version: "1.1.0", generated });
  assert.notEqual(run.code, 0);
  assert.match(run.stderr, /forbidden DTD or entity declaration/);
  await assert.rejects(access(run.outputPath));
});

test("publication refuses a destination changed after the history snapshot", async () => {
  const generated = appcastXml([appcastItem("1.1.0", "fresh")]);
  const existing = appcastXml([appcastItem("1.0.0", "snapshot")]);
  const competing = appcastXml([appcastItem("1.0.1", "competing")]);
  const run = await runMerge({
    version: "1.1.0",
    generated,
    existing,
    outputExisting: competing,
  });
  assert.notEqual(run.code, 0);
  assert.match(run.stderr, /destination changed after the existing-history snapshot/);
  assert.equal(await readFile(run.outputPath, "utf8"), competing);
});
