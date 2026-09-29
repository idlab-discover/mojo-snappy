"""Native raw Snappy blocks with caller-bounded output and bounded match state.

The encoder follows Google Snappy 1.2.2 level-1 compression: 64 KiB fragments,
a greedy single-candidate hash table of at most 32K 16-bit entries, heuristic
match skipping and the shortest copy encodings. On targets with SSE4.2 it
hashes with CRC32C like an SSE4.2 build of Google Snappy; elsewhere it uses the
portable multiplicative hash. Either way output bytes match Google Snappy built
for the same target features.
The decoder accepts all three copy forms, including overlapping backreferences.
No framing, Python, or external codec library is involved.
"""


from std.bit import byte_swap, count_leading_zeros, count_trailing_zeros
from std.builtin.globals import global_constant
from std.memory import unsafe_memcpy, unsafe_memset_zero
from std.ffi import external_call
from std.sys import llvm_intrinsic
from std.sys.info import CompilationTarget, is_big_endian


comptime _BLOCK_SIZE = 65536
"""Encoder fragment size; every copy offset stays below 65536."""
comptime _MIN_HASH_TABLE_SIZE = 256
comptime _MAX_HASH_TABLE_SIZE = 32768
comptime _INPUT_MARGIN = 15
"""Input bytes kept beyond the encoder main loop for 16-byte overreads."""


# ---------------------------------------------------------------------------
# Unaligned little-endian access. Callers prove every accessed byte lies in
# storage owned by a live, non-resizing List for the duration of the access.
# ---------------------------------------------------------------------------


@always_inline
def _ld16(p: Pointer[UInt8, _], i: Int) -> Int:
    var word = (
        p.unsafe_offset(i).unsafe_bitcast[UInt16]().unsafe_load[alignment=1]()
    )
    comptime if is_big_endian():
        word = byte_swap(word)
    return Int(word)


@always_inline
def _ld32(p: Pointer[UInt8, _], i: Int) -> UInt32:
    var word = (
        p.unsafe_offset(i).unsafe_bitcast[UInt32]().unsafe_load[alignment=1]()
    )
    comptime if is_big_endian():
        word = byte_swap(word)
    return word


@always_inline
def _ld64(p: Pointer[UInt8, _], i: Int) -> UInt64:
    var word = (
        p.unsafe_offset(i).unsafe_bitcast[UInt64]().unsafe_load[alignment=1]()
    )
    comptime if is_big_endian():
        word = byte_swap(word)
    return word


@always_inline
def _st32(p: Pointer[mut=True, UInt8, _], i: Int, var value: UInt32):
    comptime if is_big_endian():
        value = byte_swap(value)
    p.unsafe_offset(i).unsafe_bitcast[UInt32]().unsafe_store[alignment=1](value)


@always_inline
def _copy16(
    dst: Pointer[mut=True, UInt8, _],
    d: Int,
    src: Pointer[UInt8, _],
    s: Int,
):
    dst.unsafe_offset(d).unsafe_store(
        src.unsafe_offset(s).unsafe_load[width=16]()
    )


@always_inline
def _self_copy16(p: Pointer[mut=True, UInt8, _], d: Int, s: Int):
    """Copy 16 bytes within one buffer; the load completes before the store."""
    p.unsafe_offset(d).unsafe_store(p.unsafe_offset(s).unsafe_load[width=16]())


@always_inline
def _copy_bytes(
    dst: Pointer[mut=True, UInt8, _],
    d: Int,
    src: Pointer[UInt8, _],
    s: Int,
    count: Int,
):
    """Copy count bytes between distinct buffers.

    Large copies use the C library memcpy, whose string-instruction paths
    stream into cold output faster than an inlined vector loop.
    """
    if count >= 4096:
        _ = external_call["memcpy", Pointer[UInt8, MutAnyOrigin]](
            dst.unsafe_offset(d), src.unsafe_offset(s), count
        )
    else:
        unsafe_memcpy(
            dest=dst.unsafe_offset(d), src=src.unsafe_offset(s), count=count
        )


# ---------------------------------------------------------------------------
# Header
# ---------------------------------------------------------------------------


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


def _read_header(data: List[UInt8], mut cursor: Int) raises -> Int:
    """Parse the varint32 decoded length at cursor, advancing past it."""
    var declared = UInt64(0)
    for i in range(5):
        var byte = _read_le[1](data, cursor)
        if i == 4 and byte > 15:
            raise Error("Snappy length overflow")
        declared |= UInt64(byte & 127) << UInt64(7 * i)
        if byte < 128:
            return Int(declared)
    raise Error("Snappy length overflow")


