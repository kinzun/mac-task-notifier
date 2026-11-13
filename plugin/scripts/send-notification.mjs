import { readFile } from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';

setTimeout(() => {
  console.error('mac-task-notifier: 通知发送超时，已跳过。');
  process.exit(0);
}, 2000);

try {
  const filename = process.env.MAC_NOTIFY_CONFIG || path.join(os.homedir(), '.config/mac-task-notifier/sender.json');
  let config;
  try {
    config = JSON.parse(await readFile(filename, 'utf8'));
  } catch (error) {
    if (error.code === 'ENOENT') process.exit(0);
    throw error;
  }
  if (!config || typeof config.url !== 'string' || typeof config.token !== 'string' || !config.token.trim() || /[\r\n]/.test(config.token)) {
    throw new Error('Invalid configuration');
  }
  const endpoint = new URL(config.url);
  if (!['http:', 'https:'].includes(endpoint.protocol) || endpoint.username || endpoint.password) {
    throw new Error('Invalid endpoint');
  }
  const response = await fetch(endpoint, {
    method: 'POST',
    redirect: 'error',
    headers: { 'Content-Type': 'application/json', Authorization: `Bearer ${config.token}` },
    body: JSON.stringify({ title: 'Codex 回复完成', message: '一轮回复已结束，可以回来看看了。' }),
  });
  await response.body?.cancel();
  if (!response.ok) console.error('mac-task-notifier: 接收器未接受通知，已跳过。');
} catch {
  console.error('mac-task-notifier: 无法发送通知，请检查接收器和发送配置。');
} finally {
  process.exit(0);
}
