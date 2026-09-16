"""Differential raw Snappy checks against Arrow and cramjam.

Run using pixi run -e oracle python. All generated blocks remain in build/.
"""
import json
from pathlib import Path
import random
import subprocess

import cramjam
import pyarrow as pa

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / "build/snappy-interop"
HARNESS = '''from std.sys import argv
from mojo_snappy import encode_snappy, decode_snappy

def main() raises:
    var args = argv()
    var source = open(args[2], "r")
    var size = Int(source.seek(0, 2))
    _ = source.seek(0)
    var data = source.read_bytes(size)
    var result: List[UInt8]
    if args[1] == "encode":
        result = encode_snappy(data, 32 + size + size // 6)
    else:
        result = decode_snappy(data, Int(args[4]))
    var output = open(args[3], "w")
    output.write_bytes(result)
'''


def main():
    OUT.mkdir(parents=True, exist_ok=True)
    harness = OUT / "codec_interop.mojo"
    harness.write_text(HARNESS)
    binary = OUT / "codec-interop"
    subprocess.run(["pixi", "run", "mojo", "build", "-O3", "-D", "ASSERT=all",
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
            stem = OUT / f"{size}-{label}"
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
    report = {"fixtures": count, "directions_per_fixture": 4,
              "seed": 932847, "pyarrow": pa.__version__,
              "cramjam": cramjam.__version__}
    (OUT / "results.json").write_text(json.dumps(report, indent=2) + "\n")
    print(json.dumps(report))


if __name__ == "__main__":
    main()