# ---------------------------------------------------------------------------
# Decoder
# ---------------------------------------------------------------------------


def _pattern_masks[trailing: Bool]() -> InlineArray[SIMD[DType.uint8, 16], 64]:
    """Shuffle masks at index 16 * chunk + offset, for offsets 1..15.

    Output bytes [16k, 16k + 16) of a copy repeating its `offset` preceding
    bytes are seed lane (i + 16k) % offset. Leading masks index a vector
    loaded at op - offset (seed in lanes 0..offset-1); trailing masks index
    a vector loaded at op - 16 (seed in lanes 16-offset..15), which matches
    the previous 16-byte store so the load can be forwarded. All four chunks
    derive from the seed independently. The pattern-extension idea follows
    Google Snappy; see THIRD_PARTY_NOTICES.md.
    """
    var table = InlineArray[SIMD[DType.uint8, 16], 64](
        fill=SIMD[DType.uint8, 16](0)
    )
    for chunk in range(4):
        for offset in range(1, 16):
            for i in range(16):
                var lane = (i + 16 * chunk) % offset
                comptime if trailing:
                    lane += 16 - offset
                table[16 * chunk + offset][i] = UInt8(lane)
    return table^


comptime _PATTERN_MASKS = _pattern_masks[False]()
comptime _TRAILING_PATTERN_MASKS = _pattern_masks[True]()


@no_inline
def _pattern_copy_exact(
    dst: Pointer[mut=True, UInt8, _], op: Int, offset: Int, length: Int
):
    """Write length <= 64 bytes repeating the offset < 16 bytes before op.

    Caller proves offset <= op - op_base and op + length <= op_end. Reads
    only the seed bytes and writes exactly [op, op + length).
    """
    var seed = SIMD[DType.uint8, 16](0)
    for i in range(offset):
        seed[i] = dst[unsafe_offset=op - offset + i]
    var masks = global_constant[_PATTERN_MASKS]().unsafe_ptr()
    var done = 0
    for chunk in range(4):
        if done == length:
            return
        var pattern = seed._dynamic_shuffle(
            masks[unsafe_offset=16 * chunk + offset]
        )
        if length - done >= 16:
            dst.unsafe_offset(op + done).unsafe_store(pattern)
            done += 16
        else:
            for i in range(length - done):
                dst[unsafe_offset=op + done + i] = pattern[i]
            return


def _length_minus_offset() -> InlineArray[Int16, 256]:
    """Per-tag length minus the tag-encoded offset bits, as in Google Snappy.

    The low byte is the command length. For COPY_1 the tag's offset bits are
    subtracted as offset_high << 8; COPY_2 has none. Short literals get a
    spurious offset of 256, so entry - extracted_offset > 0 exactly when a
    copy overlaps its own output (offset < length). Long literals and COPY_4
    store 0xFF, which always takes that branch and has bit 7 set, marking
    them for the exact path. See THIRD_PARTY_NOTICES.md.
    """
    var table = InlineArray[Int16, 256](fill=0)
    for tag in range(256):
        var data = tag >> 2
        var kind = tag & 3
        var entry: Int
        if kind == 3:
            entry = 0xFF
        elif kind == 2:
            entry = data + 1
        elif kind == 1:
            entry = (data & 7) + 4 - ((data >> 3) << 8)
        elif data < 60:
            entry = data + 1 - 256
        else:
            entry = 0xFF
        table[tag] = Int16(entry)
    return table^


comptime _LENGTH_MINUS_OFFSET = _length_minus_offset()
comptime _FAST_INPUT_MARGIN = 65
"""Fast-loop input slack: a tag plus a 64-byte literal overread."""
comptime _FAST_OUTPUT_MARGIN = 64
"""Fast-loop output slack: every fast command writes at most 64 bytes."""


