#!/usr/bin/env python3
"""检查真实 ELF 导出/导入；同一入口也供收到设备库后做本机只读核对。"""
import argparse
from pathlib import Path
import re
import struct
import subprocess


class Elf:
    def __init__(self, path):
        self.path = Path(path)
        self.data = self.path.read_bytes()
        if self.data[:6] != b'\x7fELF\x02\x01':
            raise ValueError(f'Not ELF64 little-endian: {path}')
        start = struct.unpack_from('<Q', self.data, 40)[0]
        size, count, names = struct.unpack_from('<HHH', self.data, 58)
        self.sections = [struct.unpack_from('<IIQQQQIIQQ', self.data, start + i * size) for i in range(count)]
        strings = self.raw(self.sections[names])
        self.named = {self.text(strings, s[0]): s for s in self.sections}

    def raw(self, section):
        return self.data[section[4]:section[4] + section[5]]

    @staticmethod
    def text(data, offset):
        return data[offset:data.index(b'\0', offset)].decode()

    def symbols(self, dynamic=True):
        for s in self.sections:
            if s[1] != (11 if dynamic else 2):
                continue
            strings = self.raw(self.sections[s[6]])
            for offset in range(s[4], s[4] + s[5], s[9]):
                name, info, other, index, value, size = struct.unpack_from('<IBBHQQ', self.data, offset)
                if name:
                    yield self.text(strings, name), info, other, index, value, size


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--plugin', required=True, type=Path)
    parser.add_argument('--providers', action='append', type=Path, required=True)
    parser.add_argument('--nm', type=Path)
    args = parser.parse_args()
    plugin = Elf(args.plugin)
    undefined = {s[0] for s in plugin.symbols() if not s[3] and s[1] >> 4 in (1, 2)}
    if any('__ndk1' in name for name in undefined):
        raise SystemExit('ERROR: NDK C++ ABI remains in plugin imports')
    providers = {}
    for root in args.providers:
        for path in sorted(root.rglob('*.so')):
            try:
                elf = Elf(path)
            except ValueError:
                continue
            for name, info, other, index, _, _ in elf.symbols():
                if index and info >> 4 in (1, 2) and other & 3 in (0, 3):
                    providers.setdefault(name.split('@')[0], set()).add(path.name)
    missing = []
    for name in sorted(undefined):
        found = providers.get(name.split('@')[0], set())
        print(f'UND {name} => {", ".join(sorted(found)) or "MISSING"}')
        if not found:
            missing.append(name)
        # STL 的运行库入口必须存在于平台 libc++，不能靠 CI AIDL 库偶然导出的模板冒充。
        if re.match(r'_ZN[KVO]?St', name) or re.match(r'_ZT[IVS]NSt', name) or name.startswith(('_Zn', '_Zd')):
            if 'libc++.so' not in found:
                missing.append(f'{name} (not exported by platform libc++)')
    defined = {s[0] for s in plugin.symbols(dynamic=False) if s[3]}
    if any('BnEffect' in name for name in defined):
        missing.append('plugin defines private BnEffect binding')
    if args.nm:
        subprocess.run([args.nm, '--dynamic', '--undefined-only', '--demangle', args.plugin], check=True)
    if missing:
        raise SystemExit('ABI verification failed:\n' + '\n'.join(missing))
    print(f'ABI symbol check passed: {len(undefined)} imports, no __ndk1, all providers found')


if __name__ == '__main__':
    main()
