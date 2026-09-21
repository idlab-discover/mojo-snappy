"""Native raw Snappy blocks with caller-bounded output and bounded match state.

The encoder uses a greedy, single-candidate hash table of at most 16K entries
and a 64K lookback.
The decoder accepts all three copy forms, including overlapping backreferences.
No framing, Python, or external codec library is involved.
"""


from std.bit import byte_swap, count_trailing_zeros
from std.memory import unsafe_memcpy
from std.sys.info import is_big_endian


@always_inline
def _read_le[count: Int](data: List[UInt8], mut cursor: Int) raises -> Int:
    """Read 1..4 bytes with one shared truncation check before fixed accesses.

    Internal callers maintain 0 <= cursor <= len(data); no padding is read.
    """
    comptime assert 1 <= count <= 4
    if count > len(data) - cursor:
        raise Error("Truncated Snappy block")
    var value = UInt64(0)
    comptime for i in range(count):
        value |= UInt64(data[cursor + i]) << UInt64(8 * i)
    cursor += count
    return Int(value)


@always_inline
def _pattern_copy[period: Int](mut result: List[UInt8], var count: Int):
    """Expand an initialized period into exact, phase-correct vector appends.

    Caller proves 2 <= period < 16, period <= len(result), 16 <= count <= 64,
    and len(result) + count <= expected_size. Only the last period bytes are
    read; every seed lane is initialized before pattern construction. After
    writing 16 bytes, lane i must represent old lane (i + 16) % period.
    Each extend writes at most the remaining count and updates initialized
    length. No pointer survives growth, and no spare capacity is read.
    Pattern rotation follows Google Snappy's short-pattern extension idea;
    see THIRD_PARTY_NOTICES.md. Unlike its slack copies, writes are exact.
    """
    comptime assert 2 <= period < 16
    var end = len(result) + count
    if end > result.capacity():
        result.reserve(max(end, 2 * result.capacity()))
    comptime if period == 4:
        var seed4 = (
            result.unsafe_ptr()
            .unsafe_offset(len(result) - 4)
            .unsafe_load[width=4]()
        )
        var eight = seed4.join(seed4)
        var sixteen = eight.join(eight)
        var wide = sixteen.join(sixteen)
        if count == 64:
            result.extend(wide.join(wide))
        else:
            result.extend(wide.join(wide), count=count)
        return
    var seed = SIMD[DType.uint8, 16](0)
    comptime for i in range(period):
        seed[i] = result[len(result) - period + i]
    var pattern = SIMD[DType.uint8, 16](0)
    comptime for i in range(16):
        pattern[i] = seed[i % period]
    while count >= 16:
        result.extend(pattern)
        var next_pattern = SIMD[DType.uint8, 16](0)
        comptime for i in range(16):
            next_pattern[i] = pattern[(i + 16) % period]
        pattern = next_pattern
        count -= 16
    if count:
        result.extend(pattern, count=count)


@no_inline
def _expand_pattern(mut result: List[UInt8], offset: Int, count: Int):
    """Dispatch a validated offset 2..15 and count 16..64.

    Keep uncommon period construction outside the ordinary copy loop.
    """
    comptime for period in range(2, 16):
        if offset == period:
            _pattern_copy[period](result, count)
            return


