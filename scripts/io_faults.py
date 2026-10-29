"""Exercise public commands under close failures; only owned synthetic temp files."""
import argparse
import json
import os
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser()
parser.add_argument('--node', default='node')
parser.add_argument('--cli', type=Path, default=ROOT / '_build/js/release/build/cmd/main/main.js')
parser.add_argument('--example', type=Path, default=ROOT / '_build/js/release/build/examples/create_controlled_io/create_controlled_io.js')
args = parser.parse_args()


def run_scenarios(directory):
    directory.mkdir()
    payload = directory / 'payload.bin'
    payload.write_bytes(bytes(i % 251 for i in range(2097169)))
    preload = directory / 'close-failure.mjs'
    preload.write_text('''import fs from 'node:fs';
import path from 'node:path';
const watched=path.resolve(process.env.SWARM_CLOSE_PATH), role=process.env.SWARM_CLOSE_ROLE;
const open=fs.openSync, close=fs.closeSync, fds=new Set();
let failedFd;
const stats={injected:false,retries:0};
fs.openSync=function(file,...rest) {
  const fd=open.call(this,file,...rest), full=path.resolve(String(file));
  if (fd===failedFd) failedFd=undefined; // a later successful open may reuse a number
  if (role==='stage' ? path.basename(full)==='data' && path.dirname(path.dirname(full))===watched && path.basename(path.dirname(full)).startsWith('.swarmcrate-') : full===watched) fds.add(fd);
  return fd;
};
fs.closeSync=function(fd) {
  if (fd===failedFd) stats.retries++;
  const applies=fds.delete(fd);
  const result=close.call(this,fd);
  if (applies && !stats.injected) {
    stats.injected=true; failedFd=fd;
    throw Error('injected close failure after underlying close');
  }
  return result;
};
process.on('exit',()=>fs.writeFileSync(process.env.SWARM_CLOSE_STATS,JSON.stringify(stats)));
''', encoding='utf-8')
    checks = 0

    def invoke(entry, parts, code, watched=None, role='file'):
        env = dict(os.environ)
        command = [args.node]
        if watched is not None:
            stats_path = directory / 'close-stats.json'
            env.update(SWARM_CLOSE_PATH=str(watched), SWARM_CLOSE_ROLE=role, SWARM_CLOSE_STATS=str(stats_path))
            command += ['--import', preload.as_uri()]
        result = subprocess.run([*command, str(entry), *map(str, parts)], capture_output=True, text=True, encoding='utf-8', env=env)
        assert result.returncode == code, (parts, result.returncode, result.stdout, result.stderr)
        value = json.loads(result.stdout)
        if watched is not None:
            stats = json.loads(stats_path.read_text(encoding='utf-8'))
            assert stats == {'injected': True, 'retries': 0}, stats
            assert not any(p.name.startswith('.swarmcrate-') for p in directory.iterdir())
        if code == 1:
            assert value['error'] == 'io' and 'injected close failure' in value['detail'], value
        return value

    for mode in ['v1', 'v2', 'hybrid']:
        torrent = directory / f'{mode}.torrent'
        invoke(args.cli, ['create', payload, torrent, '--mode', mode, '--piece-length', '2097152'], 0)
        checks += 1

        invoke(args.cli, ['inspect', torrent], 1, torrent)
        checks += 1
        failed_create = directory / f'{mode}-read-fail.torrent'
        invoke(args.cli, ['create', payload, failed_create, '--mode', mode], 1, payload)
        assert not failed_create.exists()
        checks += 1

        receipt = directory / f'{mode}-unreadable.json'
        diagnostics = directory / f'{mode}-unreadable-files.json'
        report = invoke(args.cli, ['verify', torrent, payload, '--receipt', receipt, '--diagnostics', diagnostics], 2, payload)
        multiplier = 2 if mode == 'hybrid' else 1
        assert not report['ok'] and report['unreadable_pieces'] == multiplier
        assert report['checked_pieces'] == 2 * multiplier and report['failed_pieces'] == multiplier, report
        captured = json.loads(receipt.read_text(encoding='utf-8'))
        assert captured['outcome'] == 'FAIL' and captured['verification'] == report
        grouped = json.loads(diagnostics.read_text(encoding='utf-8'))
        assert grouped['files'][0]['unreadable_bytes'] == '2097152'
        checks += 1

        failed_write = directory / f'{mode}-write-fail.torrent'
        invoke(args.cli, ['create', payload, failed_write, '--mode', mode], 1, failed_write)
        assert not failed_write.exists()
        checks += 1

        failed_receipt = directory / f'{mode}-receipt-fail.json'
        invoke(args.cli, ['verify', torrent, payload, '--receipt', failed_receipt], 1, failed_receipt)
        assert not failed_receipt.exists()
        checks += 1

        failed_atomic = directory / f'{mode}-atomic-fail.torrent'
        invoke(args.example, ['full', 'create', payload, failed_atomic, '--mode', mode], 1, directory, 'stage')
        assert not failed_atomic.exists()
        checks += 1
    return checks


if __name__ == '__main__':
    with tempfile.TemporaryDirectory(prefix='swarmcrate-close-') as temp:
        count = run_scenarios(Path(temp) / 'cases')
    assert count == 21, count
    print(json.dumps({'close_failure_scenarios': count, 'node': args.node, 'result': 'PASS'}))
