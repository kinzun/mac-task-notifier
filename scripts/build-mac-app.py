from pathlib import Path
import platform
import plistlib
import shutil
import subprocess
import sys
import tempfile

source = Path(__file__).resolve().parents[1]
app = source.parent / 'Mac 任务通知.app'
contents = app / 'Contents'
executable = contents / 'MacOS' / 'MacTaskNotifier'
resources = contents / 'Resources'
executable.parent.mkdir(parents=True, exist_ok=True)
(resources / 'service' / 'public').mkdir(parents=True, exist_ok=True)
node = sys.argv[1] if len(sys.argv) > 1 else shutil.which('node')
if not node:
    raise SystemExit('构建需要已有的 Node 20+。')
runtime = resources / 'node'
if runtime.exists():
    runtime.chmod(0o755)
shutil.copy2(node, runtime)
runtime.chmod(0o755)
subprocess.run([str(runtime), '--version'], check=True, stdout=subprocess.DEVNULL)
node_license = Path(node).resolve().parent.parent / 'LICENSE'
if not node_license.is_file():
    raise SystemExit('缺少 Node 原始许可证，不能打包分发。')
shutil.copy2(node_license, resources / 'LICENSE.node')
shutil.copy2(source / 'LICENSE', resources / 'LICENSE')
with tempfile.TemporaryDirectory(prefix='mac-notifier-icon-') as temporary:
    temporary = Path(temporary)
    png = source / 'public/app-icon.png'
    iconset = temporary / 'AppIcon.iconset'
    iconset.mkdir()
    for size in [16, 32, 128, 256, 512]:
        for scale in [1, 2]:
            filename = f'icon_{size}x{size}' + ('@2x' if scale == 2 else '') + '.png'
            subprocess.run(['/usr/bin/sips', '-z', str(size * scale), str(size * scale), str(png), '--out', str(iconset / filename)], check=True, stdout=subprocess.DEVNULL)
    subprocess.run(['/usr/bin/iconutil', '-c', 'icns', str(iconset), '-o', str(resources / 'AppIcon.icns')], check=True)
for name in ['server.mjs', 'notification.applescript', 'public/index.html', 'public/app-icon.png']:
    shutil.copy2(source / name, resources / 'service' / name)
info = {
    'CFBundleIdentifier': 'local.mac-task-notifier',
    'CFBundleName': 'Mac 任务通知',
    'CFBundleDisplayName': 'Mac 任务通知',
    'CFBundleExecutable': 'MacTaskNotifier',
    'CFBundlePackageType': 'APPL',
    'CFBundleShortVersionString': '0.2.4',
    'CFBundleVersion': '8',
    'CFBundleIconFile': 'AppIcon',
    'LSMinimumSystemVersion': '13.0',
    'NSHighResolutionCapable': True,
    'LSUIElement': True,
    'NSAppTransportSecurity': {'NSAllowsLocalNetworking': True},
}
with (contents / 'Info.plist').open('wb') as file:
    plistlib.dump(info, file)
subprocess.run([
    '/usr/bin/clang', '-O2', '-fobjc-arc', '-target', f'{platform.machine()}-apple-macos13.0',
    str(source / 'mac/MacNotifier.m'), '-o', str(executable),
    '-framework', 'AppKit', '-framework', 'WebKit', '-framework', 'UserNotifications',
], check=True)
subprocess.run(['/usr/bin/codesign', '--force', '--sign', '-', str(resources / 'node')], check=True)
subprocess.run(['/usr/bin/codesign', '--force', '--sign', '-', str(app)], check=True)
print(f'已生成可双击的 Mac 应用：{app}')
