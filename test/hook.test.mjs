import assert from 'node:assert/strict';
import { randomBytes } from 'node:crypto';
import { spawn, spawnSync } from 'node:child_process';
import { mkdtemp, readFile, rm, writeFile } from 'node:fs/promises';
import http from 'node:http';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import test from 'node:test';

const testToken = randomBytes(16).toString('hex');
const root = fileURLToPath(new URL('../', import.meta.url));
const sender = path.join(root, 'plugin/scripts/send-notification.mjs');

async function temporaryConfig(t, value) {
  const directory = await mkdtemp(path.join(os.tmpdir(), 'mac-notify-hook-'));
  t.after(() => rm(directory, { recursive: true, force: true }));
  const filename = path.join(directory, 'sender.json');
  if (value !== undefined) await writeFile(filename, JSON.stringify(value));
  return filename;
}

async function listen(t, handler) {
  const server = http.createServer(handler);
  await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
  t.after(() => {
    server.closeAllConnections();
    return new Promise(resolve => server.close(resolve));
  });
  return `http://127.0.0.1:${server.address().port}/notify`;
}

function runSender(config, payload = {}) {
  return new Promise((resolve, reject) => {
    const started = performance.now();
    const child = spawn(process.execPath, [sender], {
      env: { ...process.env, MAC_NOTIFY_CONFIG: config },
      stdio: ['pipe', 'pipe', 'pipe'],
    });
    let stdout = '';
    let stderr = '';
    child.stdout.setEncoding('utf8').on('data', chunk => { stdout += chunk; });
    child.stderr.setEncoding('utf8').on('data', chunk => { stderr += chunk; });
    child.on('error', reject);
    child.on('close', (code, signal) => resolve({ code, signal, stdout, stderr, elapsed: performance.now() - started }));
    child.stdin.on('error', () => {});
    child.stdin.end(JSON.stringify(payload));
  });
}

test('Stop hook sends authenticated fixed text without conversation contents', async t => {
  const requests = [];
  const url = await listen(t, async (request, response) => {
    let body = '';
    for await (const chunk of request) body += chunk;
    requests.push({ method: request.method, url: request.url, headers: request.headers, body });
    response.writeHead(202).end('{}');
  });
  const config = await temporaryConfig(t, { url, token: testToken });
  for (const stop_hook_active of [false, true]) {
    const result = await runSender(config, {
      hook_event_name: 'Stop', stop_hook_active,
      cwd: '/private/private-project-name',
      last_assistant_message: 'PRIVATE-CHAT-CONTENT',
      transcript_path: '/private/transcript.jsonl',
    });
    assert.equal(result.code, 0);
    assert.equal(result.stdout, '');
    assert.equal(result.stderr, '');
  }
  assert.equal(requests.length, 2);
  for (const request of requests) {
    assert.equal(request.method, 'POST');
    assert.equal(request.url, '/notify');
    assert.equal(request.headers.authorization, `Bearer ${testToken}`);
    assert.equal(request.headers['content-type'], 'application/json');
    assert.deepEqual(JSON.parse(request.body), { title: 'Codex 回复完成', message: '一轮回复已结束，可以回来看看了。' });
    assert.doesNotMatch(request.body, /PRIVATE-CHAT|private-project|transcript/);
  }
});

test('unresponsive receiver cannot delay the hook past its short deadline or trigger retries', async t => {
  let requests = 0;
  const url = await listen(t, request => { requests += 1; request.resume(); });
  const config = await temporaryConfig(t, { url: `${url}?private-query`, token: testToken });
  const result = await runSender(config);
  assert.equal(result.code, 0);
  assert.equal(result.stdout, '');
  assert.ok(result.elapsed < 2800, `hook took ${result.elapsed} ms`);
  assert.equal(requests, 1);
  assert.ok(!result.stderr.includes(testToken));
  assert.doesNotMatch(result.stderr, /private-query|127\.0\.0\.1/);
});

test('missing configuration is a quiet no-op', async t => {
  const config = await temporaryConfig(t);
  const result = await runSender(config);
  assert.equal(result.code, 0);
  assert.equal(result.stdout, '');
  assert.equal(result.stderr, '');
});

test('invalid configuration and connection refusal remain nonblocking and hide secrets', async t => {
  for (const value of [null, { url: 'file:///private-query', token: testToken }, { url: 'http://127.0.0.1:1/notify?private-query', token: testToken }]) {
    const config = await temporaryConfig(t, value);
    const result = await runSender(config);
    assert.equal(result.code, 0);
    assert.equal(result.stdout, '');
    assert.ok(!result.stderr.includes(testToken));
    assert.doesNotMatch(result.stderr, /private-query|127\.0\.0\.1/);
    assert.ok(result.elapsed < 2800);
  }
});

test('plugin uses an install-relative background Stop hook', async () => {
  const manifest = JSON.parse(await readFile(path.join(root, 'plugin/.codex-plugin/plugin.json'), 'utf8'));
  const hooks = JSON.parse(await readFile(path.join(root, 'plugin', manifest.hooks), 'utf8'));
  const hook = hooks.hooks.Stop[0].hooks[0];
  assert.equal(hook.type, 'command');
  assert.equal(hook.async, true);
  assert.ok(hook.timeout <= 3);
  assert.match(hook.command, /\$PLUGIN_ROOT\/scripts\/run-hook\.sh/);
  assert.doesNotMatch(hook.command, /\/Users\//);
  const marketplace = JSON.parse(await readFile(path.join(root, 'plugin/.agents/plugins/marketplace.json'), 'utf8'));
  assert.equal(marketplace.plugins[0].name, manifest.name);
  assert.equal(marketplace.plugins[0].source.path, './');
});

test('Hook 启动器正确传递带空格的插件目录', async t => {
  const directory = await mkdtemp(path.join(os.tmpdir(), 'mac-notify-runtime-'));
  t.after(() => rm(directory, { recursive: true, force: true }));
  const captured = path.join(directory, 'args');
  await writeFile(path.join(directory, 'node'), '#!/bin/sh\nprintf \'%s\' "$1" > "$CAPTURED"\n', { mode: 0o755 });
  const result = spawnSync('/bin/sh', [path.join(root, 'plugin/scripts/run-hook.sh')], {
    env: { PATH: directory, PLUGIN_ROOT: '/plugin with spaces', CAPTURED: captured },
  });
  assert.equal(result.status, 0);
  assert.equal(await readFile(captured, 'utf8'), '/plugin with spaces/scripts/send-notification.mjs');
});
