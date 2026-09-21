"""Raw Snappy format, malformed-stream and bounded encoder tests."""
from std.testing import assert_equal, assert_true, assert_raises, TestSuite
from mojo_snappy import (
    compress,
    decompress,
    uncompressed_length,
    encode_snappy,
    decode_snappy,
    decode_snappy_into,
    snappy_max_compressed_length,
)
from mojo_snappy.codec import _hash_table_size, _load4, _copy, _match_length


def _assert_into_matches(data: List[UInt8], expected: List[UInt8]) raises:
    var destination = List[UInt8](length=len(expected) + 10, fill=179)
    assert_equal(
        decode_snappy_into(data, destination, len(expected), 0, 5),
        len(expected),
    )
    for i in range(len(expected)):
        assert_equal(destination[5 + i], expected[i])
    for i in range(5):
        assert_equal(destination[i], UInt8(179))
        assert_equal(destination[5 + len(expected) + i], UInt8(179))


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
    _assert_into_matches(block, decoded)
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
        _assert_into_matches(block, expected)
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
    _assert_into_matches(block, decoded)
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


def _append_varint(mut block: List[UInt8], var value: Int):
    while value >= 128:
        block.append(UInt8((value & 127) | 128))
        value >>= 7
    block.append(UInt8(value))


def test_decoder_copy_widths_and_tails() raises:
    # Every length, all forms, growing overlap and non-overlap at both widths.
    for kind in [1, 2, 3]:
        for offset in [
            1,
            2,
            3,
            4,
            5,
            6,
            7,
            8,
            9,
            10,
            11,
            12,
            13,
            14,
            15,
            16,
            17,
            31,
            32,
            33,
        ]:
            for count in range(1, 65):
                if kind == 1 and (count < 4 or count > 11):
                    continue
                var block: List[UInt8] = [99, 98, 97]
                _append_varint(block, offset + count)
                block.append(UInt8((offset - 1) << 2))
                var expected = List[UInt8]()
                for i in range(offset):
                    block.append(UInt8(i))
                    expected.append(UInt8(i))
                var tag = ((count - 1) << 2) | kind
                if kind == 1:
                    tag = ((count - 4) << 2) | 1
                block.append(UInt8(tag))
                var width = 1 if kind == 1 else (2 if kind == 2 else 4)
                for i in range(width):
                    block.append(UInt8((offset >> (8 * i)) & 255))
                for i in range(count):
                    expected.append(UInt8(i % offset))
                assert_equal(decode_snappy(block, len(expected), 3), expected)
                var destination = List[UInt8](
                    length=len(expected) + 10, fill=179
                )
                assert_equal(
                    decode_snappy_into(block, destination, len(expected), 3, 5),
                    len(expected),
                )
                for i in range(len(expected)):
                    assert_equal(destination[5 + i], expected[i])
                for i in range(5):
                    assert_equal(destination[i], UInt8(179))
                    assert_equal(destination[5 + len(expected) + i], UInt8(179))
                # Keep the declared size correct but exceed it with the copy.
                var short = block.copy()
                short[3] -= 1
                with assert_raises():
                    _ = decode_snappy(short, len(expected) - 1, 3)
                with assert_raises():
                    _ = decode_snappy_into(
                        short, destination, len(expected) - 1, 3, 5
                    )
                # Each prefix that cuts a tag/offset must fail explicitly.
                for cut in range(width + 1):
                    var truncated = block[: len(block) - cut - 1]
                    with assert_raises():
                        _ = decode_snappy(
                            List[UInt8](truncated), len(expected), 3
                        )
                    with assert_raises():
                        _ = decode_snappy_into(
                            List[UInt8](truncated),
                            destination,
                            len(expected),
                            3,
                            5,
                        )
                    for i in range(5):
                        assert_equal(destination[i], UInt8(179))
                        assert_equal(
                            destination[5 + len(expected) + i], UInt8(179)
                        )


