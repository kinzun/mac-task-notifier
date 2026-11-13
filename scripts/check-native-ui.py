from pathlib import Path
import subprocess
import tempfile

source = Path(__file__).resolve().parents[1]
with tempfile.TemporaryDirectory(prefix='mac-notifier-ui-check-') as temporary:
    for name in ['status-icon', 'notification-mask']:
        executable = Path(temporary) / name
        subprocess.run([
            '/usr/bin/clang', '-fobjc-arc', str(source / 'test' / f'{name}.m'),
            '-framework', 'AppKit', '-o', str(executable),
        ], check=True)
        subprocess.run([str(executable)], check=True)
