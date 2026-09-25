import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
const read = p => readFileSync(new URL(`../${p}`, import.meta.url), 'utf8');
test('headless packaging refuses interactive fallback and never publishes the feed for unsigned candidates', () => {
  const source = read('build_release.sh');
  assert.ok(source.includes('RELEASE_HEADLESS'));
  assert.ok(source.includes('refusing interactive Finder fallback'));
  assert.ok(source.includes('"$RELEASE_SIGN_UPDATES" == "1" && "$RELEASE_STAGE_ONLY" != "1"'));
  assert.ok(source.indexOf('"$ROOT_DIR/scripts/prepare_tiktoken_lfs.sh"') < source.indexOf('GIT_LFS_SKIP_SMUDGE=1 swift test'));
});
