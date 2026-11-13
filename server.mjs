import { execFile } from 'node:child_process';
import { randomBytes, timingSafeEqual } from 'node:crypto';
import { readFile, mkdir, writeFile } from 'node:fs/promises';
import { createServer } from 'node:http';
import { homedir, networkInterfaces } from 'node:os';
import { join } from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';
import { promisify } from 'node:util';

const runFile = promisify(execFile);
const directory = fileURLToPath(new URL('.', import.meta.url));
const script = join(directory, 'notification.applescript');

export async function loadToken(configDirectory) {
  await mkdir(configDirectory, { recursive: true, mode: 0o700 });
  const file = join(configDirectory, 'receiver.json');
  try {
    const { token } = JSON.parse(await readFile(file, 'utf8'));
    if (!/^[a-f0-9]{64}$/.test(token)) throw new Error('接收配置中的密钥无效');
    return token;
  } catch (error) {
    if (error.code !== 'ENOENT') throw error;
    const token = randomBytes(32).toString('hex');
    await writeFile(file, JSON.stringify({ token }, null, 2), { mode: 0o600, flag: 'wx' });
    return token;
  }
}

export async function showNotification({ title, message }) {
  if (process.env.MAC_NOTIFY_APP) {
    await runFile(process.env.MAC_NOTIFY_APP, ['--notify', title, message], { timeout: 5000 });
    return;
  }
  // 文字作为参数传入固定脚本，永远不拼进 AppleScript 源码。
  await runFile('/usr/bin/osascript', [script, title, message], { timeout: 5000 });
}

function readBody(request) {
  return new Promise((resolve, reject) => {
    const chunks = [];
    let bytes = 0;
    request.on('data', chunk => {
      bytes += chunk.length;
      if (bytes > 8192) { reject(Object.assign(new Error(), { status: 413 })); return; }
      chunks.push(chunk);
    });
    request.on('end', () => resolve(Buffer.concat(chunks).toString('utf8')));
    request.on('error', reject);
  });
}

function lanAddress() {
  return Object.entries(networkInterfaces())
    .filter(([name]) => !/^(utun|tun|lo)/.test(name))
    .flatMap(([, addresses]) => addresses)
    .find(address => address.family === 'IPv4' && !address.internal &&
      /^(10\.|192\.168\.|172\.(1[6-9]|2\d|3[01])\.)/.test(address.address))?.address || '127.0.0.1';
}

export function createNotifierServer({ token, notify = showNotification, configDirectory }) {
  const server = createServer(async (request, response) => {
    response.setHeader('Cache-Control', 'no-store');
    response.setHeader('X-Content-Type-Options', 'nosniff');
    const send = (status, value) => {
      response.writeHead(status, { 'Content-Type': 'application/json; charset=utf-8' });
      response.end(JSON.stringify(value));
    };
    if (request.method === 'GET' && request.url === '/health') return send(200, { ok: true });
    if ((request.method === 'GET' && ['/', '/api/config'].includes(request.url)) ||
      (request.method === 'POST' && request.url === '/api/connect')) {
      const local = ['127.0.0.1', '::1', '::ffff:127.0.0.1'].includes(request.socket.remoteAddress);
      const host = request.headers.host;
      const allowedHost = ['127.0.0.1', 'localhost', '[::1]'].some(name => host === `${name}:${server.address().port}`);
      if (!local || !allowedHost || request.headers['sec-fetch-site'] === 'cross-site' ||
        (request.headers.origin && request.headers.origin !== `http://${host}`)) {
        return send(403, { error: '设置页只允许本机访问' });
      }
      if (request.url === '/api/config') {
        return send(200, { endpoint: `http://${lanAddress()}:${server.address().port}/notify`, token });
      }
      if (request.url === '/api/connect') {
        if (request.headers.authorization !== `Bearer ${token}`) return send(401, { error: '密钥无效' });
        if (!configDirectory) return send(503, { error: '未设置配置目录' });
        const config = { url: `http://127.0.0.1:${server.address().port}/notify`, token };
        const filename = join(configDirectory, 'sender.json');
        try {
          await writeFile(filename, JSON.stringify(config, null, 2), { mode: 0o600, flag: 'wx' });
        } catch (error) {
          if (error.code !== 'EEXIST') return send(503, { error: '无法保存发送配置' });
          let previous;
          try { previous = JSON.parse(await readFile(filename, 'utf8')); } catch { /* 保留损坏的用户配置。 */ }
          if (previous?.url !== config.url || previous?.token !== token) {
            return send(409, { error: '已有不同的发送配置，请先备份 sender.json，再更换接收端' });
          }
        }
        return send(200, { ok: true });
      }
      try {
        const html = await readFile(join(directory, 'public/index.html'));
        response.writeHead(200, {
          'Content-Type': 'text/html; charset=utf-8',
          'Content-Security-Policy': "default-src 'self'; script-src 'unsafe-inline'; style-src 'unsafe-inline'; connect-src 'self'; frame-ancestors 'none'; base-uri 'none'",
        });
        return response.end(html);
      } catch { return send(500, { error: '无法读取测试页' }); }
    }
    if (request.method !== 'POST' || request.url !== '/notify') return send(404, { error: '地址不存在' });
    const supplied = Buffer.from(request.headers.authorization || '');
    const expected = Buffer.from(`Bearer ${token}`);
    if (supplied.length !== expected.length || !timingSafeEqual(supplied, expected)) {
      request.resume();
      return send(401, { error: '密钥无效' });
    }
    if (!/^application\/json(?:\s*;|$)/i.test(request.headers['content-type'] || '') ||
      (request.headers['content-encoding'] && request.headers['content-encoding'] !== 'identity')) {
      request.resume();
      return send(415, { error: '请发送未压缩的 JSON' });
    }
    try {
      const body = await readBody(request);
      let data;
      try { data = JSON.parse(body); } catch { return send(400, { error: 'JSON 格式无效' }); }
      if (!data || Array.isArray(data) || typeof data.title !== 'string' || !data.title.trim() ||
        data.title.length > 120 || typeof data.message !== 'string' || !data.message.trim() ||
        data.message.length > 1000 || /\0/.test(data.title + data.message)) {
        return send(400, { error: '标题须为 1–120 字符，正文须为 1–1000 字符' });
      }
      await notify({ title: data.title, message: data.message });
      return send(202, { ok: true });
    } catch (error) {
      return send(error.status === 413 ? 413 : 503, {
        error: error.status === 413 ? '请求体不能超过 8 KiB' : '无法提交系统通知，请检查 Mac 通知设置',
      });
    }
  });
  server.requestTimeout = 5000;
  server.headersTimeout = 5000;
  server.setTimeout(10000, socket => socket.destroy());
  return server;
}

if (process.argv[1] && pathToFileURL(process.argv[1]).href === import.meta.url) {
  const port = Number(process.env.MAC_NOTIFY_PORT || 8765);
  if (!Number.isInteger(port) || port < 1 || port > 65535) throw new Error('端口须在 1–65535 之间');
  const configDirectory = process.env.MAC_NOTIFY_CONFIG_DIR || join(homedir(), '.config/mac-task-notifier');
  const token = await loadToken(configDirectory);
  const server = createNotifierServer({ token, configDirectory });
  server.on('error', error => { console.error(`启动失败：${error.code || '未知错误'}`); process.exitCode = 1; });
  server.listen(port, '0.0.0.0', () => console.log(`本地测试页：http://127.0.0.1:${port}\n保持此进程运行即可接收通知。`));
  for (const signal of ['SIGINT', 'SIGTERM']) process.on(signal, () => { server.close(); server.closeAllConnections(); });
}
