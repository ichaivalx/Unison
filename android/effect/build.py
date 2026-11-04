#!/usr/bin/env python3
"""生成冻结的 AIDL V2 NDK 绑定，编译并打包 KernelSU 模块。只在 CI 运行。"""
import os
from pathlib import Path
import shutil
import subprocess
import urllib.request
import zipfile

ROOT = Path(__file__).resolve().parent
BUILD = ROOT / 'build'
BUILD.mkdir(exist_ok=True)
TAG = 'android-15.0.0_r1'


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
media_path = 'media/aidl_api/android.media.audio.common.types/3'
system = checkout('platform_system_hardware_interfaces', 'system', [media_path])
# SDK 36 的生成器需要新版 defineClass/asBinderReference；这些辅助头不改变 V2 线格式。
native = checkout('platform_frameworks_native', 'native', ['libs/binder/ndk/include_cpp'], 'android-16.0.0_r1')
include = BUILD / 'aidl/include'
src = BUILD / 'aidl/src'
include.mkdir(parents=True, exist_ok=True)
src.mkdir(parents=True, exist_ok=True)
shutil.copytree(native / 'libs/binder/ndk/include_cpp/android', include / 'android', dirs_exist_ok=True)
roots = [(hardware / path, version) for path, version in groups] + [(system / media_path, 3)]
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
    '-DANDROID_ABI=arm64-v8a', '-DANDROID_PLATFORM=android-35', '-DANDROID_STL=c++_static',
    '-DCMAKE_BUILD_TYPE=Release')
run(cmake, '--build', BUILD / 'native-build', '--parallel', '4')

module = ROOT.parent / 'ksu-module'
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
    archive.writestr('LICENSE', license_text)
print(out)
