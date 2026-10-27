// Test-only guard: planning must not open payload files.
import fs from 'node:fs';
import path from 'node:path';
const root = path.resolve(process.env.SWARM_PLAN_ROOT);
const open = fs.openSync;
fs.openSync = function(file, flags, ...rest) {
  const full = path.resolve(String(file));
  if (full === root || full.startsWith(root + path.sep)) {
    throw Error('Planning attempted to open a payload file');
  }
  return open.call(this, file, flags, ...rest);
};
