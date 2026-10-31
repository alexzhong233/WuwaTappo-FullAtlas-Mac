"""Refresh public catalog data; commit only after all referenced images verify."""
from pathlib import Path
import concurrent.futures, hashlib, json, os, shutil, time, urllib.parse, urllib.request

API = 'https://api-mc-wuwatappo.kurogames-global.com'

def get_json(url):
    with urllib.request.urlopen(urllib.request.Request(url, headers={'User-Agent': 'WuwaTappo-LocalGallery-Cache'}), timeout=30) as response:
        return json.load(response)

def _read_json(path, default):
    """读旧缓存做增量对比。全新安装根本没有这些文件，不能直接抛错。"""
    try:
        return json.loads(path.read_text(encoding='utf-8'))
    except (OSError, ValueError):
        return default

def sync(root, progress, api=None, allowed_hosts=None):
    # 国服与国际服的图鉴/素材是两个官方源，域名与内容都可能不同。
    # 由调用方（local_host 读 local_config.json）传入，缺省仍走国服。
    api = (api or API).rstrip('/')
    allowed = set()
    for item in [api] + list(allowed_hosts or []):
        parsed = urllib.parse.urlparse(item)
        allowed.add(parsed.hostname or item)
    root = Path(root)
    cache = root / 'cache'
    activity = get_json(api + '/api/common/activity-config')
    atlas = get_json(api + '/api/common/atlas')
    if activity.get('code') != 0 or atlas.get('code') != 0 or not isinstance(atlas.get('data'), list) or not atlas['data']:
        raise ValueError('官方目录响应格式异常，保留原缓存')
    host = activity['data']['assets_host'].rstrip('/')
    if urllib.parse.urlparse(host).hostname not in allowed:
        raise ValueError('未识别的素材域名，保留原缓存')
    old_atlas = _read_json(cache / 'atlas.json', None)
    old_activity = _read_json(cache / 'activity-config.json', None)
    old_manifest = _read_json(cache / 'asset_manifest.json', None)
    # 三份旧文件齐备才走「没变化就不下载」的捷径；缺任何一份说明是首次安装
    # 或缓存被清理过，必须完整拉一遍，否则 READY 永远为 false。
    if (old_manifest is not None and old_atlas is not None and old_activity is not None
            and (old_activity.get('data') or {}).get('assets_json_ts') == activity['data'].get('assets_json_ts')
            and old_atlas.get('data') == atlas['data']):
        return {'changed': False, 'atlas_count': len(atlas['data']), 'asset_count': len(old_manifest.get('records') or [])}
    pointer = get_json(host + '/app/json-host/appearance_asset_host.json')
    url = pointer['url']
    if urllib.parse.urlparse(url).hostname != urllib.parse.urlparse(host).hostname:
        raise ValueError('未识别的素材清单地址')
    catalog = get_json(url)
    types = ['character_skin', 'accessory', 'emote']
    if not all(isinstance(catalog.get(t), dict) and isinstance(catalog.get(t + '_atlas'), dict) for t in types):
        raise ValueError('新版素材结构不兼容，保留原缓存')
    for item in atlas['data']:
        typ = item['asset_type']
        entry = catalog[typ].get(str(item['asset_id']))
        if not entry or str(entry.get('height_light_id')) not in catalog[typ.removesuffix('_atlas')]:
            raise ValueError('图鉴到可用外观的映射缺失，保留原缓存')
    # 上次同步被强杀（关窗口 / 断电）会留下半套 staging，重来前先清掉，避免越积越多
    for stale in root.glob('cache_staging_*'):
        shutil.rmtree(stale, ignore_errors=True)
    stage = root / ('cache_staging_' + str(time.time_ns()))
    assets = stage / 'assets'
    assets.mkdir(parents=True)
    jobs = {}
    def rewrite(obj):
        if isinstance(obj, dict):
            for key, value in obj.items():
                if key == 'url' and isinstance(value, str):
                    full = urllib.parse.urljoin(host + '/', value)
                    if urllib.parse.urlparse(full).hostname != urllib.parse.urlparse(host).hostname:
                        raise ValueError('未识别的外部图片域名')
                    name = hashlib.sha256(full.encode()).hexdigest() + '.png'
                    jobs[name] = full
                    obj[key] = 'assets/' + name
                else:
                    rewrite(value)
        elif isinstance(obj, list):
            for value in obj:
                rewrite(value)
    rewrite(catalog)
    def download(pair):
        name, source = pair
        target = assets / name
        existing = cache / 'assets' / name
        if existing.exists():
            try:
                os.link(existing, target)
            except OSError:
                shutil.copy2(existing, target)
            data = target.read_bytes()
        else:
            error = None
            for attempt in range(3):
                try:
                    with urllib.request.urlopen(source, timeout=40) as response:
                        data = response.read()
                    error = None
                    break
                except Exception as exc:
                    error = exc
                    time.sleep(attempt + 0.5)
            if error:
                raise error
            target.write_bytes(data)
        if not data.startswith(b'\x89PNG\r\n\x1a\n'):
            raise ValueError('下载素材不是有效 PNG')
        return {'file': name, 'source': source, 'size': len(data), 'sha256': hashlib.sha256(data).hexdigest()}
    records = []
    with concurrent.futures.ThreadPoolExecutor(max_workers=8) as executor:
        futures = [executor.submit(download, item) for item in jobs.items()]
        for i, future in enumerate(concurrent.futures.as_completed(futures), 1):
            records.append(future.result())
            progress(i, len(jobs))
    for name, obj in [('activity-config.json', activity), ('atlas.json', atlas), ('offline_catalog.json', catalog),
                      ('asset_manifest.json', {'records': records, 'errors': []})]:
        (stage / name).write_text(json.dumps(obj, ensure_ascii=False, separators=(',', ':')), encoding='utf-8')
    # Preserve a recoverable previous generation; never replace a working cache
    # with a partial download. The host serializes this with mode changes.
    # Windows 上杀毒软件 / 索引服务会在换缓存瞬间短暂占住目录（WinError 5），
    # 与上面的下载重试同理，做几次退避重试而不是直接失败。
    def rename_dir(src, dst, attempts=5):
        error = None
        for attempt in range(attempts):
            try:
                src.rename(dst)
                return
            except PermissionError as exc:
                error = exc
                time.sleep(attempt + 0.5)
        raise error
    archive = root / ('cache_previous_' + str(time.time_ns()))
    # 首次安装时 cache 目录并不存在：没有旧代可归档，直接把新的一代改名上线。
    if cache.exists():
        rename_dir(cache, archive)
    try:
        rename_dir(stage, cache)
    except Exception:
        if archive.exists():
            rename_dir(archive, cache)
        raise
    # 宿主只用最近两代做旧素材回退，更早的整代缓存直接删掉，否则每次同步
    # 都会多留近百 MB。
    for stale in sorted(root.glob('cache_previous_*'), reverse=True)[2:]:
        shutil.rmtree(stale, ignore_errors=True)
    return {'changed': True, 'atlas_count': len(atlas['data']), 'asset_count': len(records),
            'assets_json_ts': activity['data']['assets_json_ts']}
