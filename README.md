# mojo-snappy

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

The public functions borrow `List[UInt8]` inputs and return owned byte lists:

- `encode_snappy(data, max_output_bytes, start=0)` encodes the source suffix and
  raises if encoded output would exceed the supplied byte-length limit.
- `decode_snappy(data, expected_size, start=0)` decodes a raw block from the suffix,
  requiring the declared and actual output lengths to equal `expected_size`.
  Invalid offsets, truncated commands, output overruns and trailing commands reject.
- `snappy_max_compressed_length(size)` supplies a conservative encoded-size bound
  for input lengths from zero through `2**32 - 1`.

The decoder handles all copy forms and overlapping backreferences. Fixed-width
reads check truncation before accessing bytes. Backreferences use bounded 16-byte
and 4-byte copies where the source is initialized, with forward byte copies for
small overlapping patterns and tails. No input padding is required. The encoder
uses a power-of-two hash table sized to the source suffix (256–16,384 `Int`
entries), greedy matching and two-byte-offset copies. Inputs shorter than four
bytes allocate no hash table. Hash reads and initial match comparisons use guarded,
unaligned four-byte loads; the hash is independent of host byte order. Large
inputs compare readable candidates before checking distance, preserving the same
matches while reducing failed-probe branches. Match extension locates the first
unequal byte with guarded word XORs, retains 16-byte comparisons for equal long
runs, and uses scalar tails without reading padding. Encoder bytes are unchanged.
See [third-party notices](THIRD_PARTY_NOTICES.md) for upstream attribution.
For suffixes of at least 16 KiB, unsuccessful searches gradually skip positions
after 128 consecutive probes, with a maximum 16-byte stride. Every match resets
the search to consecutive positions. Shorter inputs use exhaustive search.
Skipped bytes remain literals: this trades some compression density for less
probing in incompressible regions and can miss short repeated islands. The stride
bound applies across the entire suffix; 64 KiB is a lookback limit, not an input
or Parquet page-size limit.
Limits constrain byte-list lengths; standard-library capacity growth and allocator
overhead mean these are not exact allocation or RSS limits. Speed and compression
density depend on the input and assertion policy.

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

Keep `-D ASSERT=all` for development and correctness checks. The existing
`test-release` task means an optimized, assertion-enabled build (`-O3`), not a
checks-disabled build. For an explicitly opted-in release executable:

```sh
mkdir -p build
pixi run mojo build -O3 -D ASSERT=none -I src examples/roundtrip.mojo -o build/roundtrip-release
pixi run test-release-noassert
pixi run test-package-noassert
pixi run -e oracle test-interop --assertions none
```

`ASSERT=none` disables compiler/standard-library assertions throughout the
consumer, including container bounds diagnostics. It does not disable this
codec's explicit errors for invalid sizes, source starts, truncated commands,
invalid offsets, output limits or trailing data. The decoder allocates output
only as commands are validated, never from the advertised length alone.
Disabling assertions removes protection against implementation mistakes;
sampled interoperability tests are not a proof of memory safety. This is an
opt-in performance configuration, not the default test or package policy.

`mojo precompile` stores non-elaborated code: choose `-O3 -D ASSERT=all` or
`-O3 -D ASSERT=none` when building the **consumer**, for either source or `.mojoc`
imports. Precompilation does not freeze a release assertion policy. Report these
flags with benchmarks; comparisons with native Snappy built with `-DNDEBUG`
should show both Mojo configurations. Codec algorithms and compressed sizes do
not change with this policy.

## Packaging and future distribution

The manifest defines a `pixi-build-mojo` package that creates a Conda artifact and
installs `mojo_snappy.mojoc` under `lib/mojo`. Build, host and consumer compiler
requirements are pinned to `1.0.0`; precompiled Mojo packages are compiler-specific.
The Pixi build feature is currently a preview feature.

`pixi build --output-dir build/dist` creates a local `.conda` artifact (Pixi 0.80
also offers `pixi publish --path . --target-dir build/dist` as its replacement).
No registry publication is configured. Before public release, choose a license,
set the actual repository URL and release provenance, and verify name availability
in the target registry/channel. No license has been selected by this extraction.

Conda distributions can be hosted on prefix.dev or anaconda.org using the same
`mojo-snappy` name. PyPI permits that name too, but publishing there would require
a separate Python distribution layout/build configuration; a `.conda` artifact
cannot be uploaded as a wheel. This project does not currently expose a Python API
or build a wheel. PyPI normalizes `mojo-snappy`, `mojo_snappy` and `mojo.snappy` to
the same distribution name; that does not rename the Mojo import.

References: [Mojo packaging](https://mojolang.org/docs/tools/packaging/),
[Mojo names](https://mojolang.org/docs/manual/packages/#package-naming-and-identifiers),
[Pixi Mojo backend](https://pixi.prefix.dev/latest/build/backends/pixi-build-mojo/),
[Conda names](https://conda.org/learn/specifications/distribution/package-identifiers/),
[PyPI names](https://packaging.python.org/en/latest/specifications/name-normalization/),
[Snappy raw format](https://github.com/google/snappy/blob/main/format_description.txt).

## Provenance

Extracted from `pyroquet-next` commit `ef0206f`, originally introduced in
`df3aa36`. The codec algorithm is unchanged by extraction. Codec unit and differential
tests moved with the library; Parquet page and reader-oracle tests remain in Pyroquet.
