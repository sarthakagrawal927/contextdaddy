import { readFile, stat } from 'node:fs/promises';
import { createHash } from 'node:crypto';
import release from './release.json' with { type: 'json' };
if (!release.ready || !/^[a-f0-9]{64}$/.test(release.sha256 || '')) throw Error('A qualified release is required before deployment');
const file = new URL('./public' + release.path, import.meta.url);
const info = await stat(file);
if (info.size !== release.bytes) throw Error('Release size mismatch');
if (createHash('sha256').update(await readFile(file)).digest('hex') !== release.sha256) throw Error('Release checksum mismatch');
console.log('Qualified DMG matches the download manifest.');
