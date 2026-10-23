"""Compress and restore a small byte sequence."""
from std.testing import assert_equal
from mojo_snappy import (
    compress,
    compress_into,
    decompress,
    decompress_into,
    max_compressed_length,
)


def main() raises:
    var original = List[UInt8](length=1000, fill=42)
    var compressed = compress(original)
    var restored = decompress(compressed, max_output_bytes=4096)
    assert_equal(restored, original)
    # Reuse caller-owned buffers: slices select the region to use.
    var packed = List[UInt8](
        length=max_compressed_length(len(original)), fill=0
    )
    var packed_size = compress_into(original, packed)
    var scratch = List[UInt8](length=len(original), fill=0)
    _ = decompress_into(packed[:packed_size], scratch)
    assert_equal(scratch, original)
    print(
        len(original),
        "bytes ->",
        len(compressed),
        "bytes ->",
        len(restored),
        "bytes",
    )
