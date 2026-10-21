#!/usr/bin/env node
import { existsSync } from 'node:fs';
import { fileURLToPath, pathToFileURL } from 'node:url';
const root = fileURLToPath(new URL('../', import.meta.url));
const candidates = ['release', 'debug'].map(mode => `${root}_build/js/${mode}/build/cmd/main/main.js`);
const entry = candidates.find(existsSync);
if (!entry) {
  console.error('Build first: moon build --target js --release');
  process.exitCode = 1;
} else {
  await import(pathToFileURL(entry).href);
}
