"""Native raw Snappy blocks with caller-bounded output and bounded match state.

The encoder uses a greedy, single-candidate hash table of at most 16K entries
and a 64K lookback.
The decoder accepts all three copy forms, including overlapping backreferences.
No framing, Python, or external codec library is involved.
"""


from std.bit import byte_swap
from std.sys.info import is_big_endian


def _read_le(data: List[UInt8], mut cursor: Int, count: Int) raises -> Int:
    if count > len(data) - cursor:
        raise Error("Truncated Snappy block")
    var value = UInt64(0)
    for i in range(count):
        value |= UInt64(data[cursor + i]) << UInt64(8 * i)
    cursor += count
    return Int(value)


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
        var byte = _read_le(data, cursor, 1)
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
        var tag = _read_le(data, cursor, 1)
        var kind = tag & 3
        var count = (tag >> 2) + 1
        if kind == 0:
            if count > 60:
                count = _read_le(data, cursor, count - 60) + 1
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
                offset = ((tag & 224) << 3) | _read_le(data, cursor, 1)
            else:
                offset = _read_le(data, cursor, 2 if kind == 2 else 4)
            if offset <= 0 or offset > len(result):
                raise Error("Invalid Snappy copy offset")
            if count > expected_size - len(result):
                raise Error("Snappy copy exceeds output")
            if count >= 16 and (offset == 1 or offset >= 16):
                var end = len(result) + count
                if end > result.capacity():
                    result.reserve(max(end, 2 * result.capacity()))
                if offset == 1:
                    var byte = result[len(result) - 1]
                    result.resize(end, fill=byte)
                    continue
                # Each vector reads only initialized bytes. Later vectors
                # may reference bytes appended by an earlier vector.
                while count >= 16:
                    var bytes = (
                        result.unsafe_ptr()
                        .unsafe_offset(len(result) - offset)
                        .unsafe_load[width=16]()
                    )
                    result.extend(bytes)
                    count -= 16
            for _ in range(count):
                var byte = result[len(result) - offset]
                result.append(byte)
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
    var table = List[Int](length=table_size, fill=-1)
    var pos = start
    var literal_start = start
    # Large inputs start with 128 consecutive probes. After misses the stride
    # grows with bytes passed, but never exceeds 16. Unlike an unbounded search,
    # a long random prefix cannot leave arbitrarily wide gaps between probes.
    # Small inputs retain exhaustive search without runtime policy overhead.
    var skip = 128
    while len(data) - pos >= 4:
        var slot = _hash4(data, pos) & (table_size - 1)
        var candidate = table[slot]
        table[slot] = pos
        # Every populated entry was stored at an earlier position in this
        # suffix. Thus start <= candidate < pos <= len(data)-4, proving both
        # four-byte reads safe. The hash mask is within the initialized table.
        var matches = candidate >= start and pos - candidate <= 65535
        if matches:
            matches = _load4(data, candidate) == _load4(data, pos)
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
        var count = 4
        # Both loads stay within the source, including overlapping matches.
        # Fall back to byte comparisons at the first unequal vector or tail.
        comptime width = 16
        while len(data) - pos - count >= width:
            var current = (
                data.unsafe_ptr()
                .unsafe_offset(pos + count)
                .unsafe_load[width=width]()
            )
            var previous = (
                data.unsafe_ptr()
                .unsafe_offset(candidate + count)
                .unsafe_load[width=width]()
            )
            if current != previous:
                break
            count += width
        while (
            pos + count < len(data)
            and data[candidate + count] == data[pos + count]
        ):
            count += 1
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
