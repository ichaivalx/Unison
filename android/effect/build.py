#!/usr/bin/env python3
"""生成冻结的 AIDL V2 NDK 绑定，编译并打包 KernelSU 模块。只在 CI 运行。"""
import os
from pathlib import Path
import shutil
import subprocess
import urllib.request
import zipfile
import tarfile
import io
import re

ROOT = Path(__file__).resolve().parent
BUILD = ROOT / 'build'
BUILD.mkdir(exist_ok=True)
TAG = 'android-16.0.0_r1'


def run(*args):
    subprocess.run([str(arg) for arg in args], check=True)


def checkout(repo, name, paths, ref=TAG):
    dest = BUILD / name
    if not dest.exists():
        run('git', 'clone', '--depth=1', '--filter=blob:none', '--sparse', '--branch', ref,
            f'https://github.com/aosp-mirror-neo/{repo}.git', dest)
    run('git', '-C', dest, 'sparse-checkout', 'set', *paths)
    return dest


# 构建方式参考 dungxnd/ViPERFX_RE 的树外 AIDL 构建；不引入其 DSP 或 FMQ shim。
# 固定 V2 冻结接口及其 imports，不能用 current/V3 替代。
groups = [
    ('common/aidl/aidl_api/android.hardware.common/2', 2),
    ('common/fmq/aidl/aidl_api/android.hardware.common.fmq/1', 1),
    ('audio/aidl/aidl_api/android.hardware.audio.common/3', 3),
    ('audio/aidl/aidl_api/android.hardware.audio.effect/2', 2),
]
hardware = checkout('platform_hardware_interfaces', 'hardware', [path for path, _ in groups])
media_path = 'media/aidl_api/android.media.audio.common.types/4'
system = checkout('platform_system_hardware_interfaces', 'system', [media_path])
# SDK 36 的生成器需要新版 defineClass/asBinderReference；这些辅助头不改变 V2 线格式。
native = checkout('platform_frameworks_native', 'native', ['libs/binder/ndk'], 'android-16.0.0_r1')
include = BUILD / 'aidl/include'
src = BUILD / 'aidl/src'
include.mkdir(parents=True, exist_ok=True)
src.mkdir(parents=True, exist_ok=True)
for headers in ('include_ndk', 'include_cpp', 'include_platform'):
    shutil.copytree(native / f'libs/binder/ndk/{headers}/android', include / 'android', dirs_exist_ok=True)

# AOSP Android 16 的平台 libc++（clang-r547379），不是 NDK 的 __ndk1 运行库。
# 官方编译产物仅作链接及符号参考，不进入模块；收到设备库后还需逐符号交叉核对。
clang_revision = 'ad834e67b1105d15ef907f6255d4c96e8e733f57'
clang_base = 'https://android.googlesource.com/platform/prebuilts/clang/host/linux-x86'
platform_cpp = BUILD / 'platform-cxx'
for remote, local in (
    ('clang-r547379/include/c++/v1', 'include'),
    ('clang-r547379/android_libc++/platform/aarch64/include/c++/v1', 'config'),
    ('clang-r547379/android_libc++/platform/aarch64/lib', 'lib'),
):
    dest = platform_cpp / local
    dest.mkdir(parents=True, exist_ok=True)
    url = f'{clang_base}/+archive/{clang_revision}/{remote}.tar.gz'
    with urllib.request.urlopen(url, timeout=90) as response:
        with tarfile.open(fileobj=io.BytesIO(response.read()), mode='r:gz') as archive:
            # 通用头的 __config_site 指向宿主配置；只使用单独下载的平台配置。
            members = [m for m in archive.getmembers() if not m.issym() and not m.islnk()]
            archive.extractall(dest, members=members, filter='data')
assert (platform_cpp / 'lib/libc++.so').read_bytes().startswith(b'\x7fELF')
assert (platform_cpp / 'config/__config_site').is_file()

