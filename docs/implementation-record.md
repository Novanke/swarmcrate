# Implementation evidence — 2026-10-29

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
| `798bb17` | Create hybrids from a single non-rewindable payload pass; reject excessive aligned piece counts before I/O. |
| `12ae7e0` | Index v2 directory nodes instead of scanning sibling arrays, preserving deterministic metadata. |
| `e20bf22` | Recommend piece sizes using mode/alignment-aware counts, automatic CLI policy and command-level help. |
| `a72aabe` | Batch v2 I/O into bounded chunks while retaining 16 KiB Merkle leaves and per-piece failure isolation. |
| `2d45efd` | Parse standalone v1 virtual padding with real-file index mapping, storage limits and explicit link/attribute rejection. |
| `f64fb7d` | Verify hybrid payloads from one shared bounded read pass; retain independent hash checks, piece failure isolation, diagnostic ordering and capped details. |
| `43501f3` | Snapshot/recheck source directories including empty ones, reject stale creation after roster changes, and bound/close OS directory enumeration. |
| `8c71e94` | Compute payload-free layout plans, expose portable JSON/API and a read-only CLI, and reuse the preflight before actual creation. |
| `ba92f90` | Capture immutable identity/scope-bound verification receipts, export them through the CLI without breaking legacy reports, and preflight report destinations before payload reads. |
| `bde126d` | Group candidate failure ranges by real file, union physical intervals across schemes, preserve size/empty-file issues, and export immutable scoped diagnostics with honest truncation semantics and HTML summaries. |
| `a4bbae9` | Add opt-in cooperative verification progress/cancellation, preserve observer errors outside read recovery, and demonstrate portable and filesystem consumers that never return/save cancelled receipts. |
| `188f2cd` | Add controlled creation, frozen inputs and cancellable encoding/finalization gates; publish controlled outputs through same-parent staging and atomic non-replacing links with source rechecks. |

The later interoperability, CI and documentation commits are additional evidence, not required to make this list exceed ten. Whether a milestone meets a competition's definition of an effective commit is for its reviewers to decide.

## Source measurement

`python scripts/source_audit.py` currently reports 21 root implementation files, 3,989 nonblank/non-comment code lines, and 2,461 conservative function-body lines. The second metric excludes type declarations, signatures/opening lines, punctuation-only lines, and all inline function bodies on their signature line. Both exclude tests, examples, benchmarks, docs, generated `.mbti`, dependencies, CLI, host adapter and all foreign JavaScript. The algorithm is visible and repeatable; it does not claim to reproduce the organizer's private calculation.

## Executed verification

- Toolchain: MoonBit stable 2026-10-16, moon `0.1.20261016`, moonc `v0.10.16+b1a0e846e`.
- Wasm GC: 53 core test blocks passed with warnings denied.
- JS: 73 blocks passed, including real filesystem and CLI scenarios, with warnings denied.
- Independent real-file script: 215 scenarios passed using libtorrent `2.1.1.0`, torf `4.3.1`, and Python's SHA-1/SHA-256.
- The script checks output acceptance and hashes, reads and verifies libtorrent-generated v1/v2/hybrid torrents, exercises Unicode/nested/empty files, piece/block boundaries, corruption, truncation, missing payload, HTML output, no overwrite and endpoint edits.
- No network session, tracker connection, download or seeding is used in these checks.
- Selection scenarios distinguish a subset from a full check, require v1 boundary neighbours, ignore unrelated damage during a subset check, fail missing empty files and normalize a selection of all files to complete verification.
- 0.3.0 adds aligned-count preflight, one-pass callback accounting, flat/shared 5,000-file trees, automatic policy checks, and 1/2/4 MiB piece sizes over a 2 MiB+17 byte file. Benchmarks are a separate synthetic measurement, never counted as tests or implementation volume.

Reproduce with the commands in the README and inspect CI logs for the exact public commit being reviewed. Test-block counts and enumerated real-file scenarios are separate metrics and are never added together as a test count.

0.4.0 adds standalone v1 padded-storage verification, including omitted paths, safe repeated pad names, trailing pads, mixed aligned/unaligned real files, exact callback mapping, partial scopes and corrupt-data offsets. The library example is executed on both backends; CI rejects an older or unrecognized compiler version. Examples and CI changes are not included in root implementation volume.

0.5.0 adds single-pass hybrid verification, stable-input report comparisons with the existing separate v1/v2 verifiers, non-rewindable callbacks, transient-failure isolation, the maximum piece width, independently altered hashes and real OS read counters. Ten added disk scenarios cover full/subset/empty selection and injected exceptions/short reads. Benchmarks compare the same source against registry 0.4.0, not a local source override.

