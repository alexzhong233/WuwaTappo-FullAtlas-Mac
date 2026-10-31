"""Create a Windows .lnk shortcut via pylnk3 (no COM).

Local policy blocks COM instantiation (WScript.Shell), and hand-rolled .lnk
bytes are rejected by the shell because a valid LinkTargetIDList is required,
so pylnk3 builds the IDList + header for us.

Usage:
  python tools/make_shortcut.py --out "<path.lnk>" --target <exe> [--arguments ..]
         [--workdir ..] [--icon ..] [--description ..] [--window minimized]
"""
import argparse
import os
import sys

import pylnk3

WINDOW_MODES = {
    'normal': pylnk3.WINDOW_NORMAL,
    'maximized': pylnk3.WINDOW_MAXIMIZED,
    'minimized': pylnk3.WINDOW_MINIMIZED,
}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--out', required=True)
    ap.add_argument('--target', required=True)
    ap.add_argument('--arguments', default=None)
    ap.add_argument('--workdir', default=None)
    ap.add_argument('--icon', default=None)
    ap.add_argument('--description', default=None)
    ap.add_argument('--window', default=None, choices=sorted(WINDOW_MODES))
    args = ap.parse_args()

    for label in ('target', 'workdir', 'icon'):
        value = getattr(args, label)
        if value and not os.path.exists(value):
            sys.exit(f'{label} 不存在: {value}')

    out = os.path.abspath(args.out)
    if os.path.exists(out):
        os.remove(out)

    lnk = pylnk3.for_file(
        target_file=os.path.abspath(args.target),
        arguments=args.arguments,
        description=args.description,
        icon_file=os.path.abspath(args.icon) if args.icon else None,
        work_dir=os.path.abspath(args.workdir) if args.workdir else None,
        window_mode=WINDOW_MODES[args.window] if args.window else None,
    )
    lnk.save(out)
    print(f'{os.path.getsize(out)} bytes -> {out}')
    return 0


if __name__ == '__main__':
    sys.exit(main())
