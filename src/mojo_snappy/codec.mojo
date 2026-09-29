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


def _read_header(src: Span[UInt8, _], mut cursor: Int) raises -> Int:
    """Parse the varint32 decoded length at src[cursor:], advancing past it.

    Rejects truncated headers and values above 2**32 - 1.
    """
    var declared = UInt64(0)
    for i in range(5):
        if cursor >= len(src):
            raise Error("Truncated Snappy header")
        var byte = Int(src[cursor])
        cursor += 1
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


def uncompressed_length(src: Span[UInt8, _]) raises -> Int:
    """Return the decoded size advertised by a block header.

    Validates only the header, not the remaining block, and allocates
    nothing. The result is not evidence that the block is valid or that its
    size is safe to allocate.
    """
    var cursor = 0
    return _read_header(src, cursor)


def decompress(
    src: Span[UInt8, _], *, max_output_bytes: Int
) raises -> List[UInt8]:
    """Decode a complete raw Snappy block into a new List.

    Raises if the advertised size exceeds max_output_bytes (which must be
    nonnegative), if the block is malformed, or if it decodes to any size
    other than the advertised one. Output is allocated only for a size the
    input could actually produce, at most 64/3 bytes per compressed byte,
    so a header alone cannot force an allocation beyond that.
    """
    if max_output_bytes < 0:
        raise Error("Invalid Snappy output limit")
    var cursor = 0
    var size = _read_header(src, cursor)
    if size > max_output_bytes:
        raise Error("Snappy decoded output exceeds limit")
    # Every command byte decodes to at most 64/3 output bytes (a 3-byte
    # COPY_2 of length 64), so a larger size cannot be valid.
    if UInt64(size) * 3 > UInt64(len(src) - cursor) * 64:
        raise Error("Snappy declared length exceeds maximum expansion")
    var result = List[UInt8](unsafe_uninit_length=size)
    if (
        _decode_block(
            src.unsafe_ptr(), cursor, len(src), result.unsafe_ptr(), 0, size
        )
        != size
    ):
        raise Error("Snappy decoded length mismatch")
    return result^


def decompress_into(
    src: Span[UInt8, _], dst: Span[mut=True, UInt8, _]
) raises -> Int:
    """Decode a complete raw Snappy block into dst and return its size n.

    Requires uncompressed_length(src) <= len(dst). Writes only dst[:n]; bytes
    from dst[n:] are never written or read. Raises for malformed blocks and
    for any decoded size other than the advertised one, after which dst[:n]
    may hold arbitrary bytes. To require an exact size, pass a slice of that
    length and compare the result. src and dst must not overlap.
    """
    var cursor = 0
    var size = _read_header(src, cursor)
    if size > len(dst):
        raise Error("Snappy destination too small")
    if (
        _decode_block(
            src.unsafe_ptr(), cursor, len(src), dst.unsafe_ptr(), 0, size
        )
        != size
    ):
        raise Error("Snappy decoded length mismatch")
    return size


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


@always_inline
def _probe16(
    src: Pointer[UInt8, _],
    base: Int,
    ip: Int,
    table: Pointer[mut=True, UInt16, _],
    mask: UInt32,
    mut candidate: Int,
) -> Int:
    """Index and test positions ip..ip+15; return the first match or 16.

    Requires ip + 24 <= the fragment end (loads reach ip + 16 + 8). Every probed position is
    recorded in the table, as in Google Snappy's unrolled loop; a match at
    i leaves candidate at its earlier occurrence. Fully unrolled.
    """
    var data = _ld64(src, ip)
    comptime for j in range(4):
        comptime for k in range(4):
            comptime i = 4 * j + k
            var word = UInt32(data)
            var index = _table_index(word, mask)
            var found = base + Int(table[unsafe_offset=index])
            table[unsafe_offset=index] = UInt16(ip - base + i)
            if _ld32(src, found) == word:
                candidate = found
                return i
            data >>= 8
        data = _ld64(src, ip + 4 * j + 4)
    return 16


