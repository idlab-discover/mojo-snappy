# mojo-snappy 0.2.1

Raw Snappy block codec in Mojo. Target: Linux x86-64, Mojo/compiler 1.2.0.
This release is a compiler migration. The public API and compressed output are
unchanged from 0.2.0.

## Compiler compatibility

| Library version | Mojo compiler | Source |
|---|---|---|
| 0.2.0 build 0 | 1.0.0 | `v0.2.0` (`1bb71be`) |
| 0.2.0 build 1 | 1.1.0 | `83a08c6` (`InlineArray` → `Array` migration) |
| 0.2.1 build 0 | 1.2.0 | `v0.2.1` |

From 0.2.1 on, each compiler migration gets a new library version and tag. A
build number increment is reserved for recipe-only rebuilds of the same source.

## Changes

- Following the [Mojo 1.2.0 changelog](https://mojolang.org/releases/v1.2.0/),
  little-endian loads and stores use `SIMD.from_endian[.little]` and
  `to_endian[.little]` instead of the deprecated `is_big_endian()` predicate
  and manual byte swaps.
- Inline hints use `@inline(.always)` and `@inline(.never)`.
- `Array` replaces `InlineArray`, carried over from the Mojo 1.1.0 build.
- `test-release` now uses release defaults, `-O3 -D ASSERT=none`;
  `test-release-assert` keeps optimized coverage with assertions enabled.

## Verification

The unit suite, golden Google Snappy outputs and PyArrow/cramjam
interoperability pass under both assertion policies. The Conda package
passes its isolated installation tests without a source include path.