@always_inline
def _decode_fast(
    src: Pointer[UInt8, _],
    mut ip: Int,
    ip_end: Int,
    dst: Pointer[mut=True, UInt8, _],
    op_base: Int,
    mut op: Int,
    op_end: Int,
):
    """Decode short literals, COPY_1 and COPY_2 while slack remains.

    Requires op - op_base >= 16, which stays true as op only grows.
    Runs while more than 65 input bytes and at least 64 output bytes remain;
    stops without consuming a long literal, COPY_4 or invalid copy, which
    the exact path then handles or rejects. Every command reads at most 64
    bytes from [ip + 1, ip_end) or from [op_base, op + 64) and writes 64
    bytes within [op, op_end). Bytes past a command's length are overwritten
    by later commands before being read as decoded output, and pattern or
    overcopy loads that observe undecoded bytes only use them as such
    slack. Literal and copy sources are selected by address, not branch.
    """
    var table = global_constant[_LENGTH_MINUS_OFFSET]().unsafe_ptr()
    var trailing = global_constant[_TRAILING_PATTERN_MASKS]().unsafe_ptr()
    var ip_limit = ip_end - _FAST_INPUT_MARGIN
    var op_limit = op_end - _FAST_OUTPUT_MARGIN
    while ip < ip_limit and op <= op_limit:
        var tag = Int(src[unsafe_offset=ip])
        var entry = Int(table[unsafe_offset=tag])
        var kind = tag & 3
        # Offset bits after the tag: none, one or two bytes by kind.
        var extracted = Int(_ld32(src, ip + 1)) & Int(
            (UInt64(0x0000FFFF00FF0000) >> UInt64(16 * kind)) & 0xFFFF
        )
        var length = entry & 0xFF
        var next_ip = (ip + 2 + (tag >> 2)) if kind == 0 else (ip + 1 + kind)
        var offset = length - entry + extracted
        if entry > extracted:
            if length & 0x80:
                return
            # Overlapping COPY_1 / COPY_2: 0 <= offset < length <= 64.
            if UInt(offset - 1) >= UInt(op - op_base):
                return
            if offset < 16:
                # Load the 16 decoded bytes ending at op (op - op_base >= 16):
                # that load matches an earlier store and can be forwarded.
                var seed = dst.unsafe_offset(op - 16).unsafe_load[width=16]()
                dst.unsafe_offset(op).unsafe_store(
                    seed._dynamic_shuffle(trailing[unsafe_offset=offset])
                )
                if length > 16:
                    dst.unsafe_offset(op + 16).unsafe_store(
                        seed._dynamic_shuffle(
                            trailing[unsafe_offset=16 + offset]
                        )
                    )
                    if length > 32:
                        dst.unsafe_offset(op + 32).unsafe_store(
                            seed._dynamic_shuffle(
                                trailing[unsafe_offset=32 + offset]
                            )
                        )
                        dst.unsafe_offset(op + 48).unsafe_store(
                            seed._dynamic_shuffle(
                                trailing[unsafe_offset=48 + offset]
                            )
                        )
            else:
                # Each 16-byte source chunk ends at or before its destination.
                var done = 0
                while done < length:
                    _self_copy16(dst, op + done, op - offset + done)
                    done += 16
            ip = next_ip
            op += length
            continue
        # Non-overlapping copy (offset >= length) or short literal.
        if op - offset < op_base and kind != 0:
            return
        var address = (Int(dst) + op - offset) if kind != 0 else (
            Int(src) + ip + 1
        )
        var source = Pointer[UInt8, ImmutAnyOrigin](unsafe_from_address=address)
        # Load each 32-byte half before storing it: source bytes past length
        # may overlap the destination but are only slack.
        dst.unsafe_offset(op).unsafe_store(source.unsafe_load[width=32]())
        if length > 32:
            dst.unsafe_offset(op + 32).unsafe_store(
                source.unsafe_offset(32).unsafe_load[width=32]()
            )
        ip = next_ip
        op += length


