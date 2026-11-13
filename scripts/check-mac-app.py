import os
from pathlib import Path
import plistlib
import subprocess
import sys

source = Path(__file__).resolve().parents[1]
app = Path(sys.argv[1]) if len(sys.argv) > 1 else source.parent / 'Mac 任务通知.app'
contents = app / 'Contents'
with (contents / 'Info.plist').open('rb') as file:
    info = plistlib.load(file)
assert info['CFBundlePackageType'] == 'APPL'
assert info['CFBundleIdentifier'] == 'local.mac-task-notifier'
assert info['LSUIElement'] is True
assert os.access(contents / 'MacOS' / info['CFBundleExecutable'], os.X_OK)
resources = contents / 'Resources'
version = subprocess.check_output([resources / 'node', '--version'], text=True).strip()
assert int(version.lstrip('v').split('.')[0]) >= 20
assert (resources / 'LICENSE.node').is_file()
assert (resources / 'LICENSE').is_file()
assert (resources / 'AppIcon.icns').is_file()
for name in ['server.mjs', 'notification.applescript', 'public/index.html']:
    assert (resources / 'service' / name).read_bytes() == (source / name).read_bytes()
assert not list(app.rglob('receiver.json'))
assert not list(app.rglob('sender.json'))
print(f'Mac 应用检查通过：可执行文件、内置 Node {version}、服务资源及密钥排除。')