@always_inline
def _copy(mut result: List[UInt8], offset: Int, var count: Int):
    """Append a validated backreference, including bytes produced by this copy.

    Caller proves 0 < offset <= len(result), 1 <= count <= 64, and
    len(result) + count <= expected_size. Reserve only this validated command.
    A direct width-W load requires offset >= W and count >= W: it ends at
    or before the current initialized length. Each extend initializes the next
    W bytes before a later load can reference them. Only SIMD values, never
    pointers, survive an extend; all writes fit the reserved end. Short periods
    instead construct initialized vectors from an exact seed. Offset four
    repeats one four-byte seed to 64 bytes in registers: 64 % 4 == 0, and the
    bounded partial extend writes only count bytes. No enlarged logical length
    or uninitialized storage is exposed on either normal or error exits.
    """
    if count >= 16 and offset == 1:
        var end = len(result) + count
        if end > result.capacity():
            result.reserve(max(end, 2 * result.capacity()))
        var byte = result[len(result) - 1]
        result.resize(end, fill=byte)
        return
    if count >= 4 and offset >= 4:
        var end = len(result) + count
        if end > result.capacity():
            result.reserve(max(end, 2 * result.capacity()))
        # Keep the long-copy path, then handle short copies and vector tails.
        if offset >= 16:
            while count >= 16:
                var bytes = (
                    result.unsafe_ptr()
                    .unsafe_offset(len(result) - offset)
                    .unsafe_load[width=16]()
                )
                result.extend(bytes)
                count -= 16
        elif count >= 16:
            _expand_pattern(result, offset, count)
            return
        while count >= 4:
            var bytes = (
                result.unsafe_ptr()
                .unsafe_offset(len(result) - offset)
                .unsafe_load[width=4]()
            )
            result.extend(bytes)
            count -= 4
    if count >= 16:
        # Only offsets two and three remain after the paths above.
        _expand_pattern(result, offset, count)
        return
    # Short offsets 1..3 and final tails use forward byte copies; every source
    # byte is initialized before append makes it available to later iterations.
    for _ in range(count):
        var byte = result[len(result) - offset]
        result.append(byte)


def decode_snappy(
    data: List[UInt8], expected_size: Int, start: Int = 0
) raises -> List[UInt8]:
    """Decode a block only if its declared and actual sizes equal expected_size.
    """
    if expected_size < 0 or UInt64(expected_size) > UInt64(0xFFFFFFFF):
        raise Error("Invalid Snappy expected size")
    if start < 0 or start > len(data):
        raise Error("Invalid Snappy source start")
    var cursor = start
    var declared = UInt64(0)
    var terminated = False
    for i in range(5):
        var byte = _read_le[1](data, cursor)
        if i == 4 and byte > 15:
            raise Error("Snappy length overflow")
        declared |= UInt64(byte & 127) << UInt64(7 * i)
        if byte < 128:
            terminated = True
            break
    if not terminated or declared != UInt64(expected_size):
        raise Error("Snappy declared length mismatch")
    var result = List[UInt8]()
    # Grow only from validated commands; a malicious preamble cannot itself
    # trigger a huge allocation. Each append is bounded by expected_size.
    while cursor < len(data):
        var tag = _read_le[1](data, cursor)
        var kind = tag & 3
        var count = (tag >> 2) + 1
        if kind == 0:
            if count > 60:
                if count == 61:
                    count = _read_le[1](data, cursor) + 1
                elif count == 62:
                    count = _read_le[2](data, cursor) + 1
                elif count == 63:
                    count = _read_le[3](data, cursor) + 1
                else:
                    count = _read_le[4](data, cursor) + 1
            if count > len(data) - cursor or count > expected_size - len(
                result
            ):
                raise Error("Snappy literal exceeds input or output")
            result.extend(data[cursor : cursor + count])
            cursor += count
        else:
            var offset: Int
            if kind == 1:
                count = 4 + ((tag >> 2) & 7)
                offset = ((tag & 224) << 3) | _read_le[1](data, cursor)
            else:
                offset = _read_le[2](data, cursor) if kind == 2 else _read_le[
                    4
                ](data, cursor)
            if offset <= 0 or offset > len(result):
                raise Error("Invalid Snappy copy offset")
            if count > expected_size - len(result):
                raise Error("Snappy copy exceeds output")
            _copy(result, offset, count)
    if len(result) != expected_size:
        raise Error("Snappy decoded length mismatch")
    return result^


def _put(mut output: List[UInt8], value: Int, limit: Int) raises:
    if len(output) >= limit:
        raise Error("Snappy encoded output exceeds limit")
    output.append(UInt8(value & 255))


def _literal(
    data: List[UInt8],
    start: Int,
    count: Int,
    mut output: List[UInt8],
    limit: Int,
) raises:
    if count == 0:
        return
    var value = count - 1
    if count <= 60:
        _put(output, value << 2, limit)
    else:
        var bytes = 1
        while (value >> (8 * bytes)) != 0:
            bytes += 1
        _put(output, (59 + bytes) << 2, limit)
        for i in range(bytes):
            _put(output, value >> (8 * i), limit)
    if count > limit - len(output):
        raise Error("Snappy encoded output exceeds limit")
    output.extend(data[start : start + count])