@always_inline
def _decode_block(
    src: Pointer[UInt8, _],
    var ip: Int,
    ip_end: Int,
    dst: Pointer[mut=True, UInt8, _],
    op_base: Int,
    op_end: Int,
) raises -> Int:
    """Decode commands from src[ip:ip_end] into dst[op_base:op_end].

    Return the final output position; callers compare it with op_end.
    src and dst belong to distinct live Lists that cannot resize meanwhile.
    Reads stay in [ip, ip_end), reads and writes of dst stay in
    [op_base, op_end), and backreferences only reach [op_base, op).
    The fast loop may write slack bytes in [op, op_end) that later commands
    overwrite; a block that decodes fully therefore initializes exactly
    [op_base, op_end). Other commands run exact and fully checked.
    """
    var op = op_base
    while ip < ip_end:
        if (
            ip_end - ip > _FAST_INPUT_MARGIN
            and op_end - op >= _FAST_OUTPUT_MARGIN
            and op - op_base >= 16
        ):
            _decode_fast(src, ip, ip_end, dst, op_base, op, op_end)
            if ip >= ip_end:
                break
        var tag = Int(src[unsafe_offset=ip])
        ip += 1
        var kind = tag & 3
        var length = (tag >> 2) + 1
        if kind == 0:
            if length > 60:
                var extra = length - 60
                if extra > ip_end - ip:
                    raise Error("Truncated Snappy block")
                length = 0
                for i in range(extra):
                    length |= Int(src[unsafe_offset=ip + i]) << (8 * i)
                length += 1
                ip += extra
            if length > ip_end - ip or length > op_end - op:
                raise Error("Snappy literal exceeds input or output")
            _copy_bytes(dst, op, src, ip, length)
            ip += length
            op += length
            continue
        var offset: Int
        if kind == 1:
            if ip_end - ip < 1:
                raise Error("Truncated Snappy block")
            length = ((tag >> 2) & 7) + 4
            offset = ((tag & 0xE0) << 3) | Int(src[unsafe_offset=ip])
            ip += 1
        elif kind == 2:
            if ip_end - ip < 2:
                raise Error("Truncated Snappy block")
            offset = _ld16(src, ip)
            ip += 2
        else:
            if ip_end - ip < 4:
                raise Error("Truncated Snappy block")
            offset = Int(_ld32(src, ip))
            ip += 4
        if UInt(offset - 1) >= UInt(op - op_base):
            raise Error("Invalid Snappy copy offset")
        if length > op_end - op:
            raise Error("Snappy copy exceeds output")
        if offset >= 16 and length >= 16:
            # Non-overlapping 16-byte chunks, then one final chunk ending
            # exactly at op + length (it rewrites some equal bytes).
            var done = 0
            while length - done > 16:
                _self_copy16(dst, op + done, op - offset + done)
                done += 16
            _self_copy16(dst, op + length - 16, op + length - 16 - offset)
        elif offset < 16 and offset < length:
            _pattern_copy_exact(dst, op, offset, length)
        else:
            # offset >= length: source bytes all precede op.
            for i in range(length):
                dst[unsafe_offset=op + i] = dst[unsafe_offset=op + i - offset]
        op += length
    return op


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
    if _read_header(data, cursor) != expected_size:
        raise Error("Snappy declared length mismatch")
    # Every command byte decodes to at most 64/3 output bytes (a 3-byte
    # COPY_2 of length 64), so a larger size cannot be valid. Rejecting it
    # bounds the allocation by the compressed input, never by the header.
    if UInt64(expected_size) * 3 > UInt64(len(data) - cursor) * 64:
        raise Error("Snappy declared length exceeds maximum expansion")
    var result = List[UInt8](unsafe_uninit_length=expected_size)
    var written = _decode_block(
        data.unsafe_ptr(),
        cursor,
        len(data),
        result.unsafe_ptr(),
        0,
        expected_size,
    )
    if written != expected_size:
        raise Error("Snappy decoded length mismatch")
    return result^


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
    Late errors may leave arbitrary bytes anywhere in the target range.
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
    if _read_header(data, cursor) != expected_size:
        raise Error("Snappy declared length mismatch")
    var end = destination_start + expected_size
    var written = _decode_block(
        data.unsafe_ptr(),
        cursor,
        len(data),
        destination.unsafe_ptr(),
        destination_start,
        end,
    )
    if written != end:
        raise Error("Snappy decoded length mismatch")
    return expected_size


def uncompressed_length(data: List[UInt8], start: Int = 0) raises -> Int:
    """Read the UInt32 output size advertised by the header at start.

    Validate only the header, not the remaining block. No output is allocated.
    A returned size is not evidence that the block is valid or safe to allocate.
    """
    if start < 0 or start > len(data):
        raise Error("Invalid Snappy source start")
    var cursor = start
    return _read_header(data, cursor)