def test_four_byte_copy_chains_and_late_failure() raises:
    # Repeated exact copies cross allocation boundaries and must only read the
    # decoded prefix, even with caller storage filled with unrelated bytes.
    for kind in [1, 2, 3]:
        for offset in [1, 2, 3, 4, 5, 15, 16]:
            var size = offset + 4 * 17
            var block: List[UInt8] = [231, 232]
            _append_varint(block, size)
            block.append(UInt8((offset - 1) << 2))
            var expected = List[UInt8]()
            for i in range(offset):
                block.append(UInt8(65 + i))
                expected.append(UInt8(65 + i))
            for _ in range(17):
                block.append(UInt8(1 if kind == 1 else 12 | kind))
                block.append(UInt8(offset))
                for _ in range(0 if kind == 1 else (1 if kind == 2 else 3)):
                    block.append(0)
                for _ in range(4):
                    expected.append(expected[len(expected) - offset])
            assert_equal(decode_snappy(block, size, 2), expected)
            var destination = List[UInt8](length=size + 8, fill=179)
            assert_equal(
                decode_snappy_into(block, destination, size, 2, 3), size
            )
            for i in range(size):
                assert_equal(destination[3 + i], expected[i])
            var before = destination.copy()
            # A full copy after the advertised end must fail before any store.
            block.append(1)
            block.append(1)
            with assert_raises():
                _ = decode_snappy_into(block, destination, size, 2, 3)
            assert_equal(destination, before)
            with assert_raises():
                _ = decode_snappy(block, size, 2)
            for i in range(3):
                assert_equal(destination[i], UInt8(179))
            for i in range(3 + size, len(destination)):
                assert_equal(destination[i], UInt8(179))


def test_decoder_copy_capacity_transitions() raises:
    # Exercise exact reserved boundaries independently of List growth policy.
    for offset in [
        1,
        2,
        3,
        4,
        5,
        6,
        7,
        8,
        9,
        10,
        11,
        12,
        13,
        14,
        15,
        16,
        17,
        31,
        32,
        33,
    ]:
        for count in range(1, 65):
            for spare in [0, count - 1, count, count + 1]:
                var output = List[UInt8](capacity=offset + spare)
                assert_equal(output.capacity(), offset + spare)
                for i in range(offset):
                    output.append(UInt8(i))
                _copy(output, offset, count)
                assert_equal(len(output), offset + count)
                for i in range(len(output)):
                    assert_equal(output[i], UInt8(i % offset))


def test_decoder_literal_width_boundaries() raises:
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
            # Width checks must precede loads, including zero-byte availability.
            for available in range(width):
                var truncated = List[UInt8](block[: header_size + available])
                with assert_raises():
                    _ = decode_snappy(truncated, count)
            for i in range(count):
                block.append(UInt8(i & 255))
            var decoded = decode_snappy(block, count)
            for i in range(count):
                assert_equal(decoded[i], UInt8(i & 255))


def test_encoder_word_match_boundaries() raises:
    # The first four bytes have already matched. Cover every remaining byte
    # around word/vector boundaries, with exact-size storage and overlap.
    for alignment in range(16):
        for offset in [1, 2, 3, 4, 7, 8, 15, 16, 31, 32, 33]:
            var pos = alignment + offset
            for available in range(41):
                for mismatch in range(available + 1):
                    var data = List[UInt8](length=pos + 4 + available, fill=0)
                    if mismatch < available:
                        data[pos + 4 + mismatch] = 128
                    assert_equal(
                        _match_length(data, alignment, pos), 4 + mismatch
                    )


def test_encoder_word_suffix_limits() raises:
    for alignment in range(16):
        for length in [4, 7, 8, 11, 12, 15, 16, 19, 20, 31, 32, 33, 64, 65]:
            var data = List[UInt8](length=alignment, fill=255)
            for i in range(length):
                data.append(UInt8(i % 7))
            var expected = List[UInt8](data[alignment:])
            var encoded = encode_snappy(
                data, snappy_max_compressed_length(length), alignment
            )
            assert_equal(decode_snappy(encoded, length), expected)
            assert_equal(encode_snappy(data, len(encoded), alignment), encoded)
            with assert_raises():
                _ = encode_snappy(data, len(encoded) - 1, alignment)


def test_decoder_pattern_phases_and_capacity() raises:
    # Unique seed bytes reveal phase errors, including periods not dividing 16.
    # Exact capacities expose command tails and genuine reallocating growth.
    for period in range(2, 16):
        for phase in range(period):
            for padding in [0, 15, 16, 17]:
                var prefix = padding + period
                for count in range(1, 65):
                    for spare in [0, count - 1, count, count + 1]:
                        var output = List[UInt8](capacity=prefix + spare)
                        assert_equal(output.capacity(), prefix + spare)
                        for _ in range(padding):
                            output.append(201)
                        for i in range(period):
                            output.append(UInt8(65 + (phase + i) % period))
                        var old_capacity = output.capacity()
                        _copy(output, period, count)
                        assert_equal(len(output), prefix + count)
                        assert_true(output.capacity() >= prefix + count)
                        if spare < count:
                            assert_true(output.capacity() > old_capacity)
                        else:
                            assert_equal(output.capacity(), old_capacity)
                        for i in range(padding):
                            assert_equal(output[i], UInt8(201))
                        for i in range(period + count):
                            assert_equal(
                                output[padding + i],
                                UInt8(65 + (phase + i) % period),
                            )


