# mojo-snappy

![Mojo-snappy: a flame mascot jumping down a stack of columns](assets/branding/mojo-snappy-logo-169.png)

Raw Snappy compression and decompression implemented in Mojo, pinned to **Mojo 1.0.0**.
The library uses only the Mojo standard library. Python, PyArrow and cramjam are
optional development oracles; they are not library runtime dependencies.

## Naming and scope

- Repository and distribution: `mojo-snappy`
- Mojo import: `mojo_snappy`
- Precompiled artifact: `mojo_snappy.mojoc`
- Library version: `0.1.0`, independent of the compiler version `1.0.0`

This implements raw Snappy blocks. The optional Snappy framed stream format,
stream identifiers and CRC32C checksums are not implemented. Parquet integration
belongs to downstream consumers such as Pyroquet.

## Use

```mojo
from mojo_snappy import encode_snappy, decode_snappy, snappy_max_compressed_length

var data = List[UInt8](length=1000, fill=42)
var encoded = encode_snappy(data, snappy_max_compressed_length(len(data)))
var decoded = decode_snappy(encoded, len(data))
```

The public functions borrow `List[UInt8]` inputs:

- `encode_snappy(data, max_output_bytes, start=0)` encodes the source suffix and
  raises if encoded output would exceed the supplied byte-length limit.
- `decode_snappy(data, expected_size, start=0)` decodes a raw block from the suffix,
  requiring the declared and actual output lengths to equal `expected_size`.
  Invalid offsets, truncated commands, output overruns and trailing commands reject.
- `decode_snappy_into(data, destination, expected_size, start=0, destination_start=0)`
  decodes into an initialized, caller-owned List and returns `expected_size`.
  It performs no output allocation or resizing, enabling buffer reuse and decoding
  directly into a larger final buffer.
- `snappy_max_compressed_length(size)` supplies a conservative encoded-size bound
  for input lengths from zero through `2**32 - 1`.

For reusable storage:

```mojo
from mojo_snappy import decode_snappy_into

var destination = List[UInt8](length=len(data), fill=0)
_ = decode_snappy_into(encoded, destination, len(data))
```

`destination` must have enough **initialized length**, not just reserved capacity,
for `destination_start + expected_size` bytes. Its prefix and tail remain untouched.
Late errors may leave a partially decoded region; only consume it after success.
Input and destination must be distinct Lists. Reuse the buffer after consumers have
finished with its previous contents. For a prefixed final buffer, pass its prefix
length as `destination_start`; `start` independently selects the compressed suffix.

`encode_snappy` and `decode_snappy` return newly owned Lists. Use `decode_snappy`
when the decoder should manage output allocation; it grows only after validating
commands, so a header alone cannot trigger a large allocation. Caller-owned decoding
requires the caller to choose and allocate an acceptable output size in advance.
Both decoders support all Snappy copy forms and overlapping backreferences and
require no input padding.
The encoder uses an input-sized hash table, greedy matching and adaptive search
skipping on inputs of at least 16 KiB. Speed and compression density vary by input;
byte-length limits are not exact allocation or RSS limits.
See [third-party notices](THIRD_PARTY_NOTICES.md) for upstream attribution.

## Benchmarks

Local measurement on **2026-09-20**, AMD Ryzen 9 5950X, source commit
`5dcd1b8`, Mojo **1.0.0**. The same 14 inputs from the existing comparison
suite are used for all three implementations. **Local Snappy** is the retained
Snappy 1.2.2 source build (`-O3 -g -DNDEBUG -march=native`); **distro Snappy**
is the installed Arch Extra package **1.2.2-3**, loaded from `/usr/lib`.
Both use compression level 1. Mojo is freshly built with `-O3`; the primary
column uses `ASSERT=none`, with `ASSERT=all` alongside for comparison.

**Time per call in microseconds (µs); lower is better.** Medians of seven
shuffled rounds, calibrated to approximately 100 ms per sample, pinned to CPU 8.