def _hash_table_size(size: Int) -> Int:
    """Power-of-two entry count for a validated suffix size, clamped to 256..16K.

    Bound before doubling so even a UInt32-maximum suffix needs no large
    intermediate calculation. Entries remain Int absolute positions: a legal
    suffix can start beyond 4 GiB in its source list.
    """
    var count = 256
    while count < min(size, 16384):
        count *= 2
    return count


def _load4(data: List[UInt8], pos: Int) -> UInt32:
    """Load four bytes after the caller proves 0 <= pos <= len(data) - 4.

    The borrowed input stays alive and cannot grow during encoding. The pointer
    is used only for this load; byte alignment is sufficient. Normalize the
    word to little endian so hash choices are independent of host byte order.
    """
    var word = (
        data.unsafe_ptr()
        .unsafe_offset(pos)
        .unsafe_bitcast[UInt32]()
        .unsafe_load[alignment=1]()
    )
    comptime if is_big_endian():
        return byte_swap(word)
    else:
        return word


@always_inline
def _match_length(data: List[UInt8], candidate: Int, pos: Int) -> Int:
    """Extend four equal bytes, with start <= candidate < pos <= len(data)-4.

    The guarded current read proves the earlier candidate read also fits,
    including overlap: both read the immutable input, not a growing output.
    count <= len(data)-pos keeps each addition within the validated list.
    Normalize only unequal words before locating their first different byte.
    The short-match XOR strategy follows Google Snappy's FindMatchLength;
    see THIRD_PARTY_NOTICES.md. No speculative next-probe loads are performed.
    """
    var count = 4
    while len(data) - pos - count >= 8:
        var current = (
            data.unsafe_ptr()
            .unsafe_offset(pos + count)
            .unsafe_bitcast[UInt64]()
            .unsafe_load[alignment=1]()
        )
        var previous = (
            data.unsafe_ptr()
            .unsafe_offset(candidate + count)
            .unsafe_bitcast[UInt64]()
            .unsafe_load[alignment=1]()
        )
        var different = current ^ previous
        if different != 0:
            comptime if is_big_endian():
                different = byte_swap(different)
            # Four-byte matches are common: avoid bit-scan latency when the
            # very first extension byte differs. This is data-independent
            # policy: the same exact match length is returned on every path.
            if UInt8(different) != 0:
                return count
            return count + Int(count_trailing_zeros(different)) // 8
        count += 8
        # Keep equal long runs at the existing 16-byte comparison width.
        while len(data) - pos - count >= 16:
            var current16 = (
                data.unsafe_ptr()
                .unsafe_offset(pos + count)
                .unsafe_load[width=16]()
            )
            var previous16 = (
                data.unsafe_ptr()
                .unsafe_offset(candidate + count)
                .unsafe_load[width=16]()
            )
            if current16 != previous16:
                break
            count += 16
    while (
        count < len(data) - pos and data[candidate + count] == data[pos + count]
    ):
        count += 1
    return count


def _hash4(data: List[UInt8], pos: Int) -> Int:
    var word = _load4(data, pos)
    return Int((word * UInt32(0x1E35A7BD)) >> 18)


def snappy_max_compressed_length(size: Int) raises -> Int:
    """Conservative encoded bound for this encoder, for a UInt32 input size."""
    if size < 0 or UInt64(size) > UInt64(0xFFFFFFFF):
        raise Error("Invalid Snappy input size")
    return 32 + size + size // 6


