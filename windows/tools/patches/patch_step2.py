"""Patch build_integration.py so the 1.0.2 adapter also accepts the 1.0.3 layout.

已在 src/patched 中应用过（幂等：重复执行会跳过）。
用法（任意目录）： .venv\\Scripts\\python.exe tools\\patches\\patch_step2.py
"""
import pathlib

ROOT = pathlib.Path(__file__).resolve().parents[2]
p = ROOT / 'src/patched/tools/build_integration.py'
s = p.read_text(encoding='utf-8')

if "'1.0.3'" in s:
    print('already patched, nothing to do')
    raise SystemExit(0)

old_state = """state_ref = re.search(r'const ([\\w$]+) = ' + re.escape(pi['ref']) + r'\\(null\\)', root_source)
assert state_ref, 'Panel snapshot state declaration changed'"""

new_state = """state_ref = re.search(r'const ([\\w$]+) = ' + re.escape(pi['ref']) + r'\\(null\\)', root_source)
if not state_ref:
    # 1.0.3 delivers the snapshot through a subscription callback instead of a null ref.
    sub = re.search(r'=\\s*await\\s+[\\w$]+\\(\\s*([\\w$]+)\\s*=>\\s*\\{(.{0,800}?)\\n\\s*\\}\\)', root_source, re.S)
    assert sub, 'Panel snapshot subscription changed'
    _param, _body = sub.group(1), sub.group(2)
    _got = re.search(r'([\\w$]+)\\.value = ' + re.escape(_param) + r'\\b', _body)
    assert _got, 'Panel snapshot state assignment changed'
    state_ref = (_got.group(0), _got.group(1))
assert state_ref, 'Panel snapshot state declaration changed'"""

assert old_state in s, 'state anchor not found'
s = s.replace(old_state, new_state)

old_ver = "assert config['client_version'] == '1.0.2', 'Desktop assistant requires the verified 1.0.2 adapter'"
new_ver = "assert config['client_version'] in ('1.0.2', '1.0.3'), 'Desktop assistant requires a verified adapter'"
assert old_ver in s
s = s.replace(old_ver, new_ver)

p.write_text(s, encoding='utf-8')
print('patched build_integration.py for 1.0.3')
