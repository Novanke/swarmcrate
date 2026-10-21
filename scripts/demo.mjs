#!/usr/bin/env node
import { mkdirSync, writeFileSync, existsSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { join } from 'node:path';
import { spawnSync } from 'node:child_process';

const root = fileURLToPath(new URL('../', import.meta.url));
const output = join(root, 'artifacts', 'demo');
if (existsSync(output)) throw Error('artifacts/demo already exists; move it aside before generating another demo.');
mkdirSync(output, { recursive: true });
const payload = join(output, 'dataset');
mkdirSync(join(payload, 'docs'), { recursive: true });
writeFileSync(join(payload, 'README.txt'), 'SwarmCrate synthetic offline distribution example.\n');
writeFileSync(join(payload, 'docs', '说明.txt'), '这是人工合成的演示数据，不包含个人信息。\n');
const binary = Uint8Array.from({ length: 70001 }, (_, i) => (i * 73 + 19) % 251);
writeFileSync(join(payload, 'data.bin'), binary);
writeFileSync(join(payload, 'empty.txt'), '');
function run(command, params, filename, expectedCode = 0) {
  const result = spawnSync(process.execPath, [join(root, 'scripts', 'swarmcrate.mjs'), command, ...params], { encoding: 'utf8' });
  if (result.status !== expectedCode) throw Error(`${command}: ${result.stdout}\n${result.stderr}`);
  if (filename) writeFileSync(join(output, filename), result.stdout);
  return result.stdout;
}
for (const mode of ['v1', 'v2', 'hybrid']) {
  const torrent = join(output, `${mode}.torrent`);
  run('create', [payload, torrent, '--mode', mode, '--piece-length', '16384'], `${mode}-create.json`);
  run('inspect', [torrent], `${mode}-inspect.json`);
  run('magnet', [torrent], `${mode}.magnet.txt`);
  run('verify', [torrent, payload, '--html', join(output, `${mode}-pass.html`)], `${mode}-pass.json`);
}
binary[20000] ^= 255;
writeFileSync(join(payload, 'data.bin'), binary);
const failure = JSON.parse(run('verify', [join(output, 'hybrid.torrent'), payload, '--html', join(output, 'hybrid-damage.html')], 'hybrid-damage.json', 2));
if (failure.failed_pieces !== 2 || failure.failures[0].spans[0].offset !== '16384') throw Error('damage location mismatch');
binary[20000] ^= 255;
writeFileSync(join(payload, 'data.bin'), binary);
const edited = join(output, 'hybrid-edited.torrent');
run('edit', [join(output, 'hybrid.torrent'), edited, '--tracker', 'https://example.org/announce'], 'hybrid-edited.json');
run('verify', [edited, payload], 'hybrid-edited-verify.json');
writeFileSync(join(output, 'README.txt'), 'Synthetic payload restored after the damage test. Open hybrid-pass.html and hybrid-damage.html to compare. Tracker example.org is a placeholder; no network requests were made.\n');
console.log(JSON.stringify({ output, created_formats: ['v1', 'v2', 'hybrid'], intact: 'PASS', corruption_detected_at: 16384, tracker_edit: 'PASS' }, null, 2));
