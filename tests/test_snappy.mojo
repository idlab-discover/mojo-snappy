"""Raw Snappy format, malformed-block, buffer-contract and parity tests."""
from std.sys.info import CompilationTarget
from std.testing import assert_equal, assert_true, assert_raises, TestSuite
from mojo_snappy import (
    compress,
    compress_into,
    decompress,
    decompress_into,
    max_compressed_length,
    uncompressed_length,
)


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------


comptime SENTINEL = UInt8(179)


def _lcg_bytes(n: Int, seed: UInt32, bits: Int) -> List[UInt8]:
    var state = seed
    var out = List[UInt8](capacity=n)
    for _ in range(n):
        state = state * UInt32(1664525) + UInt32(1013904223)
        out.append(UInt8((state >> 24) & UInt32((1 << bits) - 1)))
    return out^


def _numeric_page(values: Int, seed: UInt32) -> List[UInt8]:
    """Little-endian UInt32 runs with noisy low bits, like a PLAIN page."""
    var state = seed
    var out = List[UInt8](capacity=4 * values)
    for i in range(values):
        state = state * UInt32(1664525) + UInt32(1013904223)
        var value = UInt32((i // 3) * 7) + (state >> 29)
        for k in range(4):
            out.append(UInt8((value >> UInt32(8 * k)) & 255))
    return out^


def _fnv1a(data: List[UInt8]) -> UInt64:
    var h = UInt64(0xCBF29CE484222325)
    for b in data:
        h = (h ^ UInt64(b)) * UInt64(0x100000001B3)
    return h


def _append_varint(mut block: List[UInt8], var value: Int):
    while value >= 128:
        block.append(UInt8((value & 127) | 128))
        value >>= 7
    block.append(UInt8(value))


def _append_literal(mut block: List[UInt8], bytes: List[UInt8]):
    if len(bytes) <= 60:
        block.append(UInt8((len(bytes) - 1) << 2))
    else:
        block.append(UInt8(60 << 2))
        block.append(UInt8(len(bytes) - 1))
    block.extend(bytes.copy())


def _append_copy(mut block: List[UInt8], kind: Int, offset: Int, count: Int):
    if kind == 1:
        block.append(UInt8(1 | ((count - 4) << 2) | ((offset >> 8) << 5)))
        block.append(UInt8(offset & 255))
        return
    block.append(UInt8(kind | ((count - 1) << 2)))
    for i in range(2 if kind == 2 else 4):
        block.append(UInt8((offset >> (8 * i)) & 255))


def _into_padded(block: List[UInt8], size: Int, pad: Int) raises -> List[UInt8]:
    """Decode into dst[pad:pad+size+pad] of a sentinel buffer; check both pads.
    """
    var buffer = List[UInt8](length=size + 3 * pad, fill=SENTINEL)
    var n = decompress_into(block, buffer[pad : pad + size + pad])
    assert_equal(n, size)
    for i in range(pad):
        assert_equal(buffer[i], SENTINEL)
    for i in range(pad + size, len(buffer)):
        assert_equal(buffer[i], SENTINEL)
    return List[UInt8](buffer[pad : pad + size])


def _check_decoders(block: List[UInt8], expected: List[UInt8]) raises:
    assert_equal(uncompressed_length(block), len(expected))
    assert_equal(decompress(block, max_output_bytes=len(expected)), expected)
    assert_equal(_into_padded(block, len(expected), 7), expected)


def _check_rejected(block: List[UInt8], limit: Int = 1 << 20) raises:
    """Both decoders reject; decompress_into never writes past its window."""
    with assert_raises():
        _ = decompress(block, max_output_bytes=limit)
    var buffer = List[UInt8](length=96, fill=SENTINEL)
    try:
        _ = decompress_into(block, buffer[8:72])
        raise Error("decompress_into accepted a rejected block")
    except e:
        if String(e) == "decompress_into accepted a rejected block":
            raise e^
    for i in range(8):
        assert_equal(buffer[i], SENTINEL)
    var size: Int
    try:
        size = uncompressed_length(block)
    except:
        size = 0
    for i in range(8 + min(size, 64), len(buffer)):
        assert_equal(buffer[i], SENTINEL)


def _check_roundtrip(data: List[UInt8]) raises -> List[UInt8]:
    """Compress both ways, check the bound and round trips; return the block."""
    var block = compress(data)
    var bound = max_compressed_length(len(data))
    assert_true(len(block) <= bound)
    # compress_into may write anywhere in its bound, never past it.
    var buffer = List[UInt8](length=bound + 32, fill=SENTINEL)
    var n = compress_into(data, buffer[:bound])
    assert_equal(n, len(block))
    assert_equal(List[UInt8](buffer[:n]), block)
    for i in range(bound, len(buffer)):
        assert_equal(buffer[i], SENTINEL)
    _check_decoders(block, data)
    return block^


# ---------------------------------------------------------------------------
# Encoder
# ---------------------------------------------------------------------------


def test_matches_google_snappy_output() raises:
    # Golden outputs from Google Snappy 1.2.2: an SSE4.2 -march=native build
    # (CRC32C hash) and a generic build (multiplicative hash). The low-entropy
    # and random inputs agree across both; the numeric page does not.
    var sse42 = CompilationTarget.has_sse4()
    var low = _check_roundtrip(_lcg_bytes(200000, 1, 2))
    assert_equal(len(low), 94103)
    assert_equal(_fnv1a(low), UInt64(0x9836CFDA7582D5B6))
    var nibbles = _check_roundtrip(_lcg_bytes(200000, 2, 4))
    assert_equal(len(nibbles), 200015)
    assert_equal(_fnv1a(nibbles), UInt64(0xFF707581AF978670))
    var random = _check_roundtrip(_lcg_bytes(70000, 3, 8))
    assert_equal(len(random), 70009)
    assert_equal(_fnv1a(random), UInt64(0x18A84A122D97DF3C))
    var page = _check_roundtrip(_numeric_page(75000, 4))
    if sse42:
        assert_equal(len(page), 294701)
        assert_equal(_fnv1a(page), UInt64(0xBB33127E123D404F))
    else:
        assert_equal(len(page), 293723)
        assert_equal(_fnv1a(page), UInt64(0xD81D78C5B57A2444))


def test_roundtrip_sizes_and_fragment_boundaries() raises:
    # Around the 15-byte main-loop margin, 16-probe window, hash-table sizes
    # and 64 KiB fragments, for compressible and incompressible content.
    for size in [
        0,
        1,
        3,
        4,
        14,
        15,
        16,
        17,
        31,
        32,
        33,
        40,
        60,
        61,
        255,
        256,
        257,
        4095,
        4096,
        32767,
        32768,
        32769,
        65535,
        65536,
        65537,
        131072,
        200003,
    ]:
        var cyclic = List[UInt8](capacity=size)
        for i in range(size):
            cyclic.append(UInt8(i % 251))
        var block = _check_roundtrip(cyclic)
        if size > 1000:
            assert_true(len(block) < size // 2)
        _ = _check_roundtrip(_lcg_bytes(size, UInt32(size), 8))
        _ = _check_roundtrip(_lcg_bytes(size, UInt32(size + 1), 2))


def test_every_small_size_and_period() raises:
    # Every tail length through the fast-literal and probe windows, with
    # matches ending at the final legal read.
    for size in range(80):
        for period in [1, 2, 3, 4, 7, 8, 16, 17]:
            var data = List[UInt8](capacity=size)
            for i in range(size):
                data.append(UInt8(i % period))
            _ = _check_roundtrip(data)


def test_match_lengths_across_word_boundaries() raises:
    # A repeated seed whose repetition breaks after every length 4..80 and
    # at every offset class, so matches end on each byte of the 8- and
    # 16-byte comparison steps and the copy-splitting thresholds (12, 64, 68).
    for offset in [1, 2, 3, 4, 7, 8, 15, 16, 31, 32, 33, 2047, 2048, 4000]:
        for length in [
            4,
            5,
            7,
            8,
            11,
            12,
            13,
            15,
            16,
            17,
            63,
            64,
            65,
            67,
            68,
            69,
            80,
        ]:
            var data = _lcg_bytes(offset, UInt32(offset * 131 + length), 8)
            for _ in range(length):
                data.append(data[len(data) - offset])
            data.append(data[len(data) - offset] ^ 0x55)
            data.extend(_lcg_bytes(40, UInt32(length), 8))
            _ = _check_roundtrip(data)


def test_recovery_after_incompressible_runs() raises:
    # Heuristic skipping must still find a later repetitive island, and
    # skipped bytes must stay in the pending literal.
    for prefix in [127, 128, 129, 1023, 65535, 65536, 65537, 262144]:
        for tail in range(4):
            var data = _lcg_bytes(prefix, 932847, 8)
            for _ in range(256):
                data.append(42)
            data.extend(_lcg_bytes(tail, 7, 8))
            var block = _check_roundtrip(data)
            assert_true(len(block) < prefix + tail + 100)


def test_compress_into_contract() raises:
    var data = _lcg_bytes(1000, 5, 8)
    var bound = max_compressed_length(len(data))
    var small = List[UInt8](length=bound - 1, fill=SENTINEL)
    with assert_raises():
        _ = compress_into(data, small)
    for i in range(len(small)):
        assert_equal(small[i], SENTINEL)
    # A larger buffer is fine; bytes past the bound stay untouched.
    var large = List[UInt8](length=bound + 100, fill=SENTINEL)
    var n = compress_into(data, large)
    assert_equal(List[UInt8](large[:n]), compress(data))
    for i in range(bound, len(large)):
        assert_equal(large[i], SENTINEL)
    # Sub-span sources and destinations.
    var framed: List[UInt8] = [9, 9, 9]
    framed.extend(data.copy())
    assert_equal(compress(framed[3:]), compress(data))
    var empty = List[UInt8]()
    assert_equal(compress(empty), List[UInt8](length=1, fill=0))
    var one = List[UInt8](length=max_compressed_length(0), fill=SENTINEL)
    assert_equal(compress_into(empty, one), 1)
    assert_equal(one[0], UInt8(0))


def test_max_compressed_length() raises:
    assert_equal(max_compressed_length(0), 32)
    assert_equal(max_compressed_length(6), 39)
    assert_equal(max_compressed_length(0xFFFFFFFF), 5010795209)
    for bad in [-1, 0x100000000]:
        with assert_raises():
            _ = max_compressed_length(bad)


# ---------------------------------------------------------------------------
# Decoder: valid blocks
# ---------------------------------------------------------------------------


def test_copy_forms_and_high_offsets() raises:
    # Literal 'x' then COPY_1, COPY_2, COPY_4, each with offset one.
    for kind in [1, 2, 3]:
        var block: List[UInt8] = [5, 0, 120]
        _append_copy(block, kind, 1, 4)
        _check_decoders(block, List[UInt8](length=5, fill=120))
    # COPY_1's high offset bits: 300 literal bytes, then offset 300 length 4.
    var block: List[UInt8] = [176, 2, 244, 43, 1]
    var expected = List[UInt8]()
    for i in range(300):
        block.append(UInt8(i & 255))
        expected.append(UInt8(i & 255))
    _append_copy(block, 1, 300, 4)
    for i in range(4):
        expected.append(UInt8(i))
    _check_decoders(block, expected)
    # 65536 literal bytes then COPY_4 length four at distance 65536.
    var far: List[UInt8] = [132, 128, 4, 244, 255, 255]
    var far_expected = List[UInt8]()
    for i in range(65536):
        far.append(UInt8(i & 255))
        far_expected.append(UInt8(i & 255))
    _append_copy(far, 3, 65536, 4)
    for i in range(4):
        far_expected.append(UInt8(i))
    _check_decoders(far, far_expected)


def test_copy_placements_fast_and_exact() raises:
    # Each copy form, offset and length placed so it runs in the fast loop
    # (which needs >= 16 decoded bytes, > 65 input and >= 64 output bytes
    # left), in the exact path at the block start or tail, and across the
    # transitions: an optional 16-byte lead-in, then 0..70 trailing output
    # bytes with small or large trailing input.
    for lead in [0, 16]:
        for kind in [1, 2, 3]:
            for offset in [1, 2, 3, 4, 5, 7, 8, 9, 15, 16, 17, 31, 32, 33, 64]:
                for count in range(1, 65):
                    if kind == 1 and (count < 4 or count > 11):
                        continue
                    for trailer in [0, 1, 15, 16, 17, 47, 63, 64, 70]:
                        var expected = _lcg_bytes(lead, UInt32(offset), 8)
                        for i in range(offset):
                            expected.append(UInt8(17 + 3 * i))
                        for _ in range(count):
                            expected.append(expected[len(expected) - offset])
                        var block = List[UInt8]()
                        _append_varint(block, lead + offset + count + trailer)
                        if lead:
                            _append_literal(block, List[UInt8](expected[:lead]))
                        _append_literal(
                            block, List[UInt8](expected[lead : lead + offset])
                        )
                        _append_copy(block, kind, offset, count)
                        if trailer % 2 == 0:
                            for i in range(trailer):
                                block.append(0)
                                block.append(UInt8(200 + i % 50))
                                expected.append(UInt8(200 + i % 50))
                        else:
                            var literal = List[UInt8]()
                            for i in range(trailer):
                                literal.append(UInt8(i))
                            _append_literal(block, literal)
                            expected.extend(literal^)
                        _check_decoders(block, expected)


def _framed(body: List[UInt8], size: Int) -> List[UInt8]:
    var block = List[UInt8]()
    _append_varint(block, size)
    block.extend(body.copy())
    return block^


def test_pattern_phases_and_chains() raises:
    # Unique seed bytes reveal phase errors, including periods not dividing
    # 16. After a 16-byte lead-in, a chain of copies advances the phase
    # repeatedly in the fast loop (kept eligible by a 70-byte literal after
    # it); a second chain at the very end then runs in the exact tail.
    for period in range(1, 16):
        for phase in range(period):
            for count in range(1, 65):
                var expected = _lcg_bytes(16, UInt32(period), 8)
                var body = List[UInt8]()
                _append_literal(body, expected)
                for _ in range(2):
                    var seed = List[UInt8]()
                    for i in range(period):
                        seed.append(UInt8(65 + (phase + i) % period))
                    _append_literal(body, seed)
                    expected.extend(seed^)
                    for _ in range(6):
                        _append_copy(body, 2, period, count)
                    for _ in range(6 * count):
                        expected.append(expected[len(expected) - period])
                    if len(body) < 200:
                        var gap = _lcg_bytes(70, UInt32(count), 8)
                        _append_literal(body, gap)
                        expected.extend(gap^)
                _check_decoders(_framed(body, len(expected)), expected)


def test_literal_length_widths() raises:
    for count in [
        1,
        4,
        15,
        16,
        17,
        59,
        60,
        61,
        255,
        256,
        257,
        65535,
        65536,
        65537,
    ]:
        for width in range(1, 5):
            if (count - 1) >> (8 * width) != 0:
                continue
            var block = List[UInt8]()
            _append_varint(block, count)
            block.append(UInt8((59 + width) << 2))
            var header_size = len(block)
            for i in range(width):
                block.append(UInt8(((count - 1) >> (8 * i)) & 255))
            # Each truncation inside the length bytes rejects before loads.
            for available in range(width):
                _check_rejected(List[UInt8](block[: header_size + available]))
            var expected = List[UInt8]()
            for i in range(count):
                block.append(UInt8(i & 255))
                expected.append(UInt8(i & 255))
            _check_decoders(block, expected)


# ---------------------------------------------------------------------------
# Decoder: malformed blocks and limits
# ---------------------------------------------------------------------------


def test_rejects_truncation_and_trailing_commands() raises:
    var good: List[UInt8] = [5, 0, 120, 14, 1, 0]
    _check_decoders(good, List[UInt8](length=5, fill=120))
    for cut in range(len(good)):
        _check_rejected(List[UInt8](good[:cut]))
    # Every copy form rejects every truncated offset.
    for kind in [1, 2, 3]:
        var width = 1 if kind == 1 else (2 if kind == 2 else 4)
        var tag = 1 if kind == 1 else (12 | kind)
        for count in range(width):
            var block: List[UInt8] = [5, 0, 120, UInt8(tag)]
            for i in range(count):
                block.append(UInt8(1 if i == 0 else 0))
            _check_rejected(block)
    # Declared size smaller or larger than the commands produce.
    for declared in [4, 6]:
        var bad = good.copy()
        bad[0] = UInt8(declared)
        _check_rejected(bad)
    var trailing = good.copy()
    trailing.append(0)
    trailing.append(42)
    _check_rejected(trailing)


def test_rejects_invalid_offsets_and_lengths() raises:
    for offset in [0, 2]:
        var bad: List[UInt8] = [5, 0, 120, 14, UInt8(offset), 0]
        _check_rejected(bad)
    # Four-byte literal lengths must not wrap at the UInt32 boundary.
    for last in [254, 255]:
        _check_rejected([1, 252, UInt8(last), 255, 255, 255, 120])
    _check_rejected([1, 252, 255, 255, 255, 255])
    _check_rejected([0, 0, 42])
    _check_rejected([1])
    # A copy may not reach before the block's own output, even when the
    # destination buffer holds earlier bytes.
    var bad_offset: List[UInt8] = [4, 14, 1, 0]
    var buffer = List[UInt8](length=16, fill=SENTINEL)
    with assert_raises():
        _ = decompress_into(bad_offset, buffer[8:])
    for i in range(8):
        assert_equal(buffer[i], SENTINEL)
    # Invalid offsets deep inside a block, where the fast loop runs: 200
    # literal bytes, valid copies, then a copy reaching before byte zero.
    for kind in [1, 2, 3]:
        var block = List[UInt8]()
        _append_varint(block, 200 + 40 * 8 + 4 + 200)
        _append_literal(block, _lcg_bytes(60, 1, 8))
        _append_literal(block, _lcg_bytes(60, 2, 8))
        _append_literal(block, _lcg_bytes(60, 3, 8))
        _append_literal(block, _lcg_bytes(20, 4, 8))
        for _ in range(40):
            _append_copy(block, 2, 100, 8)
        # Offset 521 exceeds the 520 decoded bytes; COPY_1 can encode it.
        _append_copy(block, kind, 200 + 40 * 8 + 1, 4)
        for _ in range(4):
            _append_literal(block, _lcg_bytes(50, 5, 8))
        _check_rejected(block)


def test_headers_and_output_limits() raises:
    for size in [0, 1, 127, 128, 16383, 16384, 0x0FFFFFFF, 0xFFFFFFFF]:
        var header = List[UInt8]()
        _append_varint(header, size)
        assert_equal(uncompressed_length(header), size)
        for cut in range(len(header)):
            with assert_raises():
                _ = uncompressed_length(List[UInt8](header[:cut]))
        if size:
            # A header alone is not a valid block and allocates nothing.
            _check_rejected(header, 0x100000000)
        header.append(255)
        assert_equal(uncompressed_length(header), size)
    var noncanonical: List[UInt8] = [128, 128, 128, 128, 0]
    assert_equal(uncompressed_length(noncanonical), 0)
    assert_equal(decompress(noncanonical, max_output_bytes=0), List[UInt8]())
    for last in [16, 128, 255]:
        var overflow: List[UInt8] = [255, 255, 255, 255, UInt8(last)]
        with assert_raises():
            _ = uncompressed_length(overflow)
        _check_rejected(overflow, 0x100000000)
    # Sizes the input cannot produce reject before allocation.
    _check_rejected([255, 255, 255, 255, 15], 0x100000000)
    # max_output_bytes and destination length bound the advertised size.
    var block = compress(_lcg_bytes(1000, 3, 2))
    assert_equal(len(decompress(block, max_output_bytes=1000)), 1000)
    for limit in [-1, 0, 999]:
        with assert_raises():
            _ = decompress(block, max_output_bytes=limit)
    var buffer = List[UInt8](length=1100, fill=SENTINEL)
    with assert_raises():
        _ = decompress_into(block, buffer[:999])
    for i in range(len(buffer)):
        assert_equal(buffer[i], SENTINEL)
    var empty = List[UInt8]()
    with assert_raises():
        _ = uncompressed_length(empty)
    with assert_raises():
        _ = decompress(empty, max_output_bytes=10)


def test_decompress_into_reuse() raises:
    # One buffer reused for blocks of varying sizes, including zero; only
    # the decoded prefix changes and storage never moves.
    var buffer = List[UInt8](length=1100, fill=SENTINEL)
    var address = UInt(buffer.unsafe_ptr())
    for n in [0, 1, 64, 1024, 5, 0, 257, 16, 1100]:
        var raw = _lcg_bytes(n, UInt32(n), 3)
        var block = compress(raw)
        var before = buffer.copy()
        assert_equal(decompress_into(block, buffer), n)
        assert_equal(len(buffer), 1100)
        assert_equal(UInt(buffer.unsafe_ptr()), address)
        assert_equal(List[UInt8](buffer[:n]), raw)
        for i in range(n, len(buffer)):
            assert_equal(buffer[i], before[i])
    # A compressed block embedded in a larger stream, decoded into a slice.
    var framed: List[UInt8] = [99, 98]
    var raw = _lcg_bytes(300, 1, 2)
    framed.extend(compress(raw))
    framed.append(97)
    var block_end = len(framed) - 1
    assert_equal(decompress(framed[2:block_end], max_output_bytes=300), raw)
    _check_rejected(List[UInt8](framed[2:]))


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