def test_decoder_encoder_produced_patterns() raises:
    for period in [1, 2, 3, 4, 5, 7, 8, 15, 16, 17]:
        for phase in range(period):
            for count in [
                1,
                period - 1,
                period,
                period + 1,
                15,
                16,
                17,
                63,
                64,
                65,
                257,
            ]:
                var expected = List[UInt8]()
                for i in range(count):
                    expected.append(UInt8(65 + (phase + i) % period))
                var encoded = encode_snappy(
                    expected, snappy_max_compressed_length(count)
                )
                assert_equal(decode_snappy(encoded, count), expected)


def test_into_reuse_and_boundaries() raises:
    var dst = List[UInt8](length=1100, fill=177)
    var address = UInt(dst.unsafe_ptr())
    for n in [0, 1, 64, 1024, 5, 0, 257, 16]:
        var raw = List[UInt8]()
        for i in range(n):
            raw.append(UInt8(i % 7))
        var block = encode_snappy(raw, 2000)
        var framed: List[UInt8] = [99, 98]
        framed.extend(block[:])
        var before = dst.copy()
        assert_equal(decode_snappy_into(framed, dst, n, 2, 5), n)
        assert_equal(len(dst), 1100)
        assert_equal(UInt(dst.unsafe_ptr()), address)
        for i in range(5):
            assert_equal(dst[i], before[i])
        for i in range(n):
            assert_equal(dst[5 + i], raw[i])
        for i in range(5 + n, len(dst)):
            assert_equal(dst[i], before[i])
        if n:
            with assert_raises():
                _ = decode_snappy_into(block, dst, n, 0, len(dst) - n + 1)


def test_into_failure_contract() raises:
    var good: List[UInt8] = [5, 0, 120, 14, 1, 0]
    var dst = List[UInt8](length=20, fill=77)
    var bad: List[UInt8] = [5, 0, 120, 14, 0, 0]
    with assert_raises():
        _ = decode_snappy_into(bad, dst, 5, 0, 3)
    assert_equal(dst[3], UInt8(120))
    for i in range(len(dst)):
        if i != 3:
            assert_equal(dst[i], UInt8(77))
    # Existing prefix must not legitimize a backreference before decoded byte 0.
    var bad_offset: List[UInt8] = [4, 14, 1, 0]
    var before = dst.copy()
    with assert_raises():
        _ = decode_snappy_into(bad_offset, dst, 4, 0, 8)
    assert_equal(dst, before)
    for size in [-1, 4, 6, 0x100000000]:
        with assert_raises():
            _ = decode_snappy_into(good, dst, size)
        assert_equal(dst, before)
    for start in [-1, len(good) + 1]:
        with assert_raises():
            _ = decode_snappy_into(good, dst, 5, start)
        assert_equal(dst, before)
    for start in [-1, len(dst) + 1, 0x7FFFFFFFFFFFFFFF]:
        with assert_raises():
            _ = decode_snappy_into(good, dst, 5, 0, start)
        assert_equal(dst, before)
    var reserved = List[UInt8](capacity=100)
    with assert_raises():
        _ = decode_snappy_into(good, reserved, 5)
    var zero: List[UInt8] = [0]
    assert_equal(decode_snappy_into(zero, dst, 0, 0, len(dst)), 0)
    assert_equal(decode_snappy_into(zero, reserved, 0), 0)
    assert_equal(dst, before)
    var missing = List[UInt8]()
    with assert_raises():
        _ = decode_snappy_into(missing, dst, 0)


def _assert_into_rejects(data: List[UInt8], expected_size: Int) raises:
    var destination = List[UInt8](length=expected_size + 10, fill=179)
    with assert_raises():
        _ = decode_snappy_into(data, destination, expected_size, 0, 5)
    for i in range(5):
        assert_equal(destination[i], UInt8(179))
        assert_equal(destination[5 + expected_size + i], UInt8(179))