0.6.0 adds directory-membership/identity snapshots and bounded enumeration in the MoonBit host/CLI layer. Twenty-seven new disk scenarios cover all modes, seven mutation conditions, stable/alternate enumeration controls, fixed-layout content identities and handle closure. Host APIs also test explicit budgets and membership comparison independent of timestamps. This host/CLI work is deliberately excluded from the root-library source measurement above; no new portable-core line count is claimed.

0.7.0 adds pure layout planning and a read-only CLI. Hand-checked layouts cover trailing empty files, original input order, exact piece limits and duplicate-root layer bounds. Ten real-file planning scenarios prohibit payload opens and compare planned sizes/counts with independently decoded created torrents. The roadmap distinguishes implemented milestones from future work and does not claim adoption or complete packaging-format compatibility.

0.8.0 adds same-verification immutable receipts bound to exact metainfo bytes, infohashes, real-file mapping, required-file size observations and the actual scope/results. Three portable test blocks cover callback/report mutation isolation, complete/partial/failure semantics, missing empty files, bounded details and distribution-edit identity. Twenty-seven added disk scenarios compare raw SHA-256 and libtorrent identities, scopes, layouts, export privacy, output preflight and changes after reads. Existing read/fault observations now export receipts too, retaining one payload pass. Receipts are unsigned ordinary JSON; no authentication, trusted timestamp or imported-receipt verifier is claimed.

0.9.0 adds grouped physical byte-range unions, separate hash/unreadable/missing/extra categories, expected-content attention bytes and missing-empty-file markers. Four portable test blocks cover an independent byte bitmap, 64-bit endpoints, hybrid deduplication, v1 neighbour ambiguity, size mismatches and truncated inventories. Thirty-two added disk scenarios exercise complete/selected/damaged/missing/short/long inputs, incomplete diagnostics, independently encoded v1 padding and output/detail-limit guards. Existing OS exception/short-read and source-change checks now cover diagnostic export too, preserving one payload pass and preventing stale artifacts. The new export is immutable and identity-bound; old APIs/stdout remain compatible, and no exact bad-byte attribution or automatic repair is claimed.

0.10.0 adds scalar synchronous verification checkpoints and an additive controlled API. Five new core blocks cover monotonic full/subset/empty progress, every cancellation/error stage, ordinary reader errors named `cancelled`, missing inputs and observer failure during read recovery. Thirty SDK disk scenarios exercise both completed and cancelled consumers in all three modes, including finalization cancellation after all checks, accurate bounded reads, damaged/missing files, existing artifacts and source changes. Both portable examples execute on Wasm GC and JS; 215 existing interoperability cases remain separate and continue to pass. Source/byte identity, same-scope receipts and legacy signatures remain intact. Creation control, asynchronous storage, browser event-loop adapters and resume remain future work.

0.11.0 implements creation control separately from verification, preserving canonical output, original indices and one-pass payload reads. Four core blocks cover every cancellation/error checkpoint, completed-read/encoded cancellation, input mutation isolation, read failure and invalid preflight. Host/CLI blocks exercise atomic publication, existing outputs and the final write gate. Seventy-eight new disk cases span three modes, single/multifile inputs, observer/source changes, partial and zero writes, sync/link errors, racing writers, and simulated process exits before/after publication. Completed outputs match legacy bytes and verify; no incomplete target is exposed by this writer, while competing targets are preserved. New atomic publication requires hard links; crash-orphan staging, synchronous latency and non-atomic source checks are documented rather than hidden. Existing 215 interoperability and 30 verification-control scenarios continue passing.

0.11.1 repairs three independently reproduced defects: public SHA-1 oversize preflight, structured handling of read/write/atomic-stage close failures without descriptor retry, and Windows Node 22.16.0 path/handle device-field disagreement. The minimum runtime executes the full existing disk chain, including source-change interception, plus 21 close-fault scenarios; CI covers Windows/Linux and Node 22.16.0/24. Public signatures and schemas are unchanged. This is reliability work for existing offline creation/verification rather than a new downloader, repair engine or security-certification claim.

0.12.0 adds a portable MoonBit batch manifest/parser/runner and a MoonBit filesystem command. Task-local load/parse/selection/consistency errors do not stop later tasks; integrity FAIL and partial success remain distinct. Compact immutable summaries bind raw manifest/metainfo identities, exact scope and same-run receipt digests. Bounded serialization, protected inputs, final source/manifest checks and atomic non-replacing publication complete the offline chain. Five core and six CLI blocks plus portable/real-file examples provide evidence; no Python verification was removed and no Linguist classification was changed to increase the displayed language share.

0.13.0 adds synchronous global batch checkpoints, true aggregate I/O deltas, provenance-based observer aborts across task/read-recovery catches, and a final controlled publication gate. Cancellation never returns a BatchAudit, including after every accepted row and serialized summary. Four portable and four CLI blocks plus 48 real child-process scenarios cover cancellation, source mutation, atomic faults and abrupt exits. Single-task/legacy batch APIs remain compatible; forceful termination and cooperative cancellation are explicitly distinguished.
