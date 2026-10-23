#!/usr/bin/env node
// Repeated process-level measurements, not timing assertions or a source metric.
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { resolve } from 'node:path';
const root = fileURLToPath(new URL('../', import.meta.url));
let baseline;
let runs = 5;
const args = process.argv.slice(2);
for (let i = 0; i < args.length; i += 2) {
  if (i + 1 === args.length) throw Error('Usage: node scripts/benchmark.mjs [--runs 1..20] [--baseline BUILT_BENCH.js]');
  if (args[i] === '--baseline') baseline = resolve(args[i + 1]);
  else if (args[i] === '--runs') runs = Number(args[i + 1]);
  else throw Error(`Unknown option: ${args[i]}`);
}
if (!Number.isInteger(runs) || runs < 1 || runs > 20) throw Error('runs must be in 1..20');
const current = resolve(root, '_build/js/release/build/bench/bench.js');
const results = new Map([[current, []]]);
if (baseline) results.set(baseline, []);
// Alternate process order to reduce the influence of background load and warming.
for (let i = 0; i < runs; i++) {
  const entries = [...results.keys()];
  if (i % 2) entries.reverse();
  for (const entry of entries) {
    const result = spawnSync(process.execPath, [entry], { encoding: 'utf8', timeout: 120000 });
    if (result.error || result.status !== 0) throw Error(`${entry}: ${result.error || result.stderr || result.stdout}`);
    results.get(entry).push(result.stdout.trim().split(/\r?\n/).map(JSON.parse));
  }
}
function summarize(samples) {
  if (!samples.length || samples.some(s => s.length !== 3)) throw Error('Expected three benchmark cases');
  return samples[0].map((first, index) => {
    const times = samples.map(sample => {
      const item = sample[index];
      for (const key of ['case', 'files', 'read_calls', 'read_bytes', 'metainfo_bytes', 'info_hash_v1', 'info_hash_v2']) {
        if (item[key] !== first[key]) throw Error(`Unstable ${key} in benchmark`);
      }
      return item.milliseconds;
    }).sort((a, b) => a - b);
    const middle = Math.floor(times.length / 2);
    const median = times.length % 2 ? times[middle] : (times[middle - 1] + times[middle]) / 2;
    const { milliseconds, ...metrics } = first;
    return { ...metrics, median_milliseconds: Math.round(median * 100) / 100 };
  });
}
const output = { runs, node: process.version, platform: process.platform, architecture: process.arch, current: summarize(results.get(current)) };
if (baseline) {
  output.baseline = summarize(results.get(baseline));
  for (let i = 0; i < output.current.length; i++) {
    const a = output.current[i], b = output.baseline[i];
    if (a.case !== b.case || a.files !== b.files || a.info_hash_v1 !== b.info_hash_v1 || a.info_hash_v2 !== b.info_hash_v2) {
      throw Error('Baseline and current input/layout identities differ');
    }
  }
  output.content_identities_preserved = true;
}
console.log(JSON.stringify(output, null, 2));
