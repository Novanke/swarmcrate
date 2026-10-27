# Changelog

## 0.7.0 — 2026-10-27

- Add portable `plan_torrent(files, options)`, `TorrentPlan` and `plan_json` (`swarmcrate.plan.v1`). Compute real/logical bytes, virtual hybrid padding, empty-file counts, both scheme piece counts, exact v1 hash bytes and a v2 piece-layer upper bound without payload reads or hashes.
- Add CLI `plan INPUT` with shared creation-option preparation, automatic sizing and scan-consistency checks. Preserve creation output and all existing verification schemas. Creation uses the same preflight before payload I/O.
- Preserve canonical last-file padding behavior, including trailing empty files. Layer bytes are bounded before content-based deduplication and are not advertised as complete metainfo size, physical storage or integrity evidence.
- Establish three focused product tracks in `docs/ROADMAP.md`: release/data delivery, offline audit/diagnostics and reusable MoonBit SDK. The next milestone is an identity-bound saved verification receipt.
- Pass 27 core / 34 JS test blocks and 156 independent real-file scenarios, including planning with payload opens blocked and comparisons against real created torrents. Both runnable examples and the disk demo now include planning.

## 0.6.0 — 2026-10-27

- Recheck all scanned directory membership and identity before committing created metainfo, including otherwise unrepresented empty directories. Detect additions, removal, rename and replacement without relying only on file tokens; enumeration order alone does not fail or change content identity.
- Add JS-only host APIs `scan_snapshot(path, max_entries=200000)` and `check_scan_unchanged(snapshot)`, plus `ScanSnapshot` and `DirectorySnapshot`. Keep the existing `scan` tuple API. The CLI automatically uses the stronger completion check; it still provides sequential consistency checks, not an atomic snapshot.
- Bound traversal by a shared descendant-entry budget (files and directories, excluding the input root), retain the real-file/depth limits, and enumerate OS directories incrementally with handle cleanup on success and failure. Preserve budget/OS errors instead of masking them as JSON parse failures.
- Pass 24 core / 30 JS test blocks and 146 independent real-file scenarios. Twenty-seven added scenarios mutate directory membership in all three modes, check stable/reordered controls and content identity, verify no stale output is committed, and observe directory-handle cleanup. The portable core and its conservative source measurement are unchanged.

## 0.5.0 — 2026-10-26

- Verify hybrid payloads with one bounded real-file read pass shared by SHA-1 and SHA-256. Preserve the different data-zero and Merkle zero-hash rules, including optional trailing padding, empty files and selected-file scopes. Both expected hashes are checked independently.
- Isolate failed/short/oversized reads to their piece and continue later pieces. A transient failure now makes both checks for that piece unreadable, without a second scheme retry. Stable inputs and deterministic failures preserve the former two-pass diagnostic order, indices, ranges, counters and detail cap; public signatures and JSON schemas stay unchanged.
- Add non-rewindable-source accounting up to the 16 MiB piece limit, reference comparisons against separate verification passes, and independently tampered hash-scheme regressions. Extend real-file interoperability with observed OS reads and injected read failures.
- Pass 24 core / 27 JS test blocks and 119 independent real-file scenarios. Add a hybrid-verification benchmark against registry 0.4.0: half the logical payload reads and callbacks with the same hash-check count and content identifiers. The measured CPU-bound times remain close; no twofold speed claim.

## 0.4.0 — 2026-10-25

- Read standalone v1 BEP 47 padding as virtual zeros, keeping real callback indices, selected-file scopes and damage spans separate from storage layout. Support omitted/repeated safe padding paths and trailing padding; ordinary files need not all be aligned. Creation of standalone v1 remains unpadded.
- Validate storage entry counts, padded sizes, alignment and SHA-1 hash counts. Reject unsupported single-file attributes and symlink targets that previously could be ignored. This is an explicitly documented BEP 47 subset, not full extended-attribute support.
- Add an executable pure MoonBit public-API example on Wasm GC and JS, covering creation, inspection, magnet output, intact verification and deliberate corruption in all three modes.
- Enforce stable moonc >= 0.10.14 in Windows/Linux CI and document the tested 0.10.16 toolchain. Refresh the evidence map against the entrant-provided final acceptance guide; accepted entrants do not need another application form.
- Pass 21 core / 24 JS test blocks and 109 independent real-file scenarios, including padded v1 acceptance by libtorrent. No report schema or public API signature changes.

## 0.3.0 — 2026-10-23

- Hybrid creation reads each real payload byte once, feeds both hash schemes from the same data, and generates alignment zeros internally. Excessive aligned piece counts are rejected before payload I/O, including cases where the unpadded v1 count would fit.
- Batch v2 reads up to 1 MiB without crossing piece boundaries. The Merkle leaf size remains 16 KiB, and verification still isolates read failures to a piece.
- Index v2 directories by full path instead of repeatedly scanning sibling nodes. Preserve canonical metadata and content identifiers for a fixed input/layout.
- Add `recommend_piece_length(files, mode=Hybrid, target_pieces=4096)`. It accounts for separately aligned v2/hybrid files, does not inflate tiny files to chase an impossible target, and enforces the hard piece limit.
- CLI creation defaults to `--piece-length auto`; explicitly pass the old `262144` default to preserve a previous default layout. The library's `create_options` default remains 256 KiB. Command-level `--help` is available without input paths.
- Add a reproducible benchmark, 5,000-file tree and non-rewindable-source regressions, larger chunk interoperability cases, design notes and a review evidence map. Verification JSON stays at schema v2; no report fields were removed.
- Upgrade the Node/Python setup actions to Node 24-compatible versions; keep the tested application runtimes at Node 24 and Python 3.12.

## 0.2.0 — 2026-10-23

- Verify selected files through `verify_payload(..., selected_files=Some(indices))` or repeated CLI `verify --file RELATIVE/PATH`. `verification_scope` resolves required files before disk access, including only the necessary v1 shared-piece neighbours. Full verification remains the default.
- Verification reports identify the selected scope, required boundary files and skipped hashes. Successful subsets are labelled **PARTIAL PASS** in HTML. Empty files remain part of completeness and missing-empty-file checks.
- Isolate v2 read/short-read failures to their current piece, continue checking later pieces, and avoid constructing a second full actual piece layer during verification.
- Recheck required file tokens after verification and before creating HTML output. A detected concurrent change returns an input/I/O error instead of publishing a stale success report. These checks are sequential, not an atomic snapshot.
- Add real-file selection scenarios for v1/v2/hybrid, and test the optimized CLI in Windows/Linux CI. The offline demo accepts a new output directory and demonstrates a subset pass while an unrelated file is damaged.

### API and report migration

Existing `verify_payload` calls without a selection still verify all files. `VerificationReport` adds `scope : VerificationScope` and `skipped_pieces`; applications that construct report structs must provide these fields. Use `scope.complete && report.ok` when a whole-payload result is required.

The verification JSON schema changes from `swarmcrate.verify.v1` to **`swarmcrate.verify.v2`**. `ok=true` applies to the selected scope; check `complete=true` before treating it as a full check. `selected_files` and `required_files` use the indices from `inspect_torrent(...).files`; v1 neighbour files may only be partially read. `checked_pieces + skipped_pieces` includes both schemes for hybrids. The info JSON schema remains `swarmcrate.info.v1`.

## 0.1.0 — 2026-10-21

Initial release: canonical metainfo creation/inspection for v1, v2 and hybrid torrents; bounded real-file hashing and verification; magnet handling; identity-preserving endpoint editing; Node filesystem CLI; JSON and offline HTML reports. Independent checks covered 67 real-file scenarios.
