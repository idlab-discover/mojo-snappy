"""Differential raw Snappy checks against Arrow and cramjam.

Run using pixi run -e oracle python. All generated blocks remain in build/.
"""
import argparse
import json
from pathlib import Path
import random
import subprocess

import cramjam
import pyarrow as pa

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / "build/snappy-interop"
HARNESS = '''from std.sys import argv
from mojo_snappy import encode_snappy, decode_snappy, decode_snappy_into, compress, decompress, uncompressed_length

def main() raises:
    var args = argv()
    var source = open(args[2], "r")
    var size = Int(source.seek(0, 2))
    _ = source.seek(0)
    var data = source.read_bytes(size)
    var result: List[UInt8]
    if args[1] == "encode":
        result = compress(data)
        if result != encode_snappy(data, 32 + size + size // 6):
            raise Error("compress changed encoded bytes")
    else:
        result = decompress(data, max_output_bytes=Int(args[4]))
        if uncompressed_length(data) != Int(args[4]) or result != decode_snappy(data, Int(args[4])):
            raise Error("decompress disagrees with exact-size decoder")
        var destination = List[UInt8](length=len(result) + 10, fill=179)
        if decode_snappy_into(data, destination, len(result), 0, 5) != len(result):
            raise Error("decode-into length mismatch")
        for i in range(len(result)):
            if destination[5 + i] != result[i]:
                raise Error("decode-into byte mismatch")
        for i in range(5):
            if destination[i] != 179 or destination[5 + len(result) + i] != 179:
                raise Error("decode-into changed destination boundary")
    var output = open(args[3], "w")
    output.write_bytes(result)
'''


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--assertions", choices=("all", "none"), default="all")
    args = parser.parse_args()
    out = OUT / args.assertions
    out.mkdir(parents=True, exist_ok=True)
    harness = out / "codec_interop.mojo"
    harness.write_text(HARNESS)
    binary = out / "codec-interop"
    subprocess.run(["pixi", "run", "mojo", "build", "-O3", "-D", f"ASSERT={args.assertions}",
                    "-I", "src", str(harness), "-o", str(binary)], cwd=ROOT, check=True)
    rng = random.Random(932847)
    codec = pa.Codec("snappy")
    count = 0
    sizes = [0, 1, 3, 4, 59, 60, 61, 127, 128, 255, 256, 257,
             2047, 2048, 65535, 65536, 100000, 262144]
    for size in sizes:
        for label, data in [
            ("random", rng.randbytes(size)),
            ("constant", b"x" * size),
            ("cycle", (bytes(range(251)) * (size // 251 + 1))[:size]),
            ("mixed", bytes(rng.randrange(8) for _ in range(size))),
        ]:
            stem = out / f"{size}-{label}"
            raw = stem.with_suffix(".raw")
            native = stem.with_suffix(".native")
            decoded = stem.with_suffix(".decoded")
            raw.write_bytes(data)
            subprocess.run([str(binary), "encode", str(raw), str(native)], check=True)
            encoded = native.read_bytes()
            assert bytes(codec.decompress(encoded, size)) == data
            assert bytes(cramjam.snappy.decompress_raw(encoded)) == data
            for name, external in [
                ("arrow", bytes(codec.compress(data))),
                ("cramjam", bytes(cramjam.snappy.compress_raw(data))),
            ]:
                reference = stem.with_suffix(f".{name}")
                reference.write_bytes(external)
                subprocess.run([str(binary), "decode", str(reference),
                                str(decoded), str(size)], check=True)
                assert decoded.read_bytes() == data, (size, label, name)
            count += 1
    report = {"assertions": args.assertions, "fixtures": count, "directions_per_fixture": 4,
              "seed": 932847, "pyarrow": pa.__version__,
              "cramjam": cramjam.__version__}
    (out / "results.json").write_text(json.dumps(report, indent=2) + "\n")
    print(json.dumps(report))


if __name__ == "__main__":
    main()
