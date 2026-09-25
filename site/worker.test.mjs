import assert from 'node:assert/strict';
import { test } from 'node:test';
import worker from './worker.mjs';

const env = {
  ASSETS: {
    fetch: async (request) => new Response(`asset:${new URL(request.url).pathname}`, { status: 200 }),
  },
};

test('serves /download on context.daddyrad.com', async () => {
  for (const method of ['GET', 'HEAD']) {
    const response = await worker.fetch(new Request(`https://context.daddyrad.com/download`, { method }), env);
    assert.equal(response.status, 200, method);
    assert.equal(response.headers.get('Content-Type'), 'application/x-apple-diskimage');
    assert.match(response.headers.get('Content-Disposition') ?? '', /ContextDaddy-0\.1\.0-2-arm64\.dmg/);
    assert.equal(response.headers.get('X-Content-Type-Options'), 'nosniff');
  }
});

test('proxies non-download paths to the Pages landing', async () => {
  const original = globalThis.fetch;
  let requested;
  globalThis.fetch = async (input) => { requested = input.url; return new Response('landing', { status: 200 }); };
  try {
    const response = await worker.fetch(new Request('https://context.daddyrad.com/release/?a=1'), env);
    assert.equal(response.status, 200);
    assert.equal(requested, 'https://contextdaddy-landing.pages.dev/release/?a=1');
  } finally {
    globalThis.fetch = original;
  }
});

test('unknown hosts 404', async () => {
  const other = await worker.fetch(new Request('https://example.com/download'), env);
  assert.equal(other.status, 404);
});

test('rejects non-read methods', async () => {
  const response = await worker.fetch(new Request('https://context.daddyrad.com/download', { method: 'POST' }), env);
  assert.equal(response.status, 405);
});