def _compress_fragment[
    table_size: Int
](
    src: Pointer[UInt8, _],
    base: Int,
    size: Int,
    dst: Pointer[mut=True, UInt8, _],
    var op: Int,
    table: Pointer[mut=True, UInt16, _],
    dynamic_table_size: Int,
) -> Int:
    """Compress src[base:base+size], size <= 64 KiB, starting at dst[op].

    Port of Google Snappy 1.2.2 CompressFragment (level 1): identical match
    choices and encodings, hence identical output. table holds table_size
    zeroed entries; each stores a position relative to base, so candidates
    stay in [base, ip) and offsets below 65536. dst needs
    32 + size + size / 6 bytes from op. See THIRD_PARTY_NOTICES.md.

    A nonzero table_size parameter fixes the table size at compile time
    (full 64 KiB fragments); zero uses dynamic_table_size.
    """
    var mask: UInt32
    comptime if table_size:
        mask = UInt32(2 * (table_size - 1))
    else:
        mask = UInt32(2 * (dynamic_table_size - 1))
    var ip = base
    var ip_end = base + size
    if size >= _INPUT_MARGIN:
        var ip_limit = ip_end - _INPUT_MARGIN
        while True:
            # Bytes in [next_emit, ip) are pending literal bytes.
            var next_emit = ip
            ip += 1
            # Little-endian bytes at ip; the match loop keeps it current.
            var data = UInt64(0)
            var skip = UInt32(32)
            var candidate = base
            var matched_early = False
            if ip_limit - ip >= 16:
                # Probe the next 16 positions densely before skipping.
                var i = _probe16(src, base, ip, table, mask, candidate)
                if i < 16:
                    # Literal of i + 1 <= 16 bytes, then the match.
                    dst[unsafe_offset=op] = UInt8(i << 2)
                    _copy16(dst, op + 1, src, next_emit)
                    ip += i
                    op += i + 2
                    matched_early = True
                if not matched_early:
                    ip += 16
                    skip += 16
            if not matched_early:
                data = _ld64(src, ip)
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


def max_compressed_length(source_length: Int) raises -> Int:
    """Worst-case compressed size for a source of 0..2**32 - 1 bytes.

    Matches Google Snappy's MaxCompressedLength: 32 + n + n / 6.
    """
    if source_length < 0 or UInt64(source_length) > UInt64(0xFFFFFFFF):
        raise Error("Invalid Snappy input size")
    return 32 + source_length + source_length // 6


def _compress_block(
    src: Span[UInt8, _], dst: Pointer[mut=True, UInt8, _]
) -> Int:
    """Compress src into dst, which has max_compressed_length(len(src)) bytes.

    Like Google Snappy's RawCompress, fragments write directly into dst and
    their bounded overwrites fit within that single worst-case bound.
    """
    var size = len(src)
    var op = 0
    var remaining = size
    while remaining >= 128:
        dst[unsafe_offset=op] = UInt8((remaining & 127) | 128)
        op += 1
        remaining >>= 7
    dst[unsafe_offset=op] = UInt8(remaining)
    op += 1
    if size == 0:
        return op
    # Each fragment clears the prefix it uses before reading it.
    var table = List[UInt16](
        unsafe_uninit_length=_hash_table_size(min(size, _BLOCK_SIZE))
    )
    var input = src.unsafe_ptr()
    var pos = 0
    while pos < size:
        var fragment = min(size - pos, _BLOCK_SIZE)
        var table_size = _hash_table_size(fragment)
        unsafe_memset_zero(table.unsafe_ptr(), table_size)
        if table_size == _MAX_HASH_TABLE_SIZE:
            op = _compress_fragment[_MAX_HASH_TABLE_SIZE](
                input, pos, fragment, dst, op, table.unsafe_ptr(), table_size
            )
        else:
            op = _compress_fragment[0](
                input, pos, fragment, dst, op, table.unsafe_ptr(), table_size
            )
        pos += fragment
    return op


def compress(src: Span[UInt8, _]) raises -> List[UInt8]:
    """Compress src into a new raw Snappy block.

    Raises only for sources longer than 2**32 - 1 bytes. The result's
    capacity is max_compressed_length(len(src)); its length is the block size.
    """
    var output = List[UInt8](
        unsafe_uninit_length=max_compressed_length(len(src))
    )
    var size = _compress_block(src, output.unsafe_ptr())
    output.resize(size, fill=0)
    return output^


def compress_into(
    src: Span[UInt8, _], dst: Span[mut=True, UInt8, _]
) raises -> Int:
    """Compress src into dst and return the block size.

    Requires len(dst) >= max_compressed_length(len(src)). Any byte of that
    worst-case prefix may be written; bytes beyond it are never touched.
    src and dst must not overlap.
    """
    if len(dst) < max_compressed_length(len(src)):
        raise Error("Snappy destination smaller than max_compressed_length")
    return _compress_block(src, dst.unsafe_ptr())
