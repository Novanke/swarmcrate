# Changelog

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
