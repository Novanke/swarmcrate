"""Real output preflight, path-alias and failed-write ownership regressions."""
import argparse
import ctypes
import json
import os
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]


def output_safety_scenarios(node, cli, controlled):
    checks = 0
    with tempfile.TemporaryDirectory(prefix='swarmcrate-output-safety-') as temporary:
        root = Path(temporary).resolve()
        source = root / 'payload.bin'
        source.write_bytes(bytes(i % 251 for i in range(70001)))
        preload = root / 'output-faults.mjs'
        preload.write_text('''import fs from 'node:fs';import path from 'node:path';
const open=fs.openSync,read=fs.readSync,close=fs.closeSync,opendir=fs.opendirSync,fds=new Map();
const source=path.resolve(process.env.SWARM_SAFETY_SOURCE),target=path.resolve(process.env.SWARM_SAFETY_TARGET);
const stats={bytes:0,source_opens:0,directory_opens:0,injected:false};
fs.openSync=function(p,...a){const full=path.resolve(String(p));if(full===source)stats.source_opens++;const fd=open.call(this,p,...a);fds.set(fd,full);return fd;};
fs.opendirSync=function(...a){stats.directory_opens++;return opendir.apply(this,a);};
fs.readSync=function(fd,...a){const n=read.call(this,fd,...a);if(fds.get(fd)===source)stats.bytes+=n;return n;};
fs.closeSync=function(fd){const full=fds.get(fd);fds.delete(fd);const result=close.call(this,fd);if(process.env.SWARM_SAFETY_FAULT==='replace-close'&&full===target&&!stats.injected){stats.injected=true;fs.renameSync(target,target+'.original');fs.writeFileSync(target,'competing task');throw Error('injected close failure after another writer replaced the path');}return result;};
process.on('exit',()=>fs.writeFileSync(process.env.SWARM_SAFETY_STATS,JSON.stringify(stats)));
''', encoding='utf-8')

        def command(parts, code=0, program=cli, target=None, fault=''):
            env = dict(os.environ)
            prefix = []
            stats = root / 'stats.json'
            if target is not None:
                prefix = ['--import', preload.as_uri()]
                env.update(SWARM_SAFETY_SOURCE=str(source), SWARM_SAFETY_TARGET=str(target), SWARM_SAFETY_STATS=str(stats), SWARM_SAFETY_FAULT=fault)
            result = subprocess.run([node, *prefix, str(program), *map(str, parts)], capture_output=True, text=True, encoding='utf-8', env=env)
            assert result.returncode == code, (parts, result.returncode, result.stdout, result.stderr)
            value = json.loads(result.stdout)
            return value, json.loads(stats.read_text()) if target is not None else None

        for mode in ['v1', 'v2', 'hybrid']:
            seed = root / (mode + '.torrent')
            command(['create', source, seed, '--mode', mode])
            for variant, target in [('existing', seed), ('missing-parent', root / 'absent' / (mode + '.torrent')), ('directory', root)]:
                before = seed.read_bytes()
                for program, prefix in [(cli, []), (controlled, ['full'])]:
                    result, observed = command([*prefix, 'create', source, target, '--mode', mode], code=1, program=program, target=target)
                    assert result['error'] == 'usage' and observed['source_opens'] == observed['bytes'] == observed['directory_opens'] == 0
                    assert seed.read_bytes() == before
                    checks += 1
            # A same-path replacement after close must outlive this writer's error handling.
            for kind in ['create', 'edit', 'receipt', 'diagnostics', 'html']:
                target = root / (mode + '-' + kind + '.out')
                parts = ['create', source, target, '--mode', mode] if kind == 'create' else ['edit', seed, target] if kind == 'edit' else ['verify', seed, source, '--' + kind, target]
                result, observed = command(parts, code=1, target=target, fault='replace-close')
                assert result['error'] == 'io' and observed['injected']
                assert target.read_bytes() == b'competing task'
                assert (Path(str(target) + '.original')).is_file()
                checks += 1

        # Invalid sources remain isolated, and unselected unusable paths do not block export.
        payload = root / 'scope-input'
        payload.mkdir()
        (payload / 'good').write_bytes(b'hello')
        (payload / 'nested').mkdir()
        (payload / 'nested/leaf').write_bytes(b'other')
        seed = root / 'scope.torrent'
        command(['create', payload, seed])
        (payload / 'nested/leaf').unlink()
        (payload / 'nested').rmdir()
        (payload / 'nested').write_bytes(b'not a directory')
        report = root / 'scope-receipt.json'
        result, _ = command(['verify', seed, payload, '--file', 'good', '--receipt', report])
        assert result['ok'] and not result['complete'] and report.is_file()
        checks += 1
        manifest = root / 'isolated.json'
        manifest.write_text(json.dumps({'schema':'swarmcrate.audit-manifest.v1','tasks':[
            {'id':'bad','metainfo':str(source / 'not-a-directory.torrent'),'payload':str(source)},
            {'id':'good','metainfo':str(root / 'hybrid.torrent'),'payload':str(source)}]}),encoding='utf-8')
        result, _ = command(['audit-batch', manifest, root / 'isolated-summary.json'],code=1)
        assert [task['outcome'] for task in result['tasks']] == ['ERROR','PASS']
        checks += 1

        # Report aliases must not create a missing/unselected payload file.
        alias_checks = 0
        short_alias = 'not available'
        if os.name == 'nt':
            payload = root / 'long-payload-directory-for-alias'
            payload.mkdir()
            (payload / 'good').write_bytes(b'hello')
            missing = payload / 'missing.json'
            missing.write_bytes(b'')
            seed = root / 'alias.torrent'
            command(['create', payload, seed])
            missing.unlink()
            extended = lambda p: '\\\\?\\' + str(p)
            device_drive = lambda p: '\\\\.\\' + str(p)
            aliases = [(str(payload), extended(missing)), (extended(payload), str(missing)),
                       (str(payload), device_drive(missing)), (device_drive(payload), str(missing))]
            get_short = ctypes.WinDLL('kernel32', use_last_error=True).GetShortPathNameW
            get_short.argtypes = [ctypes.c_wchar_p, ctypes.c_wchar_p, ctypes.c_uint]
            get_short.restype = ctypes.c_uint
            buffer = ctypes.create_unicode_buffer(32768)
            size = get_short(str(payload), buffer, len(buffer))
            if size and size < len(buffer) and buffer.value.lower() != str(payload).lower():
                aliases.append((str(payload), str(Path(buffer.value) / missing.name)))
                short_alias = 'passed'
            for index, (payload_name, output_name) in enumerate(aliases):
                for option in ['--receipt', '--diagnostics', '--html']:
                    result, _ = command(['verify', seed, payload_name, '--file', 'good', option, output_name], code=1)
                    assert result['error'] == 'usage' and not missing.exists(), (index, option, result, output_name, payload_name)
                    checks += 1
                    alias_checks += 1
                manifest = root / ('alias-' + str(index) + '.json')
                manifest.write_text(json.dumps({'schema':'swarmcrate.audit-manifest.v1','tasks':[{'id':'selected','metainfo':str(seed),'payload':payload_name,'files':['good']}]}), encoding='utf-8')
                result, _ = command(['audit-batch', manifest, output_name], code=1)
                assert result['error'] == 'usage' and not missing.exists()
                checks += 1
                alias_checks += 1
            for suffix in ['.', ' ', ':receipt']:
                result, _ = command(['verify', seed, payload, '--file', 'good', '--receipt', str(missing) + suffix], code=1)
                assert result['error'] in ['io','usage'] and not missing.exists()
                checks += 1
        result = {'output_safety_scenarios': checks, 'windows_alias_scenarios': alias_checks, 'short_alias_fixture': short_alias}
        print(json.dumps(result))
        return result


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--node', default='node')
    parser.add_argument('--cli', type=Path, default=ROOT / '_build/js/release/build/cmd/main/main.js')
    parser.add_argument('--example', type=Path, default=ROOT / '_build/js/release/build/examples/create_controlled_io/create_controlled_io.js')
    args = parser.parse_args()
    output_safety_scenarios(args.node, args.cli.resolve(), args.example.resolve())
