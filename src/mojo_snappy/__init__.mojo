"""Raw Snappy compression and decompression in Mojo."""
from .codec import (
    compress,
    compress_into,
    decompress,
    decompress_into,
    max_compressed_length,
    uncompressed_length,
)
