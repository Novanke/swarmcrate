# Changelog

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
