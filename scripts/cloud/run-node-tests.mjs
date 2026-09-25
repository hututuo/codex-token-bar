#!/usr/bin/env node
import { readdirSync } from 'node:fs';
import { resolve, join } from 'node:path';
import { spawnSync } from 'node:child_process';
const root = resolve(process.argv[2] ?? 'tauri-app/src');
function walk(directory) {
  return readdirSync(directory, { withFileTypes: true }).flatMap(entry => {
    const file = join(directory, entry.name);
    if (entry.isDirectory()) return walk(file);
    return entry.isFile() && entry.name.endsWith('.test.mjs') ? [file] : [];
  });
}
const files = walk(root).sort();
if (!files.length) throw new Error(`No test files discovered in ${root}`);
const result = spawnSync(process.execPath, ['--test', '--test-concurrency=3', ...files], { stdio: 'inherit' });
if (result.error) throw result.error;
process.exit(result.status ?? 1);
