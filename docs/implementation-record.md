# Implementation evidence — 2026-10-23

Each implementation milestone below contains executable MoonBit behavior and its checks. History is ordinary chronological development; no empty commits, backdating, force-pushed reconstruction, document-only or test-only milestones are presented as functional work.

| Commit | Functional implementation |
| --- | --- |
| `8f2193b` | Bounded canonical bencode, exact source spans, malformed input rejection. |
| `e7c972e` | Portable file-set validation, collision handling, deterministic ordering, creation options. |
| `a1af5d2` | Bounded v1 streaming piece hashing across files; piece-to-file spans. |
| `6801f9f` | Real v1 single/multifile metainfo creation and strict inspection. |
| `b4c1348` | BEP 52 Merkle roots and authenticated piece layers. |
| `b5731c2` | v2 file trees and deduplicated layers, validation of referenced roots. |
| `0bf796b` | Hybrid generation, virtual padding, v1/v2 layout agreement. |
| `b236ca2` | Real payload verification, bounded damage/unreadable diagnostics. |
| `8d79953` | Magnet URI generation/parser, Base32 and SHA-256 multihash support. |
| `23f72e6` | Distribution endpoint editing preserving exact content identity. |
| `9b2f928` | Bounded filesystem adapter, edit detection, exclusive output. |
| `32aff5a` | Lossless JSON and self-contained offline HTML verification reports. |
| `11f1661` | Working create/inspect/verify/magnet/edit commands and exit statuses. |
| `b95cdb6` | Checked v2 length arithmetic, indexed piece layers, URL/report hardening. |
| `e84b87b` | Reject empty-only payloads for client compatibility; validate every generated result before returning it. |
| `571f941` | Isolate v2 read failures per piece and continue later checks without constructing a full actual piece layer. |
| `5d31817` | Selected-file verification, v1 boundary dependency planning, explicit scope/skipped counts and partial HTML/JSON reporting. |
| `a0037a2` | Detect payload changes after the last read and before verification reports are written; include empty/missing files. |

The later interoperability, CI and documentation commits are additional evidence, not required to make this list exceed ten. Whether a milestone meets a competition's definition of an effective commit is for its reviewers to decide.

## Source measurement

`python scripts/source_audit.py` currently reports 12 root implementation files, 2,163 nonblank/non-comment code lines, and 1,362 conservative function-body lines. The second metric excludes type declarations, signatures/opening lines, punctuation-only lines, and all inline function bodies on their signature line. Both exclude tests, examples, docs, generated `.mbti`, dependencies, CLI, host adapter and all foreign JavaScript. The algorithm is visible and repeatable; it does not claim to reproduce the organizer's private calculation.

## Executed verification

- Toolchain: MoonBit stable 2026-10-16, moon `0.1.20261016`, moonc `v0.10.16+b1a0e846e`.
- Wasm GC: 14 core test blocks passed with warnings denied.
- JS: 17 blocks passed, including real filesystem and CLI scenarios, with warnings denied.
- Independent real-file script: 82 scenarios passed using libtorrent `2.1.1.0`, torf `4.3.1`, and Python's SHA-1/SHA-256.
- The script checks output acceptance and hashes, reads and verifies libtorrent-generated v1/v2/hybrid torrents, exercises Unicode/nested/empty files, piece/block boundaries, corruption, truncation, missing payload, HTML output, no overwrite and endpoint edits.
- No network session, tracker connection, download or seeding is used in these checks.
- Selection scenarios distinguish a subset from a full check, require v1 boundary neighbours, ignore unrelated damage during a subset check, fail missing empty files and normalize a selection of all files to complete verification.

Reproduce with the commands in the README and inspect CI logs for the exact public commit being reviewed. Test-block counts and enumerated real-file scenarios are separate metrics and are never added together as a test count.
