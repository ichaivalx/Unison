from pathlib import Path
import os
import shutil
import subprocess
import sys

flutter = shutil.which('flutter')
if flutter is None:
    raise RuntimeError('Flutter SDK is not on PATH')
plugin = Path(__file__).resolve().parents[1]
host = Path(os.environ['RUNNER_TEMP']) / 'unison-native-smoke'
subprocess.run([flutter, 'create', '--platforms=windows', '--project-name=unison_native_smoke', str(host)], check=True)
(host / 'pubspec.yaml').write_text(f"""name: unison_native_smoke
publish_to: none
environment:
  sdk: ^3.13.0
dependencies:
  flutter:
    sdk: flutter
  unison_native:
    path: '{plugin.as_posix()}'
""")
shutil.copyfile(plugin / 'tool/smoke_windows.dart', host / 'lib/main.dart')
subprocess.run([flutter, 'pub', 'get'], cwd=host, check=True)
subprocess.run([flutter, 'build', 'windows', '--release'], cwd=host, check=True)
out = plugin / 'build/smoke'
shutil.copytree(host / 'build/windows/x64/runner/Release', out, dirs_exist_ok=True)
subprocess.run([str(out / 'unison_native_smoke.exe')], cwd=out, check=True, timeout=30)
print((out / 'unison_native_smoke.exe.result.json').read_text())