| Input | Operation | Mojo | Local Snappy | Distro Snappy | Mojo (assertions) |
|---|---|---:|---:|---:|---:|
| random-64 | encode | 0.187 | 0.084 | 0.089 | 0.196 |
| random-64 | decode | 0.031 | 0.049 | 0.044 | 0.036 |
| constant-64 | encode | 0.145 | 0.062 | 0.055 | 0.158 |
| constant-64 | decode | 0.056 | 0.083 | 0.086 | 0.064 |
| cycle-64 | encode | 0.194 | 0.084 | 0.088 | 0.201 |
| cycle-64 | decode | 0.031 | 0.049 | 0.044 | 0.035 |
| low-entropy-64 | encode | 0.232 | 0.088 | 0.102 | 0.241 |
| low-entropy-64 | decode | 0.103 | 0.062 | 0.056 | 0.113 |
| random-65536 | encode | 10.603 | 2.376 | 2.414 | 10.184 |
| random-65536 | decode | 1.034 | 1.458 | 1.454 | 1.157 |
| constant-65536 | encode | 7.243 | 3.244 | 3.906 | 7.955 |
| constant-65536 | decode | 5.176 | 5.682 | 39.203 | 7.913 |
| cycle-65536 | encode | 7.401 | 3.667 | 4.022 | 8.098 |
| cycle-65536 | decode | 7.043 | 4.837 | 6.787 | 10.534 |
| low-entropy-65536 | encode | 177.090 | 100.432 | 120.461 | 193.751 |
| low-entropy-65536 | decode | 91.242 | 69.744 | 90.832 | 124.516 |
| random-1048576 | encode | 142.498 | 45.938 | 46.760 | 142.552 |
| random-1048576 | decode | 33.087 | 30.776 | 30.679 | 35.063 |
| constant-1048576 | encode | 53.676 | 57.341 | 71.528 | 64.958 |
| constant-1048576 | decode | 82.877 | 93.066 | 641.140 | 125.457 |
| cycle-1048576 | encode | 53.960 | 60.409 | 70.650 | 65.391 |
| cycle-1048576 | decode | 113.550 | 79.552 | 111.265 | 169.027 |
| low-entropy-1048576 | encode | 2773.462 | 1867.047 | 2225.404 | 3066.913 |
| low-entropy-1048576 | decode | 1603.829 | 1119.874 | 1476.166 | 2092.943 |
| alice29.txt | encode | 414.495 | 300.894 | 372.225 | 442.111 |
| alice29.txt | decode | 320.394 | 148.855 | 198.765 | 373.280 |
| html | encode | 87.291 | 58.280 | 82.973 | 97.247 |
| html | decode | 72.185 | 35.620 | 44.869 | 90.195 |

**Compressed bytes; lower is better.** Both Mojo assertion modes produce
identical output. Sizes are measured independently for each implementation.

| Input | Raw bytes | Mojo | Local Snappy | Distro Snappy |
|---|---:|---:|---:|---:|
| random-64 | 64 | 67 | 67 | 67 |
| constant-64 | 64 | 6 | 6 | 6 |
| cycle-64 | 64 | 67 | 67 | 67 |
| low-entropy-64 | 64 | 66 | 65 | 65 |
| random-65536 | 65,536 | 65,542 | 65,542 | 65,542 |
| constant-65536 | 65,536 | 3,077 | 3,077 | 3,077 |
| cycle-65536 | 65,536 | 3,320 | 3,321 | 3,321 |
| low-entropy-65536 | 65,536 | 53,528 | 45,441 | 45,676 |
| random-1048576 | 1,048,576 | 1,048,583 | 1,048,627 | 1,048,627 |
| constant-1048576 | 1,048,576 | 49,157 | 49,187 | 49,187 |
| cycle-1048576 | 1,048,576 | 49,400 | 53,091 | 53,091 |
| low-entropy-1048576 | 1,048,576 | 840,446 | 731,333 | 733,384 |
| alice29.txt | 152,089 | 95,118 | 86,834 | 86,727 |
| html | 102,400 | 24,158 | 22,653 | 22,758 |

