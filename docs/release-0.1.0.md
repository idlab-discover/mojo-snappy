# mojo-snappy 0.1.0

First release candidate of a raw Snappy block codec implemented in Mojo.
Target: Linux x86-64, Mojo/compiler 1.0.0. The library uses only the Mojo standard
library; Python and external codecs are development/test dependencies.

## API and behavior

- `encode_snappy(data, max_output_bytes, start=0)` encodes a borrowed byte-list
  suffix and returns an owned byte list within the supplied output limit.
- `decode_snappy(data, expected_size, start=0)` handles all Snappy copy forms,
  including overlapping references, and requires exact declared/decoded size.
- `snappy_max_compressed_length(size)` supplies an encoder output bound.

Explicit size, offset, truncation, output-limit and trailing-data errors remain
active with assertions disabled. Decoder allocation follows validated commands,
not the advertised size alone. No padding or speculative output writes are required.

## Scope

Raw blocks only: no framed streams, framing checksums, Python API or Parquet
reader/writer. Distribution and source imports use `mojo-snappy` / `mojo_snappy`.
The `.mojoc` package is compiler-specific; consumer builds select assertion policy.
Linux ARM, macOS and Windows are not covered by this release's installation tests.

Performance varies by data and assertion policy. No universal speedup or native
Snappy parity is claimed. Intermediate-size incompressible encoding and ordinary
short-copy decoding remain known optimization opportunities. Rejected experimental
implementations are not part of this release.

The malformed maximum-literal block `00 fc ff ff ff ff` is rejected, unlike the
Google Snappy 1.2.2 oracle observed during verification. Unsupported downstream
Parquet logical/nested materialization is outside this codec's release scope.

## Verification and distribution

CI runs source, optimized, precompiled-package and example tests; PyArrow/cramjam
interoperability under both assertion policies; and an isolated Conda installation
with the full codec suite under both policies. Historical focused memory checks
supplement these tests; they are not a proof of memory safety.

Apache-2.0 for this project, with upstream Google Snappy BSD-3-Clause attribution
and terms in `THIRD_PARTY_NOTICES.md`. The release Conda recipe includes both.
The package contains `lib/mojo/mojo_snappy.mojoc` and pins mojo-compiler to 1.0.0.

This document describes the candidate. A tag or channel publication is not implied.
See [distribution](distribution.md) for release steps and current prerequisites.