def decompress(
    data: List[UInt8], *, max_output_bytes: Int, start: Int = 0
) raises -> List[UInt8]:
    """Decode data[start:] when its exact size is unknown but bounded.

    max_output_bytes must be nonnegative and limits decoded byte length, not
    allocation capacity or RSS. Reject an advertised size above this limit
    before decoding, then validate the complete block. Output is allocated
    only for sizes the compressed input could actually produce (at most 64/3
    bytes per input byte), never for an arbitrary header value.
    Use decode_snappy instead when an independent exact size is known.
    """
    if max_output_bytes < 0:
        raise Error("Invalid Snappy output limit")
    var expected_size = uncompressed_length(data, start)
    if expected_size > max_output_bytes:
        raise Error("Snappy decoded output exceeds limit")
    return decode_snappy(data, expected_size, start)


# ---------------------------------------------------------------------------
# Encoder
# ---------------------------------------------------------------------------


def _hash_table_size(size: Int) -> Int:
    """Power-of-two entry count for a fragment size, clamped to 256..32K.

    Matches Google Snappy's CalculateTableSize without large intermediates.
    """
    var count = _MIN_HASH_TABLE_SIZE
    while count < min(size, _MAX_HASH_TABLE_SIZE):
        count *= 2
    return count


def _load4(data: List[UInt8], pos: Int) -> UInt32:
    """Load four little-endian bytes after the caller proves pos+4 <= len."""
    return _ld32(data.unsafe_ptr(), pos)


@always_inline
def _table_index(word: UInt32, mask: UInt32) -> Int:
    """Map a little-endian word to a 16-bit table entry index.

    mask is 2 * (table_size - 1): Google Snappy hashes to an even byte offset
    into the uint16 table, so the entry index is (hash & mask) >> 1.
    """
    var hash: UInt32
    comptime if CompilationTarget.has_sse4():
        hash = llvm_intrinsic["llvm.x86.sse42.crc32.32.32", UInt32](word, mask)
    else:
        hash = (word * UInt32(0x1E35A7BD)) >> 16
    return Int(hash & mask) >> 1


@always_inline
def _select_if_zero(key: UInt32, if_zero: UInt64, otherwise: UInt64) -> UInt64:
    """Branch-free select: this choice is unpredictable and on the critical path.
    """
    var keep = UInt64(0) - UInt64(key == 0)
    return (if_zero & keep) | (otherwise & ~keep)


@always_inline
def _find_match_length(
    src: Pointer[UInt8, _], s1: Int, s2: Int, limit: Int, mut data: UInt64
) -> Int:
    """Largest n with src[s1:s1+n] == src[s2:s2+n] and s2 + n <= limit.

    Requires s1 < s2 <= limit, so both reads stay below limit. When at least
    8 bytes remain after the match, also set data to the little-endian bytes
    at s2 + n (at least the low five are exact). data derives from loads at
    s2 only, keeping the candidate load off the next hash lookup's critical
    path. Port of Google Snappy's 64-bit FindMatchLength; see
    THIRD_PARTY_NOTICES.md.
    """
    var matched = 0
    if limit - s2 >= 16:
        var a1 = _ld64(src, s1)
        var a2 = _ld64(src, s2)
        if a1 != a2:
            var different = a1 ^ a2
            var shift = count_trailing_zeros(different)
            var a3 = _ld64(src, s2 + 4)
            # Past the first four bytes, shift from the word at s2 + 4.
            a2 = _select_if_zero(UInt32(different), a3, a2)
            data = a2 >> (shift & 24)
            return Int(shift >> 3)
        matched = 8
    while limit - s2 - matched >= 16:
        var a1 = _ld64(src, s1 + matched)
        var a2 = _ld64(src, s2 + matched)
        if a1 == a2:
            matched += 8
            continue
        var different = a1 ^ a2
        var shift = count_trailing_zeros(different)
        var a3 = _ld64(src, s2 + matched + 4)
        a2 = _select_if_zero(UInt32(different), a3, a2)
        data = a2 >> (shift & 24)
        return matched + Int(shift >> 3)
    while s2 + matched < limit:
        if src[unsafe_offset=s1 + matched] != src[unsafe_offset=s2 + matched]:
            if limit - s2 - matched >= 8:
                data = _ld64(src, s2 + matched)
            return matched
        matched += 1
    return matched


def _match_length(data: List[UInt8], candidate: Int, pos: Int) -> Int:
    """Extend four equal bytes, with candidate < pos <= len(data) - 4."""
    var ignored = UInt64(0)
    return 4 + _find_match_length(
        data.unsafe_ptr(), candidate + 4, pos + 4, len(data), ignored
    )


