import { tap } from 'node:test/reporters';
import { writeFileSync } from 'node:fs';

// Node treats an empty test file as a passing file-level test. Count actual
// declared tests independently, while retaining the standard TAP diagnostics.
export default async function* executionReporter(source) {
  let passed = 0;
  let skipped = 0;
  let todo = 0;
  let summary;
  const emptyFiles = [];
  async function* observed() {
    for await (const event of source) {
      const { type, data } = event;
      if (type === 'test:pass' || type === 'test:fail') {
        if (data.name === data.file) emptyFiles.push(data.file);
        else if (data.details?.type !== 'suite') {
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
  const errors = [];
  if (!summary || !summary.success || summary.counts.failed || summary.counts.cancelled) errors.push('missing or failed test summary');
  if (!passed) errors.push('no declared tests passed');
  if (emptyFiles.length) errors.push('test files contained no declared tests');
  if (todo) errors.push('TODO tests are not acceptance evidence');
  if (process.env.TOKENBAR_NODE_REQUIRE_ALL === '1' && skipped) errors.push('required tests were skipped');
  const report = { status: errors.length ? 'FAIL' : 'PASS', passed, skipped, todo, emptyFiles, errors,
    summary: summary?.counts };
  if (process.env.TOKENBAR_NODE_EXECUTION_REPORT) {
    writeFileSync(process.env.TOKENBAR_NODE_EXECUTION_REPORT, JSON.stringify(report, null, 2) + '\n', { flag: 'wx' });
  }
  if (errors.length) {
    process.exitCode = 1;
    yield `# Test execution gate rejected: ${errors.join('; ')}\n`;
  }
}
