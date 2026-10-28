# Release procedure

For every completed functionality update that will be used for review, publish a new immutable version to Mooncakes. A GitHub push alone is not package publication. Never claim a version is published until registry installation succeeds.

Choose the next unfinished milestone from `ROADMAP.md`, complete its user workflow and update its evidence before preparing a release. Keep planned work distinct from delivered behavior.

1. Update `moon.mod` version and version-bearing CLI/report/receipt producer strings; keep README installation examples current.
2. Run `python scripts/check_toolchain.py` (stable moonc >= 0.10.14), `examples/library` and `examples/controlled` on both supported backends, `moon info`, `moon fmt --check`, both backend tests with `--deny-warn`, JS build, source audit, independent interoperability and `scripts/control_interop.py` filesystem checks.
3. Verify no private application form, personal contact data, credentials, local artifacts, payloads or toolchain directories are tracked. Runtime examples must be synthetic or explicitly redistributable.
4. Commit and push the actual implementation and evidence; verify public CI. Preserve real history; do not pad source or commits.
5. Inspect `moon package --list` (see `moon package --help` for the installed toolchain), build the publish archive, and review its file list before publishing.
6. Use existing Mooncakes credentials or the normal authorized login flow. Do not print, commit or embed tokens. Run `moon publish` only for the matching tested version.
7. In a fresh external consumer project, install the exact registry version and execute a real create/inspect/verify example. Also check the public package page.
8. Create a matching Git tag after successful publication. Keep registry version, Git commit and release evidence consistent.

Competition application prose should be written and submitted by the entrant according to the organizer's rules. This repository contains technical evidence, not a signed personal application or an assurance of acceptance.
