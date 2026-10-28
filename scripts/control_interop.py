"""Run the public cooperative SDK through a real single-file Node consumer."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser()
parser.add_argument('--node', default='node')
parser.add_argument('--cli', type=Path, default=ROOT / '_build/js/release/build/cmd/main/main.js')
parser.add_argument('--example', type=Path, default=ROOT / '_build/js/release/build/examples/controlled_io/controlled_io.js')
args = parser.parse_args()
control_checks = 0


def invoke(entry, *parts, code=0, env=None, preload=None):
    command = [args.node]
    if preload:
        command += ['--import', preload.as_uri()]
    result = subprocess.run([*command, str(entry), *map(str, parts)], capture_output=True, text=True, encoding='utf-8', env=env)
    assert result.returncode == code, (parts, result.returncode, result.stdout, result.stderr)
    return json.loads(result.stdout)


def control_scenarios(directory):
    global control_checks
    directory.mkdir()
    data = bytes(i % 251 for i in range(2097169))
    payload = directory / 'payload.bin'
    preload = directory / 'change-after-close.mjs'
    preload.write_text('''import fs from 'node:fs';
import path from 'node:path';
const target = path.resolve(process.env.SWARM_CONTROL_FILE), watched = new Set();
const open = fs.openSync, close = fs.closeSync;
let changed = false;
fs.openSync = function(file, ...rest) {
  const fd = open.call(this, file, ...rest);
  if (path.resolve(String(file)) === target) watched.add(fd);
  return fd;
};
fs.closeSync = function(fd) {
  const applies = watched.delete(fd); const result = close.call(this, fd);
  if (applies && !changed) { changed = true; fs.appendFileSync(target, '!'); }
  return result;
};
''', encoding='utf-8')
    for mode in ['v1', 'v2', 'hybrid']:
        payload.write_bytes(data)
        torrent = directory / f'{mode}.torrent'
        created = invoke(args.cli, 'create', payload, torrent, '--mode', mode, '--piece-length', '2097152')
        output = directory / f'{mode}-full.json'
        full = invoke(args.example, torrent, payload, output, 'full')
        receipt = json.loads(output.read_text(encoding='utf-8'))
        assert full['ok'] and full['read_calls'] == 3 and full['validated_read_bytes'] == str(len(data))
        assert full['checked_pieces'] == full['total_checks'] == (4 if mode == 'hybrid' else 2)
        assert receipt['subject']['metainfo_sha256'] == hashlib.sha256(torrent.read_bytes()).hexdigest()
        assert receipt['subject']['info_hash_v1'] == created['info']['info_hash_v1']
        assert receipt['subject']['info_hash_v2'] == created['info']['info_hash_v2']
        assert receipt['verification'] == invoke(args.cli, 'verify', torrent, payload)
        control_checks += 1
        for action, expected_reads in [('cancel-start', 0), ('cancel-read', 1), ('cancel-check', 2), ('cancel-finalize', 3), ('observer-error', 0)]:
            output = directory / f'{mode}-{action}.json'
            result = invoke(args.example, torrent, payload, output, action, code=1 if action == 'observer-error' else 3)
            assert result['error'] == ('observer' if action == 'observer-error' else 'cancelled')
            assert result['read_calls'] == expected_reads and not output.exists()
            if action == 'cancel-read':
                assert result['validated_read_bytes'] == '1048576' and result['checked_pieces'] == 0
            if action == 'cancel-finalize':
                assert result['checked_pieces'] == result['total_checks']
            assert payload.read_bytes() == data
            control_checks += 1
        damaged = bytearray(data)
        damaged[20000] ^= 255
        payload.write_bytes(damaged)
        output = directory / f'{mode}-damage.json'
        result = invoke(args.example, torrent, payload, output, 'full', code=2)
        receipt = json.loads(output.read_text(encoding='utf-8'))
        assert not result['ok'] and result['checked_pieces'] == result['total_checks']
        assert receipt['outcome'] == 'FAIL' and receipt['file_diagnostics']['files'][0]['attention_bytes'] == '2097152'
        control_checks += 1
        payload.write_bytes(data)
        output = directory / f'{mode}-existing.json'
        output.write_bytes(b'preserve')
        result = invoke(args.example, torrent, payload, output, 'full', code=1)
        assert result['error'] == 'usage' and result['read_calls'] == 0 and output.read_bytes() == b'preserve'
        control_checks += 1
        output = directory / f'{mode}-changed.json'
        result = invoke(args.example, torrent, payload, output, 'full', code=1, preload=preload,
                        env={**os.environ, 'SWARM_CONTROL_FILE': str(payload)})
        assert result['error'] == 'changed' and not output.exists()
        control_checks += 1
        payload.unlink()
        output = directory / f'{mode}-missing.json'
        result = invoke(args.example, torrent, payload, output, 'full', code=2)
        receipt = json.loads(output.read_text(encoding='utf-8'))
        assert not result['ok'] and result['read_calls'] == 0
        assert receipt['outcome'] == 'FAIL' and receipt['verification']['file_issues'][0]['reason'] == 'missing'
        control_checks += 1


with tempfile.TemporaryDirectory(prefix='swarmcrate-control-') as temp:
    control_scenarios(Path(temp) / 'cases')
print(json.dumps({'result': 'PASS', 'control_disk_scenarios': control_checks}))