def _encode_snappy[
    large: Bool
](data: List[UInt8], max_output_bytes: Int, start: Int = 0) raises -> List[
    UInt8
]:
    """Encode with a constant full-table mask or an input-sized small table.

    Specializing the full-table path avoids carrying a dynamic mask through
    long matches. Both paths keep input validation and output-limit errors.
    """
    if start < 0 or start > len(data):
        raise Error("Invalid Snappy source start")
    if max_output_bytes < 0 or UInt64(len(data) - start) > UInt64(0xFFFFFFFF):
        raise Error("Invalid Snappy input size or output limit")
    var output = List[UInt8]()
    var remaining = len(data) - start
    while remaining >= 128:
        _put(output, (remaining & 127) | 128, max_output_bytes)
        remaining >>= 7
    _put(output, remaining, max_output_bytes)
    # No match is possible; avoid allocating any hash state.
    if len(data) - start < 4:
        _literal(data, start, len(data) - start, output, max_output_bytes)
        return output^
    var table_size: Int
    comptime if large:
        table_size = 16384
    else:
        table_size = _hash_table_size(len(data) - start)
    # Large probes compare bytes first to avoid unpredictable occupancy/age
    # branches on misses. Initialize to a readable position in this suffix.
    # Int entries preserve arbitrary validated absolute starts, even >4 GiB.
    var initial: Int
    comptime if large:
        initial = start
    else:
        initial = -1
    var table = List[Int](length=table_size, fill=initial)
    var pos = start
    var literal_start = start
    # Large inputs start with 128 consecutive probes. After misses the stride
    # grows with bytes passed, but never exceeds 16. Unlike an unbounded search,
    # a long random prefix cannot leave arbitrarily wide gaps between probes.
    # Small inputs retain exhaustive search without runtime policy overhead.
    var skip = 128
    while len(data) - pos >= 4:
        var word = _load4(data, pos)
        var slot = Int((word * UInt32(0x1E35A7BD)) >> 18) & (table_size - 1)
        var candidate = table[slot]
        table[slot] = pos
        # The mask addresses initialized state. On the large path every
        # entry is in [start, pos], so both four-byte reads fit. An untouched
        # slot refers to start: its bytes cannot equal this word unless its
        # hash equals hash(start), whose slot was populated by the first
        # probe. Reject the initial zero offset explicitly. This sentinel
        # therefore preserves the old unpopulated-slot decisions exactly.
        # Small inputs keep -1 and guard occupancy before reading.
        var matches: Bool
        comptime if large:
            matches = _load4(data, candidate) == word
            if matches:
                matches = pos > candidate and pos - candidate <= 65535
        else:
            matches = candidate >= start and pos - candidate <= 65535
            if matches:
                matches = _load4(data, candidate) == word
        if not matches:
            comptime if large:
                var step = skip >> 7
                # The last increment can reach at most 2062, so step remains
                # <= 16 and the counter cannot grow with the input length.
                if skip < 2048:
                    skip += step
                # Clamp before addition, including near an absolute Int limit.
                # Skipped bytes remain in the pending literal, not discarded.
                pos += min(step, len(data) - pos)
            else:
                pos += 1
            continue
        _literal(
            data, literal_start, pos - literal_start, output, max_output_bytes
        )
        # Restore dense search immediately after every successful match.
        skip = 128
        var count = _match_length(data, candidate, pos)
        var offset = pos - candidate
        var left = count
        while left > 0:
            var chunk = min(left, 64)
            # COPY_2 permits lengths 1..64, so arbitrary match tails are legal.
            _put(output, ((chunk - 1) << 2) | 2, max_output_bytes)
            _put(output, offset, max_output_bytes)
            _put(output, offset >> 8, max_output_bytes)
            left -= chunk
        pos += count
        literal_start = pos
        # Retain a recent candidate after long runs without work proportional
        # to every skipped byte in the matched span.
        if pos - start >= 2 and len(data) - pos >= 2:
            table[_hash4(data, pos - 2) & (table_size - 1)] = pos - 2
    _literal(
        data, literal_start, len(data) - literal_start, output, max_output_bytes
    )
    return output^


def encode_snappy(
    data: List[UInt8], max_output_bytes: Int, start: Int = 0
) raises -> List[UInt8]:
    """Encode a raw block, raising before output length exceeds the limit."""
    # Validate before subtracting for dispatch; the implementation validates
    # the remaining public arguments before allocating or accessing input.
    if start < 0 or start > len(data):
        raise Error("Invalid Snappy source start")
    if len(data) - start >= 16384:
        return _encode_snappy[True](data, max_output_bytes, start)
    return _encode_snappy[False](data, max_output_bytes, start)


def compress(
    data: List[UInt8],
    *,
    max_output_bytes: Optional[Int] = None,
    start: Int = 0,
) raises -> List[UInt8]:
    """Compress data[start:], computing a sufficient output limit by default.

    Supply max_output_bytes to enforce a tighter encoded byte-length budget.
    The limit is not an allocation or RSS bound.
    """
    if start < 0 or start > len(data):
        raise Error("Invalid Snappy source start")
    var limit = snappy_max_compressed_length(len(data) - start)
    if max_output_bytes:
        limit = max_output_bytes.value()
    return encode_snappy(data, limit, start)


