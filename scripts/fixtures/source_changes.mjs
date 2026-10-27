// Test-only instrumentation of synthetic payloads; never imported by the CLI.
import fs from 'node:fs';
import path from 'node:path';

const root = path.resolve(process.env.SWARM_SNAPSHOT_ROOT);
const action = process.env.SWARM_SNAPSHOT_ACTION;
if (!['stable', 'reorder', 'add', 'fill-empty', 'add-empty', 'remove-empty', 'rename-empty', 'replace-empty', 'during-list'].includes(action)) {
  throw Error('Unknown synthetic source-change action');
}
const inside = file => file === root || file.startsWith(root + path.sep);
const at = relative => {
  const target = path.resolve(root, relative);
  if (!inside(target) || target === root) throw Error('Fixture path escaped its payload root');
  return target;
};
const stats = { mutations: 0, payload_reads: 0, opened: 0, closed: 0, reordered: 0 };
function mutate() {
  if (stats.mutations || action === 'stable' || action === 'reorder') return;
  if (action === 'add' || action === 'during-list') fs.writeFileSync(at('new.txt'), 'synthetic addition');
  else if (action === 'fill-empty') fs.writeFileSync(at('empty/new.txt'), 'synthetic addition');
  else if (action === 'add-empty') fs.mkdirSync(at('new-empty'));
  else if (action === 'remove-empty') fs.rmdirSync(at('empty'));
  else if (action === 'rename-empty') fs.renameSync(at('empty'), at('renamed'));
  else if (action === 'replace-empty') { fs.rmdirSync(at('empty')); fs.mkdirSync(at('empty')); }
  stats.mutations++;
}

const open = fs.openSync, read = fs.readSync, close = fs.closeSync, opendir = fs.opendirSync;
const watched = new Map(), lists = new Map();
fs.openSync = function(file, ...rest) {
  const fd = open.call(this, file, ...rest), full = path.resolve(String(file));
  if (inside(full)) watched.set(fd, full);
  return fd;
};
fs.readSync = function(fd, ...rest) {
  const n = read.call(this, fd, ...rest);
  if (watched.has(fd)) {
    stats.payload_reads++;
    if (watched.get(fd) === at('a.bin') && n > 0 && action !== 'during-list') mutate();
  }
  return n;
};
fs.closeSync = function(fd) { watched.delete(fd); return close.call(this, fd); };
fs.opendirSync = function(file, ...rest) {
  const directory = opendir.call(this, file, ...rest), full = path.resolve(String(file));
  if (!inside(full)) return directory;
  stats.opened++;
  const next = directory.readSync.bind(directory), done = directory.closeSync.bind(directory);
  directory.closeSync = function() { const result = done(); stats.closed++; return result; };
  if (action === 'reorder') {
    const entries = [];
    let entry;
    while ((entry = next()) !== null) entries.push(entry);
    const count = (lists.get(full) || 0) + 1;
    lists.set(full, count);
    if (count % 2 === 0) { entries.reverse(); stats.reordered++; }
    let index = 0;
    directory.readSync = () => entries[index++] || null;
  } else {
    directory.readSync = function() {
      const entry = next();
      if (entry === null && action === 'during-list' && full === root) mutate();
      return entry;
    };
  }
  return directory;
};
process.on('exit', () => fs.writeFileSync(process.env.SWARM_SNAPSHOT_RESULT, JSON.stringify(stats)));
