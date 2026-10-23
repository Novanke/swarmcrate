# Reproducible performance comparison

Measured on 2026-10-23, Windows x64, Node.js v24.19.0, MoonBit stable 2026-10-16, optimized JS builds. The same `bench/main.mbt` was compiled against the registry's `Novanke/swarmcrate@0.2.0` and the 0.3.0 source. The harness alternates process order and reports the median of five runs. Compilation and the final inspection used to print identifiers are outside the measured interval; validation performed inside `create_torrent` is included.

| Synthetic case | 0.2.0 median | 0.3.0 median | Content identifiers |
| --- | ---: | ---: | --- |
| Flat v2 tree, 1,000 files | 39.35 ms | 35.41 ms | identical |
| Flat v2 tree, 5,000 files | 162.11 ms | 92.52 ms | identical |
| Hybrid, 8 MiB + 3 bytes | 114.14 ms | 111.36 ms | identical v1 and v2 |

The flat cases contain empty files and one one-byte file, intentionally isolating metadata/tree costs. The hybrid callback returns synthetic bytes valued 7. It reads **16,777,222 bytes in 546 callbacks** with 0.2.0, and **8,388,611 bytes in 33 callbacks** with 0.3.0. These are logical payload bytes and callback invocations, not physical disk reads or OS syscall counts. The hash workload remains; no substantial hybrid wall-clock speedup is claimed from this CPU/cache-bound sample. Directory indexing reduces sibling scans; encoding still sorts dictionary keys, so the whole creator is not claimed to be linear.

Results depend on hardware, runtime warm-up and background load. These samples do not establish production throughput, peak memory, hard-drive/network performance or user adoption. No timing threshold is used in CI. Separate correctness tests enforce non-repeated reads, bounded request sizes, unchanged Merkle roots and canonical output; independent real-file tests cover the filesystem CLI.

## Run the current benchmark

```sh
moon build --target js --release --deny-warn
node scripts/benchmark.mjs --runs 5
```

The benchmark is JS-only because its monotonic clock uses Node. The library being measured remains portable MoonBit. Benchmark source and generated artifacts are excluded from implementation measurements.

## Reproduce the registry baseline

Create a separate sibling directory `baseline`, copy this repository's `bench/` folder into it, and give it this `moon.mod`:

```text
name = "reviewer/baseline"
version = "0.0.1"
preferred_target = "js"
license = "Apache-2.0"
```

In that directory, install the exact baseline and compile the copied benchmark:

```sh
moon add Novanke/swarmcrate@0.2.0
moon build --target js --release --deny-warn
```

Back in the current repository:

```sh
node scripts/benchmark.mjs --runs 5 --baseline ../baseline/_build/js/release/build/bench/bench.js
```

Keep the benchmark code, compiler, runtime, piece policy and synthetic data identical. Do not point the baseline module at a local source override. The harness rejects changed case identities, checks stable read counts across runs, and compares both infohashes before declaring the layouts equivalent. It prints machine-readable JSON so a reviewer can inspect their own results instead of relying on the table above.
