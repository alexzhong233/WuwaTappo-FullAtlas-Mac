/**
 * 平台一致性（platform parity）
 *
 * macOS 与 Windows 共用同一套 FullAtlas 前端模块，但各自保留 4 行平台适配：
 * 品牌文案、更新监控卡（Mac 查官方基底 / Windows 开更新管理器）、VERSION 常量，
 * 以及 local_atlas_controller 的 request / assetsHost 取值方式。
 *
 * 两处不共用同一份文件，是因为 windows/src 是上游 Averionx/WuwaTappo-FullAtlas
 * 的完整快照（走 tools/patches 的 diff 存档），直接抽公共件会让上游同步失去可比性。
 * 所以这里改成锁住「差异规模」：谁只改一侧、忘了另一侧，差异行数就会翻倍并在这里失败。
 *
 * 差异上限变化时需要人工确认：是上游升级带来的新分化，还是漏改了。
 */
import assert from 'node:assert/strict';
import test from 'node:test';
import { readFile } from 'node:fs/promises';
import path from 'node:path';

const root = path.resolve(import.meta.dirname, '..');
const MAC_DIR = 'fullatlas-source';
const WIN_DIR = 'windows/src/src';
const MODULES = ['assistant_dashboard.js', 'desktop_assistant.js', 'local_atlas_controller.js'];

/** 忽略行尾 CR 的行级 diff，返回 ['-旧行' | '+新行', ...]。 */
function lineDiff(left, right) {
  const a = left.split('\n').map(line => line.replace(/\r$/, ''));
  const b = right.split('\n').map(line => line.replace(/\r$/, ''));
  const n = a.length, m = b.length;
  const dp = Array.from({ length: n + 1 }, () => new Uint32Array(m + 1));
  for (let i = n - 1; i >= 0; i -= 1) {
    for (let j = m - 1; j >= 0; j -= 1) {
      dp[i][j] = a[i] === b[j] ? dp[i + 1][j + 1] + 1 : Math.max(dp[i + 1][j], dp[i][j + 1]);
    }
  }
  const out = [];
  let i = 0, j = 0;
  while (i < n && j < m) {
    if (a[i] === b[j]) { i += 1; j += 1; }
    else if (dp[i + 1][j] >= dp[i][j + 1]) out.push(`-${a[i++]}`);
    else out.push(`+${b[j++]}`);
  }
  while (i < n) out.push(`-${a[i++]}`);
  while (j < m) out.push(`+${b[j++]}`);
  return out;
}

for (const name of MODULES) {
  test(`${name} 的平台差异不超过 4 行，两侧不会静默分叉`, async () => {
    const mac = await readFile(path.join(root, MAC_DIR, name), 'utf8');
    const win = await readFile(path.join(root, WIN_DIR, name), 'utf8');
    const diff = lineDiff(mac, win);
    const preview = diff.map(line => `  ${line.slice(0, 140)}`).join('\n');
    assert.ok(
      diff.length <= 4,
      `${name} 两侧差异 ${diff.length} 行，超过约定的 4 行：\n${preview}\n` +
        '若只改了其中一侧，请同步另一侧；若确属新的平台分化，再上调 tests/platform-parity.test.mjs 的上限。',
    );
  });
}

test('Mac 侧模块版本号与本仓库 package.json 保持一致', async () => {
  const pkg = JSON.parse(await readFile(path.join(root, 'package.json'), 'utf8'));
  const source = await readFile(path.join(root, MAC_DIR, 'desktop_assistant.js'), 'utf8');
  const version = /const VERSION='([^']+)'/.exec(source)?.[1];
  assert.equal(version, pkg.version, 'Mac 侧 VERSION 需跟随整合版发版号');
});

test('Windows 侧模块版本号跟随上游 FullAtlas，不随本仓库发版变动', async () => {
  const source = await readFile(path.join(root, WIN_DIR, 'desktop_assistant.js'), 'utf8');
  const version = /const VERSION='([^']+)'/.exec(source)?.[1];
  assert.equal(version, '1.2', 'Windows 侧沿用上游 FullAtlas 1.2 的版本号');
});
