# Output safety and final-review fixes — 0.14.1

This maintenance release fixes independently reproduced failures in the existing offline workflow. It adds no downloader or network service. Core portable-name validation and CLI preflight/overlap policy remain MoonBit; the Node bridge supplies filesystem observations and checked I/O.

## Reject unusable creation targets before expensive work

Both ordinary and controlled `create` now resolve/freeze and preflight their new destination before scanning or hashing the input. An existing file/directory or missing parent returns an error without payload opens, directory enumeration or progress callbacks. Existing files remain unchanged. Before the fix, ordinary creation read all 1,048,577 bytes of a synthetic file before reporting either an existing target or a missing parent.

Preflight is advisory, not a reservation: final writes still use exclusive creation, so a competing target created later is preserved. Other write-time failures, such as permissions changing or disk exhaustion, can still happen after hashing.

## Compare filesystem path identities before writing reports

`host.canonical_path` resolves existing OS path aliases using the nearest existing ancestor, then appends any missing tail without creating it. Original existing components are checked for links before canonicalization. Only a missing component permits this fallback; permission errors, non-directory ancestors and other OS errors fail normally. MoonBit normalizes Windows drive/UNC namespace forms and compares complete path components, including filesystem roots.

This closes a reproduced case where `verify --file good --receipt` or `audit-batch` could use a Windows extended path to create a missing/unselected payload file as a report. Extended paths, explicit drive-filesystem namespace aliases and available 8.3 short-path spellings are now compared with the protected physical locations. Raw non-filesystem devices, Windows alternate streams and trailing-dot/space paths are rejected in these comparisons. Symlinks/junctions remain unsupported. See the [Node realpath primitive](https://nodejs.org/docs/latest-v22.x/api/fs.html#fsrealpathsyncnativepath-options) and [Windows path/namespace conventions](https://learn.microsoft.com/en-us/windows/win32/fileio/naming-a-file).

Output normalization is strict. When an input cannot be safely normalized, its lexical guard is retained and the existing loader/required-file checks report the task error; a bad task does not abort later tasks, and an unselected unusable input does not block a valid partial report. This fallback never grants permission to follow links or use unsupported input paths.

The canonical path is for preflight, not an authorization token or atomic filesystem snapshot. Writes keep their frozen absolute targets and exclusive creation. Stable trusted local directories remain required; malicious directory replacement and unsupported filesystem aliases are not claimed to be solved.

## Preserve another writer's replacement after an error

Ordinary `write_new` cleanup now checks whether the current path still identifies the originally created regular file before unlinking it. If a close error happens after another writer has replaced that path, the competing file remains. A synthetic close-failure fixture reproduced its deletion in registry 0.14.0; fixed commands preserve the competing bytes for create, edit and all three single-verification report formats.

Ordinary writes are still not atomic publication. If an original identity cannot be established, or cleanup itself fails, a failed write can leave a partial own file. The command reports failure and never deletes an uncertain replacement. Controlled creation/batch output retains its separate atomic staging contract.

## Portable names and runnable examples

Portable MoonBit path validation additionally rejects the Windows reserved superscript COM/LPT forms and console-device stems. Tests cover case, extensions and nested components with ordinary-name controls; they do not open devices. The rules follow [Microsoft naming guidance](https://learn.microsoft.com/en-us/windows/win32/fileio/naming-a-file) and [the DOS-device classification documentation](https://learn.microsoft.com/en-us/windows/win32/devnotes/rtlisdosdevicename_u).

The batch cancellation examples use distinct output names, so the complete-run example does not prevent the later cancel-file example from running. The independent interoperability script defaults to the documented release build, avoiding an unrelated stale debug artifact. Existing-output rejection has its own zero-I/O tests, while all directory-mutation cases still run with fresh destinations.

## Reproduce

```sh
moon test --target wasm-gc --deny-warn
moon test --target js --deny-warn
moon build --target js --release --deny-warn
python scripts/output_safety_interop.py
```

The new script tests zero-I/O early rejection, replacement-on-close failures, all three report formats, batch summaries and Windows path aliases. It reports platform-dependent counts and whether 8.3 aliases were available; it does not change filesystem settings to create them. Source and registry consumption also run the existing interoperability, cancellation, close-fault and staging suites. CI requires all four Windows/Linux × Node 22.16.0/24 combinations to finish independently.
