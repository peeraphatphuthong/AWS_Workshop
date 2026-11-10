import { test } from 'node:test';
import assert from 'node:assert/strict';
import { cached } from '../src/cache.js';

test('concurrent callers share one in-flight call', async () => {
  let calls = 0;
  const get = cached(async () => {
    calls += 1;
    await new Promise((resolve) => setTimeout(resolve, 20));
    return calls;
  }, 1000);
  const results = await Promise.all([get(), get(), get(), get()]);
  assert.deepEqual(results, [1, 1, 1, 1]);
  assert.equal(calls, 1);
});

test('value is reused until the TTL expires', async () => {
  let t = 0;
  let calls = 0;
  const get = cached(async () => ++calls, 5000, () => t);
  assert.equal(await get(), 1);
  t = 4999;
  assert.equal(await get(), 1);
  t = 5000;
  assert.equal(await get(), 2);
});

test('ttl 0 refreshes on every sequential call', async () => {
  let calls = 0;
  const get = cached(async () => ++calls, 0);
  assert.equal(await get(), 1);
  assert.equal(await get(), 2);
});

test('errors are not cached', async () => {
  let calls = 0;
  const get = cached(async () => {
    calls += 1;
    if (calls === 1) throw new Error('boom');
    return 'ok';
  }, 1000);
  await assert.rejects(get(), /boom/);
  assert.equal(await get(), 'ok');
});
