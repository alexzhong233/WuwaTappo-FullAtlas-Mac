"""Dump / compare .lnk structure to debug shell link generation (MS-SHLLINK)."""
import struct
import sys

FLAG_NAMES = {
    0x00000001: 'HasLinkTargetIDList', 0x00000002: 'HasLinkInfo',
    0x00000004: 'HasName', 0x00000008: 'HasRelativePath',
    0x00000010: 'HasWorkingDir', 0x00000020: 'HasArguments',
    0x00000040: 'HasIconLocation', 0x00000080: 'IsUnicode',
    0x00000100: 'ForceNoLinkInfo', 0x00000200: 'HasExpString',
    0x00400000: 'UnaliasOnSave', 0x00800000: 'PreferEnvironmentPath',
}


def dump(path):
    data = open(path, 'rb').read()
    print(f'== {path}  ({len(data)} bytes)')
    header_size = struct.unpack_from('<I', data, 0)[0]
    print(f'   HeaderSize = {header_size:#x}')
    clsid = data[4:20].hex()
    print(f'   CLSID = {clsid}')
    flags = struct.unpack_from('<I', data, 20)[0]
    names = [n for f, n in FLAG_NAMES.items() if flags & f]
    print(f'   Flags = {flags:#010x}  {names}')
    print(f'   FileAttributes = {struct.unpack_from("<I", data, 24)[0]:#x}')
    print(f'   ShowCommand = {struct.unpack_from("<I", data, 60)[0]}')

    off = header_size
    # IDList
    if flags & 0x1:
        idlist_size = struct.unpack_from('<H', data, off)[0]
        print(f'   IDListSize = {idlist_size} (at {off:#x})')
        off += 2 + idlist_size
    if flags & 0x2:
        li_size, li_hdr, li_flags = struct.unpack_from('<III', data, off)
        vol_off, base_off, net_off, suffix_off = struct.unpack_from('<IIII', data, off + 12)
        print(f'   LinkInfo: size={li_size} hdr={li_hdr:#x} flags={li_flags:#x} '
              f'vol={vol_off:#x} base={base_off:#x} net={net_off:#x} suffix={suffix_off:#x}')
        base = data[off + base_off: data.index(b'\x00', off + base_off)].decode('mbcs', 'replace')
        print(f'   LocalBasePath = {base!r}')
        off += li_size
    for label, flag in (('NAME', 0x4), ('RELATIVE_PATH', 0x8), ('WORKING_DIR', 0x10),
                        ('ARGUMENTS', 0x20), ('ICON', 0x40)):
        if not flags & flag:
            continue
        if flags & 0x80:
            cnt = struct.unpack_from('<H', data, off)[0]
            raw = data[off + 2: off + 2 + cnt * 2]
            print(f'   {label}: cnt={cnt} {raw.decode("utf-16-le", "replace")!r}')
            off += 2 + cnt * 2
        else:
            off_end = data.index(b'\x00', off)
            print(f'   {label}: {data[off:off_end]!r}')
            off = off_end + 1
    print(f'   remaining bytes after StringData: {len(data) - off}')
    return data


if __name__ == '__main__':
    for p in sys.argv[1:]:
        dump(p)
        print()
