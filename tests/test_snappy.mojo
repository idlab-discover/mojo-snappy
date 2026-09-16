"""Raw Snappy format, malformed-stream and bounded encoder tests."""
from std.testing import assert_equal, assert_true, assert_raises, TestSuite
from mojo_snappy import (
    encode_snappy,
    decode_snappy,
    snappy_max_compressed_length,
)
from mojo_snappy.codec import _hash_table_size, _load4


def test_roundtrip_and_compression() raises:
    for n in [0, 1, 3, 4, 59, 60, 61, 255, 256, 257, 65535, 65536, 100000]:
        var data = List[UInt8]()
        for i in range(n):
            data.append(UInt8(i % 251))
        var encoded = encode_snappy(data, n + n // 6 + 32)
        assert_equal(decode_snappy(encoded, n), data)
        var exact = encode_snappy(data, len(encoded))
        assert_equal(exact, encoded)
        with assert_raises():
            _ = encode_snappy(data, len(encoded) - 1)
        if n > 1000:
            assert_true(len(encoded) < n // 2)


def test_copy_forms_and_overlap() raises:
    # Literal 'x' then COPY_1, COPY_2, COPY_4, each with offset one.
    for tag in [1, 14, 15]:
        var encoded: List[UInt8] = [5, 0, 120]
        encoded.append(UInt8(tag))
        encoded.append(1)
        if tag != 1:
            encoded.append(0)
        if tag == 15:
            encoded.append(0)
            encoded.append(0)
        assert_equal(decode_snappy(encoded, 5), List[UInt8](length=5, fill=120))
    # COPY_1's high offset bits: 300 literal bytes, then offset 300 length 4.
    var block: List[UInt8] = [176, 2, 244, 43, 1]
    for i in range(300):
        block.append(UInt8(i & 255))
    block.append(33)
    block.append(44)
    var decoded = decode_snappy(block, 304)
    for i in range(304):
        assert_equal(decoded[i], UInt8((i % 300) & 255))


def test_extended_literals_and_long_copy_offset() raises:
    # Extended literal lengths are legal in each of the four widths.
    for width in range(1, 5):
        var block: List[UInt8] = [1, UInt8((59 + width) << 2), 0]
        for _ in range(width - 1):
            block.append(0)
        block.append(42)
        var expected: List[UInt8] = [42]
        assert_equal(decode_snappy(block, 1), expected)
    # 65536 literal bytes then COPY_4 length four at distance 65536.
    var block: List[UInt8] = [132, 128, 4, 244, 255, 255]
    for i in range(65536):
        block.append(UInt8(i & 255))
    block.append(15)
    block.append(0)
    block.append(0)
    block.append(1)
    block.append(0)
    var decoded = decode_snappy(block, 65540)
    for i in range(65540):
        assert_equal(decoded[i], UInt8(i & 255))


def test_malformed_and_truncation() raises:
    var good: List[UInt8] = [5, 0, 120, 14, 1, 0]
    for n in range(len(good)):
        var prefix = List[UInt8]()
        for i in range(n):
            prefix.append(good[i])
        with assert_raises():
            _ = decode_snappy(prefix, 5)
    with assert_raises():
        _ = decode_snappy(good, 4)
    good.append(0)
    good.append(1)
    with assert_raises():
        _ = decode_snappy(good, 5)
    var zero_offset: List[UInt8] = [5, 0, 120, 14, 0, 0]
    with assert_raises():
        _ = decode_snappy(zero_offset, 5)
    var past_start: List[UInt8] = [5, 0, 120, 14, 2, 0]
    with assert_raises():
        _ = decode_snappy(past_start, 5)
    var overflow: List[UInt8] = [255, 255, 255, 255, 16]
    with assert_raises():
        _ = decode_snappy(overflow, 0)
    var unterminated: List[UInt8] = [128, 128, 128, 128, 128]
    with assert_raises():
        _ = decode_snappy(unterminated, 0)
    var oversized_literal: List[UInt8] = [1, 252, 255, 255, 255, 255]
    with assert_raises():
        _ = decode_snappy(oversized_literal, 1)
    with assert_raises():
        _ = decode_snappy(good, -1)
    with assert_raises():
        _ = encode_snappy(good, -1)


def test_suffix_and_source_bounds() raises:
    var data: List[UInt8] = [90, 91, 1, 2, 3, 1, 2, 3, 1, 2, 3]
    var wanted: List[UInt8] = [1, 2, 3, 1, 2, 3, 1, 2, 3]
    var encoded = encode_snappy(data, 100, 2)
    var prefixed: List[UInt8] = [90, 91]
    for byte in encoded:
        prefixed.append(byte)
    assert_equal(decode_snappy(prefixed, 9, 2), wanted)
    assert_equal(
        decode_snappy(encode_snappy(data, 1, len(data)), 0), List[UInt8]()
    )
    for start in [-1, len(data) + 1]:
        with assert_raises():
            _ = encode_snappy(data, 100, start)
        with assert_raises():
            _ = decode_snappy(data, 0, start)


def test_compressed_length_bound() raises:
    assert_equal(snappy_max_compressed_length(0), 32)
    assert_equal(snappy_max_compressed_length(0xFFFFFFFF), 5010795209)
    with assert_raises():
        _ = snappy_max_compressed_length(-1)
    with assert_raises():
        _ = snappy_max_compressed_length(0x100000000)


def test_validation_without_compiler_assertions() raises:
    # These must raise explicit codec errors even under ASSERT=none.
    var empty: List[UInt8] = [0]
    with assert_raises():
        _ = decode_snappy(empty, 0x100000000)
    # A maximum advertised size must not allocate output before validation.
    var huge: List[UInt8] = [255, 255, 255, 255, 15]
    with assert_raises():
        _ = decode_snappy(huge, 0xFFFFFFFF)
    # Each copy form must reject every truncated offset, including COPY_4.
    for kind in [1, 2, 3]:
        var width = 1 if kind == 1 else (2 if kind == 2 else 4)
        var tag = 1 if kind == 1 else (12 | kind)
        for count in range(width):
            var block: List[UInt8] = [5, 0, 120, UInt8(tag)]
            for i in range(count):
                block.append(UInt8(1 if i == 0 else 0))
            with assert_raises():
                _ = decode_snappy(block, 5)
    # Four-byte literal lengths must not wrap at the UInt32 boundary.
    for last in [254, 255]:
        var block: List[UInt8] = [1, 252, UInt8(last), 255, 255, 255, 120]
        with assert_raises():
            _ = decode_snappy(block, 1)


def test_hash_state_bounds_and_word_byte_order() raises:
    assert_equal(_hash_table_size(0), 256)
    for boundary in [256, 512, 1024, 2048, 4096, 8192, 16384]:
        assert_equal(_hash_table_size(boundary - 1), boundary)
        assert_equal(_hash_table_size(boundary), boundary)
        assert_equal(_hash_table_size(boundary + 1), min(2 * boundary, 16384))
    # Exercise arithmetic at the format limit without allocating that input.
    assert_equal(_hash_table_size(0xFFFFFFFF), 16384)
    for start in range(8):
        var data = List[UInt8](length=start, fill=0)
        data.append(0x01)
        data.append(0x23)
        data.append(0x45)
        data.append(0xFE)
        assert_equal(_load4(data, start), UInt32(0xFE452301))


def test_encoder_word_tails_and_suffix_alignment() raises:
    # Every alignment, four-byte boundary and SIMD tail; the last four bytes
    # repeat an earlier word and can be a match at the final legal read.
    for start in range(8):
        for size in range(40):
            var data = List[UInt8](length=start, fill=255)
            var expected = List[UInt8]()
            for i in range(size):
                var byte = UInt8(i % 7)
                expected.append(byte)
                data.append(byte)
            var encoded = encode_snappy(
                data, snappy_max_compressed_length(size), start
            )
            assert_equal(decode_snappy(encoded, size), expected)
            assert_equal(encode_snappy(data, len(encoded), start), encoded)
            with assert_raises():
                _ = encode_snappy(data, len(encoded) - 1, start)


def test_encoder_table_transitions_and_collisions() raises:
    for boundary in [16, 32, 64, 128, 256, 512, 1024, 2048, 4096, 8192, 16384]:
        for delta in [-1, 0, 1]:
            var size = boundary + delta
            var expected = List[UInt8]()
            var state = UInt32(932847)
            # Repeated and distinct words share a bounded table. A hash hit
            # alone must never emit a copy without comparing all four bytes.
            for i in range(size):
                state = state * UInt32(1664525) + UInt32(1013904223)
                expected.append(UInt8((state >> 24) & 15))
            for i in range(4):
                expected[size - 4 + i] = expected[i]
            var data: List[UInt8] = [99, 98, 97]
            data.extend(expected.copy())
            var encoded = encode_snappy(
                data, snappy_max_compressed_length(size), 3
            )
            assert_equal(decode_snappy(encoded, size), expected)
            assert_equal(encode_snappy(data, len(encoded), 3), encoded)
            with assert_raises():
                _ = encode_snappy(data, len(encoded) - 1, 3)


def test_adaptive_search_recovery_and_literal_tails() raises:
    # Long random runs must not prevent recovery when repetition resumes.
    # Include stride transitions, suffix-relative 64K boundaries and every
    # final literal tail. Compression checks allow changed match choices.
    for prefix in [127, 128, 129, 1023, 65535, 65536, 65537, 262144]:
        for tail in range(4):
            var expected = List[UInt8]()
            var state = UInt32(932847)
            for _ in range(prefix):
                state = state * UInt32(1664525) + UInt32(1013904223)
                expected.append(UInt8(state >> 24))
            for _ in range(256):
                expected.append(42)
            # Keep even the early transition cases on the adaptive large path.
            var padding = max(0, 16384 - prefix - 256 - tail)
            for _ in range(padding):
                state = state * UInt32(1664525) + UInt32(1013904223)
                expected.append(UInt8(state >> 24))
            for i in range(tail):
                expected.append(UInt8(200 + i))
            var data: List[UInt8] = [90, 91, 92]
            data.extend(expected.copy())
            var encoded = encode_snappy(
                data, snappy_max_compressed_length(len(expected)), 3
            )
            assert_equal(decode_snappy(encoded, len(expected)), expected)
            # Two probes at most 16 bytes apart recover the constant island;
            # leave room for literal headers, copy tags and the final tail.
            assert_true(len(encoded) < prefix + padding + 80)
            assert_equal(encode_snappy(data, len(encoded), 3), encoded)
            with assert_raises():
                _ = encode_snappy(data, len(encoded) - 1, 3)


def test_adaptive_search_long_runs_and_short_islands() raises:
    var expected = List[UInt8]()
    var state = UInt32(932847)
    # Repeatedly exercise the saturated counter and islands shorter than its
    # stride. Missing a match is allowed; losing any skipped input byte is not.
    for band in range(64):
        for _ in range(65536 + band % 4):
            state = state * UInt32(1664525) + UInt32(1013904223)
            expected.append(UInt8(state >> 24))
        for _ in range(8):
            expected.append(42)
    for i in range(256):
        expected.append(UInt8(i % 7))
    var encoded = encode_snappy(
        expected, snappy_max_compressed_length(len(expected))
    )
    assert_equal(decode_snappy(encoded, len(expected)), expected)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
