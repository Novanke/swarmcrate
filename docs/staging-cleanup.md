# Interrupted publication staging — 0.14.0

Controlled creation and both batch commands publish through an exclusive same-parent stage, fsync and a non-replacing hard link. Cooperative cancellation stops before publication. A forced process exit can leave the stage behind; this workflow identifies and selectively removes confirmed local orphans without deleting a complete published target.

## Read first, select one operation

```sh
node scripts/swarmcrate.mjs staging-list ./output
node scripts/swarmcrate.mjs staging-clean ./output/.swarmcrate-OPERATION-SUFFIX --operation OPERATION
```

Use the exact absolute `path` and 32-character lowercase hexadecimal `operation_id` from the inventory, replacing the placeholders above. `staging-list` is read-only and lists direct `.swarmcrate-*` entries, with a budget of 4,096 total parent entries. It never searches descendants or deletes anything. A missing/unreadable parent or exceeded budget fails rather than returning a partial inventory.

Each row has schema `swarmcrate.staging-inspection.v1`, `path`, `operation_id` (nullable), `status` and `reason`:

| Status | Meaning | Cleanup |
| --- | --- | --- |
| `orphan` | Matching local provenance, original directory/data identity, exact members and a positively absent owner PID | One selected operation may be removed after fresh checks |
| `active` | Owner PID exists, including a reused PID | Refused |
| `unverified` | Legacy/invalid marker, missing local receipt, foreign context, unknown members, changed objects, unsupported identities or uncertain process observation | Refused |

`staging-clean` checks again, requires the matching operation ID and returns `status: removed` only after the stage and matching local receipt have been removed. Any error returns exit 1 and structured JSON; it never reports verification success, creates a batch summary, resumes publishing, or changes the target. There is no `--force`, age threshold or bulk delete command.

## Ownership and deletion boundaries

New stages are named `.swarmcrate-<random-operation-id>-<six-character-suffix>`. Before payload writing, the publisher writes and fsyncs `owner.json` and a byte-identical exclusive machine-local receipt, `.swarmcrate-owner-<id>.json`, in the canonical OS temporary directory. Records bind schema version, operation, absolute stage/target paths, stable directory/data identities, PID, hostname/user and expected byte length. POSIX receipts must belong to the current UID with no group/other permissions. Records contain local paths/context, so treat them as local operational data.

Only `data` and `owner.json` may be present. Cleanup acquires an exclusive `cleanup.lock`, rechecks the observations and positively absent PID, then unlinks only the fixed, matching files and uses nonrecursive `rmdir`. Symlinks/junctions, special files, additional directories/files, changed stamps and competing cleanup claims stop the operation. The marker's target path is validated as a same-parent binding but is never used for deletion. A hard-linked complete target remains intact after removing staging data.

The JS bridge supplies filesystem/process primitives; MoonBit parses bounded records, classifies evidence, builds opaque inspection plans, enforces membership/identity policy and sequences cleanup. `inspect_staging`, `scan_staging`, `staging_inspection_json` and `cleanup_staging(inspection, operation_id)` are in `Novanke/swarmcrate/host` (JS). An inspection cannot be imported from arbitrary JSON. The portable root parser/classifier runs on Wasm GC and JS and grants no filesystem authority.

## Conservative limits

- This supports stable, trusted local output and temporary directories. It is not authentication against malicious code running as the same user, hostile ancestor replacement, shared temporary directories or shared multi-host cleanup. Records are ordinary unsigned provenance, not cryptographic publisher credentials.
- PID probing only tests existence: an existing/reused PID is preserved; only `ESRCH` is accepted as absent. Permission/unknown errors preserve the stage. No process is signalled for termination and no age-based guess is used.
- Version 0.13.0 and earlier stages have no trustworthy ownership record and are preserved. An exit before both records finish, OS temporary-directory cleanup, unavailable stable file identity or a stale cleanup claim can also leave an unverified residue. Diagnose such entries manually; this command deliberately cannot authorize their removal.
- Checks and unlinks are sequential, not a filesystem transaction. A later unlink/rmdir/receipt removal error can leave a partially cleaned directory or receipt. Unknown files and another cleaner's claim remain untouched. The error is reported and eligibility must be inspected again; no recursive fallback or stale-lock reclamation occurs.
- Ordinary `create`/`edit` and older sequential report outputs keep their existing contracts. This staging recovery applies to `write_new_atomic`, controlled creation and batch publication, not every file created by the tool.

## Reproduce

```sh
moon test --target wasm-gc --deny-warn
moon test --target js --deny-warn
moon build --target js --release --deny-warn
python scripts/staging_interop.py
python scripts/creation_interop.py
python scripts/batch_control_interop.py
```

Core tests cover strict parsing, exact local binding and fail-closed classification. Host tests cover stale/repeated plans, unknown members and replaced directories. The real-process script holds an active writer, kills it, checks pre/post-publication exits, selects one of two operations, preserves legacy/foreign/extra/replaced objects, injects claim races and post-inspection changes, and checks deletion failures. Symlink fixtures run where the OS grants permission and are explicitly reported otherwise. CI executes the script on Windows/Linux with Node 22.16.0 and 24; tests use synthetic temporary files and no network client.
