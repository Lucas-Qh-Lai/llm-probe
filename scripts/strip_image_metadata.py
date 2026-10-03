#!/usr/bin/env python3
"""Removes text/EXIF chunks from PNG files without touching a single pixel.

`screencapture` embeds an XMP block (``iTXt``/``tEXt``) with the capture tool and
timestamps. Documentation screenshots are published, so the metadata is stripped
before the files are committed. Pure standard library: no Pillow dependency.

Usage:
    python3 scripts/strip_image_metadata.py docs/images/*.png
"""

from __future__ import annotations

import struct
import sys

PNG_SIGNATURE = b"\x89PNG\r\n\x1a\n"
# Ancillary chunks that can carry text, EXIF or timestamps.
DROP = {b"tEXt", b"zTXt", b"iTXt", b"eXIf", b"tIME", b"dSIG"}


def strip(path: str) -> tuple[int, int]:
    data = open(path, "rb").read()
    if not data.startswith(PNG_SIGNATURE):
        raise ValueError(f"{path} is not a PNG file")

    out = bytearray(PNG_SIGNATURE)
    pos = len(PNG_SIGNATURE)
    dropped = 0
    kept = 0
    while pos + 8 <= len(data):
        length = struct.unpack(">I", data[pos : pos + 4])[0]
        kind = data[pos + 4 : pos + 8]
        end = pos + 12 + length
        if end > len(data):
            raise ValueError(f"{path} is truncated")
        if kind in DROP:
            dropped += 1
        else:
            out += data[pos:end]
            kept += 1
        pos = end
        if kind == b"IEND":
            break

    if dropped:
        open(path, "wb").write(bytes(out))
    return kept, dropped


def main(argv: list[str]) -> int:
    if not argv:
        print(__doc__, file=sys.stderr)
        return 2
    total = 0
    for path in argv:
        kept, dropped = strip(path)
        total += dropped
        state = "clean" if dropped == 0 else f"stripped {dropped} metadata chunk(s)"
        print(f"{path}: {state}, {kept} chunks kept")
    if total == 0:
        print("nothing to strip")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
