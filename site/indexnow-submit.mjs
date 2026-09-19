import { readFile } from 'node:fs/promises';

const KEY = 'bdeaa89dd1f1f7869584f50121c6e7da';
const HOST = 'storagedaddy.significanthobbies.com';
const keyLocation = `https://${HOST}/${KEY}.txt`;

const sitemap = await readFile(new URL('./public/storagedaddy/sitemap.xml', import.meta.url), 'utf8');
const urlList = [...sitemap.matchAll(/<loc>(https:\/\/[^<]+)<\/loc>/g)].map((m) => m[1]);
if (urlList.length === 0) throw Error('No URLs found in sitemap.xml');

const response = await fetch('https://api.indexnow.org/indexnow', {
  method: 'POST',
  headers: { 'content-type': 'application/json; charset=utf-8' },
  body: JSON.stringify({ host: HOST, key: KEY, keyLocation, urlList }),
});
const text = await response.text();
console.log(`IndexNow ${response.status} for ${urlList.length} URL(s): ${urlList.join(', ')}`);
if (text.trim()) console.log(text.trim());
if (!response.ok && response.status !== 202) throw Error(`IndexNow submission failed: ${response.status}`);