def test_into_headers_literals_and_trailing_commands() raises:
    _assert_into_rejects([255, 255, 255, 255, 16], 0)
    _assert_into_rejects([128, 128, 128, 128, 128], 0)
    _assert_into_rejects([1, 252, 255, 255, 255, 255], 1)
    _assert_into_rejects([0, 0, 42], 0)
    _assert_into_rejects([1], 1)
    for width in range(1, 5):
        var block: List[UInt8] = [1, UInt8((59 + width) << 2)]
        for _ in range(width):
            block.append(0)
        block.append(42)
        var destination = List[UInt8](length=3, fill=179)
        assert_equal(decode_snappy_into(block, destination, 1, 0, 1), 1)
        var expected: List[UInt8] = [179, 42, 179]
        assert_equal(destination, expected)
        for cut in range(len(block)):
            _assert_into_rejects(List[UInt8](block[:cut]), 1)


def test_convenience_roundtrips_and_budgets() raises:
    for start in range(4):
        for size in [0, 1, 3, 4, 60, 128, 256, 16384, 65536]:
            var data = List[UInt8](length=start, fill=179)
            for i in range(size):
                data.append(UInt8(i % 251))
            var packed = compress(data, start=start)
            assert_equal(
                packed,
                encode_snappy(data, snappy_max_compressed_length(size), start),
            )
            assert_equal(
                compress(data, max_output_bytes=len(packed), start=start),
                packed,
            )
            with assert_raises():
                _ = compress(
                    data, max_output_bytes=len(packed) - 1, start=start
                )
            var framed: List[UInt8] = [99, 98, 97]
            framed.extend(packed[:])
            assert_equal(uncompressed_length(framed, 3), size)
            var expected = List[UInt8](data[start:])
            assert_equal(
                decompress(framed, max_output_bytes=size, start=3), expected
            )
            assert_equal(
                decompress(framed, max_output_bytes=size + 10, start=3),
                expected,
            )
            if size:
                with assert_raises():
                    _ = decompress(framed, max_output_bytes=size - 1, start=3)
    var empty = List[UInt8]()
    with assert_raises():
        _ = compress(empty, max_output_bytes=0)
    with assert_raises():
        _ = compress(empty, max_output_bytes=-1)
    var zero: List[UInt8] = [0]
    with assert_raises():
        _ = decompress(zero, max_output_bytes=-1)
    for start in [-1, 2]:
        with assert_raises():
            _ = compress(zero, start=start)
        with assert_raises():
            _ = decompress(zero, max_output_bytes=1, start=start)
        with assert_raises():
            _ = uncompressed_length(zero, start)


def test_uncompressed_length_header_only() raises:
    for size in [0, 1, 127, 128, 16383, 16384, 0x0FFFFFFF, 0xFFFFFFFF]:
        var header = List[UInt8]()
        _append_varint(header, size)
        assert_equal(uncompressed_length(header), size)
        for cut in range(len(header)):
            with assert_raises():
                _ = uncompressed_length(List[UInt8](header[:cut]))
        if size:
            # A valid header does not validate the block or allocate its size.
            with assert_raises():
                _ = decompress(header, max_output_bytes=0x100000000)
        header.append(255)
        assert_equal(uncompressed_length(header), size)
    var noncanonical: List[UInt8] = [128, 128, 128, 128, 0]
    assert_equal(uncompressed_length(noncanonical), 0)
    assert_equal(decompress(noncanonical, max_output_bytes=0), List[UInt8]())
    for last in [16, 128, 255]:
        var overflow: List[UInt8] = [255, 255, 255, 255, UInt8(last)]
        with assert_raises():
            _ = uncompressed_length(overflow)
        with assert_raises():
            _ = decompress(overflow, max_output_bytes=0x100000000)


def test_decompress_validates_entire_block() raises:
    var good: List[UInt8] = [5, 0, 120, 14, 1, 0]
    for cut in range(len(good)):
        with assert_raises():
            _ = decompress(List[UInt8](good[:cut]), max_output_bytes=100)
    for offset in [0, 2]:
        var bad = good.copy()
        bad[4] = UInt8(offset)
        with assert_raises():
            _ = decompress(bad, max_output_bytes=100)
    for declared in [4, 6]:
        var bad = good.copy()
        bad[0] = UInt8(declared)
        with assert_raises():
            _ = decompress(bad, max_output_bytes=100)
    good.append(0)
    good.append(42)
    with assert_raises():
        _ = decompress(good, max_output_bytes=100)
    var literal_overflow: List[UInt8] = [1, 252, 255, 255, 255, 255]
    with assert_raises():
        _ = decompress(literal_overflow, max_output_bytes=100)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
