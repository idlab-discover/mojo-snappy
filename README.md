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

The decoder handles all copy forms and overlapping backreferences. The encoder
uses a 16,384-entry hash table, greedy matching and two-byte-offset copies.
Limits constrain byte-list lengths; standard-library capacity growth and allocator
overhead mean these are not exact allocation or RSS limits. No speed claims have
been established against optimized reference implementations.

## Develop and verify

```sh
pixi install --locked
pixi run mojo --version
pixi run check
pixi run -e oracle test-interop
```

`check` runs native debug/release tests, tests the precompiled package independently
of the source import path, and executes the example. The optional oracle environment
is separately defined and locked in `pixi.toml` / `pixi.lock`. Differential tests
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
