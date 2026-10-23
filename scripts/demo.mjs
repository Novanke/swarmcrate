#!/usr/bin/env node
import { mkdirSync, writeFileSync, existsSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { join, resolve } from 'node:path';
import { spawnSync } from 'node:child_process';

const root = fileURLToPath(new URL('../', import.meta.url));
const args = process.argv.slice(2);
if (args.length && (args.length !== 2 || args[0] !== '--output')) throw Error('Usage: node scripts/demo.mjs [--output NEW_DIRECTORY]');
const output = args.length ? resolve(args[1]) : join(root, 'artifacts', 'demo');
if (existsSync(output)) throw Error(`${output} already exists; select a new --output directory.`);
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
const partial = JSON.parse(run('verify', [join(output, 'hybrid.torrent'), payload, '--file', 'docs/说明.txt', '--html', join(output, 'selected-pass.html')], 'selected-pass.json'));
if (!partial.ok || partial.complete || !partial.skipped_pieces) throw Error('selected scope mismatch');
binary[20000] ^= 255;
writeFileSync(join(payload, 'data.bin'), binary);
const edited = join(output, 'hybrid-edited.torrent');
run('edit', [join(output, 'hybrid.torrent'), edited, '--tracker', 'https://example.org/announce'], 'hybrid-edited.json');
run('verify', [edited, payload], 'hybrid-edited-verify.json');
writeFileSync(join(output, 'README.txt'), 'Synthetic payload restored after the damage test. Compare hybrid-pass.html, hybrid-damage.html, and selected-pass.html (only docs/说明.txt was checked while data.bin was damaged). Tracker example.org is a placeholder; no network requests were made.\n');
console.log(JSON.stringify({ output, created_formats: ['v1', 'v2', 'hybrid'], intact: 'PASS', corruption_detected_at: 16384, selected_file: 'PARTIAL PASS', tracker_edit: 'PASS' }, null, 2));