def uncompressed_length(data: List[UInt8], start: Int = 0) raises -> Int:
    """Read the UInt32 output size advertised by the header at start.

    Validate only the header, not the remaining block. No output is allocated.
    A returned size is not evidence that the block is valid or safe to allocate.
    """
    if start < 0 or start > len(data):
        raise Error("Invalid Snappy source start")
    var cursor = start
    var declared = UInt64(0)
    for i in range(5):
        var byte = _read_le[1](data, cursor)
        if i == 4 and byte > 15:
            raise Error("Snappy length overflow")
        declared |= UInt64(byte & 127) << UInt64(7 * i)
        if byte < 128:
            return Int(declared)
    raise Error("Snappy length overflow")


def decompress(
    data: List[UInt8], *, max_output_bytes: Int, start: Int = 0
) raises -> List[UInt8]:
    """Decode data[start:] when its exact size is unknown but bounded.

    max_output_bytes must be nonnegative and limits decoded byte length, not
    allocation capacity or RSS. Reject an advertised size above this limit
    before decoding. Then validate the complete block with ordinary bounded
    output growth; the header alone never causes an output allocation.
    Use decode_snappy instead when an independent exact size is known.
    """
    if max_output_bytes < 0:
        raise Error("Invalid Snappy output limit")
    var expected_size = uncompressed_length(data, start)
    if expected_size > max_output_bytes:
        raise Error("Snappy decoded output exceeds limit")
    return decode_snappy(data, expected_size, start)


@always_inline
def _store_into[
    width: SIMDLength
](
    mut output: List[UInt8],
    mut written: Int,
    value: SIMD[DType.uint8, width],
    count: Int,
):
    # Parser proves 0 <= count <= width and written + count <= len(output).
    # Full-width stores and scalar tails write exactly count initialized bytes.
    if count == Int(width):
        output.unsafe_ptr().unsafe_offset(written).unsafe_store(value)
    else:
        for i in range(count):
            output[written + i] = value[i]
    written += count


@always_inline
def _pattern_copy_into[
    period: Int
](mut result: List[UInt8], mut written: Int, var count: Int):
    comptime assert 2 <= period < 16
    comptime if period == 4:
        var seed4 = (
            result.unsafe_ptr()
            .unsafe_offset(written - 4)
            .unsafe_load[width=4]()
        )
        var eight = seed4.join(seed4)
        var sixteen = eight.join(eight)
        var wide = sixteen.join(sixteen)
        if count == 64:
            _store_into(result, written, wide.join(wide), 64)
        else:
            _store_into(result, written, wide.join(wide), count)
        return
    var seed = SIMD[DType.uint8, 16](0)
    comptime for i in range(period):
        seed[i] = result[written - period + i]
    var pattern = SIMD[DType.uint8, 16](0)
    comptime for i in range(16):
        pattern[i] = seed[i % period]
    while count >= 16:
        _store_into(result, written, pattern, 16)
        var next_pattern = SIMD[DType.uint8, 16](0)
        comptime for i in range(16):
            next_pattern[i] = pattern[(i + 16) % period]
        pattern = next_pattern
        count -= 16
    if count:
        _store_into(result, written, pattern, count)


@no_inline
def _expand_pattern_into(
    mut result: List[UInt8], mut written: Int, offset: Int, count: Int
):
    comptime for period in range(2, 16):
        if offset == period:
            _pattern_copy_into[period](result, written, count)
            return


