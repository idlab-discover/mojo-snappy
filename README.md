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
from mojo_snappy import compress, decompress

var data = List[UInt8](length=1000, fill=42)
var encoded = compress(data)
var decoded = decompress(encoded, max_output_bytes=4096)
```

The public functions borrow `List[UInt8]` inputs. For ordinary use:

- `compress(data, *, max_output_bytes=None, start=0)` encodes the source suffix.
  By default it computes a sufficient encoded-size bound; supply a tighter
  `max_output_bytes` to enforce your own budget. Output bytes match `encode_snappy`.
- `decompress(data, *, max_output_bytes, start=0)` decodes a raw block when its
  exact output size is unknown. The required, nonnegative cap limits decoded byte
  length. The advertised size must fit the cap, and the entire block must validate.
  Sizes the compressed input cannot produce are rejected before any allocation.
- `uncompressed_length(data, start=0)` returns the UInt32 size advertised by the
  header, without allocating output. It rejects truncated or overflowing headers,
  but **does not validate the remaining block**. Apply your own size budget before
  using this value to allocate storage.

For exact-size validation and caller-owned storage, the existing functions remain
available with unchanged arguments:

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
Late errors may leave arbitrary bytes in the target range; only consume it after success.
Input and destination must be distinct Lists. Reuse the buffer after consumers have
finished with its previous contents. For a prefixed final buffer, pass its prefix
length as `destination_start`; `start` independently selects the compressed suffix.

`compress`, `decompress`, `encode_snappy` and `decode_snappy` return newly owned
Lists. Use `decode_snappy` when independent metadata supplies the exact output size;
unlike a maximum, this also rejects blocks whose decoded size is smaller than expected.
Both allocating decoders allocate the advertised size up front only when the
compressed input could produce it: each input byte decodes to at most 64/3 bytes,
so a header alone cannot trigger an allocation beyond about 21x the input length.
Larger advertised sizes reject immediately. Caller-owned decoding
requires the caller to choose and allocate an acceptable output size in advance.
Both decoders support all Snappy copy forms and overlapping backreferences and
require no input padding.
The encoder is a port of Google Snappy 1.2.2 level-1 compression and produces
byte-identical output to Google Snappy built for the same target: with SSE4.2 it
hashes with CRC32C like a `-march=native` x86 build; elsewhere it uses the portable
multiplicative hash of generic builds (such as distribution packages).
Byte-length limits are not exact allocation or RSS limits: encoding always
reserves the worst-case bound and checks `max_output_bytes` against the result.
See [third-party notices](THIRD_PARTY_NOTICES.md) for upstream attribution.

## Benchmarks

Local measurement on **2026-09-30**, AMD Ryzen 9 5950X, Mojo **1.0.0**. The same
14 inputs as earlier comparisons are used for all three implementations.
**Local Snappy** is the retained Snappy 1.2.2 source build
(`-O3 -g -DNDEBUG -march=native`); **distro Snappy** is the installed Arch Extra
package **1.2.2-3**, loaded from `/usr/lib`. Both use compression level 1. Mojo is
freshly built with `-O3` for the host CPU; the primary column uses `ASSERT=none`,
with `ASSERT=all` alongside for comparison.

**Time per call in microseconds (µs); lower is better.** Medians of seven
shuffled rounds, calibrated to approximately 100 ms per sample, pinned to CPU 8.

| Input | Operation | Mojo | Local Snappy | Distro Snappy | Mojo (assertions) | Mojo / Local |
|---|---|---:|---:|---:|---:|---:|
| random-64 | encode | 0.094 | 0.084 | 0.089 | 0.092 | 1.12 |
| random-64 | decode | 0.031 | 0.048 | 0.043 | 0.032 | 0.63 |
| constant-64 | encode | 0.060 | 0.062 | 0.053 | 0.063 | 0.96 |
| constant-64 | decode | 0.046 | 0.081 | 0.081 | 0.049 | 0.57 |
| cycle-64 | encode | 0.092 | 0.082 | 0.088 | 0.091 | 1.12 |
| cycle-64 | decode | 0.030 | 0.048 | 0.043 | 0.032 | 0.63 |
| low-entropy-64 | encode | 0.101 | 0.088 | 0.102 | 0.101 | 1.15 |
| low-entropy-64 | decode | 0.043 | 0.061 | 0.055 | 0.044 | 0.70 |
| random-65536 | encode | 1.921 | 2.372 | 2.405 | 1.863 | 0.81 |
| random-65536 | decode | 1.009 | 1.454 | 1.453 | 1.012 | 0.69 |
| constant-65536 | encode | 3.110 | 3.233 | 3.868 | 3.101 | 0.96 |
| constant-65536 | decode | 3.525 | 5.703 | 38.897 | 3.645 | 0.62 |
| cycle-65536 | encode | 3.306 | 3.655 | 4.013 | 3.283 | 0.90 |
| cycle-65536 | decode | 2.848 | 4.821 | 6.691 | 2.961 | 0.59 |
| low-entropy-65536 | encode | 106.725 | 100.130 | 120.022 | 105.750 | 1.07 |
| low-entropy-65536 | decode | 44.048 | 69.509 | 90.314 | 41.841 | 0.63 |
| random-1048576 | encode | 33.184 | 46.020 | 46.250 | 32.115 | 0.72 |
| random-1048576 | decode | 16.688 | 30.545 | 30.591 | 16.703 | 0.55 |
| constant-1048576 | encode | 49.176 | 57.809 | 70.857 | 49.206 | 0.85 |
| constant-1048576 | decode | 54.728 | 92.759 | 643.282 | 56.775 | 0.59 |
| cycle-1048576 | encode | 52.322 | 60.460 | 70.685 | 52.052 | 0.87 |
| cycle-1048576 | decode | 45.260 | 79.294 | 111.361 | 47.166 | 0.57 |
| low-entropy-1048576 | encode | 1886.641 | 1863.876 | 2226.021 | 1875.975 | 1.01 |
| low-entropy-1048576 | decode | 732.168 | 1117.286 | 1475.244 | 703.077 | 0.66 |
| alice29.txt | encode | 273.225 | 301.048 | 370.284 | 271.279 | 0.91 |
| alice29.txt | decode | 97.320 | 149.342 | 197.773 | 95.341 | 0.65 |
| html | encode | 38.940 | 58.326 | 81.780 | 38.571 | 0.67 |
| html | decode | 18.628 | 35.521 | 44.506 | 18.734 | 0.52 |

**Compressed bytes; lower is better.** Mojo output is byte-identical to local
Snappy (both hash with SSE4.2 CRC32C). Built for baseline x86-64, Mojo output is
byte-identical to the distro package instead.

| Input | Raw bytes | Mojo | Local Snappy | Distro Snappy |
|---|---:|---:|---:|---:|
| random-64 | 64 | 67 | 67 | 67 |
| constant-64 | 64 | 6 | 6 | 6 |
| cycle-64 | 64 | 67 | 67 | 67 |
| low-entropy-64 | 64 | 65 | 65 | 65 |
| random-65536 | 65,536 | 65,542 | 65,542 | 65,542 |
| constant-65536 | 65,536 | 3,077 | 3,077 | 3,077 |
| cycle-65536 | 65,536 | 3,321 | 3,321 | 3,321 |
| low-entropy-65536 | 65,536 | 45,441 | 45,441 | 45,676 |
| random-1048576 | 1,048,576 | 1,048,627 | 1,048,627 | 1,048,627 |
| constant-1048576 | 1,048,576 | 49,187 | 49,187 | 49,187 |
| cycle-1048576 | 1,048,576 | 53,091 | 53,091 | 53,091 |
| low-entropy-1048576 | 1,048,576 | 731,333 | 731,333 | 733,384 |
| alice29.txt | 152,089 | 86,834 | 86,834 | 86,727 |
| html | 102,400 | 22,653 | 22,653 | 22,758 |

These are hot-buffer, allocating public-API measurements: each call allocates
and frees its output. File I/O, process startup and validation are excluded.
All decoders consume the same distro-produced stream; every producer’s output
was byte-validated with every decoder. The shared host uses dynamic clocks
without core isolation; small differences should not be treated as decisive.
Harnesses, hashes and raw samples are retained locally in the gitignored
`build/three-way-20260930/` directory and are not distributed.

### Real Parquet pages

The synthetic inputs above are small or extreme. A second comparison uses
**159 real Parquet pages** (144 MB decoded, median about 1 MB): a byte-weighted
sample from a 25.3 GB collection of public network-security datasets, mostly
FLOAT/DOUBLE/INT PLAIN data pages and RLE_DICTIONARY IDs. Decoding uses each
page's original Snappy block as written by the dataset's producer; encoding
compresses the decoded page. Same host and CPU pinning, five shuffled rounds,
about 20 ms per sample; aggregate throughput is total bytes over the sum of
per-page medians. Measured on 2026-09-30 at commit `a99946c`.

| Operation | Mojo GB/s | Local Snappy GB/s | Distro Snappy GB/s | Mojo / Local time |
|---|---:|---:|---:|---:|
| encode | 0.95 | 0.99 | 0.76 | 1.03 |
| decode (allocating) | 2.61 | 1.80 | 1.10 | 0.69 |
| decode into reused buffer | 2.72 | 1.84 | 1.15 | 0.68 |

Per page, Mojo decodes faster than local Snappy on all 159 pages (median time
ratio 0.68). Encoding is at parity on the median page (ratio 1.01; 10th/90th
percentiles 0.72/1.11). The largest remaining encode gap is a sequential INT64
index page (about 1.24x). Compressed output is byte-identical to local Snappy
on every page. The page corpus is not distributed with the repository.

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