@always_inline
def _emit_literal[
    fast: Bool
](
    dst: Pointer[mut=True, UInt8, _],
    var op: Int,
    src: Pointer[UInt8, _],
    literal: Int,
    length: Int,
) -> Int:
    """Emit src[literal:literal+length], length >= 1, returning the new op.

    The fast form may read up to 15 bytes past the literal and write up to
    15 bytes past its end; the encoder main loop guarantees 15 input bytes
    and the output buffer keeps MaxCompressedLength slack per fragment.
    """
    var n = length - 1
    comptime if fast:
        if length <= 16:
            dst[unsafe_offset=op] = UInt8(n << 2)
            _copy16(dst, op + 1, src, literal)
            return op + 1 + length
    if n < 60:
        dst[unsafe_offset=op] = UInt8(n << 2)
        op += 1
    else:
        var count = (31 - Int(count_leading_zeros(UInt32(n)))) // 8 + 1
        dst[unsafe_offset=op] = UInt8((59 + count) << 2)
        # Four bytes are stored; at least 61 literal bytes follow.
        _st32(dst, op + 1, UInt32(n))
        op += 1 + count
    comptime if fast:
        var done = 0
        while True:
            _copy16(dst, op + done, src, literal + done)
            done += 16
            if done >= length:
                break
    else:
        _copy_bytes(dst, op, src, literal, length)
    return op + length


@always_inline
def _emit_copy_at_most_64(
    dst: Pointer[mut=True, UInt8, _], op: Int, offset: Int, length: Int
) -> Int:
    """Emit one copy with 4 <= length <= 64 and 0 < offset < 65536.

    Stores four bytes, of which two or three are meaningful.
    """
    if length < 12:
        # COPY_1 (1 | (length - 4) << 2 | (offset >> 8) << 5, offset & 255)
        # when offset < 2048, else COPY_2. Offset size is unpredictable, so
        # select arithmetically like Google Snappy's EmitCopyAtMost64.
        var short = Int(offset < 2048)
        var u = (length << 2) + (offset << 8)
        u += short * (1 - 16 + ((offset >> 3) & 0xE0)) + (1 - short) * (2 - 4)
        _st32(dst, op, UInt32(u))
        return op + 3 - short
    _st32(dst, op, UInt32(2 + ((length - 1) << 2) + (offset << 8)))
    return op + 3


@always_inline
def _emit_copy(
    dst: Pointer[mut=True, UInt8, _], var op: Int, offset: Int, var length: Int
) -> Int:
    """Emit a copy of any length >= 4, keeping each final piece >= 4 bytes."""
    if length >= 12:
        while length >= 68:
            op = _emit_copy_at_most_64(dst, op, offset, 64)
            length -= 64
        if length > 64:
            op = _emit_copy_at_most_64(dst, op, offset, 60)
            length -= 60
    return _emit_copy_at_most_64(dst, op, offset, length)


