# Dependencies and provenance

SwarmCrate's own implementation is licensed under [Apache-2.0](LICENSE). It independently implements the metadata and hashing layout described in the BEPs linked in the README. It does not vendor BitTorrent client source code or claim those standards or cryptographic algorithms as original inventions.

## Runtime dependency

- **`moonbitlang/x@0.5.5`, package `crypto`** — official MoonBit SHA-1/SHA-256 implementation, Apache-2.0. Upstream: <https://github.com/moonbitlang/x>. The installed module declares `license = "Apache-2.0"`; its crypto source carries Copyright 2025 International Digital Economy Academy and Apache-2.0 notices. It is resolved separately by Moon, not copied into this repository, and excluded from implementation measurements. Preserve upstream license/copyright notices when redistributing a bundled build that includes it.

The MoonBit standard library/toolchain and Node.js are separately installed execution prerequisites. No external torrent generator, hash command, tracker or network service is used at runtime.

## Independent verification tools

`libtorrent==2.1.1` and `torf==4.3.1` are installed separately for `scripts/interop.py` and CI. They are independent comparison tools, not runtime dependencies or vendored implementations. Tests use Python's standard `hashlib` as a separate hash oracle. Their source is excluded from the source audit. The repository does not distribute their binaries or dependency directories.

All generated demonstration payloads are synthetic. Application forms, contact details, credentials and local review artifacts must remain outside the published source/package.
