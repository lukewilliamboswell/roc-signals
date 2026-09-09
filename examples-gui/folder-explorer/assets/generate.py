#!/usr/bin/env python3
"""Regenerates the folder-explorer glyph assets and their manifest.

The glyphs are original works generated for this repository: a folder and a
file page drawn as flat shapes in the app's AA palette.
Run from this directory: python3 generate.py
"""

import hashlib
import json
import pathlib
import struct
import zlib

SIZE = 32

AMBER = (0xE8, 0xC2, 0x7A)
AMBER_DEEP = (0xC9, 0x9E, 0x52)
PAGE = (0xA9, 0xBF, 0xCC)
PAGE_DEEP = (0x7E, 0x96, 0xA5)


def png(width, height, pixel):
    rows = b"".join(
        b"\0" + b"".join(bytes(pixel(x, y)) for x in range(width)) for y in range(height)
    )

    def chunk(tag, data):
        return struct.pack(">I", len(data)) + tag + data + struct.pack(">I", zlib.crc32(tag + data))

    return (
        b"\x89PNG\r\n\x1a\n"
        + chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 6, 0, 0, 0))
        + chunk(b"IDAT", zlib.compress(rows, 9))
        + chunk(b"IEND", b"")
    )


def folder(x, y):
    tab = 4 <= y < 9 and 3 <= x < 15
    body = 9 <= y < 27 and 2 <= x < 30
    if not (tab or body):
        return (0, 0, 0, 0)
    lid = 9 <= y < 12
    return (*(AMBER_DEEP if lid or tab else AMBER), 255)


def file_page(x, y):
    fold = 8
    if not (3 <= y < 29 and 7 <= x < 25):
        return (0, 0, 0, 0)
    # Cut the folded corner off the page's top right.
    if y - 3 < fold and x - 7 >= 18 - (y - 3):
        past_fold = (x - 7) + (y - 3) >= 18 + fold
        if past_fold:
            return (0, 0, 0, 0)
        return (*PAGE_DEEP, 255)
    # Three rule lines suggest text.
    if x in range(10, 22) and y in (13, 17, 21):
        return (*PAGE_DEEP, 255)
    return (*PAGE, 255)


def main():
    here = pathlib.Path(__file__).parent
    (here / "glyphs").mkdir(exist_ok=True)
    entries = []
    for name, pixel in (("folder", folder), ("file", file_page)):
        data = png(SIZE, SIZE, pixel)
        relative = f"glyphs/{name}.png"
        (here / relative).write_bytes(data)
        entries.append({"name": relative, "sha256": hashlib.sha256(data).hexdigest()})
    manifest = json.dumps({"assets": entries}, indent=1) + "\n"
    (here / "manifest.json").write_text(manifest)
    print(manifest, end="")


if __name__ == "__main__":
    main()
