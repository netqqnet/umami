import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import test from 'node:test';

const pkg = JSON.parse(await readFile(new URL('../../package.json', import.meta.url)));
const config = JSON.parse(await readFile(new URL('../../vercel.json', import.meta.url)));

test('Vercel builds every upstream asset without running database migrations', () => {
  assert.equal(pkg.version, '3.4.1');
  assert.equal(config.buildCommand, 'pnpm run build:vercel');
  assert.equal(config.installCommand, `npx --yes pnpm@${pkg.engines.pnpm} install --frozen-lockfile`);
  assert.equal(pkg.scripts['build:vercel'], pkg.scripts.build.replace(' check:db', ''));
});
