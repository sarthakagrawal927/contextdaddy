import { createHash } from 'node:crypto';
import { readFile, stat } from 'node:fs/promises';
import release from './release.json' with { type: 'json' };

if (!/^[a-f0-9]{64}$/.test(release.sha256) ||
    release.path !== `/downloads/${release.filename}` ||
    !Number.isSafeInteger(release.bytes) || release.bytes < 1) {
  throw new Error('A qualified release manifest is required before deployment');
}

const file = new URL(`./public${release.path}`, import.meta.url);
if ((await stat(file)).size !== release.bytes ||
    createHash('sha256').update(await readFile(file)).digest('hex') !== release.sha256) {
  throw new Error('Release asset does not match the qualified artifact');
}

console.log('Qualified ContextDaddy DMG matches the download manifest.');
