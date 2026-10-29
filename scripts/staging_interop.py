"""Real interrupted publishers and conservative cleanup; synthetic owned fixtures only."""
import argparse
import json
import os
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]


def staging_scenarios(node, cli, example):
    checks = 0
    with tempfile.TemporaryDirectory(prefix='swarmcrate-staging-check-') as temporary:
        root = Path(temporary).resolve()
        payload = root / 'payload'
        payload.write_bytes(bytes(range(251)) * 71)
        preloader = root / 'interrupt.mjs'
        preloader.write_text('''import fs from 'node:fs';
import path from 'node:path';
const open=fs.openSync,write=fs.writeSync,link=fs.linkSync,watched=new Set();
fs.openSync=function(p,...a){const fd=open.call(this,p,...a);if(path.basename(String(p))==='data'&&path.basename(path.dirname(String(p))).startsWith('.swarmcrate-'))watched.add(fd);return fd;};
fs.writeSync=function(fd,b,o,n,pos){if(watched.has(fd)){const used=write.call(this,fd,b,o,Math.min(n,13),pos);if(process.env.SWARM_STAGE_FAULT==='pause'){fs.writeFileSync(process.env.SWARM_STAGE_READY,'ready');Atomics.wait(new Int32Array(new SharedArrayBuffer(4)),0,0,60000);}process.exit(91);return used;}return write.call(this,fd,b,o,n,pos);};
if(process.env.SWARM_STAGE_FAULT==='linked'){fs.writeSync=write;fs.linkSync=function(...a){const result=link.apply(this,a);process.exit(92);return result;};}
''', encoding='utf-8')

        def command(*parts, code=0, preload=None, env=None):
            result = subprocess.run([node, *(['--import', preload.as_uri()] if preload else []), str(cli), *map(str, parts)],
                                    capture_output=True, text=True, encoding='utf-8', env=env)
            assert result.returncode == code, (parts, result.returncode, result.stdout, result.stderr)
            return json.loads(result.stdout)

        def rows():
            return command('staging-list', root)['stages']

        def row_for(stage):
            return next(r for r in rows() if Path(r['path']) == stage)

        def interrupted(label, mode='write'):
            target = root / (label + '.torrent')
            result = subprocess.run([node, '--import', preloader.as_uri(), str(example), 'full', 'create', str(payload), str(target)],
                                    capture_output=True, text=True, encoding='utf-8', env=dict(os.environ, SWARM_STAGE_FAULT=mode))
            assert result.returncode == (92 if mode == 'linked' else 91), (result.returncode, result.stdout, result.stderr)
            stage = next(p for p in root.glob('.swarmcrate-*') if p.is_dir() and json.loads((p / 'owner.json').read_text())['target_path'] == str(target))
            owner = json.loads((stage / 'owner.json').read_text())
            receipt = Path(tempfile.gettempdir()).resolve() / ('.swarmcrate-owner-' + owner['operation_id'] + '.json')
            assert receipt.read_bytes() == (stage / 'owner.json').read_bytes()
            assert row_for(stage)['status'] == 'orphan', row_for(stage)
            return stage, owner, receipt, target

        def clean(stage, owner, code=0, preload=None):
            return command('staging-clean', stage, '--operation', owner['operation_id'], code=code, preload=preload)

        # An actually live publisher is preserved, then becomes eligible after an OS kill.
        ready = root / 'ready'
        live_target = root / 'live.torrent'
        child = subprocess.Popen([node, '--import', preloader.as_uri(), str(example), 'full', 'create', str(payload), str(live_target)],
                                 stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                                 env=dict(os.environ, SWARM_STAGE_FAULT='pause', SWARM_STAGE_READY=str(ready)))
        import time
        try:
            deadline = time.monotonic() + 20
            while not ready.exists() and time.monotonic() < deadline:
                assert child.poll() is None
                time.sleep(.02)
            assert ready.exists()
            stage = next(root.glob('.swarmcrate-*'))
            owner = json.loads((stage / 'owner.json').read_text())
            before = {p.name: p.read_bytes() for p in stage.iterdir()}
            assert row_for(stage)['status'] == 'active'
            clean(stage, owner, code=1)
            assert before == {p.name: p.read_bytes() for p in stage.iterdir()}
            checks += 1
        finally:
            child.kill()
            child.wait(timeout=10)
        assert row_for(stage)['status'] == 'orphan'
        clean(stage, owner)
        assert not stage.exists() and not live_target.exists()
        checks += 1

        # Two separate operations: selection cleans exactly one; post-link output survives.
        first, own1, rec1, target1 = interrupted('before')
        second, own2, rec2, target2 = interrupted('after', 'linked')
        saved = target2.read_bytes()
        command('verify', target2, payload)
        command('staging-clean', first, '--operation', own2['operation_id'], code=1)
        assert first.exists() and second.exists()
        clean(first, own1)
        assert not first.exists() and not rec1.exists() and second.exists() and rec2.exists() and not target1.exists()
        clean(second, own2)
        assert not second.exists() and not rec2.exists() and target2.read_bytes() == saved
        checks += 3

        # Ambiguous entries and pre-existing ordinary files are never interpreted as ownership.
        legacy = root / '.swarmcrate-legacy'
        legacy.mkdir()
        (legacy / 'data').write_bytes(b'foreign task')
        ordinary = root / '.swarmcrate-ordinary-file'
        ordinary.write_bytes(b'keep')
        assert row_for(legacy)['status'] == row_for(ordinary)['status'] == 'unverified'
        command('staging-clean', legacy, '--operation', '0' * 32, code=1)
        assert (legacy / 'data').read_bytes() == b'foreign task' and ordinary.read_bytes() == b'keep'
        checks += 1

        # Tamper one property, prove zero stage deletions, then restore only our own fixture.
        for fault in ['extra-file', 'subdirectory', 'missing-receipt', 'receipt-mismatch', 'marker-truncated', 'foreign-host', 'foreign-user', 'live-pid', 'data-replaced', 'data-oversize', 'cleanup-lock']:
            stage, owner, receipt, target = interrupted(fault)
            marker = stage / 'owner.json'
            original = marker.read_bytes()
            data_bytes = (stage / 'data').read_bytes()
            extra = stage / ('extra' if fault != 'cleanup-lock' else 'cleanup.lock')
            if fault in ['extra-file', 'cleanup-lock']:
                extra.write_bytes(b'other task')
            elif fault == 'subdirectory':
                extra.mkdir()
                (extra / 'keep').write_bytes(b'keep')
            elif fault == 'missing-receipt':
                receipt.unlink()
            elif fault == 'receipt-mismatch':
                receipt.write_bytes(b'wrong')
            elif fault == 'marker-truncated':
                marker.write_bytes(b'{')
            elif fault in ['foreign-host', 'foreign-user', 'live-pid']:
                changed = dict(owner)
                changed[{'foreign-host':'host', 'foreign-user':'user', 'live-pid':'pid'}[fault]] = os.getpid() if fault == 'live-pid' else 'different-machine-or-user'
                marker.write_text(json.dumps(changed), encoding='utf-8')
                receipt.write_bytes(marker.read_bytes())
            elif fault == 'data-replaced':
                (stage / 'data').rename(stage / 'original')
                (stage / 'data').write_bytes(data_bytes)
                # Unknown original is a second independent reason to preserve; move it outside.
                (stage / 'original').rename(root / 'saved-data')
            elif fault == 'data-oversize':
                (stage / 'data').write_bytes(b'x' * (int(owner['expected_bytes']) + 1))
            expected = 'active' if fault == 'live-pid' else 'unverified'
            assert row_for(stage)['status'] == expected, (fault, row_for(stage))
            before_names = sorted(p.name for p in stage.iterdir())
            clean(stage, owner, code=1)
            assert before_names == sorted(p.name for p in stage.iterdir()) and not target.exists()
            # Restore exact original object identities, not fabricated cleanup authorization.
            if fault in ['extra-file', 'cleanup-lock']:
                extra.unlink()
            elif fault == 'subdirectory':
                (extra / 'keep').unlink()
                extra.rmdir()
            elif fault == 'data-replaced':
                (stage / 'data').unlink()
                (root / 'saved-data').rename(stage / 'data')
            elif fault == 'data-oversize':
                (stage / 'data').write_bytes(data_bytes)
            marker.write_bytes(original)
            receipt.write_bytes(original)
            receipt.chmod(0o600)
            clean(stage, owner)
            checks += 1

        # Changes after inspection / exclusive claim and real deletion failures.
        for fault in ['add-after-claim', 'data-after-claim', 'receipt-after-claim', 'unlink-fail', 'rmdir-fail', 'probe-unknown', 'claim-race', 'swap-after-claim']:
            stage, owner, receipt, target = interrupted(fault)
            injected = root / (fault + '.mjs')
            injected.write_text('''import fs from 'node:fs';
import path from 'node:path';
const stage=process.env.SWARM_CLEAN_STAGE,receipt=process.env.SWARM_CLEAN_RECEIPT,fault=process.env.SWARM_CLEAN_FAULT;
const open=fs.openSync,close=fs.closeSync,unlink=fs.unlinkSync,rmdir=fs.rmdirSync,kill=process.kill;
let swapFd;
fs.openSync=function(p,...a){if(fault==='claim-race'&&path.resolve(String(p))===path.join(stage,'cleanup.lock')){const other=open.call(this,p,'wx',0o600);writeOther(other);}
const fd=open.call(this,p,...a);if(path.resolve(String(p))===path.join(stage,'cleanup.lock')){if(fault==='add-after-claim')fs.writeFileSync(path.join(stage,'injected'),'keep');if(fault==='data-after-claim')fs.appendFileSync(path.join(stage,'data'),'!');if(fault==='receipt-after-claim')fs.appendFileSync(receipt,' ');if(fault==='swap-after-claim')swapFd=fd;}return fd;};
fs.closeSync=function(fd){const swap=fd===swapFd;const result=close.call(this,fd);if(swap){swapFd=undefined;fs.renameSync(stage,stage+'.saved');fs.mkdirSync(stage);fs.writeFileSync(path.join(stage,'data'),'other data');fs.writeFileSync(path.join(stage,'owner.json'),'other owner');}return result;};
function writeOther(fd){try{fs.writeSync(fd,Buffer.from('other cleaner'));}finally{fs.closeSync(fd);}}
fs.unlinkSync=function(p){if(fault==='unlink-fail'&&path.resolve(String(p))===path.join(stage,'data'))throw Error('injected unlink failure');return unlink.call(this,p);};
fs.rmdirSync=function(p){if(fault==='rmdir-fail'&&path.resolve(String(p))===stage)throw Error('injected rmdir failure');return rmdir.call(this,p);};
if(fault==='probe-unknown')process.kill=function(pid,sig){if(sig===0){const e=Error('denied');e.code='EPERM';throw e;}return kill.call(this,pid,sig);};
''', encoding='utf-8')
            environment = dict(os.environ, SWARM_CLEAN_STAGE=str(stage), SWARM_CLEAN_RECEIPT=str(receipt), SWARM_CLEAN_FAULT=fault)
            result = command('staging-clean', stage, '--operation', owner['operation_id'], code=1, preload=injected, env=environment)
            assert result['error'] in ['staging', 'changed'] and stage.exists() and not target.exists()
            if fault == 'add-after-claim':
                assert (stage / 'injected').read_bytes() == b'keep'
                (stage / 'injected').unlink()
            if fault == 'claim-race':
                assert (stage / 'cleanup.lock').read_bytes() == b'other cleaner'
                assert (stage / 'data').exists() and (stage / 'owner.json').exists()
                (stage / 'cleanup.lock').unlink()
            if fault == 'swap-after-claim':
                assert (stage / 'data').read_bytes() == b'other data' and (stage / 'owner.json').read_bytes() == b'other owner'
                moved = stage.with_name(stage.name + '.saved')
                assert (moved / 'data').exists() and (moved / 'owner.json').exists() and (moved / 'cleanup.lock').exists()
                (stage / 'data').unlink()
                (stage / 'owner.json').unlink()
                stage.rmdir()
                moved.rename(stage)
                (stage / 'cleanup.lock').unlink()  # Exact test-owned claim, not automatic recovery.
            if fault == 'rmdir-fail':
                assert not list(stage.iterdir())  # Honest partial cleanup; no invented success.
                stage.rmdir()
                receipt.unlink()
            else:
                if fault == 'receipt-after-claim':
                    receipt.write_bytes((stage / 'owner.json').read_bytes())
                clean(stage, owner)
            checks += 1

        # Two actual cleaner processes contend for the same operation.
        stage, owner, receipt, target = interrupted('two-cleaners', 'linked')
        target_bytes = target.read_bytes()
        claimed, release = root / 'claimed', root / 'release'
        pause = root / 'pause-cleaner.mjs'
        pause.write_text('''import fs from 'node:fs';
import path from 'node:path';
const open=fs.openSync;
fs.openSync=function(p,...a){const fd=open.call(this,p,...a);if(path.basename(String(p))==='cleanup.lock'){fs.writeFileSync(process.env.SWARM_CLAIM_READY,'ready');const deadline=Date.now()+20000;while(!fs.existsSync(process.env.SWARM_CLAIM_RELEASE)){if(Date.now()>deadline)throw Error('cleaner fixture timeout');Atomics.wait(new Int32Array(new SharedArrayBuffer(4)),0,0,20);}}return fd;};
''', encoding='utf-8')
        first = subprocess.Popen([node, '--import', pause.as_uri(), str(cli), 'staging-clean', str(stage), '--operation', owner['operation_id']],
                                 stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, encoding='utf-8',
                                 env=dict(os.environ, SWARM_CLAIM_READY=str(claimed), SWARM_CLAIM_RELEASE=str(release)))
        try:
            deadline = time.monotonic() + 15
            while not claimed.exists() and time.monotonic() < deadline:
                assert first.poll() is None
                time.sleep(.02)
            assert claimed.exists()
            before = {p.name: p.read_bytes() for p in stage.iterdir()}
            receipt_before = receipt.read_bytes()
            clean(stage, owner, code=1)
            assert before == {p.name: p.read_bytes() for p in stage.iterdir()} and receipt.read_bytes() == receipt_before
            release.write_bytes(b'release')
            stdout, stderr = first.communicate(timeout=10)
            assert first.returncode == 0 and json.loads(stdout)['status'] == 'removed', (stdout, stderr)
            assert not stage.exists() and not receipt.exists() and target.read_bytes() == target_bytes
        finally:
            if first.poll() is None:
                first.kill()
                first.wait(timeout=10)
        checks += 1

        # Real symlink/junction is explicitly preserved on platforms with fixture permission.
        stage, owner, receipt, _ = interrupted('link-member')
        (stage / 'data').rename(root / 'link-original')
        symlinks = 'not available'
        try:
            os.symlink(payload, stage / 'data')
            assert row_for(stage)['status'] == 'unverified'
            clean(stage, owner, code=1)
            assert (stage / 'data').is_symlink() and payload.read_bytes()
            (stage / 'data').unlink()
            symlinks = 'passed'
            checks += 1
        except OSError:
            pass
        (root / 'link-original').rename(stage / 'data')
        clean(stage, owner)
        assert (legacy / 'data').read_bytes() == b'foreign task' and ordinary.read_bytes() == b'keep'
        assert not list(Path(tempfile.gettempdir()).resolve().glob('.swarmcrate-owner-' + owner['operation_id'] + '.json'))
        print(json.dumps({'staging_scenarios': checks, 'symlink_fixture': symlinks}))
        return checks


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--node', default='node')
    parser.add_argument('--cli', type=Path, default=ROOT / '_build/js/release/build/cmd/main/main.js')
    parser.add_argument('--example', type=Path, default=ROOT / '_build/js/release/build/examples/create_controlled_io/create_controlled_io.js')
    args = parser.parse_args()
    staging_scenarios(args.node, args.cli.resolve(), args.example.resolve())
