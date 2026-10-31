"""Run the built MoonBit CLI against real files and independent BitTorrent implementations.
Test-only dependencies: libtorrent==2.1.1, torf==4.3.1. No network sessions are started.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import random
import subprocess
import tempfile

import libtorrent as lt
import torf

ROOT = Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser()
parser.add_argument("--node", default="node")
parser.add_argument("--cli", type=Path, default=ROOT / "_build/js/release/build/cmd/main/main.js")
args = parser.parse_args()
checks = 0


def command(*parts, code=0):
    result = subprocess.run([args.node, str(args.cli), *map(str, parts)], capture_output=True, text=True, encoding="utf-8")
    assert result.returncode == code, (parts, result.returncode, result.stdout, result.stderr)
    return result.stdout


def merkle(data):
    if not data:
        return b""
    nodes = [hashlib.sha256(data[i:i + 16384]).digest() for i in range(0, len(data), 16384)]
    capacity = 1 << (len(nodes) - 1).bit_length()
    nodes += [bytes(32)] * (capacity - len(nodes))
    while len(nodes) > 1:
        nodes = [hashlib.sha256(nodes[i] + nodes[i + 1]).digest() for i in range(0, len(nodes), 2)]
    return nodes[0]


def tree_files(tree, prefix=()):
    for key, value in tree.items():
        if key == b"":
            yield prefix, value
        else:
            yield from tree_files(value, prefix + (key.decode("utf-8"),))


def independent_check(path, payload, mode, single):
    global checks
    raw = path.read_bytes()
    top = lt.bdecode(raw)
    info = top[b"info"]
    parsed = lt.torrent_info(top)  # Mature implementation must accept the output.
    summary = json.loads(command("inspect", path))
    hashes = parsed.info_hashes()
    assert hashes.has_v1() == (mode != "v2")
    assert hashes.has_v2() == (mode != "v1")
    if mode != "v2":
        assert summary["info_hash_v1"] == str(hashes.v1)
        if b"length" in info:
            data = payload.read_bytes()
        else:
            chunks = []
            for file in info[b"files"]:
                if b"p" in file.get(b"attr", b""):
                    chunks.append(bytes(file[b"length"]))
                else:
                    chunks.append(payload.joinpath(*(p.decode("utf-8") for p in file[b"path"])).read_bytes())
            data = b"".join(chunks)
        piece = info[b"piece length"]
        expected = b"".join(hashlib.sha1(data[i:i + piece]).digest() for i in range(0, len(data), piece))
        assert expected == info[b"pieces"]
        if mode == "v1":
            assert torf.Torrent.read(path).verify(payload, threads=1)
    if mode != "v1":
        assert summary["info_hash_v2"] == str(hashes.v2)
        for components, file in tree_files(info[b"file tree"]):
            data = (payload if single else payload.joinpath(*components)).read_bytes()
            assert file[b"length"] == len(data)
            assert file.get(b"pieces root", b"") == merkle(data)
    magnet = command("magnet", path).strip()
    decoded = lt.parse_magnet_uri(magnet).info_hashes
    assert decoded == hashes
    report = json.loads(command("verify", path, payload))
    assert report["ok"] and report["failed_pieces"] == 0
    checks += 1


def libtorrent_reference(payload, mode, piece, output):
    storage = lt.file_storage()
    if payload.is_file():
        storage.add_file(payload.name, payload.stat().st_size)
    else:
        for file in sorted(payload.rglob("*")):
            if file.is_file():
                storage.add_file(str(file.relative_to(payload.parent)).replace(os.sep, "/"), file.stat().st_size)
    flag = lt.create_torrent.v1_only if mode == "v1" else lt.create_torrent.v2_only if mode == "v2" else 0
    creator = lt.create_torrent(storage, piece, flag)
    lt.set_piece_hashes(creator, str(payload.parent))
    output.write_bytes(lt.bencode(creator.generate()))
    report = json.loads(command("verify", output, payload))
    assert report["ok"], report


def creation_planning(directory):
    """Plans must agree with independently decoded output without reading payloads."""
    global checks
    payload = directory / "planning"
    payload.mkdir()
    (payload / "a.bin").write_bytes(b"abc")
    (payload / "b.bin").write_bytes(bytes(i % 251 for i in range(32769)))
    (payload / "z-empty").write_bytes(b"")
    before = {p.name: p.read_bytes() for p in payload.iterdir()}
    preload = ROOT / "scripts/fixtures/no_payload_reads.mjs"
    for mode in ["v1", "v2", "hybrid"]:
        for policy in ["auto", "16384", "1048576"]:
            env = {**os.environ, "SWARM_PLAN_ROOT": str(payload)}
            result = subprocess.run([args.node, "--import", preload.as_uri(), str(args.cli), "plan", str(payload),
                                     "--mode", mode, "--piece-length", policy],
                                    capture_output=True, text=True, encoding="utf-8", env=env)
            assert result.returncode == 0, result.stderr + result.stdout
            plan = json.loads(result.stdout)
            assert plan["schema"] == "swarmcrate.plan.v1"
            assert plan["file_count"] == 3 and plan["empty_files"] == 1
            assert plan["real_bytes"] == "32772"
            piece = plan["piece_length"]
            assert piece == (16384 if policy == "auto" else int(policy))
            torrent = directory / f"planned-{mode}-{policy}.torrent"
            command("create", payload, torrent, "--mode", mode, "--piece-length", policy)
            lt.torrent_info(str(torrent))
            top = lt.bdecode(torrent.read_bytes())
            info = top[b"info"]
            v1 = len(info.get(b"pieces", b"")) // 20
            v2 = sum((len(data) + piece - 1) // piece for data in before.values()) if mode != "v1" else 0
            padding = sum(f[b"length"] for f in info.get(b"files", []) if f.get(b"attr") == b"p")
            actual_layers = sum(len(layer) for layer in top.get(b"piece layers", {}).values())
            assert plan["v1_pieces"] == v1 and plan["v2_pieces"] == v2
            assert int(plan["v1_hash_bytes"]) == v1 * 20
            assert int(plan["padding_bytes"]) == padding
            assert int(plan["storage_bytes"]) == 32772 + padding
            assert int(plan["v2_piece_layer_bytes_upper_bound"]) >= actual_layers
            assert json.loads(command("verify", torrent, payload))["ok"]
            assert {p.name: p.read_bytes() for p in payload.iterdir()} == before
            checks += 1
    # Single-file layout never receives hybrid inter-file padding.
    single = payload / "a.bin"
    env = {**os.environ, "SWARM_PLAN_ROOT": str(single)}
    result = subprocess.run([args.node, "--import", preload.as_uri(), str(args.cli), "plan", str(single)],
                            capture_output=True, text=True, encoding="utf-8", env=env)
    assert result.returncode == 0, result.stderr + result.stdout
    assert json.loads(result.stdout)["padding_bytes"] == "0"
    checks += 1


def source_snapshot_verification(directory):
    """Mutate actual directory membership without changing any original file bytes."""
    global checks
    preload = ROOT / "scripts/fixtures/source_changes.mjs"
    for mode in ["v1", "v2", "hybrid"]:
        reference = None
        for action in ["stable", "reorder", "add", "fill-empty", "add-empty", "remove-empty", "rename-empty", "replace-empty", "during-list"]:
            payload = directory / f"snapshot-{mode}-{action}"
            (payload / "empty").mkdir(parents=True)
            data = bytes(i % 251 for i in range(70001))
            (payload / "a.bin").write_bytes(data)
            (payload / "b.txt").write_bytes(b"secondary")
            output = directory / f"snapshot-{mode}-{action}.torrent"
            counts = directory / f"snapshot-{mode}-{action}.json"
            # Keep every mutation case on a fresh target. Existing destinations
            # are rejected before scanning and covered by output_safety_interop.py.
            env = {**os.environ, "SWARM_SNAPSHOT_ROOT": str(payload), "SWARM_SNAPSHOT_ACTION": action,
                   "SWARM_SNAPSHOT_RESULT": str(counts)}
            result = subprocess.run([args.node, "--import", preload.as_uri(), str(args.cli),
                                     "create", str(payload), str(output), "--mode", mode, "--name", "snapshot-fixture"],
                                    capture_output=True, text=True, encoding="utf-8", env=env)
            stable = action in ["stable", "reorder"]
            assert result.returncode == (0 if stable else 1), result.stderr + result.stdout
            observed = json.loads(counts.read_text())
            assert observed["opened"] == observed["closed"] and observed["opened"] >= 2
            if stable:
                assert observed["mutations"] == 0
                if action == "reorder":
                    assert observed["reordered"] > 0
                lt.torrent_info(str(output))
                summary = json.loads(command("inspect", output))
                assert [f["path"] for f in summary["files"]] == [["a.bin"], ["b.txt"]]
                hashes = (summary["info_hash_v1"], summary["info_hash_v2"])
                if reference is None:
                    reference = hashes
                else:
                    assert hashes == reference, "directory order must not change content identity"
                assert json.loads(command("verify", output, payload))["ok"]
            else:
                assert observed["mutations"] == 1
                assert json.loads(result.stdout)["error"] == "changed", result.stdout
                assert not output.exists(), "stale metadata must not be committed"
            assert (payload / "a.bin").read_bytes() == data
            assert (payload / "b.txt").read_bytes() == b"secondary"
            checks += 1


def single_pass_hybrid_verification(directory):
    """Observe actual Node filesystem reads, without replacing MoonBit hashing."""
    global checks
    payload = directory / "single-pass"
    payload.mkdir()
    (payload / "a.bin").write_bytes(bytes(i % 251 for i in range(2097169)))
    (payload / "b.bin").write_bytes(b"abc")
    (payload / "empty").write_bytes(b"")
    preload = directory / "observe-reads.mjs"
    preload.write_text('''import fs from 'node:fs';
import path from 'node:path';
const root = path.resolve(process.env.SWARM_READ_ROOT);
const watched = new Map();
const stats = {bytes:0, calls:0, max_request:0, faults:0};
const open = fs.openSync, read = fs.readSync, close = fs.closeSync;
fs.openSync = function(file, ...rest) {
  const fd = open.call(this, file, ...rest);
  const full = path.resolve(String(file));
  if (full === root || full.startsWith(root + path.sep)) watched.set(fd, full);
  return fd;
};
fs.readSync = function(fd, buffer, offset, length, position) {
  if (watched.has(fd)) {
    stats.max_request = Math.max(stats.max_request, length);
    if (process.env.SWARM_READ_FAULT && watched.get(fd).endsWith('a.bin') && position === 1048576) {
      stats.faults++;
      if (process.env.SWARM_READ_FAULT === 'throw') throw Error('test-only read failure');
      return 0;
    }
  }
  const n = read.call(this, fd, buffer, offset, length, position);
  if (watched.has(fd)) { stats.bytes += n; stats.calls++; }
  return n;
};
fs.closeSync = function(fd) { watched.delete(fd); return close.call(this, fd); };
process.on('exit', () => fs.writeFileSync(process.env.SWARM_READ_RESULT, JSON.stringify(stats)));
''', encoding="utf-8")
    for piece in [32768, 2097152]:
        torrent = directory / f"one-pass-{piece}.torrent"
        command("create", payload, torrent, "--mode", "hybrid", "--piece-length", piece)
        lt.torrent_info(str(torrent))
        total = json.loads(command("verify", torrent, payload))["checked_pieces"]
        for selected, expected in [(None, 2097172), ("a.bin", 2097169), ("b.bin", 3), ("empty", 0)]:
            counts = directory / f"reads-{piece}-{selected}.json"
            env = {**os.environ, "SWARM_READ_ROOT": str(payload), "SWARM_READ_RESULT": str(counts)}
            env.pop("SWARM_READ_FAULT", None)
            parts = ["verify", str(torrent), str(payload)]
            receipt_path = directory / f"reads-{piece}-{selected}-receipt.json"
            diagnostics_path = directory / f"reads-{piece}-{selected}-diagnostics.json"
            parts += ["--receipt", str(receipt_path), "--diagnostics", str(diagnostics_path)]
            if selected is not None:
                parts += ["--file", selected]
            result = subprocess.run([args.node, "--import", preload.as_uri(), str(args.cli), *parts],
                                    capture_output=True, text=True, encoding="utf-8", env=env)
            assert result.returncode == 0, result.stderr + result.stdout
            report = json.loads(result.stdout)
            assert json.loads(receipt_path.read_text(encoding="utf-8"))["verification"] == report
            assert json.loads(diagnostics_path.read_text(encoding="utf-8")) == json.loads(receipt_path.read_text(encoding="utf-8"))["file_diagnostics"]
            observed = json.loads(counts.read_text())
            assert report["ok"] and report["checked_pieces"] + report["skipped_pieces"] == total
            assert observed["bytes"] == expected and observed["max_request"] <= 1048576
            assert report["complete"] == (selected is None)
            checks += 1
        if piece == 2097152:
            for fault in ["throw", "short"]:
                counts = directory / f"fault-{fault}.json"
                env = {**os.environ, "SWARM_READ_ROOT": str(payload), "SWARM_READ_RESULT": str(counts),
                       "SWARM_READ_FAULT": fault}
                receipt_path = directory / f"fault-{fault}-receipt.json"
                diagnostics_path = directory / f"fault-{fault}-diagnostics.json"
                result = subprocess.run([args.node, "--import", preload.as_uri(), str(args.cli), "verify", str(torrent), str(payload), "--receipt", str(receipt_path), "--diagnostics", str(diagnostics_path)],
                                        capture_output=True, text=True, encoding="utf-8", env=env)
                assert result.returncode == 2, result.stderr + result.stdout
                report = json.loads(result.stdout)
                receipt = json.loads(receipt_path.read_text(encoding="utf-8"))
                assert receipt["verification"] == report and receipt["outcome"] == "FAIL"
                diagnostic = json.loads(diagnostics_path.read_text(encoding="utf-8"))
                assert diagnostic == receipt["file_diagnostics"]
                assert diagnostic["files"][0]["unreadable_ranges"] == [{"offset": "0", "length": "2097152"}]
                assert diagnostic["files"][0]["attention_bytes"] == "2097152"
                observed = json.loads(counts.read_text())
                assert report["checked_pieces"] == total and report["failed_pieces"] == report["unreadable_pieces"] == 2
                assert [f["scheme"] for f in report["failures"]] == ["sha1", "sha256"]
                assert observed["faults"] == 1 and observed["bytes"] == 1048576 + 17 + 3
                checks += 1


def padded_v1_verification(directory):
    """Independent BEP 47 fixtures: no padding files are ever put on disk."""
    global checks
    payload = directory / "padded-bundle"
    payload.mkdir()
    content = {b"a": b"abc", b"b": b"def", b"c": b"ghijk", b"empty": b""}
    for name, data in content.items():
        (payload / name.decode()).write_bytes(data)
    for aligned, trailing in [(False, False), (True, False), (True, True)]:
        nodes, stream = [], bytearray()
        for name, data in content.items():
            nodes.append({b"path": [name], b"length": len(data)})
            stream.extend(data)
            if (name == b"a" or (aligned and name == b"b") or (trailing and name == b"c")):
                size = 16384 - len(stream) % 16384
                nodes.append({b"attr": b"p", b"path": [b".pad", str(size).encode()], b"length": size})
                stream.extend(bytes(size))
        info = {b"name": b"padded-bundle", b"files": nodes, b"piece length": 16384,
                b"pieces": b"".join(hashlib.sha1(stream[i:i + 16384]).digest() for i in range(0, len(stream), 16384))}
        torrent = directory / f"padded-{aligned}-{trailing}.torrent"
        torrent.write_bytes(lt.bencode({b"info": info}))
        reference = lt.torrent_info(str(torrent))
        summary = json.loads(command("inspect", torrent))
        assert [f["path"] for f in summary["files"]] == [[name.decode()] for name in content]
        assert summary["info_hash_v1"] == str(reference.info_hashes().v1) == hashlib.sha1(lt.bencode(info)).hexdigest()
        report = json.loads(command("verify", torrent, payload))
        assert report["ok"] and report["checked_pieces"] == reference.num_pieces()
        assert not (payload / ".pad").exists()
        checks += 1
        # Padding isolates a's piece even while an unrelated real file is missing.
        (payload / "b").unlink()
        try:
            report = json.loads(command("verify", torrent, payload, "--file", "a"))
            assert report["ok"] and report["required_files"] == [0] and not report["complete"]
            assert not json.loads(command("verify", torrent, payload, code=2))["ok"]
        finally:
            (payload / "b").write_bytes(content[b"b"])
        checks += 1
        # Non-aligned files still share pieces: padding does not imply all files align.
        report = json.loads(command("verify", torrent, payload, "--file", "b"))
        assert report["required_files"] == ([1] if aligned else [1, 2])
        checks += 1
        (payload / "b").write_bytes(b"DEF")
        try:
            report = json.loads(command("verify", torrent, payload, code=2))
            assert report["failed_pieces"] == 1 and report["failures"][0]["piece"] == 1
            assert report["failures"][0]["spans"][0]["file"] == 1
        finally:
            (payload / "b").write_bytes(content[b"b"])
        checks += 1
        edited = directory / f"padded-edited-{aligned}-{trailing}.torrent"
        command("edit", torrent, edited, "--tracker", "https://example.org/announce")
        assert lt.bencode(lt.bdecode(edited.read_bytes())[b"info"]) == lt.bencode(info)
        assert json.loads(command("verify", edited, payload))["ok"]
        checks += 1


def receipt_verification(directory):
    """Bind exported receipts to independent raw/info hashes and actual file scopes."""
    global checks
    payload = directory / "receipt-payload"
    payload.mkdir()
    (payload / "a").write_bytes(b"abc")
    intact = bytes(i % 251 for i in range(32769))
    (payload / "b").write_bytes(intact)
    (payload / "empty").write_bytes(b"")

    def verify_receipt(torrent, output, *selection, code=0, html=None):
        params = ["verify", torrent, payload, *selection, "--receipt", output]
        if html is not None:
            params += ["--html", html]
        report = json.loads(command(*params, code=code))
        receipt = json.loads(output.read_text(encoding="utf-8"))
        raw = torrent.read_bytes()
        reference = lt.torrent_info(lt.bdecode(raw)).info_hashes()
        info = json.loads(command("inspect", torrent))
        assert report["schema"] == "swarmcrate.verify.v2"
        assert receipt["schema"] == "swarmcrate.receipt.v1"
        assert receipt["verification"] == report
        subject = receipt["subject"]
        assert subject["metainfo_sha256"] == hashlib.sha256(raw).hexdigest()
        assert subject["metainfo_bytes"] == str(len(raw))
        assert subject["info_hash_v1"] == (str(reference.v1) if reference.has_v1() else None)
        assert subject["info_hash_v2"] == (str(reference.v2) if reference.has_v2() else None)
        assert subject["files"] == [dict(index=i, **file) for i, file in enumerate(info["files"])]
        assert subject["mode"] == info["mode"] and subject["piece_length"] == info["piece_length"]
        assert subject["single_file"] == info["single_file"]
        assert receipt["outcome"] == ("FAIL" if not report["ok"] else "PASS" if report["complete"] else "PARTIAL_PASS")
        assert receipt["observations"] == [
            {"file": i, "actual_bytes": str(payload.joinpath(*info["files"][i]["path"]).stat().st_size)
             if payload.joinpath(*info["files"][i]["path"]).is_file() else None}
            for i in report["required_files"]]
        assert receipt["is_digital_signature"] is False and receipt["publisher_authenticated"] is False
        text = output.read_text(encoding="utf-8")
        assert str(payload) not in text and "private-receipt-fixture" not in text and "https://example.org" not in text
        if html:
            assert ("PARTIAL PASS" if receipt["outcome"] == "PARTIAL_PASS" else receipt["outcome"]) in html.read_text(encoding="utf-8")
        return receipt

    for mode in ["v1", "v2", "hybrid"]:
        torrent = directory / f"receipt-{mode}.torrent"
        command("create", payload, torrent, "--mode", mode, "--piece-length", "16384",
                "--tracker", "https://example.org/announce", "--comment", "private-receipt-fixture")
        full = verify_receipt(torrent, directory / f"receipt-{mode}-full.json", html=directory / f"receipt-{mode}.html")
        assert full["verification"] == json.loads(command("verify", torrent, payload))
        checks += 1
        partial = verify_receipt(torrent, directory / f"receipt-{mode}-partial.json", "--file", "a", "--file", "a")
        assert partial["verification"]["selected_files"] == [0]
        assert partial["verification"]["required_files"] == ([0, 1] if mode == "v1" else [0])
        assert partial["outcome"] == "PARTIAL_PASS"
        checks += 1
        damaged = bytearray(intact)
        damaged[20000] ^= 255
        (payload / "b").write_bytes(damaged)
        try:
            failed = verify_receipt(torrent, directory / f"receipt-{mode}-failed.json", code=2)
            assert failed["verification"]["failed_pieces"] == (2 if mode == "hybrid" else 1)
            assert failed["verification"]["failures"][0]["spans"][0]["offset"] == ("16381" if mode == "v1" else "16384")
        finally:
            (payload / "b").write_bytes(intact)
        checks += 1
        (payload / "empty").unlink()
        try:
            missing = verify_receipt(torrent, directory / f"receipt-{mode}-missing.json", "--file", "empty", code=2)
            assert missing["verification"]["checked_pieces"] == 0 and missing["outcome"] == "FAIL"
        finally:
            (payload / "empty").write_bytes(b"")
        checks += 1
        edited = directory / f"receipt-{mode}-edited.torrent"
        command("edit", torrent, edited, "--tracker", "https://example.org/new")
        different = verify_receipt(edited, directory / f"receipt-{mode}-edited.json")
        assert different["subject"]["info_hash_v1"] == full["subject"]["info_hash_v1"]
        assert different["subject"]["info_hash_v2"] == full["subject"]["info_hash_v2"]
        assert different["subject"]["metainfo_sha256"] != full["subject"]["metainfo_sha256"]
        checks += 1
        single = directory / f"receipt-single-{mode}.torrent"
        single_output = directory / f"receipt-single-{mode}.json"
        command("create", payload / "a", single, "--mode", mode)
        report = json.loads(command("verify", single, payload / "a", "--receipt", single_output))
        receipt = json.loads(single_output.read_text(encoding="utf-8"))
        assert receipt["verification"] == report and receipt["subject"]["single_file"]
        assert receipt["subject"]["files"] == [{"index": 0, "path": ["a"], "length": "3"}]
        assert receipt["subject"]["metainfo_sha256"] == hashlib.sha256(single.read_bytes()).hexdigest()
        checks += 1

    # Preflight every destination before payload reads or any report output.
    blocked = ROOT / "scripts/fixtures/no_payload_reads.mjs"
    fresh = directory / "preflight-receipt.json"
    existing = directory / "existing-report.html"
    existing.write_bytes(b"keep existing output")
    alias = directory / "same-report.json"
    empty = payload / "empty"
    empty.unlink()  # Must not recreate an unselected missing payload as a report.
    guards = [
        ["--receipt", fresh, "--html", existing],
        ["--receipt", alias, "--html", alias.parent / "." / alias.name],
        ["--receipt", alias, "--html", str(alias).upper()],
        ["--receipt", empty, "--file", "a"],
        ["--html", empty, "--file", "a"],
        ["--receipt", payload],
        ["--receipt", directory / "no-parent/out.json"],
        ["--receipt", ""],
    ]
    for extra in guards:
        result = subprocess.run([args.node, "--import", blocked.as_uri(), str(args.cli), "verify", str(torrent), str(payload), *map(str, extra)],
                                capture_output=True, text=True, encoding="utf-8", env={**os.environ, "SWARM_PLAN_ROOT": str(payload)})
        assert result.returncode == 1 and json.loads(result.stdout)["error"] == "usage", result.stderr + result.stdout
        assert not fresh.exists() and not alias.exists() and not empty.exists()
        assert existing.read_bytes() == b"keep existing output"
        checks += 1
    empty.write_bytes(b"")

    # A change detected after the last read must prevent both artifacts from being written.
    preload = directory / "receipt-changed.mjs"
    preload.write_text('''import fs from 'node:fs';
import path from 'node:path';
const root = path.resolve(process.env.SWARM_RECEIPT_ROOT), observed = new Map();
const open = fs.openSync, close = fs.closeSync;
fs.openSync = function(file, ...rest) {
  const fd = open.call(this, file, ...rest);
  if (path.resolve(String(file)) === path.join(root, 'b')) observed.set(fd, true);
  return fd;
};
fs.closeSync = function(fd) {
  const change = observed.delete(fd); const result = close.call(this, fd);
  if (change) fs.appendFileSync(path.join(root, 'b'), '!');
  return result;
};
''', encoding="utf-8")
    receipt_path, html_path = directory / "changed-receipt.json", directory / "changed-report.html"
    diagnostics_path = directory / "changed-diagnostics.json"
    result = subprocess.run([args.node, "--import", preload.as_uri(), str(args.cli), "verify", str(torrent), str(payload),
                             "--receipt", str(receipt_path), "--html", str(html_path), "--diagnostics", str(diagnostics_path)],
                            capture_output=True, text=True, encoding="utf-8", env={**os.environ, "SWARM_RECEIPT_ROOT": str(payload)})
    assert result.returncode == 1 and json.loads(result.stdout)["error"] == "changed", result.stderr + result.stdout
    assert not receipt_path.exists() and not html_path.exists() and not diagnostics_path.exists()
    checks += 1


def file_diagnostics_verification(directory):
    """Exercise grouped physical ranges, incomplete inventories and guarded outputs."""
    global checks
    payload = directory / "diagnostic-payload"
    payload.mkdir()
    data = bytes(i % 251 + 1 for i in range(65537))
    (payload / "a").write_bytes(b"abc")
    (payload / "b").write_bytes(data)
    (payload / "c").write_bytes(b"content")
    (payload / "empty").write_bytes(b"")
    for mode in ["v1", "v2", "hybrid"]:
        torrent = directory / f"diagnostic-{mode}.torrent"
        command("create", payload, torrent, "--mode", mode, "--piece-length", "16384")
        hashes = lt.torrent_info(lt.bdecode(torrent.read_bytes())).info_hashes()

        def run(suffix, *options, code=0):
            prefix = directory / f"diagnostic-{mode}-{suffix}"
            sidecar, receipt, html = prefix.with_suffix(".json"), prefix.with_suffix(".receipt.json"), prefix.with_suffix(".html")
            report = json.loads(command("verify", torrent, payload, *options, "--diagnostics", sidecar, "--receipt", receipt, "--html", html, code=code))
            exported = json.loads(receipt.read_text(encoding="utf-8"))
            diagnostic = json.loads(sidecar.read_text(encoding="utf-8"))
            assert exported["verification"] == report and exported["file_diagnostics"] == diagnostic
            assert diagnostic["schema"] == "swarmcrate.diagnostics.v1"
            assert diagnostic["metainfo_sha256"] == hashlib.sha256(torrent.read_bytes()).hexdigest()
            assert diagnostic["info_hash_v1"] == (str(hashes.v1) if hashes.has_v1() else None)
            assert diagnostic["info_hash_v2"] == (str(hashes.v2) if hashes.has_v2() else None)
            for key in ["ok", "complete", "selected_files", "required_files", "checked_pieces", "skipped_pieces", "failed_pieces", "unreadable_pieces", "details_truncated"]:
                assert diagnostic[key] == report[key]
            assert diagnostic["ranges_complete"] == (not report["details_truncated"])
            assert diagnostic["omitted_failure_checks"] == report["failed_pieces"] - len(report["failures"])
            assert [f["file"] for f in diagnostic["files"]] == report["required_files"]
            for file in diagnostic["files"]:
                assert file["selected"] == (file["file"] in report["selected_files"])
                assert file["ranges_complete"] == diagnostic["ranges_complete"]
                actual = payload.joinpath(*file["path"])
                assert file["actual_bytes"] == (str(actual.stat().st_size) if actual.is_file() else None)
                for kind in ["hash_mismatch", "unreadable", "missing", "extra", "attention"]:
                    end = -1
                    for interval in file[kind + "_ranges"]:
                        offset, length = int(interval["offset"]), int(interval["length"])
                        assert offset > end and length > 0
                        end = offset + length
                        assert end <= int(file["expected_bytes"]) if kind != "extra" else offset >= int(file["expected_bytes"])
                    assert int(file[kind + "_bytes"]) == sum(int(r["length"]) for r in file[kind + "_ranges"])
            assert "Per-file attention ranges" in html.read_text(encoding="utf-8")
            assert ("INCOMPLETE" in html.read_text(encoding="utf-8")) == report["details_truncated"]
            return report, diagnostic, {f["file"]: f for f in diagnostic["files"]}

        intact, diagnostic, rows = run("intact")
        assert intact == json.loads(command("verify", torrent, payload))
        assert diagnostic["files_with_recorded_issues"] == 0
        checks += 1
        damaged = bytearray(data)
        damaged[20000] ^= 255
        damaged[40000] ^= 255
        (payload / "b").write_bytes(damaged)
        report, diagnostic, rows = run("damage", code=2)
        offset = 16381 if mode == "v1" else 16384
        assert rows[1]["hash_mismatch_ranges"] == [{"offset": str(offset), "length": "32768"}]
        assert rows[1]["attention_bytes"] == "32768"  # Four hybrid hash failures, two physical pieces.
        assert diagnostic["files_with_recorded_issues"] == 1
        checks += 1
        report, diagnostic, rows = run("subset-good", "--file", "a")
        assert report["ok"] and not report["complete"] and diagnostic["ranges_complete"]
        assert list(rows) == ([0, 1] if mode == "v1" else [0])
        if mode == "v1":
            assert not rows[1]["selected"] and not rows[1]["has_recorded_issue"]
        checks += 1
        report, diagnostic, rows = run("subset-damage", "--file", "b", code=2)
        assert not report["complete"] and rows[1]["attention_bytes"] == "32768"
        checks += 1
        (payload / "b").write_bytes(data)
        (payload / "c").unlink()
        (payload / "empty").unlink()
        report, diagnostic, rows = run("missing", code=2)
        assert rows[2]["missing_ranges"] == [{"offset": "0", "length": "7"}]
        assert rows[3]["has_recorded_issue"] and rows[3]["attention_ranges"] == []
        assert rows[3]["size_issue"] == "missing"
        assert rows[1]["unreadable_bytes"] == ("4" if mode == "v1" else "0")
        checks += 1
        (payload / "c").write_bytes(b"content++")
        (payload / "empty").write_bytes(b"")
        (payload / "b").write_bytes(data[:20000])
        report, diagnostic, rows = run("sizes", code=2)
        assert rows[1]["missing_ranges"] == [{"offset": "20000", "length": "45537"}]
        assert rows[1]["unreadable_bytes"] == rows[1]["attention_bytes"] == "65537"
        assert rows[2]["extra_ranges"] == [{"offset": "7", "length": "2"}]
        assert rows[2]["attention_bytes"] == "7"
        assert (payload / "b").read_bytes() == data[:20000] and (payload / "c").read_bytes() == b"content++"
        checks += 1
        (payload / "b").write_bytes(bytes(len(data)))
        (payload / "c").write_bytes(b"changed")
        report, diagnostic, rows = run("truncated", "--detail-limit", "1", code=2)
        assert report["details_truncated"] and not diagnostic["ranges_complete"]
        assert diagnostic["omitted_failure_checks"] > 0
        assert not rows[2]["has_recorded_issue"] and not rows[2]["ranges_complete"]  # Omitted does not mean passed.
        checks += 1
        (payload / "b").write_bytes(data)
        (payload / "c").write_bytes(b"content")

    # Independent padded v1 metadata: diagnostic file indices must exclude virtual padding.
    padded = directory / "diagnostic-padded"
    padded.mkdir()
    (padded / "a").write_bytes(b"abc")
    (padded / "b").write_bytes(b"FAIL")
    stream = b"abc" + bytes(16381) + b"pass"
    info = {b"name": b"padded", b"piece length": 16384,
            b"files": [{b"path": [b"a"], b"length": 3}, {b"attr": b"p", b"length": 16381}, {b"path": [b"b"], b"length": 4}],
            b"pieces": b"".join(hashlib.sha1(stream[i:i+16384]).digest() for i in range(0, len(stream), 16384))}
    pad_torrent, pad_output = directory / "diagnostic-padded.torrent", directory / "diagnostic-padded.json"
    pad_torrent.write_bytes(lt.bencode({b"info": info}))
    lt.torrent_info(str(pad_torrent))
    command("verify", pad_torrent, padded, "--diagnostics", pad_output, code=2)
    result = json.loads(pad_output.read_text(encoding="utf-8"))
    assert [f["path"] for f in result["files"]] == [["a"], ["b"]]
    assert result["files"][1]["attention_ranges"] == [{"offset": "0", "length": "4"}]
    assert not (padded / ".pad").exists()
    checks += 1
    # All three artifact paths share preflight policy, before payload reads/writes.
    fresh = directory / "diagnostic-new.json"
    existing = directory / "diagnostic-existing.json"
    existing.write_bytes(b"preserve")
    (payload / "empty").unlink()
    guards = [["--diagnostics", existing, "--receipt", fresh],
              ["--diagnostics", fresh, "--receipt", fresh],
              ["--diagnostics", fresh, "--html", str(fresh).upper()],
              ["--diagnostics", payload / "empty", "--file", "a"],
              ["--diagnostics", directory / "no-parent/diagnostic.json"], ["--diagnostics", ""]]
    guards += [["--diagnostics", fresh, "--detail-limit", value] for value in ["0", "10001", "bad", "-1"]]
    for options in guards:
        result = subprocess.run([args.node, "--import", (ROOT / "scripts/fixtures/no_payload_reads.mjs").as_uri(), str(args.cli),
                                 "verify", str(torrent), str(payload), *map(str, options)], capture_output=True, text=True, encoding="utf-8",
                                env={**os.environ, "SWARM_PLAN_ROOT": str(payload)})
        assert result.returncode == 1 and json.loads(result.stdout)["error"] == "usage", result.stderr + result.stdout
        assert not fresh.exists() and not (payload / "empty").exists()
        assert existing.read_bytes() == b"preserve"
        checks += 1


def selected_verification(directory, bundle, mode):
    global checks
    torrent = directory / f"selected-{mode}.torrent"
    command("create", bundle, torrent, "--mode", mode, "--piece-length", "16384")
    # This metadata is also accepted by an independent implementation.
    lt.torrent_info(lt.bdecode(torrent.read_bytes()))
    summary = json.loads(command("inspect", torrent))
    names = ["/".join(f["path"]) for f in summary["files"]]
    total = json.loads(command("verify", torrent, bundle))["checked_pieces"]
    html = directory / f"partial-{mode}.html"
    report = json.loads(command("verify", torrent, bundle, "--file", "a.bin", "--file", "a.bin", "--html", html))
    assert report["schema"] == "swarmcrate.verify.v2"
    assert report["ok"] and not report["complete"]
    assert report["selected_files"] == [names.index("a.bin")]
    expected_required = [names.index("a.bin"), names.index("b.bin")] if mode == "v1" else [names.index("a.bin")]
    assert report["required_files"] == expected_required
    assert report["checked_pieces"] + report["skipped_pieces"] == total
    assert "PARTIAL PASS" in html.read_text(encoding="utf-8")
    checks += 1
    # A selected v1 boundary needs the neighbour's bytes; v2/hybrid do not.
    neighbour = bundle / "b.bin"
    saved = neighbour.read_bytes()
    neighbour.unlink()
    try:
        report = json.loads(command("verify", torrent, bundle, "--file", "a.bin", code=2 if mode == "v1" else 0))
        assert report["ok"] == (mode != "v1")
        if mode == "v1":
            assert report["unreadable_pieces"] == 1
            assert report["file_issues"][0]["path"] == "b.bin"
    finally:
        neighbour.write_bytes(saved)
    checks += 1
    # Damage outside the selected pieces does not fail a subset or disappear from a full check.
    unrelated = bundle / "c.bin"
    saved = unrelated.read_bytes()
    damaged = bytearray(saved)
    damaged[0] ^= 0xFF
    unrelated.write_bytes(damaged)
    try:
        assert json.loads(command("verify", torrent, bundle, "--file", "a.bin"))["ok"]
        assert not json.loads(command("verify", torrent, bundle, "--file", "c.bin", code=2))["ok"]
        assert not json.loads(command("verify", torrent, bundle, code=2))["ok"]
    finally:
        unrelated.write_bytes(saved)
    checks += 1
    empty = bundle / "empty"
    empty.unlink()
    try:
        report = json.loads(command("verify", torrent, bundle, "--file", "empty", code=2))
        assert not report["ok"] and not report["complete"] and report["checked_pieces"] == 0
        assert report["file_issues"][0]["path"] == "empty"
    finally:
        empty.write_bytes(b"")
    checks += 1
    command("verify", torrent, bundle, "--file", "../not-a-file", code=1)
    selection = [part for name in reversed(names) for part in ("--file", name)]
    report = json.loads(command("verify", torrent, bundle, *selection))
    assert report["ok"] and report["complete"] and report["skipped_pieces"] == 0
    assert report["checked_pieces"] == total
    checks += 1


with tempfile.TemporaryDirectory(prefix="swarmcrate-interop-") as temp:
    directory = Path(temp)
    rng = random.Random(20261021)
    bundle = directory / "bundle"
    bundle.mkdir()
    for name, size in [("a.bin", 1), ("b.bin", 16384), ("c.bin", 16385), ("nested/目录.bin", 131073), ("empty", 0)]:
        file = bundle / name
        file.parent.mkdir(parents=True, exist_ok=True)
        file.write_bytes(rng.randbytes(size))
    single = directory / "single.bin"
    for payload in [bundle, single]:
        sizes = [32769] if payload == bundle else [1, 16384, 16385, 32768, 32769, 131073]
        for size in sizes:
            if payload == single:
                payload.write_bytes(rng.randbytes(size))
            for piece in [16384, 32768, 65536]:
                for mode in ["v1", "v2", "hybrid"]:
                    torrent = directory / f"{payload.name}-{size}-{piece}-{mode}.torrent"
                    command("create", payload, torrent, "--mode", mode, "--piece-length", piece)
                    independent_check(torrent, payload, mode, payload.is_file())
                    if size == 32769 or payload == bundle:
                        reference = directory / f"reference-{payload.name}-{piece}-{mode}.torrent"
                        libtorrent_reference(payload, mode, piece, reference)
    # Damaged real files, truncated/missing payloads, offline report, and no overwrite.
    for mode in ["v1", "v2", "hybrid"]:
        single.write_bytes(rng.randbytes(50000))
        torrent = directory / f"damage-{mode}.torrent"
        command("create", single, torrent, "--mode", mode, "--piece-length", "16384")
        intact = single.read_bytes()
        changed = bytearray(intact)
        changed[20000] ^= 0xFF
        single.write_bytes(changed)
        report_path = directory / f"report-{mode}.html"
        report = json.loads(command("verify", torrent, single, "--html", report_path, code=2))
        assert report["failed_pieces"] == (2 if mode == "hybrid" else 1)
        assert report["failures"][0]["spans"][0]["offset"] == "16384"
        assert "FAIL" in report_path.read_text(encoding="utf-8")
        single.write_bytes(intact[:-1])
        assert json.loads(command("verify", torrent, single, code=2))["file_issues"][0]["reason"] == "size_mismatch"
        command("verify", torrent, directory / "missing", code=2)
        command("create", single, torrent, code=1)
        edited = directory / f"edited-{mode}.torrent"
        command("edit", torrent, edited, "--tracker", "https://example.org/announce", "--web-seed", "https://example.org/files/")
        assert lt.bdecode(torrent.read_bytes())[b"info"] == lt.bdecode(edited.read_bytes())[b"info"]
        checks += 1
    # Reject malformed/corrupt piece layers rather than reporting false integrity success.
    valid = lt.bdecode((directory / "single.bin-131073-16384-v2.torrent").read_bytes())
    root = next(iter(valid[b"piece layers"]))
    valid[b"piece layers"][root] = bytes(len(valid[b"piece layers"][root]))
    invalid = directory / "invalid-layer.torrent"
    invalid.write_bytes(lt.bencode(valid))
    command("inspect", invalid, code=1)
    checks += 1
    for mode in ["v1", "v2", "hybrid"]:
        selected_verification(directory, bundle, mode)
    padded_v1_verification(directory)
    single_pass_hybrid_verification(directory)
    source_snapshot_verification(directory)
    creation_planning(directory)
    receipt_verification(directory)
    file_diagnostics_verification(directory)
    # Chunk batching must not change leaves, final piece padding or file roots.
    large = directory / "large.bin"
    large.write_bytes(rng.randbytes(2097169))
    for piece in [1048576, 2097152, 4194304]:
        for mode in ["v1", "v2", "hybrid"]:
            torrent = directory / f"large-{piece}-{mode}.torrent"
            command("create", large, torrent, "--mode", mode, "--piece-length", piece)
            independent_check(torrent, large, mode, True)
    # Automatic policy is explicit in output and reproducible with the chosen size.
    for mode in ["v1", "v2", "hybrid"]:
        auto = directory / f"auto-{mode}.torrent"
        explicit = directory / f"auto-explicit-{mode}.torrent"
        result = json.loads(command("create", bundle, auto, "--mode", mode))
        piece = result["info"]["piece_length"]
        assert piece == 16384
        command("create", bundle, explicit, "--mode", mode, "--piece-length", piece)
        assert lt.bdecode(auto.read_bytes())[b"info"] == lt.bdecode(explicit.read_bytes())[b"info"]
        lt.torrent_info(lt.bdecode(auto.read_bytes()))
        assert json.loads(command("verify", auto, bundle))["ok"]
        assert "auto" in command("create", "--help")
        checks += 1

print(json.dumps({"result": "PASS", "real_file_scenarios": checks, "libtorrent": lt.__version__, "torf": torf.__version__}))
