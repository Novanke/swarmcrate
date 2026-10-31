# Changelog

## 0.14.1

- Preflight ordinary and controlled creation destinations before scanning/hashing.
- Resolve existing filesystem aliases for MoonBit report/batch output guards; handle drive/root containment and reject ambiguous Windows stream/trailing-dot paths.
- Preserve a competing writer's replacement when ordinary write cleanup follows a close error.
- Reject additional Windows device-name forms in portable metadata, fix sequential cancellation examples, and add real output/alias/ownership regression coverage to every CI matrix job.

## 0.14.0

- Add MoonBit staging provenance parsing, local inspection and selected orphan cleanup for atomic creation/batch publication.
- Preserve active/reused PIDs, legacy/unverified records, unknown members, changed objects and competing cleanup claims; never delete a published target.
- Recheck opaque plans under an exclusive claim and delete only fixed matching members with nonrecursive directory removal. Report partial cleanup failures without a force fallback.
- Extend real-process/fault CI with active publishers, abrupt exits before/after linking, two operations, two cleaners, object replacement and deletion failures. See `docs/staging-cleanup.md` for trusted-local-directory assumptions and conservative limits.

## 0.13.0 — 2026-10-29

- Add opt-in MoonBit `audit_batch_with_control`, immutable batch/verification snapshots and structured progress JSON. Count accepted rows separately from success, and aggregate real I/O deltas without an invented total-byte denominator.
- Preserve task-local storage error isolation while globally propagating observer cancellation/errors through both task catches and verification read recovery. Cancellation returns no BatchAudit, including after all rows or final serialization.
- Add JS `execute_batch_with_control`, final before_write cancellation, post-observer current-source/manifest checks and staged atomic summary publication. No callbacks after publication begins; preserve legacy API/schema/exit behavior.
- Freeze preflighted batch and creation output paths before observers run; changing the working directory cannot redirect publication into a different or protected root. Include regressions for both consumers.
- Provide a real file-consumer cancellation marker adapter: another process can create the marker, polled synchronously at checkpoints, to abort without publishing a summary.
- Add four core/four CLI control test blocks, dual-backend and filesystem consumers, and 48 child-process scenarios for cancelled outputs, observer failures, mutations, stage faults, competing writers and process exits before/after commit.

## 0.12.0 — 2026-10-29

- Add a pure MoonBit strict batch-manifest parser, sequential storage-adapter SDK and immutable compact audit summary. Bind exact manifest/metainfo SHA-256, infohashes, requested/resolved scopes and same-run receipt digests; never deduplicate checks by infohash.
- Isolate checked task errors while preserving PASS, PARTIAL_PASS and integrity FAIL. Copy exported tasks/callback mappings, discard results on completion-check failure, bound summary serialization and continue after a task quota error.
- Add MoonBit CLI `audit-batch MANIFEST.json SUMMARY.json`: manifest-relative inputs, conservative protection of every declared root, per-task metainfo/payload checks, final manifest recheck, and staged atomic non-replacing summary publication. Reject ambiguous Windows drive-relative paths; hard-link support is required for publication.
- Add five portable core and six real-file CLI test blocks, a dual-backend SDK example and an executable disk example. Preserve single-task APIs and independent Python oracles. Document sequential-time, unsigned-record and memory limitations honestly.

## 0.11.1 — 2026-10-29

- Reject more than 400,000 SHA-1 pieces in the public hashing helper before allocating the piece buffer or invoking storage. Test the exact accepted boundary without creating a giant payload.
- Keep read/write/atomic-stage close failures inside the structured I/O error boundary. Relinquish descriptor ownership before close and never retry an ambiguous close failure; verification marks the affected piece unreadable and continues instead of crashing.
- Fix Windows Node.js 22.16.0 path-stat/device versus handle-stat/device disagreement, which incorrectly rejected stable files as changed. Keep handle inode, exact size and nanosecond time checks, compare the current path observation too, and preserve source-change rejection.
- Run the full Windows/Linux CI matrix on Node.js 22.16.0 and 24. Add 21 synthetic close-failure disk scenarios covering metainfo/payload reads, later-piece continuation, FAIL receipts, ordinary writes and unpublished atomic staging. Correct obsolete creation-control descriptions; public API signatures and report schemas remain unchanged.

## 0.11.0 — 2026-10-28

- Add `create_torrent_with_control` and scalar `CreationProgress`, with separate read, pre-encoding and validated-finalization checkpoints. Cancel/observer/read failures return no metainfo, including after 100% of payload reads or after encoding. Preflight before freezing caller-owned path/endpoint arrays; preserve canonical bytes, original read indices and single-pass hybrid I/O.
- Add JS `cli.execute_create_with_control` with cancellation code 3, a final `before_write` checkpoint and source-snapshot checks before and after that observer. Preserve ordinary `execute`, creation API/output and legacy write semantics.
- Add opt-in `host.write_new_atomic`: exclusive same-parent staging, full write/fsync/close and non-replacing hard-link publication. Hard-link support is required; unsupported systems fail closed. Caught failures clean owned staging best-effort and never delete competing output. Abrupt termination may leave hidden staging, but the published target is absent or complete; no power-loss or atomic-source-snapshot guarantee.
- Pass 43 core / 52 JS blocks, 215 interoperability, 30 verification-control and 78 creation-control disk scenarios. Test all cancellation/error phases, frozen input arrays, partial/zero writes, sync/link failure, source edits inside final observers, racing outputs, and process exit before/after publication. Both portable creation examples run on Wasm GC/JS; new real-file consumers use public APIs.

