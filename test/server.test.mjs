import assert from 'node:assert/strict';
import { randomBytes } from 'node:crypto';
import { once } from 'node:events';
import { mkdtemp, readFile, rm, stat, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { get, request } from 'node:http';
import { createServer } from 'node:net';
import { spawn } from 'node:child_process';
import { join } from 'node:path';
import test from 'node:test';
import { createNotifierServer, loadToken, showNotification } from '../server.mjs';

const testToken = randomBytes(16).toString('hex');

test('设置页使用真实 PNG 图标，图标仍限制本机访问', async t => {
  const { url } = await fixture(t);
  const response = await fetch(`${url}/app-icon.png`);
  assert.equal(response.status, 200);
  assert.match(response.headers.get('content-type'), /^image\/png/);
  const png = Buffer.from(await response.arrayBuffer());
  assert.equal(png.subarray(0, 8).toString('hex'), '89504e470d0a1a0a');
  assert.match(await (await fetch(url)).text(), /<img[^>]+src="\/app-icon.png"/);
  assert.equal((await fetch(`${url}/app-icon.png`, { headers: { Origin: 'https://evil.example' } })).status, 403);
});

async function fixture(t, notify = async () => {}, configDirectory) {
  const server = createNotifierServer({ token: testToken, notify, configDirectory });
  server.listen(0, '127.0.0.1');
  await once(server, 'listening');
  t.after(() => new Promise(resolve => { server.close(resolve); server.closeAllConnections(); }));
  const url = `http://127.0.0.1:${server.address().port}`;
  const post = (body, headers = {}) => fetch(`${url}/notify`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json', Authorization: `Bearer ${testToken}`, ...headers },
    body: typeof body === 'string' ? body : JSON.stringify(body),
  });
  return { url, post };
}

test('本机连接 Hook 需要鉴权，保存私有配置且不覆盖其他接收端', async t => {
  const directory = await mkdtemp(join(tmpdir(), 'mac-notify-connect-'));
  t.after(() => rm(directory, { recursive: true, force: true }));
  const { url } = await fixture(t, undefined, directory);
  const connect = headers => fetch(`${url}/api/connect`, { method: 'POST', headers });
  assert.equal((await connect({})).status, 401);
  const headers = { Authorization: `Bearer ${testToken}` };
  assert.equal((await connect({ ...headers, Origin: 'https://evil.example' })).status, 403);
  assert.equal((await connect(headers)).status, 200);
  assert.deepEqual(JSON.parse(await readFile(join(directory, 'sender.json'), 'utf8')), {
    url: `${url}/notify`, token: testToken,
  });
  assert.equal((await stat(join(directory, 'sender.json'))).mode & 0o777, 0o600);
  assert.equal((await connect(headers)).status, 200);
  await writeFile(join(directory, 'sender.json'), '{"url":"http://other-device/notify","token":"other"}');
  assert.equal((await connect(headers)).status, 409);
  assert.match(await readFile(join(directory, 'sender.json'), 'utf8'), /other-device/);
});

test('原生通知桥接只传递参数，不把通知内容作为源码', async t => {
  const directory = await mkdtemp(join(tmpdir(), 'mac-notify-native-'));
  const helper = join(directory, 'native-helper');
  const filename = join(directory, 'args');
  await writeFile(helper, '#!/bin/sh\nprintf \'%s\\0\' "$@" > "$MAC_NOTIFY_TEST_ARGS"\n', { mode: 0o755 });
  const oldApp = process.env.MAC_NOTIFY_APP;
  const oldArgs = process.env.MAC_NOTIFY_TEST_ARGS;
  t.after(async () => {
    if (oldApp === undefined) delete process.env.MAC_NOTIFY_APP; else process.env.MAC_NOTIFY_APP = oldApp;
    if (oldArgs === undefined) delete process.env.MAC_NOTIFY_TEST_ARGS; else process.env.MAC_NOTIFY_TEST_ARGS = oldArgs;
    await rm(directory, { recursive: true, force: true });
  });
  process.env.MAC_NOTIFY_APP = helper;
  process.env.MAC_NOTIFY_TEST_ARGS = filename;
  await showNotification({ title: '完成 "标题"', message: '中文\n$(never-run)' });
  assert.deepEqual((await readFile(filename, 'utf8')).split('\0'), ['--notify', '完成 "标题"', '中文\n$(never-run)', '']);
});

test('正确密钥提交原样文字；不把文本当脚本执行', async t => {
  const calls = [];
  const { post } = await fixture(t, async data => calls.push(data));
  const message = { title: '完成 "标题"', message: 'hello\\world\n$(touch /tmp/never-run)' };
  const response = await post(message);
  assert.equal(response.status, 202);
  assert.deepEqual(calls, [message]);
});