These are hot-buffer, allocating public-API measurements: each call allocates
and frees its output. File I/O, process startup and validation are excluded.
All decoders consume the same distro-produced stream; every producer’s output
was byte-validated with every decoder. Native output pre-sizing and Mojo’s
incremental output growth are included. The shared host uses dynamic clocks
without core isolation; small differences should not be treated as decisive.

Reproduction commands, harnesses, input/output hashes and all raw samples are
retained locally in gitignored `build/three-way-20260920/` (`REPRODUCE.md`).
These artifacts are not distributed with the repository.

## Develop and verify

```sh
pixi install --locked
pixi run mojo --version
pixi run check
pixi run -e oracle test-interop
```

`check` runs assertion-enabled tests (including optimized `-O3` builds), tests
source and freshly precompiled package imports with `ASSERT=none`, and executes
the example. Package consumers are tested independently of the source import path.
The optional oracle environment is separately defined and locked in `pixi.toml` / `pixi.lock`. Differential tests
cover both encode/decode directions against PyArrow and cramjam, with generated
fixtures in ignored `build/`.

To use this checkout as a Pixi dependency, enable `preview = ["pixi-build"]` in the
consumer's `[workspace]` and add:

```toml
[dependencies]
mojo = "==1.0.0"
mojo-snappy = { path = "../mojo-snappy" }
```

`pixi install` builds and installs the package into the consumer's environment;
`from mojo_snappy import ...` then works without a sibling source include path.
For direct source use, pass `-I /path/to/mojo-snappy/src` to Mojo.

### Assertion policy

Use `-D ASSERT=all` for development. `test-release` is optimized (`-O3`) with
assertions enabled. Opt into a checks-disabled consumer with:

```sh
pixi run mojo build -O3 -D ASSERT=none -I src examples/roundtrip.mojo -o build/roundtrip-release
```

`ASSERT=none` removes compiler/standard-library assertions, including container
bounds diagnostics. Explicit codec validation remains enabled; compressed bytes
are unchanged. Choose the assertion policy when compiling the consumer, whether
importing source or a precompiled `.mojoc` package.

## Packaging and distribution

The existing `pixi-build-mojo` manifest supports local Pixi path dependencies.
For release artifacts, use the explicit Conda recipe, which also tests an isolated
installation and includes the project license and upstream notices:

```sh
pixi run --locked -e packaging conda-build
```

Artifacts are written to `build/conda/linux-64/`. The package installs
`mojo_snappy.mojoc` under `lib/mojo` and pins the compiler to `1.0.0`.
The initial supported build/test target is Linux x86-64. No package channel has
been configured or publication claimed; there is no Python API or wheel.

GitHub CI runs the source/package checks, both oracle assertion modes and the
isolated Conda installation tests. It uploads the package, SHA256 checksums and
checkout commit as CI artifacts. See [distribution and tagging](docs/distribution.md)
and the [0.1.0 release candidate notes](docs/release-0.1.0.md).

## License

This project is licensed under [Apache-2.0](LICENSE). Adapted Google Snappy ideas
retain the BSD-3-Clause terms in [third-party notices](THIRD_PARTY_NOTICES.md);
both documents are included in the release Conda package.

References: [Mojo packaging](https://mojolang.org/docs/tools/packaging/),
[Mojo names](https://mojolang.org/docs/manual/packages/#package-naming-and-identifiers),
[Pixi Mojo backend](https://pixi.prefix.dev/latest/build/backends/pixi-build-mojo/),
[Conda names](https://conda.org/learn/specifications/distribution/package-identifiers/),
[PyPI names](https://packaging.python.org/en/latest/specifications/name-normalization/),
[Snappy raw format](https://github.com/google/snappy/blob/main/format_description.txt).

## Provenance

Extracted from `pyroquet-next` commit `ef0206f`, originally introduced in
`df3aa36`. The initial extraction preserved the codec algorithm; subsequent commits added
the bounded optimizations described above. Codec unit and differential
tests moved with the library; Parquet page and reader-oracle tests remain in Pyroquet.

<p align="center">
  <img src="assets/branding/mojo-snappy-logo-square.png" alt="Mojo-snappy mascot" width="160">
</p>
