#!/usr/bin/env node
import { existsSync, readdirSync, readFileSync } from 'node:fs';
import { resolve, join } from 'node:path';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
const root = resolve(process.argv[2] ?? 'tauri-app/src');
const options = process.argv.slice(3);
if (options.some(option => option !== '--no-skips')) throw new Error('Unknown test runner option');
const reportPath = process.env.TOKENBAR_NODE_EXECUTION_REPORT;
if (reportPath && existsSync(reportPath)) throw new Error('Refusing to overwrite Node test evidence');
function walk(directory) {
  return readdirSync(directory, { withFileTypes: true }).flatMap(entry => {
    const file = join(directory, entry.name);
    if (entry.isDirectory()) return walk(file);
    return entry.isFile() && entry.name.endsWith('.test.mjs') ? [file] : [];
  });
}
const files = walk(root).sort();
if (!files.length) throw new Error(`No test files discovered in ${root}`);
const reporter = fileURLToPath(new URL('./node-execution-reporter.mjs', import.meta.url));
const result = spawnSync(process.execPath, ['--test', '--test-concurrency=3', `--test-reporter=${reporter}`, ...files], {
  stdio: 'inherit', env: { ...process.env, TOKENBAR_NODE_REQUIRE_ALL: options.includes('--no-skips') ? '1' : '' },
});
if (result.error) throw result.error;
if (reportPath && (!existsSync(reportPath) || JSON.parse(readFileSync(reportPath, 'utf8')).status !== 'PASS')) process.exit(1);
process.exit(result.status ?? 1);
