"""Raw Snappy compression and decompression in Mojo."""
from .codec import (
    compress,
    decompress,
    uncompressed_length,
    encode_snappy,
    decode_snappy,
    decode_snappy_into,
    snappy_max_compressed_length,
)
