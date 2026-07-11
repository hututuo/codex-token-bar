import assert from "node:assert/strict";
import { readFile, readdir } from "node:fs/promises";
import { dirname, extname, resolve } from "node:path";
import test from "node:test";
import { fileURLToPath } from "node:url";

const srcRoot = resolve(dirname(fileURLToPath(import.meta.url)), "../..");

test("Radar ownership keeps API out of components and domain independent", async () => {
  const apiEdges = await dependencyEdges(resolve(srcRoot, "api"));
  const domainEdges = await dependencyEdges(resolve(srcRoot, "domain/codexRadar"));

  assert.deepEqual(
    apiEdges.filter((edge) => edge.target.startsWith(resolve(srcRoot, "components"))),
    [],
    "src/api must not import src/components",
  );
  assert.deepEqual(
    domainEdges.filter((edge) => (
      edge.target.startsWith(resolve(srcRoot, "api"))
      || edge.target.startsWith(resolve(srcRoot, "components"))
    )),
    [],
    "Radar domain must not depend on API or components",
  );

  const radarApiEdges = apiEdges.filter((edge) => edge.source.includes("codexRadar"));
  assert.equal(
    radarApiEdges.some((edge) => edge.target.startsWith(resolve(srcRoot, "domain/codexRadar"))),
    true,
    "Radar API clients should consume the neutral domain model",
  );
});

async function dependencyEdges(root) {
  const files = await sourceFiles(root);
  const edges = [];
  for (const source of files) {
    const text = await readFile(source, "utf8");
    for (const specifier of importSpecifiers(text)) {
      if (specifier.startsWith(".")) {
        edges.push({ source, specifier, target: resolve(dirname(source), specifier) });
      }
    }
  }
  return edges;
}

function importSpecifiers(source) {
  const specifiers = [];
  const pattern = /(?:import|export)\s+(?:[\s\S]*?\s+from\s+)?["']([^"']+)["']|import\(\s*["']([^"']+)["']\s*\)/g;
  for (const match of source.matchAll(pattern)) {
    specifiers.push(match[1] ?? match[2]);
  }
  return specifiers;
}

async function sourceFiles(root) {
  const entries = await readdir(root, { withFileTypes: true });
  const files = [];
  for (const entry of entries) {
    const path = resolve(root, entry.name);
    if (entry.isDirectory()) {
      files.push(...await sourceFiles(path));
    } else if ([".ts", ".tsx"].includes(extname(entry.name))) {
      files.push(path);
    }
  }
  return files;
}
