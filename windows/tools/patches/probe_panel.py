import json, re, pathlib

base = pathlib.Path(__file__).resolve().parents[2] / 'build/base-103'
st = json.loads((base / 'js_structure.json').read_text(encoding='utf-8'))
shared = st['shared']
print('shared =', shared)
txt = (base / 'readable_js/assets' / shared).read_text(encoding='utf-8')
reg = txt[txt.index('const router = createRouter'):]
routes = dict(re.findall(r'path:\s*"([^"]+)"[\s\S]*?import\("\./([^"]+)"\)', reg)[:9])
print('routes =', routes)

pn = routes['/panel']
p = st['files'][pn]
print('panel components:', [c['name'] for c in p['components']])
root = next(c for c in p['components'] if c['name'] == 'index')
src = (base / 'readable_js/assets' / pn).read_text(encoding='utf-8')
body = src[root['body']:root['bodyEnd']]
print('\n--- body 头部 400 字符 ---')
print(body[:400])
print('\n--- 所有 xx(null) 声明 ---')
for m in re.finditer(r'[\w$.]{0,40}\([^()]{0,20}null\)', body):
    print(repr(m.group(0)))
print('\n--- ref 别名 ---')
imports = p['imports']
print({k: v for k, v in imports.items() if 'ref' in k.lower() or k in ('ref', 'createRef')})
