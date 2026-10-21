# Implementation evidence — 2026-10-21

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

The later interoperability, CI and documentation commits are additional evidence, not required to make this list exceed ten. Whether a milestone meets a competition's definition of an effective commit is for its reviewers to decide.

## Source measurement

`python scripts/source_audit.py` currently reports 11 root implementation files, 1,990 nonblank/non-comment code lines, and 1,260 conservative function-body lines. The second metric excludes type declarations, signatures/opening lines, punctuation-only lines, and all inline function bodies on their signature line. Both exclude tests, examples, docs, generated `.mbti`, dependencies, CLI, host adapter and all foreign JavaScript. The algorithm is visible and repeatable; it does not claim to reproduce the organizer's private calculation.

## Executed verification

- Toolchain: MoonBit stable 2026-10-16, moon `0.1.20261016`, moonc `v0.10.16+b1a0e846e`.
- Wasm GC: 11 core test blocks passed with warnings denied.
- JS: 13 blocks passed, including real filesystem and CLI scenarios, with warnings denied.
- Independent real-file script: 67 scenarios passed using libtorrent `2.1.1.0`, torf `4.3.1`, and Python's SHA-1/SHA-256.
- The script checks output acceptance and hashes, reads and verifies libtorrent-generated v1/v2/hybrid torrents, exercises Unicode/nested/empty files, piece/block boundaries, corruption, truncation, missing payload, HTML output, no overwrite and endpoint edits.
- No network session, tracker connection, download or seeding is used in these checks.

Reproduce with the commands in the README and inspect CI logs for the exact public commit being reviewed. Test-block counts and enumerated real-file scenarios are separate metrics and are never added together as a test count.
