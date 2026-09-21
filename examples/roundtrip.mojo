"""Compress and restore a small byte sequence."""
from std.testing import assert_equal
from mojo_snappy import (
    compress,
    decompress,
    decode_snappy_into,
)


def main() raises:
    var original = List[UInt8](length=1000, fill=42)
    var compressed = compress(original)
    var restored = decompress(compressed, max_output_bytes=4096)
    assert_equal(restored, original)
    # Reuse initialized storage without allocating a new decoded list.
    var scratch = List[UInt8](length=len(original), fill=0)
    _ = decode_snappy_into(compressed, scratch, len(original))
    assert_equal(scratch, original)
    print(
        len(original),
        "bytes ->",
        len(compressed),
        "bytes ->",
        len(restored),
        "bytes",
    )