test('无密钥、错误密钥、非法输入不会触发通知', async t => {
  let calls = 0;
  const { post } = await fixture(t, async () => calls++);
  assert.equal((await post({}, { Authorization: '' })).status, 401);
  assert.equal((await post({}, { Authorization: 'Bearer wrong' })).status, 401);
  for (const body of ['{', 'null', '[]', '{}', { title: '', message: 'x' },
    { title: 'x', message: 1 }, { title: 'x'.repeat(121), message: 'x' },
    { title: 'x', message: 'x'.repeat(1001) }]) {
    assert.equal((await post(body)).status, 400);
  }
  assert.equal((await post({ title: 'x', message: 'x' }, { 'Content-Type': 'text/plain' })).status, 415);
  assert.equal((await post('x'.repeat(8193))).status, 413);
  assert.equal(calls, 0);
});

test('系统通知失败返回可见错误，不暴露内部异常', async t => {
  const { post } = await fixture(t, async () => { throw new Error('private details'); });
  const response = await post({ title: 'x', message: 'y' });
  assert.equal(response.status, 503);
  assert.doesNotMatch(await response.text(), /private details/);
});

test('本地测试页能取配置；跨站或伪造 Host 取不到密钥', async t => {
  const { url } = await fixture(t);
  const page = await fetch(url);
  assert.equal(page.status, 200);
  assert.match(await page.text(), /通知/);
  assert.match(page.headers.get('content-security-policy'), /frame-ancestors 'none'/);
  const config = await (await fetch(`${url}/api/config`)).json();
  assert.equal(config.token, testToken);
  assert.match(config.endpoint, /^http:\/\/[\d.]+:\d+\/notify$/);
  assert.equal((await fetch(`${url}/api/config`, { headers: { Origin: 'https://evil.example' } })).status, 403);
  const wrongHost = await new Promise(resolve => {
    get(`${url}/api/config`, { headers: { Host: 'evil.example' } }, response => {
      response.resume(); resolve(response.statusCode);
    });
  });
  assert.equal(wrongHost, 403);
  assert.equal((await fetch(`${url}/api/config`, { headers: { 'Sec-Fetch-Site': 'cross-site' } })).status, 403);
  assert.deepEqual(await (await fetch(`${url}/health`)).json(), { ok: true });
  assert.equal((await fetch(`${url}/missing`)).status, 404);
});

test('分段到达的中文 UTF-8 正文不损坏', async t => {
  const calls = [];
  const { url } = await fixture(t, async data => calls.push(data));
  const body = Buffer.from(JSON.stringify({ title: '任务完成', message: '中文正文' }));
  await new Promise((resolve, reject) => {
    const req = request(`${url}/notify`, { method: 'POST', headers: {
      'Content-Type': 'application/json', Authorization: `Bearer ${testToken}`,
    } }, response => {
      response.resume();
      response.on('end', resolve);
    });
    req.on('error', reject);
    const split = body.indexOf(Buffer.from('中文')) + 1;
    req.write(body.subarray(0, split));
    setTimeout(() => req.end(body.subarray(split)), 5);
  });
  assert.deepEqual(calls, [{ title: '任务完成', message: '中文正文' }]);
});

test('接收密钥持久化且仅当前用户可读；损坏配置不被覆盖', async t => {
  const directory = await mkdtemp(join(tmpdir(), 'mac-notify-'));
  t.after(() => rm(directory, { recursive: true, force: true }));
  const first = await loadToken(directory);
  assert.match(first, /^[a-f0-9]{64}$/);
  assert.equal(await loadToken(directory), first);
  assert.equal((await stat(join(directory, 'receiver.json'))).mode & 0o777, 0o600);
  await writeFile(join(directory, 'receiver.json'), '{broken');
  await assert.rejects(loadToken(directory));
  assert.equal(await readFile(join(directory, 'receiver.json'), 'utf8'), '{broken');
});

test('命令行能启动服务并在退出时释放端口', async t => {
  const directory = await mkdtemp(join(tmpdir(), 'mac-notify-cli-'));
  const reservation = createServer();
  reservation.listen(0, '127.0.0.1');
  await once(reservation, 'listening');
  const port = reservation.address().port;
  await new Promise(resolve => reservation.close(resolve));
  const child = spawn(process.execPath, ['server.mjs'], {
    cwd: new URL('..', import.meta.url),
    env: { ...process.env, MAC_NOTIFY_PORT: String(port), MAC_NOTIFY_CONFIG_DIR: directory },
    stdio: ['ignore', 'pipe', 'pipe'],
  });
  t.after(async () => { child.kill(); await rm(directory, { recursive: true, force: true }); });
  await once(child.stdout, 'data');
  assert.deepEqual(await (await fetch(`http://127.0.0.1:${port}/health`)).json(), { ok: true });
  const closed = once(child, 'close');
  child.kill('SIGTERM');
  assert.equal((await closed)[0], 0);
});
