import assert from 'node:assert/strict';
import test from 'node:test';
import { parseOptions } from '../scripts/update-official.mjs';

test('official update defaults to detection only', () => {
  assert.deepEqual(parseOptions([]), { apply: false, force: false, package: true });
  assert.deepEqual(parseOptions(['--check']), { apply: false, force: false, package: true, check: true });
});

test('official update requires explicit apply for mutations and accepts a local installer only with apply', () => {
  assert.deepEqual(parseOptions(['--apply', '--no-package']), { apply: true, force: false, package: false });
  assert.deepEqual(parseOptions(['--apply', '--force', '--installer', '/tmp/WuwaTappo.exe']), {
    apply: true, force: true, package: true, installer: '/tmp/WuwaTappo.exe',
  });
  assert.throws(() => parseOptions(['--installer', '/tmp/WuwaTappo.exe']), /必须和 --apply/);
  assert.throws(() => parseOptions(['--check', '--apply']), /不能和 --apply/);
});
