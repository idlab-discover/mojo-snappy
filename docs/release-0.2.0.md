# mojo-snappy 0.2.0

Raw Snappy block codec in Mojo. Target: Linux x86-64, Mojo/compiler 1.0.0.
This release reaches Google Snappy parity: identical compressed output and
equal-or-faster decoding, with a smaller, Span-based API. It breaks the 0.1.0 API.

## Encoder: Google Snappy 1.2.2 parity

The encoder is a port of Google Snappy 1.2.2 level-1 compression (64 KiB
fragments, 16-bit hash tables of up to 32K entries, heuristic match skipping,
COPY_1 emission and Google's copy splitting). Output is byte-identical to
Google Snappy built for the same target: CRC32C hashing on SSE4.2 targets like a
`-march=native` build, and the portable multiplicative hash elsewhere, like
distribution packages. The precompiled package selects the hash per consumer target.
Compared with 0.1.0, blocks are up to 18% smaller on text and low-entropy data.

## Decoder

One pointer-based core serves both decoders. A branch-light fast loop, modelled
on Google's `DecompressBranchless`, uses bounded overcopies and shuffle-based
pattern expansion; an exact, fully checked path handles the block tail, COPY_4,
long literals and all malformed input.

## Performance

On 159 real Parquet pages (144 MB, median about 1 MB), relative to Google Snappy
1.2.2 built with `-O3 -march=native`: decoding takes 0.69x the time and is
faster on every page; encoding takes 1.03x in aggregate and is at parity on the
median page. See the README for the synthetic and real-page tables.

## API changes

All functions take byte `Span`s. Lists convert implicitly; slicing replaces the
`start` and `destination_start` offsets.

| 0.1.0 | 0.2.0 |
|---|---|
| `encode_snappy(data, max_output_bytes, start)` | `compress(data[start:])`; compare `len(result)` with a budget. |
| `compress(data, max_output_bytes=, start=)` | `compress(data[start:])` |
| — | `compress_into(src, dst)` writes into a caller buffer of at least `max_compressed_length(len(src))` bytes. |
| `snappy_max_compressed_length(n)` | `max_compressed_length(n)` |
| `decode_snappy(data, expected_size, start)` | `decompress(data[start:], max_output_bytes=expected_size)`; check `len(result) == expected_size`. |
| `decompress(data, max_output_bytes=, start=)` | `decompress(data[start:], max_output_bytes=)` |
| `decode_snappy_into(data, dst, expected_size, start, dst_start)` | `decompress_into(data[start:], dst[dst_start:dst_start + expected_size])`; check the returned size. |
| `uncompressed_length(data, start)` | `uncompressed_length(data[start:])` |

## Behavior changes

- `decompress` allocates the advertised size up front when the compressed input
  could produce it (at most 64/3 bytes per input byte) and rejects larger
  headers immediately. 0.1.0 grew output only from validated commands.
- `decompress_into` accepts any destination at least as long as the advertised
  size and writes only `dst[:n]`. After an error that range may hold arbitrary
  bytes; bytes beyond it are never touched.
- The encoder no longer takes an output limit. `compress` reserves
  `max_compressed_length(len(src))`; `compress_into` requires a destination of that size.
- The malformed maximum-literal block `00 fc ff ff ff ff` is still rejected,
  unlike Google Snappy 1.2.2, whose 32-bit literal length wraps.

## Verification

The unit suite pins byte-identical output against golden Google Snappy results
for both hash variants, and covers fast-loop, block-start and exact-tail
placement of every copy form, offset and length. Mutation checks against
deliberately broken encoder and decoder paths confirm that it catches errors.
Outside the repository, a differential fuzzer against native libsnappy found no
disagreements over more than 40,000 valid and malformed blocks, and
PyArrow/cramjam interoperability passes under both assertion policies.
