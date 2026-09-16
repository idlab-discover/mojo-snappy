"""Raw Snappy format, malformed-stream and bounded encoder tests."""
from std.testing import assert_equal, assert_true, assert_raises, TestSuite
from mojo_snappy import (
    encode_snappy,
    decode_snappy,
    snappy_max_compressed_length,
)


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


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
