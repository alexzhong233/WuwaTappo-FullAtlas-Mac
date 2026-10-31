import { mkdir, readFile, writeFile, rename } from 'node:fs/promises';
import path from 'node:path';

export function validateCatalog(value) {
  if (!Array.isArray(value.atlas) || !value.atlas.length || !value.catalog) throw new Error('Empty FullAtlas snapshot');
  for (const type of ['character_skin', 'accessory', 'emote']) {
    if (!value.catalog[type] || !value.catalog[`${type}_atlas`]) throw new Error(`Missing FullAtlas type: ${type}`);
  }
  for (const item of value.atlas) {
    const mapping = value.catalog[item.asset_type]?.[item.asset_id];
    if (!mapping || !value.catalog[item.asset_type.replace(/_atlas$/, '')]?.[mapping.height_light_id]) throw new Error(`Invalid FullAtlas mapping: ${item.asset_id}`);
  }
}

export async function prepareCatalog(root, profile) {
  const output = path.join(root, 'build/fullatlas-catalog.json');
  try {
    const value = JSON.parse(await readFile(output, 'utf8'));
    validateCatalog(value);
    if (value.assets_host === profile.assetsOrigin) return;
  } catch {}
  async function request(url, asset = false) {
    if (asset && (new URL(url).origin !== profile.assetsOrigin || new URL(url).protocol !== 'https:')) throw new Error('Unrecognized FullAtlas catalog origin');
    const response = await fetch(url, {redirect: 'error', signal: AbortSignal.timeout(30000)});
    if (!response.ok) throw new Error(`FullAtlas HTTP ${response.status}`);
    return response.json();
  }
  const [activity, atlas] = await Promise.all([request(profile.configUrl), request(new URL('/api/common/atlas', profile.configUrl))]);
  if (activity.code !== 0 || atlas.code !== 0 || activity.data.assets_host.replace(/\/$/, '') !== profile.assetsOrigin) throw new Error('Invalid official FullAtlas response');
  const pointer = await request(`${profile.assetsOrigin}/app/json-host/appearance_asset_host.json`, true);
  const catalog = await request(pointer.url, true);
  const value = {atlas: atlas.data, catalog, assets_host: profile.assetsOrigin, assets_json_ts: activity.data.assets_json_ts};
  validateCatalog(value);
  await mkdir(path.dirname(output), {recursive: true});
  await writeFile(`${output}.tmp`, JSON.stringify(value));
  await rename(`${output}.tmp`, output);
  console.log(`Bundled ${value.atlas.length} official atlas mappings (${profile.region})`);
}
