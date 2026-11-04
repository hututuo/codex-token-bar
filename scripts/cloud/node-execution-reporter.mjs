import { tap } from 'node:test/reporters';
import { writeFileSync } from 'node:fs';

// Node treats an empty test file as a passing file-level test. Count actual
// declared tests independently, while retaining the standard TAP diagnostics.
export default async function* executionReporter(source) {
  let passed = 0;
  let skipped = 0;
  let todo = 0;
  let skippedSuites = 0;
  let todoSuites = 0;
  let summary;
  const files = new Map();
  async function* observed() {
    for await (const event of source) {
      const { type, data } = event;
      if (type === 'test:pass' || type === 'test:fail') {
        if (data.file && !files.has(data.file)) files.set(data.file, false);
        if (data.details?.type === 'suite') {
          if (data.skip) skippedSuites++;
          if (data.todo) todoSuites++;
          // Skipped suites may emit no leaf records. Keep them as explicit
          // skips, not empty files, so optional platform suites remain usable.
          if (data.file && (data.skip || data.todo)) files.set(data.file, true);
        } else if (data.name !== data.file) {
          if (data.file) files.set(data.file, true);
          if (data.skip) skipped++;
          else if (data.todo) todo++;
          else if (type === 'test:pass') passed++;
        }
      }
      if (type === 'test:summary' && !data.file) summary = data;
      yield event;
    }
  }
  yield* tap(observed());
  const emptyFiles = [...files].filter(([, declared]) => !declared).map(([file]) => file);
  const errors = [];
  if (!summary || !summary.success || summary.counts.failed || summary.counts.cancelled) errors.push('missing or failed test summary');
  if (!passed) errors.push('no declared tests passed');
  if (emptyFiles.length) errors.push('test files contained no declared tests');
  if (todo || todoSuites) errors.push('TODO tests or suites are not acceptance evidence');
  if (process.env.TOKENBAR_NODE_REQUIRE_ALL === '1' && (skipped || skippedSuites)) errors.push('required tests or suites were skipped');
  const report = { status: errors.length ? 'FAIL' : 'PASS', passed, skipped, todo, skippedSuites, todoSuites, emptyFiles, errors,
    summary: summary?.counts };
  if (process.env.TOKENBAR_NODE_EXECUTION_REPORT) {
    writeFileSync(process.env.TOKENBAR_NODE_EXECUTION_REPORT, JSON.stringify(report, null, 2) + '\n', { flag: 'wx' });
  }
  if (errors.length) {
    process.exitCode = 1;
    yield `# Test execution gate rejected: ${errors.join('; ')}\n`;
  }
}