## 0.10.0 — 2026-10-28

- Add opt-in `verify_with_control` and scalar `VerificationProgress` snapshots for synchronous cooperative verification: start, before/after real reads, each hash comparison and finalization. Preserve existing APIs, report/receipt schemas, selected scopes and one-pass hybrid reads.
- False from an observer raises `cancelled`; observer errors retain their code/detail and cannot disappear into piece-read recovery. Ordinary reader failures, including errors named `cancelled`, remain unreadable-piece failures. Cancellation returns neither report nor receipt, even after every check has completed.
- Count only selected hash checks, both hybrid schemes, read callback attempts and validated complete-read bytes. Document zero-check empty selections, completed-but-failed checks, cancellation latency and host responsibilities. This is not asynchronous I/O, creation control, browser event-loop integration or resume.
- Add portable and Node filesystem consumers. The latter rechecks the source and writes only after successful API return, with dedicated cancellation exit code 3. Windows/Linux CI executes both portable backends and real output/no-output cases.
- Pass 39 core / 46 JS test blocks, the existing 215 independent interoperability scenarios and 30 controlled-SDK disk scenarios. Cover every cancellation/error checkpoint, failed-read observer errors, monotonic counters, ordinary reader error isolation, empty/missing inputs, no duplicate reads, finalization cancellation, existing outputs and post-read source changes.

## 0.9.0 — 2026-10-28

- Group recorded failures by real file, union adjacent/overlapping physical intervals, and deduplicate hybrid SHA-1/SHA-256 ranges. Separate candidate hash-mismatch/unreadable-piece ranges, missing content, extra tails and the union of expected-content attention ranges. Preserve missing-empty-file issues without inventing bytes or locating an exact failing read from a shared v1 piece.
- Add immutable `receipt_diagnostics_json_text`, independent CLI `--diagnostics NEW.json` (`swarmcrate.diagnostics.v1`), an additive `file_diagnostics` receipt field and a grouped HTML table. Bind the export to the same exact metainfo identity, file indices, required/selected scope and counters; keep legacy stdout, APIs and exit codes compatible.
- Add CLI `--detail-limit 1..10000`. Continue all selected checks and aggregate counts; mark every diagnostic inventory incomplete when failure details are truncated, including rows with no recorded issue. File-size issues remain exhaustive. Never treat candidates as exact corrupt bytes or modify payloads automatically.
- Extend destination preflight and post-read consistency checks to diagnostic outputs. Preserve independent exclusive writes and the documented non-atomic ordering of receipt, diagnostics and HTML.
- Pass 34 core / 41 JS test blocks and 215 independent disk scenarios. Added checks cover byte-bitmap interval oracles, 64-bit offsets, shared neighbours, missing/short/long files, empty files, truncation, independent padded v1 input and output guards. OS fault/read observations now export diagnostics too, preserving one payload pass and deduplicated unreadable ranges.

## 0.8.0 — 2026-10-27

- Add `verify_with_receipt` and opaque `VerificationReceipt` with immutable `receipt_json_text` export. Capture full raw-metainfo SHA-256/byte count, infohashes, real-file index/path/length mapping, required-file size observations and the exact report from one verification. Copy caller sizes before callbacks; later report-array mutations cannot change the captured receipt.
- Add optional CLI `verify --receipt NEW.json` (`swarmcrate.receipt.v1`) while preserving legacy `swarmcrate.verify.v2` stdout and exit codes. Export full PASS, PARTIAL_PASS and FAIL distinctly, including missing empty files, unreadable pieces and truncated diagnostics. Do not claim signing, publisher authentication, trusted timestamps or saved-receipt revalidation.
- Preflight report destinations before payload reads. Reject existing or normalized/case-folded duplicate targets, missing parents and overlap with listed payload files, including missing/unselected files. Recheck required files before writing either artifact; receipt/HTML outputs are individually exclusive but not an atomic pair.
- Pass 30 core / 37 JS test blocks and 183 independent real-file scenarios. Added scenarios compare exact identity with Python/libtorrent, preserve tracker-edit infohash semantics, check file maps/scopes, single-file layouts, output guards and changes after reads. Existing OS read/fault observations now also export receipts, demonstrating no second payload pass.
- Extend both portable examples and the disk demo with saved receipts, document the schema, and advance the roadmap's next milestone to per-file diagnostics and actionable ranges.

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
