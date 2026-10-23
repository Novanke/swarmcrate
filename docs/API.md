# API contracts

The root package is portable MoonBit, tested on Wasm GC and JavaScript. `/host` and `/cli` explicitly support JavaScript only (Node.js 22.16+).

| API | Contract |
| --- | --- |
| `create_options(name)` | Hybrid, 256 KiB pieces, multifile, public, no endpoints by default. |
| `validate_sources(files)` | Validate portable paths, case/prefix collisions, signed lengths and exact host offset range; return real bytes. |
| `sorted_source_indices(files)` | Deterministic raw UTF-8 path order; indices retain the original caller mapping. |
| `create_torrent(files, options, read)` | Return canonical `.torrent` bytes. Callback `(originalIndex, offset:Int64, size:Int) -> Bytes raise CrateError` must return exactly `size` bytes. Hybrid currently reads payload twice, once per hash scheme. |
| `inspect_torrent(data)` | Strict syntax, file layout, hash count, v2 piece-layer/root validation and hybrid layout consistency. Return **real files only**, no virtual padding files. |
| `expected_v1_pieces(data)` | Concatenated 20-byte SHA-1 hashes; empty for pure v2. |
| `expected_v2_files(data)` | File roots and piece layers in inspected file order; empty for pure v1. |
| `torrent_storage_bytes(data)` | V1/hybrid storage including virtual padding; real bytes for pure v2. |
| `sha1_pieces(files, pieceLength, read)` | Hash the supplied order exactly; crosses file boundaries and skips empty files. |
| `piece_spans(files, pieceLength, index)` | Map a v1 piece in the supplied (unpadded) file concatenation to real ranges. Hybrid verification reports account for padding internally. |
| `hash_v2_file(length, pieceLength, read)` | Block/Merkle hashing; callback has no file index. Empty files return empty root/layer. |
| `validate_piece_layer(root, length, pieceLength, layer)` | Authenticate a multi-piece file's entire layer against its root. |
| `verify_payload(data, sizes, read, detail_limit=4096)` | `sizes` is `Array[Int64?]` in **inspected order**; `None` indicates unavailable file. Hash/size failures return `ok=false`; invalid metainfo/mappings raise. |
| `torrent_magnet(data)` | Exact validated infohashes, display name, unique trackers. |
| `parse_magnet(uri)` / `format_magnet(value)` | v1 hex/Base32 input, v2 `1220` SHA-256 multihash; reject conflicting hashes, invalid escapes and invalid UTF-8. |
| `edit_distribution(data, trackers, webSeeds)` | Replace both lists, preserve unknown top-level fields and exact original `info` bytes; private inputs must retain trackers. |
| `info_json`, `verification_json`, `verification_html` | Schema-tagged data and escaped, script-free offline report. |

`CrateError(code, detail)` is a structured checked error. Missing or incorrectly sized empty files still fail verification, even though they contain no pieces. Read failures are unreadable failures, never trusted zero data. A v2 read error affects only the current piece and checking continues at the next piece; a v1 boundary piece lists all contributing real ranges. Piece counts in a hybrid report count both SHA-1 and SHA-256 checks. Detail limits cap stored piece failure entries; aggregate counters continue through the whole payload.

Creating a directory ignores empty directories (BitTorrent represents files). Source tokens contain device/inode/size/mtime/ctime; the CLI checks them around reads and before committing created metadata. This detects ordinary concurrent edits, not a privileged adversary racing/replacing directory ancestors. Use stable, trusted local files for publication. Extra files not mentioned by the torrent do not affect verification; this verifies the listed payload, not a complete filesystem snapshot.

Tracker ordering is retained as tiers. Web Seeds use BEP 19 `url-list`. Private metadata uses `private=1`. Unknown top-level extensions survive edits; unsupported file attributes or future meta versions are rejected explicitly.
