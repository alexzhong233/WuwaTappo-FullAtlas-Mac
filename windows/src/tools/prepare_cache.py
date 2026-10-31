"""Download an initial public asset cache without account credentials."""
from pathlib import Path
import argparse,json,sys
sys.path.insert(0,str(Path(__file__).resolve().parents[1]/'src'))
from sync_cache import sync

ap=argparse.ArgumentParser(description=__doc__)
ap.add_argument('root',type=Path,help='Dedicated data root; creates root/cache')
args=ap.parse_args()
cache=args.root.resolve()/'cache'
if not cache.exists():
    (cache/'assets').mkdir(parents=True)
    for name,value in [('atlas.json',{'code':0,'data':[]}),
       ('activity-config.json',{'code':0,'data':{'assets_json_ts':0}}),
       ('asset_manifest.json',{'records':[],'errors':[]})]:
        (cache/name).write_text(json.dumps(value),encoding='utf-8')
# 区域源优先级与 region.ps1 一致：local_config.json（运行目录）> WUWA_REGION 环境变量 > 国服。
# 构建工作目录（inputs / assets）通常没有运行配置，必须靠 WUWA_REGION 区分国服 / 国际服，
# 否则在别的机器上构建国际服会把国服缓存拉进去。素材域名必须进 allowed_hosts，
# 否则官方源会被域名校验拦下。
config_path=args.root.resolve()/'local_config.json'
try:
    config=json.loads(config_path.read_text(encoding='utf-8-sig'))
    api=config['api_base']
    cdn_hosts=[config['cdn_host']]
except (OSError,KeyError,ValueError):
    region=(__import__('os').environ.get('WUWA_REGION') or 'cn').lower()
    if region not in ('cn','global'):
        raise SystemExit(f'未知区域：{region}（可选 cn / global）')
    api=('https://api-wutheringwaves-wuwatappo.kurogames-global.com' if region=='global'
         else 'https://api-mc-wuwatappo.kurogames-global.com')
    cdn_hosts=['https://wutheringwaves-wuwatappo.kurogames-global.com' if region=='global'
               else 'https://mc-wuwatappo.kurogames-global.com']
print(json.dumps(sync(args.root,lambda done,total:print(f'{done}/{total}',flush=True),
                 api=api,allowed_hosts=cdn_hosts),ensure_ascii=False))