@always_inline
def _copy_into(
    mut result: List[UInt8], mut written: Int, offset: Int, var count: Int
):
    """Write a validated 1..64-byte copy within initialized List storage.

    The parser proves offset fits the decoded prefix, not the destination's
    preexisting prefix, and written + count <= len(result). A width-W load
    requires offset >= W and count >= W. Stores are exact; later overlapping
    reads only observe bytes already decoded. No pointer escapes or survives
    a resize, and this path never changes the destination length.
    """
    if count >= 16 and offset == 1:
        var byte = result[written - 1]
        _store_into(result, written, SIMD[DType.uint8, 64](byte), count)
        return
    if count >= 4 and offset >= 4:
        # Keep the long-copy path, then handle short copies and vector tails.
        if offset >= 16:
            while count >= 16:
                var bytes = (
                    result.unsafe_ptr()
                    .unsafe_offset(written - offset)
                    .unsafe_load[width=16]()
                )
                _store_into(result, written, bytes, Int(bytes.length))
                count -= 16
        elif count >= 16:
            _expand_pattern_into(result, written, offset, count)
            return
        while count >= 4:
            var bytes = (
                result.unsafe_ptr()
                .unsafe_offset(written - offset)
                .unsafe_load[width=4]()
            )
            _store_into(result, written, bytes, Int(bytes.length))
            count -= 4
    if count >= 16:
        # Only offsets two and three remain after the paths above.
        _expand_pattern_into(result, written, offset, count)
        return
    # Short offsets 1..3 and final tails use forward byte copies; every source
    # byte belongs to the decoded prefix before later iterations read it.
    for _ in range(count):
        var byte = result[written - offset]
        result[written] = byte
        written += 1


def decode_snappy_into(
    data: List[UInt8],
    mut destination: List[UInt8],
    expected_size: Int,
    start: Int = 0,
    destination_start: Int = 0,
) raises -> Int:
    """Decode data[start:] into initialized caller-owned List storage.

    Return expected_size after exact header and output-size validation.
    Write only destination[destination_start:destination_start+expected_size].
    Destination length (not reserved capacity) must cover that range. Neither
    list is resized; prefix and tail stay untouched, including on errors.
    Late errors may leave a validated decoded prefix in the destination.
    Input and destination are distinct owners with immutable/mutable borrows;
    safe callers cannot pass the same List for both. No view escapes the call.
    """
    if expected_size < 0 or UInt64(expected_size) > UInt64(0xFFFFFFFF):
        raise Error("Invalid Snappy expected size")
    if start < 0 or start > len(data):
        raise Error("Invalid Snappy source start")
    if destination_start < 0 or destination_start > len(destination):
        raise Error("Invalid Snappy destination start")
    if expected_size > len(destination) - destination_start:
        raise Error("Snappy destination too small")
    var cursor = start
    var declared = UInt64(0)
    var terminated = False
    for i in range(5):
        var byte = _read_le[1](data, cursor)
        if i == 4 and byte > 15:
            raise Error("Snappy length overflow")
        declared |= UInt64(byte & 127) << UInt64(7 * i)
        if byte < 128:
            terminated = True
            break
    if not terminated or declared != UInt64(expected_size):
        raise Error("Snappy declared length mismatch")
    var written = destination_start
    while cursor < len(data):
        var tag = _read_le[1](data, cursor)
        var kind = tag & 3
        var count = (tag >> 2) + 1
        if kind == 0:
            if count > 60:
                if count == 61:
                    count = _read_le[1](data, cursor) + 1
                elif count == 62:
                    count = _read_le[2](data, cursor) + 1
                elif count == 63:
                    count = _read_le[3](data, cursor) + 1
                else:
                    count = _read_le[4](data, cursor) + 1
            if count > len(data) - cursor or count > expected_size - (
                written - destination_start
            ):
                raise Error("Snappy literal exceeds input or output")
            # Distinct List owners and exclusive output borrow ensure non-overlap.
            unsafe_memcpy(
                dest=destination.unsafe_ptr().unsafe_offset(written),
                src=data.unsafe_ptr().unsafe_offset(cursor),
                count=count,
            )
            written += count
            cursor += count
        else:
            var offset: Int
            if kind == 1:
                count = 4 + ((tag >> 2) & 7)
                offset = ((tag & 224) << 3) | _read_le[1](data, cursor)
            else:
                offset = _read_le[2](data, cursor) if kind == 2 else _read_le[
                    4
                ](data, cursor)
            if offset <= 0 or offset > written - destination_start:
                raise Error("Invalid Snappy copy offset")
            if count > expected_size - (written - destination_start):
                raise Error("Snappy copy exceeds output")
            _copy_into(destination, written, offset, count)
    if written - destination_start != expected_size:
        raise Error("Snappy decoded length mismatch")
    return written - destination_start
