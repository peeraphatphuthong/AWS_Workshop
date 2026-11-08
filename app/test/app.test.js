import { test, before, after } from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { createApp } from '../src/app.js';
import { loadConfig } from '../src/config.js';

let server;
let baseUrl;
let dataDir;

before(async () => {
  dataDir = await mkdtemp(path.join(tmpdir(), 'retail-health-'));
  const config = loadConfig({ IMDS_DISABLED: 'true', DATA_DIR: dataDir, GIT_SHA: 'test123' });
  server = createApp(config).listen(0);
  await new Promise((resolve) => server.once('listening', resolve));
  baseUrl = `http://127.0.0.1:${server.address().port}`;
});

after(async () => {
  await new Promise((resolve) => server.close(resolve));
  await rm(dataDir, { recursive: true, force: true });
});

test('GET /healthz returns ok', async () => {
  const res = await fetch(`${baseUrl}/healthz`);
  assert.equal(res.status, 200);
  assert.deepEqual(await res.json(), { status: 'ok' });
});

test('GET /readyz is ready when storage works and DB is not configured', async () => {
  const res = await fetch(`${baseUrl}/readyz`);
  assert.equal(res.status, 200);
  const body = await res.json();
  assert.equal(body.ready, true);
  assert.equal(body.db, 'not_configured');
});

test('GET /api/status reports each check', async () => {
  const res = await fetch(`${baseUrl}/api/status`);
  assert.equal(res.status, 200);
  const body = await res.json();
  assert.equal(body.app.gitSha, 'test123');
  assert.equal(body.ec2.status, 'skipped');
  assert.equal(body.ebs.status, 'ok');
  assert.ok(body.ebs.totalWrites >= 1);
  assert.equal(body.db.status, 'not_configured');
});

test('EBS check appends a line on every call', async () => {
  const first = await (await fetch(`${baseUrl}/api/status`)).json();
  const second = await (await fetch(`${baseUrl}/api/status`)).json();
  assert.equal(second.ebs.totalWrites, first.ebs.totalWrites + 1);
});

test('GET / renders the dashboard HTML', async () => {
  const res = await fetch(`${baseUrl}/`);
  assert.equal(res.status, 200);
  assert.match(res.headers.get('content-type'), /text\/html/);
  const html = await res.text();
  assert.match(html, /Retail Store Health/);
  assert.match(html, /test123/);
});

test('unknown routes return 404 JSON and no X-Powered-By header', async () => {
  const res = await fetch(`${baseUrl}/nope`);
  assert.equal(res.status, 404);
  assert.equal(res.headers.get('x-powered-by'), null);
});
