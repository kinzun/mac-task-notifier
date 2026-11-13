import json
import subprocess
from urllib.request import urlopen

processes = [line.split(maxsplit=2) for line in subprocess.check_output(
    ['ps', '-axo', 'pid=,ppid=,command='], text=True).splitlines()]
apps = [row for row in processes if len(row) == 3 and row[2].endswith(
    '/Mac 任务通知.app/Contents/MacOS/MacTaskNotifier')]
assert len(apps) == 1, f'期望仅一个应用实例，实际 {len(apps)} 个'
listener = subprocess.check_output(
    ['lsof', '-t', '-iTCP:8765', '-sTCP:LISTEN'], text=True).strip()
assert any(row[0] == listener and row[1] == apps[0][0] for row in processes), '端口必须归当前应用的子服务所有'
with urlopen('http://127.0.0.1:8765/health', timeout=2) as response:
    assert json.load(response) == {'ok': True}
print('运行检查通过：仅一个应用实例，接收子服务归属正确，健康检查正常。')
