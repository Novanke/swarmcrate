"""Public batch-control consumer under real OS faults; synthetic, owned temp data only."""
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
parser.add_argument('--example', type=Path, default=ROOT / '_build/js/release/build/examples/batch_controlled_io/batch_controlled_io.js')
args = parser.parse_args()


def batch_control_scenarios(directory):
    directory.mkdir()
    data = bytes(i % 251 for i in range(2097169))
    payload = directory / 'payload.bin'
    payload.write_bytes(data)
    manifest = directory / 'jobs.json'
    preload = directory / 'batch-faults.mjs'
    preload.write_text('''import fs from 'node:fs';
import path from 'node:path';
const target=path.resolve(process.env.SWARM_BATCH_TARGET), input=path.resolve(process.env.SWARM_BATCH_INPUT);
const mutation=process.env.SWARM_BATCH_MUTATION, fault=process.env.SWARM_BATCH_FAULT;
const marker=process.env.SWARM_BATCH_CANCEL_FILE;
const watched=new Map(), open=fs.openSync,close=fs.closeSync,read=fs.readSync,write=fs.writeSync,sync=fs.fsyncSync,link=fs.linkSync;
const stats={source_bytes:0,stage_opened:0,partial_target_seen:false,injected:false,published:false};
fs.openSync=function(file,...rest){const fd=open.call(this,file,...rest),full=path.resolve(String(file));if(full===input)watched.set(fd,'source');if(path.basename(full)==='data'&&path.basename(path.dirname(full)).startsWith('.swarmcrate-')){watched.set(fd,'stage');stats.stage_opened++;}return fd;};
fs.closeSync=function(fd){const stage=watched.get(fd)==='stage';watched.delete(fd);const value=close.call(this,fd);if(stage&&fault==='close-fail'){stats.injected=true;throw Error('injected staged close failure');}return value;};
fs.readSync=function(fd,...rest){const n=read.call(this,fd,...rest);if(watched.get(fd)==='source')stats.source_bytes+=n;return n;};
fs.writeSync=function(fd,buffer,offset,length,position){if(watched.get(fd)==='stage'){if(fs.existsSync(target))stats.partial_target_seen=true;if(fault==='write-fail'||fault==='kill-write'){stats.injected=true;const n=write.call(this,fd,buffer,offset,Math.min(13,length),position);if(fault==='kill-write')process.exit(91);throw Error('injected staged write failure');}}return write.call(this,fd,buffer,offset,length,position);};
fs.fsyncSync=function(fd){if(watched.get(fd)==='stage'&&fault==='sync-fail'){stats.injected=true;throw Error('injected staged sync failure');}return sync.call(this,fd);};
fs.linkSync=function(source,destination){if(path.resolve(String(destination))===target){if(fault==='link-fail'){stats.injected=true;throw Error('injected link failure');}if(fault==='race'){stats.injected=true;fs.writeFileSync(target,'competing writer');}const value=link.call(this,source,destination);stats.published=true;if(fault==='kill-link'){stats.injected=true;process.exit(92);}return value;}return link.call(this,source,destination);};
const stderr=process.stderr.write.bind(process.stderr);
process.stderr.write=function(chunk,...rest){if(!stats.injected){let event;try{event=JSON.parse(String(chunk));}catch{}if(mutation&&event?.phase==='before_write'){stats.injected=true;fs.appendFileSync(mutation,'!');}if(marker&&event?.verification?.phase==='after_read'){stats.injected=true;fs.writeFileSync(marker,'cancel');}}return stderr(chunk,...rest);};
process.on('exit',()=>fs.writeFileSync(process.env.SWARM_BATCH_STATS,JSON.stringify(stats)));
''', encoding='utf-8')

    def cli(*parts):
        result = subprocess.run([args.node, str(args.cli), *map(str, parts)], capture_output=True, text=True, encoding='utf-8')
        assert result.returncode == 0, (result.stdout, result.stderr)
        return json.loads(result.stdout)

    checks = 0
    for mode in ['v1', 'v2', 'hybrid']:
        seed = directory / f'{mode}.torrent'
        cli('create', payload, seed, '--mode', mode, '--piece-length', '2097152')
        seed_bytes = seed.read_bytes()
        manifest_bytes = json.dumps({'schema': 'swarmcrate.audit-manifest.v1', 'tasks': [
            {'id': 'first', 'metainfo': seed.name, 'payload': payload.name},
            {'id': 'later', 'metainfo': seed.name, 'payload': payload.name}]}).encode()
        manifest.write_bytes(manifest_bytes)
        baseline_path = directory / f'{mode}-legacy.json'
        baseline = cli('audit-batch', manifest, baseline_path)
        assert baseline['all_full_pass'] and baseline['processed_tasks'] == 2

        def run(label, action='full', code=0, fault='', mutation=None, cancel_file=False):
            # Restore only our own fixtures after the preceding injected mutation.
            payload.write_bytes(data)
            seed.write_bytes(seed_bytes)
            manifest.write_bytes(manifest_bytes)
            target = directory / f'{mode}-{label}.json'
            stats_path = directory / f'{mode}-{label}-stats.json'
            marker = directory / f'{mode}-{label}.flag'
            env = dict(os.environ, SWARM_BATCH_TARGET=str(target), SWARM_BATCH_INPUT=str(payload),
                       SWARM_BATCH_FAULT=fault, SWARM_BATCH_MUTATION=str(mutation) if mutation else '', SWARM_BATCH_STATS=str(stats_path), SWARM_BATCH_CANCEL_FILE=str(marker) if cancel_file else '')
            control_args = ['--cancel-file', str(marker)] if cancel_file else [action]
            process = subprocess.run([args.node, '--import', preload.as_uri(), str(args.example), *control_args, 'audit-batch', str(manifest), str(target)], capture_output=True, text=True, encoding='utf-8', env=env)
            assert process.returncode == code, (label, process.returncode, process.stdout, process.stderr)
            events = [json.loads(line) for line in process.stderr.splitlines()]
            stats = json.loads(stats_path.read_text(encoding='utf-8'))
            assert not stats['partial_target_seen'], (label, stats)
            result = json.loads(process.stdout) if code not in [91, 92] else None
            if code in [1, 3]:
                assert 'all_full_pass' not in result and 'tasks' not in result, result
            if code == 3:
                assert result['error'] == 'cancelled' and stats['stage_opened'] == 0
            stages = list(directory.glob('.swarmcrate-*'))
            if code in [91, 92]:
                assert len(stages) == 1
                for stage in stages:
                    assert stage.resolve().parent == directory.resolve() and stage.name.startswith('.swarmcrate-')
                    assert [p.name for p in stage.iterdir()] == ['data']
                    (stage / 'data').unlink()
                    stage.rmdir()
            else:
                assert not stages, (label, stages)
            return target, result, events, stats

        target, result, events, stats = run('full')
        assert result == baseline and target.read_bytes() == baseline_path.read_bytes()
        assert stats['source_bytes'] == 2 * len(data)
        assert events[-1]['phase'] == 'before_write' and events[-1]['completed_tasks'] == 2
        assert events[-1]['read_calls'] == '6' and events[-1]['validated_read_bytes'] == str(2 * len(data))
        assert result['manifest_sha256'] == hashlib.sha256(manifest_bytes).hexdigest()
        checks += 1
        for phase in ['verification/after_read', 'finalize', 'before_write']:
            target, _, events, _ = run('cancel-' + phase.replace('/', '-'), action='cancel-' + phase, code=3)
            assert not target.exists()
            if phase in ['finalize', 'before_write']:
                assert events[-1]['completed_tasks'] == 2
            checks += 1
        target, result, _, _ = run('observer', action='error-verification/after_read', code=1)
        assert not target.exists() and result['error'] == 'observer'
        checks += 1
        target, _, events, stats = run('external-marker', code=3, cancel_file=True)
        assert stats['injected'] and not target.exists()
        assert events[-1]['read_calls'] == '1' and events[-1]['completed_tasks'] == 0
        checks += 1
        for label, mutation in [('payload', payload), ('metainfo', seed), ('manifest', manifest)]:
            target, result, _, stats = run('change-' + label, code=1, mutation=mutation)
            assert stats['injected'] and result['error'] == 'changed' and not target.exists()
            checks += 1
        for fault in ['write-fail', 'sync-fail', 'close-fail', 'link-fail', 'race', 'kill-write', 'kill-link']:
            code = 91 if fault == 'kill-write' else 92 if fault == 'kill-link' else 1
            target, _, _, stats = run(fault, code=code, fault=fault)
            assert stats['injected']
            if fault == 'race':
                assert target.read_bytes() == b'competing writer'
            elif fault == 'kill-link':
                assert target.read_bytes() == baseline_path.read_bytes() and json.loads(target.read_text(encoding='utf-8'))['all_full_pass']
            else:
                assert not target.exists()
            checks += 1
    return checks


if __name__ == '__main__':
    with tempfile.TemporaryDirectory(prefix='swarmcrate-batch-control-') as temp:
        count = batch_control_scenarios(Path(temp) / 'cases')
    assert count == 48, count
    print(json.dumps({'result': 'PASS', 'batch_control_disk_scenarios': count}))
