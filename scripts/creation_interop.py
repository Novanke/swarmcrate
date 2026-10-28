"""Real creation cancellation and staged-publication faults; only synthetic temp files."""
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
creation_checks = 0


def creation_cli(*parts, code=0):
    result = subprocess.run([args.node, str(args.cli), *map(str, parts)], capture_output=True, text=True, encoding='utf-8')
    assert result.returncode == code, (result.returncode, result.stdout, result.stderr)
    return json.loads(result.stdout)


def creation_scenarios(directory):
    global creation_checks
    directory.mkdir()
    payload = directory / 'bundle'
    payload.mkdir()
    (payload / 'a').write_bytes(b'abc')
    data = bytes(i % 251 for i in range(2097169))
    (payload / 'b').write_bytes(data)
    (payload / 'empty').write_bytes(b'')
    (payload / 'empty-directory').mkdir()
    preload = directory / 'publication-faults.mjs'
    preload.write_text('''import fs from 'node:fs';
import path from 'node:path';
const target = path.resolve(process.env.SWARM_CREATE_TARGET), input = path.resolve(process.env.SWARM_CREATE_INPUT);
const fault = process.env.SWARM_CREATE_FAULT, watched = new Map();
const stats = {source_bytes:0, source_attempts:0, stage_opened:0, stage_closed:0, partial_target_seen:false, injected:false, published:false};
const open=fs.openSync,close=fs.closeSync,read=fs.readSync,write=fs.writeSync,sync=fs.fsyncSync,link=fs.linkSync;
fs.openSync=function(file,...rest) {
  const fd=open.call(this,file,...rest), full=path.resolve(String(file));
  if (full===input || full.startsWith(input+path.sep)) watched.set(fd,'source');
  if (path.basename(full)==='data' && path.basename(path.dirname(full)).startsWith('.swarmcrate-')) {
    watched.set(fd,'stage'); stats.stage_opened++;
  }
  return fd;
};
fs.closeSync=function(fd) {
  if (watched.get(fd)==='stage') stats.stage_closed++;
  watched.delete(fd); return close.call(this,fd);
};
fs.readSync=function(fd,...rest) {
  if (watched.get(fd)==='source') {
    stats.source_attempts++;
    if (fault==='read-fail') { stats.injected=true; throw Error('injected source read failure'); }
  }
  const n=read.call(this,fd,...rest);
  if (watched.get(fd)==='source') stats.source_bytes+=n;
  return n;
};
fs.writeSync=function(fd,buffer,offset,length,position) {
  if (watched.get(fd)==='stage') {
    if (fs.existsSync(target)) stats.partial_target_seen=true;
    if (fault==='short-write') { stats.injected=true; return 0; }
    if (['write-fail','kill-write','partial-write'].includes(fault)) {
      stats.injected=true;
      const n=write.call(this,fd,buffer,offset,Math.min(13,length),position);
      if (fault==='write-fail') throw Error('injected staged write failure');
      if (fault==='kill-write') process.exit(91);
      return n;
    }
  }
  return write.call(this,fd,buffer,offset,length,position);
};
fs.fsyncSync=function(fd) {
  if (watched.get(fd)==='stage' && fault==='fsync-fail') { stats.injected=true; throw Error('injected fsync failure'); }
  return sync.call(this,fd);
};
fs.linkSync=function(source,destination) {
  if (path.resolve(String(destination))===target) {
    if (fault==='link-fail') { stats.injected=true; throw Error('injected unsupported hard links'); }
    if (fault==='race') { stats.injected=true; fs.writeFileSync(target,'competing writer'); }
    const value=link.call(this,source,destination); stats.published=true;
    if (fault==='kill-link') { stats.injected=true; process.exit(92); }
    return value;
  }
  return link.call(this,source,destination);
};
const stderr=process.stderr.write.bind(process.stderr);
process.stderr.write=function(chunk,...rest) {
  if (fault==='source-change' && !stats.injected) {
    let event; try { event=JSON.parse(String(chunk)); } catch {}
    if (event?.phase==='before_write') { stats.injected=true; fs.writeFileSync(path.join(input,'late.txt'),'late source'); }
  }
  return stderr(chunk,...rest);
};
process.on('exit',()=>fs.writeFileSync(process.env.SWARM_CREATE_STATS,JSON.stringify(stats)));
''', encoding='utf-8')

    def run(mode, label, action='full', fault='none', code=0, source=payload, existing=False):
        output = directory / f'{mode}-{label}.torrent'
        if existing:
            output.write_bytes(b'preserved existing output')
        stats_file = directory / f'{mode}-{label}.stats.json'
        result = subprocess.run([args.node, '--import', preload.as_uri(), str(args.example), action,
                                 'create', str(source), str(output), '--mode', mode, '--piece-length', '2097152'],
                                capture_output=True, text=True, encoding='utf-8', env={**os.environ,
                                    'SWARM_CREATE_TARGET': str(output), 'SWARM_CREATE_INPUT': str(source),
                                    'SWARM_CREATE_FAULT': fault, 'SWARM_CREATE_STATS': str(stats_file)})
        assert result.returncode == code, (mode, label, result.returncode, result.stdout, result.stderr)
        events = [json.loads(line) for line in result.stderr.splitlines() if line.startswith('{')]
        observed = json.loads(stats_file.read_text(encoding='utf-8'))
        assert not observed['partial_target_seen'], 'published target was visible during staged writes'
        for previous, current in zip(events, events[1:]):
            assert int(previous['validated_read_bytes']) <= int(current['validated_read_bytes']) <= int(current['total_bytes'])
            assert previous['read_calls'] <= current['read_calls']
        if code not in [91, 92]:
            assert observed['stage_opened'] == observed['stage_closed']
            assert not list(directory.glob('.swarmcrate-*'))
        return output, json.loads(result.stdout) if result.stdout.strip() else None, events, observed

    for mode in ['v1', 'v2', 'hybrid']:
        output, result, events, observed = run(mode, 'full')
        reference = directory / f'{mode}-reference.torrent'
        creation_cli('create', payload, reference, '--mode', mode, '--piece-length', '2097152')
        assert output.read_bytes() == reference.read_bytes()
        assert creation_cli('verify', output, payload)['ok']
        assert observed['source_bytes'] == 2097172 and observed['published']
        assert events[0]['phase'] == 'start' and events[-1]['phase'] == 'before_write'
        assert events[-1]['validated_read_bytes'] == events[-1]['total_bytes'] == '2097172'
        baseline = output.read_bytes()
        creation_checks += 1
        phases = ['start', 'before_read', 'after_read', 'before_encode', 'finalize', 'before_write']
        for prefix in ['cancel', 'error']:
            for phase in phases:
                output, result, events, observed = run(mode, f'{prefix}-{phase}', action=f'{prefix}-{phase}', code=3 if prefix=='cancel' else 1)
                assert not output.exists() and observed['stage_opened'] == 0
                assert result['error'] == ('cancelled' if prefix=='cancel' else 'observer')
                assert events[-1]['phase'] == phase
                if phase in ['start', 'before_read']:
                    assert observed['source_attempts'] == 0
                if phase in ['before_encode', 'finalize', 'before_write']:
                    assert observed['source_bytes'] == 2097172
                creation_checks += 1
        output, result, events, observed = run(mode, 'existing', existing=True, code=1)
        assert output.read_bytes() == b'preserved existing output' and observed['source_attempts'] == 0 and events == []
        creation_checks += 1
        output, result, events, observed = run(mode, 'changed', fault='source-change', code=1)
        assert result['error'] == 'changed' and observed['injected'] and not output.exists()
        assert events[-1]['phase'] == 'before_write' and observed['stage_opened'] == 0
        (payload / 'late.txt').unlink()
        creation_checks += 1
        for fault in ['read-fail', 'write-fail', 'short-write', 'fsync-fail', 'link-fail', 'race', 'partial-write', 'kill-write', 'kill-link']:
            code = 91 if fault=='kill-write' else 92 if fault=='kill-link' else 0 if fault=='partial-write' else 1
            output, result, events, observed = run(mode, fault, fault=fault, code=code)
            assert observed['injected']
            if fault in ['partial-write', 'kill-link']:
                assert output.read_bytes() == baseline and creation_cli('verify', output, payload)['ok']
            elif fault == 'race':
                assert output.read_bytes() == b'competing writer'
            else:
                assert not output.exists()
            if fault in ['kill-write', 'kill-link']:
                stages = list(directory.glob('.swarmcrate-*'))
                assert len(stages) == 1
                for stage in stages:
                    assert stage.resolve().parent == directory.resolve() and stage.name.startswith('.swarmcrate-')
                    assert [p.name for p in stage.iterdir()] == ['data']
                    (stage / 'data').unlink()  # Only our exact, owned test staging file.
                    stage.rmdir()
            creation_checks += 1
        single = payload / 'b'
        output, result, events, observed = run(mode, 'single', source=single)
        assert result['info']['single_file'] and creation_cli('verify', output, single)['ok']
        assert observed['source_bytes'] == len(data)
        creation_checks += 1
        output, result, events, observed = run(mode, 'single-cancel', source=single, action='cancel-before_write', code=3)
        assert not output.exists() and observed['stage_opened'] == 0
        creation_checks += 1
        assert (payload / 'a').read_bytes() == b'abc' and (payload / 'b').read_bytes() == data


with tempfile.TemporaryDirectory(prefix='swarmcrate-creation-') as temp:
    creation_scenarios(Path(temp) / 'cases')
print(json.dumps({'result': 'PASS', 'creation_disk_scenarios': creation_checks}))
