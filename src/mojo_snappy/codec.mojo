"""Native raw Snappy blocks with caller-bounded output and fixed match state.

The encoder uses a greedy, single-candidate 16K hash table and a 64K lookback.
The decoder accepts all three copy forms, including overlapping backreferences.
No framing, Python, or external codec library is involved.
"""


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
            for i in range(count):
                result.append(data[cursor + i])
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
    for i in range(count):
        output.append(data[start + i])


def _hash4(data: List[UInt8], pos: Int) -> Int:
    var word = UInt32(data[pos]) | (UInt32(data[pos + 1]) << 8)
    word |= UInt32(data[pos + 2]) << 16
    word |= UInt32(data[pos + 3]) << 24
    return Int((word * UInt32(0x1E35A7BD)) >> 18)


def snappy_max_compressed_length(size: Int) raises -> Int:
    """Conservative encoded bound for this encoder, for a UInt32 input size."""
    if size < 0 or UInt64(size) > UInt64(0xFFFFFFFF):
        raise Error("Invalid Snappy input size")
    return 32 + size + size // 6


def encode_snappy(
    data: List[UInt8], max_output_bytes: Int, start: Int = 0
) raises -> List[UInt8]:
    """Encode a raw block, raising before output length exceeds the limit."""
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
    var table = List[Int](length=16384, fill=-1)
    var pos = start
    var literal_start = start
    while pos + 4 <= len(data):
        var slot = _hash4(data, pos)
        var candidate = table[slot]
        table[slot] = pos
        var matches = candidate >= 0 and pos - candidate <= 65535
        if matches:
            for i in range(4):
                if data[candidate + i] != data[pos + i]:
                    matches = False
                    break
        if not matches:
            pos += 1
            continue
        _literal(
            data, literal_start, pos - literal_start, output, max_output_bytes
        )
        var count = 4
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
        if pos >= start + 2 and pos + 2 <= len(data):
            table[_hash4(data, pos - 2)] = pos - 2
    _literal(
        data, literal_start, len(data) - literal_start, output, max_output_bytes
    )
    return output^
