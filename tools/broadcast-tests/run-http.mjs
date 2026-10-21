import { createHash } from 'node:crypto';
import { spawn, spawnSync } from 'node:child_process';
import { existsSync } from 'node:fs';
import { mkdir, readFile, writeFile } from 'node:fs/promises';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const here = dirname(fileURLToPath(import.meta.url));
let binary = process.env.POSTGREST_BIN;
if (!binary) {
  const isAppleSilicon = spawnSync('sysctl', ['-n', 'hw.optional.arm64'], {encoding: 'utf8'}).stdout.trim() === '1';
  if (process.platform !== 'darwin' || !isAppleSilicon) {
    throw new Error('Set POSTGREST_BIN to an official PostgREST executable on this platform.');
  }
  const cache = join(here, '.cache');
  binary = join(cache, 'postgrest');
  const archive = join(cache, 'postgrest-v16.4-macos-aarch64.tar.xz');
  const digest = '5720fbde4a19ade9fb189791615c84beb9f0e58201b1b6d17fe3b698faf60776';
  await mkdir(cache, {recursive: true});
  if (!existsSync(binary)) {
    const url = 'https://github.com/PostgREST/postgrest/releases/download/v16.4/postgrest-v16.4-macos-aarch64.tar.xz';
    const response = await fetch(url);
    if (!response.ok) throw new Error(`Could not fetch official PostgREST release: ${response.status}`);
    await writeFile(archive, Buffer.from(await response.arrayBuffer()));
    const downloaded = createHash('sha256').update(await readFile(archive)).digest('hex');
    if (downloaded !== digest) throw new Error('PostgREST download hash mismatch');
    const unpack = spawnSync('tar', ['-xJf', archive, '-C', cache], {stdio: 'inherit'});
    if (unpack.status !== 0) throw new Error('Could not extract PostgREST');
  }
}
if (!existsSync(binary)) throw new Error(`PostgREST executable missing: ${binary}`);
const child = spawn(process.execPath, ['--test', 'http.test.mjs'], {
  cwd: here, env: {...process.env, POSTGREST_BIN: binary,
    BROADCAST_TEST_ADAPTER: process.argv.includes('--adapter') ? '1' : '0'}, stdio: 'inherit',
});
child.on('exit', (code, signal) => { process.exitCode = signal ? 1 : (code ?? 1); });