def _compress_fragment(
    src: Pointer[UInt8, _],
    base: Int,
    size: Int,
    dst: Pointer[mut=True, UInt8, _],
    var op: Int,
    table: Pointer[mut=True, UInt16, _],
    table_size: Int,
) -> Int:
    """Compress src[base:base+size], size <= 64 KiB, starting at dst[op].

    Port of Google Snappy 1.2.2 CompressFragment (level 1): identical match
    choices and encodings, hence identical output. table holds table_size
    zeroed entries; each stores a position relative to base, so candidates
    stay in [base, ip) and offsets below 65536. dst needs
    32 + size + size / 6 bytes from op. See THIRD_PARTY_NOTICES.md.
    """
    var mask = UInt32(2 * (table_size - 1))
    var ip = base
    var ip_end = base + size
    if size >= _INPUT_MARGIN:
        var ip_limit = ip_end - _INPUT_MARGIN
        while True:
            # Bytes in [next_emit, ip) are pending literal bytes.
            var next_emit = ip
            ip += 1
            var data = _ld64(src, ip)
            var skip = UInt32(32)
            var candidate = base
            var matched_early = False
            if ip_limit - ip >= 16:
                # Probe the next 16 positions densely before skipping.
                var delta = ip - base
                for i in range(16):
                    var word = UInt32(data)
                    var index = _table_index(word, mask)
                    candidate = base + Int(table[unsafe_offset=index])
                    table[unsafe_offset=index] = UInt16(delta + i)
                    if _ld32(src, candidate) == word:
                        # Literal of i + 1 <= 16 bytes, then the match.
                        dst[unsafe_offset=op] = UInt8(i << 2)
                        _copy16(dst, op + 1, src, next_emit)
                        ip += i
                        op += i + 2
                        matched_early = True
                        break
                    data >>= 8
                    if i % 4 == 3:
                        data = _ld64(src, ip + i + 1)
                if not matched_early:
                    ip += 16
                    skip += 16
            if not matched_early:
                var found = False
                while True:
                    var word = UInt32(data)
                    var index = _table_index(word, mask)
                    var step = Int(skip >> 5)
                    skip += UInt32(step)
                    var next_ip = ip + step
                    if next_ip > ip_limit:
                        break
                    candidate = base + Int(table[unsafe_offset=index])
                    table[unsafe_offset=index] = UInt16(ip - base)
                    if word == _ld32(src, candidate):
                        found = True
                        break
                    data = UInt64(_ld32(src, next_ip))
                    ip = next_ip
                if not found:
                    ip = next_emit
                    break
                op = _emit_literal[True](
                    dst, op, src, next_emit, ip - next_emit
                )
            # Emit copies while the input right after each copy matches again.
            var exhausted = False
            while True:
                var start = ip
                var matched = 4 + _find_match_length(
                    src, candidate + 4, ip + 4, ip_end, data
                )
                ip += matched
                op = _emit_copy(dst, op, start - candidate, matched)
                if ip >= ip_limit:
                    exhausted = True
                    break
                # ip < ip_limit, so data holds the bytes at ip. Also index
                # ip - 1, then test the table candidate for ip.
                table[
                    unsafe_offset=_table_index(_ld32(src, ip - 1), mask)
                ] = UInt16(ip - base - 1)
                var word = UInt32(data)
                var index = _table_index(word, mask)
                candidate = base + Int(table[unsafe_offset=index])
                table[unsafe_offset=index] = UInt16(ip - base)
                if word != _ld32(src, candidate):
                    break
            if exhausted:
                break
    if ip < ip_end:
        op = _emit_literal[False](dst, op, src, ip, ip_end - ip)
    return op


def snappy_max_compressed_length(size: Int) raises -> Int:
    """Conservative encoded bound for this encoder, for a UInt32 input size."""
    if size < 0 or UInt64(size) > UInt64(0xFFFFFFFF):
        raise Error("Invalid Snappy input size")
    return 32 + size + size // 6


def encode_snappy(
    data: List[UInt8], max_output_bytes: Int, start: Int = 0
) raises -> List[UInt8]:
    """Encode a raw block, raising if its length would exceed the limit.

    Output is written into a buffer sized for the worst case of each 64 KiB
    fragment plus slack, so its capacity may exceed its final length. The
    limit therefore bounds the returned byte length, not the allocation.
    """
    if start < 0 or start > len(data):
        raise Error("Invalid Snappy source start")
    var size = len(data) - start
    if max_output_bytes < 0 or UInt64(size) > UInt64(0xFFFFFFFF):
        raise Error("Invalid Snappy input size or output limit")
    # Five varint bytes plus MaxCompressedLength per fragment. Summing the
    # per-fragment bounds keeps each fragment's 32 bytes of overwrite slack.
    var capacity = 5 + size + size // 6 + 32 * (size // _BLOCK_SIZE + 1)
    var output = List[UInt8](unsafe_uninit_length=capacity)
    var dst = output.unsafe_ptr()
    var op = 0
    var remaining = size
    while remaining >= 128:
        dst[unsafe_offset=op] = UInt8((remaining & 127) | 128)
        op += 1
        remaining >>= 7
    dst[unsafe_offset=op] = UInt8(remaining)
    op += 1
    if size > 0:
        # Each fragment clears the prefix it uses before reading it.
        var table = List[UInt16](
            unsafe_uninit_length=_hash_table_size(min(size, _BLOCK_SIZE))
        )
        var src = data.unsafe_ptr()
        var pos = start
        var end = start + size
        while pos < end:
            var fragment = min(end - pos, _BLOCK_SIZE)
            var table_size = _hash_table_size(fragment)
            unsafe_memset_zero(table.unsafe_ptr(), table_size)
            op = _compress_fragment(
                src, pos, fragment, dst, op, table.unsafe_ptr(), table_size
            )
            pos += fragment
    if op > max_output_bytes:
        raise Error("Snappy encoded output exceeds limit")
    output.resize(op, fill=0)
    return output^


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
