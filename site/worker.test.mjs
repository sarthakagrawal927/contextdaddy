import test from 'node:test';
import assert from 'node:assert/strict';
import worker from './worker.mjs';
import release from './release.json' with { type: 'json' };
function env(status = 200) {
  const events = []; const requested = [];
  return { events, requested, DOWNLOADS: { writeDataPoint(point) { events.push(point); } }, ASSETS: { async fetch(request) { requested.push(request.url); return new Response('fixture', { status }); } } };
}
test('download serves exact release with attachment, no query forwarding or client identifiers', async () => {
 const e = env(); const response = await worker.fetch(new Request('https://storagedaddy.significanthobbies.com/download?email=private', { headers: {'CF-Connecting-IP':'127.0.0.1'} }), e);
 assert.equal(response.status,200); assert.match(response.headers.get('content-disposition'), /attachment/);
 assert.equal(new URL(e.requested[0]).pathname,release.path); assert.equal(new URL(e.requested[0]).search,'');
 assert.deepEqual(e.events,[{indexes:['storagedaddy'],blobs:['download_request',release.version],doubles:[1]}]);
});
test('HEAD, range requests and missing downloads are not counted', async () => {
 for (const request of [new Request('https://storagedaddy.significanthobbies.com/download',{method:'HEAD'}), new Request('https://storagedaddy.significanthobbies.com/download',{headers:{Range:'bytes=0-15'}})]) {
  const e=env(); await worker.fetch(request,e); assert.equal(e.events.length,0);
 }
 const e=env(404); const response=await worker.fetch(new Request('https://storagedaddy.significanthobbies.com/download'),e); assert.equal(response.status,404); assert.equal(e.events.length,0);
});
test('root landing and relative assets map to packaged assets without duplicate events', async () => {
 const e=env();
 await worker.fetch(new Request('https://storagedaddy.significanthobbies.com/'),e);
 await worker.fetch(new Request('https://storagedaddy.significanthobbies.com/style.css'),e);
 assert.deepEqual(e.requested.map(u=>new URL(u).pathname),['/storagedaddy/','/storagedaddy/style.css']);
 assert.equal(e.events.length,1); assert.equal(e.events[0].blobs[0],'page_view');
});
test('legacy landing and download links redirect to the corrected domain without counting', async () => {
 for (const [path,target] of [['/storagedaddy','/'],['/storagedaddy/','/'],['/storagedaddy/download','/download'],['/storagedaddy/assets/StorageDaddy.png','/assets/StorageDaddy.png']]) {
  const e=env(); const response=await worker.fetch(new Request('https://significanthobbies.com'+path),e);
  assert.equal(response.status,308); assert.equal(response.headers.get('location'),'https://storagedaddy.significanthobbies.com'+target);
  assert.equal(e.requested.length,0); assert.equal(e.events.length,0);
 }
});
test('unsupported methods and routes never reach assets or analytics', async () => {
 const e=env(); assert.equal((await worker.fetch(new Request('https://storagedaddy.significanthobbies.com/download',{method:'POST'}),e)).status,405);
 assert.equal((await worker.fetch(new Request('https://significanthobbies.com/hub'),e)).status,404); assert.equal(e.requested.length,0); assert.equal(e.events.length,0);
});
test('analytics failure does not break a download', async () => {
 const e=env(); e.DOWNLOADS.writeDataPoint=()=>{throw Error('unavailable')}; assert.equal((await worker.fetch(new Request('https://storagedaddy.significanthobbies.com/download'),e)).status,200);
});

test('updater feed is RSS with bounded caching and does not inflate download metrics', async () => {
 const e=env(); const response=await worker.fetch(new Request('https://storagedaddy.significanthobbies.com/updates/appcast.xml'),e);
 assert.equal(new URL(e.requested[0]).pathname,'/storagedaddy/updates/appcast.xml');
 assert.equal(response.headers.get('content-type'),'application/rss+xml; charset=utf-8');
 assert.equal(response.headers.get('cache-control'),'public, max-age=300');
 assert.equal(e.events.length,0);
});
