#!/usr/bin/env python3
"""把 netbatt/ 打成 Magisk 模块包。

规矩（踩过的坑，改之前先看 README「真机实测」那张表）：
- 条目一律正斜杠。PowerShell 的 Compress-Archive 会写反斜杠，装上目录结构全废。
- .sh 一律 755。Magisk 解压不保留 zip 里的权限，但 755 + post-fs-data 里的 chmod 双保险。
- 时间戳固定成 1980-01-01，同样的源码打出来字节一致，方便比对。
- webroot/index.html 里的 __BUILD__ 换成 module.prop 的 versionCode。
"""
import os
import re
import sys
import zipfile

ROOT = os.path.dirname(os.path.abspath(__file__))
SRC = os.path.join(os.path.dirname(ROOT), 'netbatt')
FIXED = (1980, 1, 1, 0, 0, 0)


def build_code():
    prop = open(os.path.join(SRC, 'module.prop'), encoding='utf-8').read()
    m = re.search(r'^versionCode=(\d+)', prop, re.M)
    ver = re.search(r'^version=(.+)$', prop, re.M).group(1).strip()
    return int(m.group(1)), ver


def collect():
    items = []
    for base, dirs, files in os.walk(SRC):
        dirs.sort()
        rel = os.path.relpath(base, SRC).replace('\\', '/')
        if rel != '.':
            items.append((rel, None))
        for f in sorted(files):
            p = os.path.join(base, f)
            name = (rel + '/' + f) if rel != '.' else f
            items.append((name, p))
    return items


def main():
    code, ver = build_code()
    out = os.path.join(os.path.dirname(SRC), 'NetBatt-%s.zip' % ver)
    with zipfile.ZipFile(out, 'w', zipfile.ZIP_DEFLATED) as z:
        for name, path in collect():
            if path is None:
                zi = zipfile.ZipInfo(name + '/', FIXED)
                zi.create_system = 3
                zi.external_attr = (0o40755 << 16) | 0x10
                z.writestr(zi, b'')
                continue
            data = open(path, 'rb').read()
            if name.endswith('.sh'):
                data = data.replace(b'\r\n', b'\n')
            if name == 'webroot/index.html':
                data = data.replace(b'__BUILD__', str(code).encode())
            zi = zipfile.ZipInfo(name, FIXED)
            # 必须标成 Unix 建包，否则解包端按 DOS 属性处理、读不到 755
            zi.create_system = 3
            mode = 0o755 if name.endswith('.sh') else 0o644
            zi.external_attr = mode << 16
            zi.compress_type = zipfile.ZIP_DEFLATED
            z.writestr(zi, data)
    print('%s  %d bytes  build=%d' % (out, os.path.getsize(out), code))


if __name__ == '__main__':
    sys.exit(main())