# NDK 的公开链接桩缺少平台专用 C 入口；从 AOSP 导出表生成 link-only vendor 桩。
# 不伪造任何 C++ 运行库符号；完整实现与符号由实际平台 libc++ 提供。
binder_map = (native / 'libs/binder/ndk/libbinder_ndk.map.txt').read_text()
exports = re.findall(r'^\s*(A[A-Za-z0-9_]+)\s*;', binder_map, re.M)
(BUILD / 'binder_stub.c').write_text('\n'.join(f'void {name}(void) {{ __builtin_trap(); }}' for name in exports))
roots = [(hardware / path, version) for path, version in groups] + [(system / media_path, 4)]
sdk = Path(os.environ['ANDROID_HOME'])
aidls = sorted(sdk.glob('build-tools/*/aidl'), key=lambda p: tuple(int(x) for x in p.parent.name.split('.') if x.isdigit()))
if not aidls:
    raise RuntimeError('SDK build-tools 中缺少 aidl')
for path, version in roots:
    frozen_hash = (path / '.hash').read_text().strip().splitlines()[-1]
    for aidl in sorted(path.rglob('*.aidl')):
        run(aidls[-1], '--lang=ndk', '--structured', '--stability=vintf', '--min_sdk_version=35',
            f'--version={version}', f'--hash={frozen_hash}', *[f'-I{root}' for root, _ in roots],
            f'-o{src}', f'--header_out={include}', aidl)
ndk = sdk / 'ndk/30.0.16248370'
cmake = sdk / 'cmake/4.1.2/bin/cmake'
run(cmake, '-S', ROOT, '-B', BUILD / 'native-build', '-G', 'Ninja',
    f'-DCMAKE_TOOLCHAIN_FILE={ndk}/build/cmake/android.toolchain.cmake',
    '-DANDROID_ABI=arm64-v8a', '-DANDROID_PLATFORM=android-35', '-DANDROID_STL=none',
    '-DCMAKE_BUILD_TYPE=Release')
command = [str(cmake), '--build', str(BUILD / 'native-build'), '--parallel', '4']
build_result = subprocess.run(command, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
print(build_result.stdout, flush=True)
(BUILD / 'abi-vtables.txt').write_text(build_result.stdout)
build_result.check_returncode()
vtable = re.search(r"Vtable for 'UnisonEffect' \(19 entries\)\.(.*?)\n\n", build_result.stdout, re.S)
if not vtable:
    raise RuntimeError('缺少完整平台 UnisonEffect vtable 布局')
for slot, method in ((7, 'handleShellCommand'), (8, 'UnisonEffect::open'), (15, 'UnisonEffect::reopen'),
                     (16, 'getInterfaceVersion'), (17, 'getInterfaceHash'), (18, 'createBinder')):
    if not re.search(rf'\n\s*{slot}\s*\|[^\n]*{re.escape(method)}', vtable.group(1)):
        raise RuntimeError(f'平台 vtable 槽位不匹配: {slot} {method}')
print('PLATFORM VTABLE VERIFIED:' + vtable.group(1), flush=True)
toolchain = ndk / 'toolchains/llvm/prebuilt/linux-x86_64'
run('python3', ROOT / 'verify_abi.py', '--plugin', BUILD / 'native-build/libunison_tap.so',
    '--providers', BUILD / 'native-build', '--providers', platform_cpp / 'lib',
    '--providers', toolchain / 'sysroot/usr/lib/aarch64-linux-android/35',
    '--nm', toolchain / 'bin/llvm-nm')

module = ROOT.parent / 'ksu-module'
for script in sorted(module.glob('*.sh')):
    run('sh', '-n', script)
out = BUILD / 'unison-tap-ksu.zip'
with urllib.request.urlopen('https://www.apache.org/licenses/LICENSE-2.0.txt') as response:
    license_text = response.read()
with zipfile.ZipFile(out, 'w', zipfile.ZIP_DEFLATED) as archive:
    for path in sorted(module.rglob('*')):
        if path.is_file():
            info = zipfile.ZipInfo(path.relative_to(module).as_posix())
            info.external_attr = (0o100755 if path.suffix == '.sh' else 0o100644) << 16
            archive.writestr(info, path.read_bytes().replace(b'\r\n', b'\n'))
    archive.write(BUILD / 'native-build/libunison_tap.so', 'lib64/soundfx/libunison_tap.so')
    watcher = zipfile.ZipInfo('bin/unison_hal_watch')
    watcher.external_attr = 0o100755 << 16
    archive.writestr(watcher, (BUILD / 'native-build/unison_hal_watch').read_bytes())
    archive.writestr('LICENSE', license_text)
print(out)
