"""Raw Snappy compression and decompression in Mojo."""
from .codec import (
    encode_snappy,
    decode_snappy,
    decode_snappy_into,
    snappy_max_compressed_length,
)
