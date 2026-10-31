import re, pathlib

src = (pathlib.Path(__file__).resolve().parents[2]
       / 'build/base-103/readable_js/assets/index-CiT_jZa7.js').read_text(encoding='utf-8')
for var in ('Ae', 'Fe'):
    print('=' * 20, var)
    for m in re.finditer(r'\b' + var + r'\.value', src):
        i = m.start()
        seg = src[max(0, i - 90):i + 110].replace('\n', ' ')
        print(f'  @{i}: ...{seg}...')
    print()
