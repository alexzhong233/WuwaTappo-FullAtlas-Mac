import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import vm from 'node:vm';
import { parse } from 'acorn';
import { test } from 'node:test';
import { verifiedAdapterVersion } from '../scripts/fullatlas-frontend.mjs';

test('FullAtlas accepts only the reviewed official version and exact installer digest', async () => {
  const lock = JSON.parse(await readFile(new URL('../upstream-cn.json', import.meta.url), 'utf8'));
  assert.equal(verifiedAdapterVersion(lock), '1.0.2');
  assert.throws(() => verifiedAdapterVersion({ ...lock, version: '1.0.3' }), /no verified Mac adapter/);
  assert.throws(() => verifiedAdapterVersion({ ...lock, installer: { ...lock.installer, sha256: 'f'.repeat(64) } }), /no verified Mac adapter/);
  assert.throws(() => verifiedAdapterVersion({ ...lock, region: 'GLOBAL' }), /no verified Mac adapter/);
});

test('prepared FullAtlas factory stays inactive in login and other auxiliary routes', async () => {
  const { readdir } = await import('node:fs/promises');
  const directory = new URL('../build/frontend/assets/', import.meta.url);
  const sources = await Promise.all((await readdir(directory)).filter(name => name.endsWith('.js')).map(name => readFile(new URL(name, directory), 'utf8')));
  const source = sources.find(text => text.includes('const localAtlasRoute='));
  assert.ok(source, 'prepare the CN frontend before testing the integrated adapter');
  const ast = parse(source, { sourceType: 'module', ecmaVersion: 'latest' });
  const names = new Set(['localAtlasRoute', 'localAtlasController']);
  const bindings = ast.body.filter(node => node.type === 'VariableDeclaration' && node.declarations.some(d => names.has(d.id.name)));
  assert.equal(bindings.length, 2);
  const code = bindings.map(node => source.slice(node.start, node.end)).join('\n') + '\nlocalAtlasController';
  for (const route of ['/login', '/about', '/oss-notice', '/update']) {
    const controller = vm.runInNewContext(code, {
      window: { location: { hash: '#' + route } },
      createLocalAtlasController: () => { throw new Error('Auxiliary route requested the FullAtlas bridge'); },
    });
    assert.equal(controller, null, route);
  }
});
