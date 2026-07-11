import assert from "node:assert/strict";
import { readFile, readdir } from "node:fs/promises";
import { dirname, extname, resolve } from "node:path";
import test from "node:test";
import { fileURLToPath } from "node:url";
import ts from "typescript";

const srcRoot = resolve(dirname(fileURLToPath(import.meta.url)), "../..");

test("Radar ownership keeps API out of components and domain independent", async () => {
  const apiGraph = await dependencyGraph(resolve(srcRoot, "api"));
  const domainGraph = await dependencyGraph(resolve(srcRoot, "domain/codexRadar"));
  const apiEdges = apiGraph.edges;
  const domainEdges = domainGraph.edges;

  assert.deepEqual(apiGraph.unresolvedDynamicImports, [], "src/api has non-static dynamic imports");
  assert.deepEqual(domainGraph.unresolvedDynamicImports, [], "Radar domain has non-static dynamic imports");

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

test("TypeScript AST import parser covers static exports and literal dynamic imports", () => {
  const parsed = parseImportSpecifiers(`
    import value from "./static";
    export { value as forwarded } from './exported';
    const quoted = import("./dynamic-quoted");
    const template = import(\`./dynamic-template\`);
    const commented = import(/* webpackIgnore: true */ "./dynamic-commented");
    // import("./comment-only")
    const text = "export * from './string-only'";
    const unresolved = import(\`./dynamic-\${value}\`);
  `);

  assert.deepEqual(parsed.specifiers, [
    "./static",
    "./exported",
    "./dynamic-quoted",
    "./dynamic-template",
    "./dynamic-commented",
  ]);
  assert.equal(parsed.unresolvedDynamicImports, 1);
});

async function dependencyGraph(root) {
  const files = await sourceFiles(root);
  const edges = [];
  const unresolvedDynamicImports = [];
  for (const source of files) {
    const text = await readFile(source, "utf8");
    const parsed = parseImportSpecifiers(text);
    for (const specifier of parsed.specifiers) {
      if (specifier.startsWith(".")) {
        edges.push({ source, specifier, target: resolve(dirname(source), specifier) });
      }
    }
    if (parsed.unresolvedDynamicImports > 0) {
      unresolvedDynamicImports.push({ count: parsed.unresolvedDynamicImports, source });
    }
  }
  return { edges, unresolvedDynamicImports };
}

function parseImportSpecifiers(source) {
  const sourceFile = ts.createSourceFile(
    "architecture-check.tsx",
    source,
    ts.ScriptTarget.Latest,
    true,
    ts.ScriptKind.TSX,
  );
  const specifiers = [];
  let unresolvedDynamicImports = 0;

  function recordLiteral(node) {
    if (ts.isStringLiteral(node) || ts.isNoSubstitutionTemplateLiteral(node)) {
      specifiers.push(node.text);
      return true;
    }
    return false;
  }

  function visit(node) {
    if (
      (ts.isImportDeclaration(node) || ts.isExportDeclaration(node))
      && node.moduleSpecifier
    ) {
      recordLiteral(node.moduleSpecifier);
    } else if (
      ts.isCallExpression(node)
      && node.expression.kind === ts.SyntaxKind.ImportKeyword
    ) {
      if (!recordLiteral(node.arguments[0])) {
        unresolvedDynamicImports += 1;
      }
    }
    ts.forEachChild(node, visit);
  }

  visit(sourceFile);
  return { specifiers, unresolvedDynamicImports };
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
