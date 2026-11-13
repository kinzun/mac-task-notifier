import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import test from 'node:test';

test('仓库根 marketplace 能定位实际插件并保持版本一致', async () => {
  const root = new URL('../', import.meta.url);
  const marketplace = JSON.parse(await readFile(new URL('.agents/plugins/marketplace.json', root)));
  const entry = marketplace.plugins[0];
  const manifest = JSON.parse(await readFile(new URL(`${entry.source.path}/.codex-plugin/plugin.json`, root)));
  const pkg = JSON.parse(await readFile(new URL('package.json', root)));
  assert.equal(marketplace.name, 'mac-task-notifier');
  assert.equal(entry.name, manifest.name);
  assert.equal(entry.version, manifest.version);
  assert.equal(manifest.version, pkg.version);
});
