#!/usr/bin/env python3
"""Regenerates the task-board avatar assets and their manifest.

The avatars are original works generated for this repository: a solid disc
in the app's AA palette with the assignee's initial in a 5x7 bitmap face.
Run from this directory: python3 generate.py
"""

import hashlib
import json
import pathlib
import struct
import zlib

SIZE = 64
RADIUS = 30.0

LETTERS = {
    "M": ["10001", "11011", "10101", "10101", "10001", "10001", "10001"],
    "J": ["00111", "00010", "00010", "00010", "00010", "10010", "01100"],
    "S": ["01110", "10001", "10000", "01110", "00001", "10001", "01110"],
}

# Disc and letter colors come from the examples' shared AA palette family.
AVATARS = {
    "maya": ("M", (0x2E, 0x6F, 0xA3), (0xF2, 0xF5, 0xF6)),
    "jon": ("J", (0x8F, 0xD4, 0xA8), (0x16, 0x25, 0x2C)),
    "sam": ("S", (0xE8, 0xC2, 0x7A), (0x16, 0x25, 0x2C)),
}


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


def avatar(letter, disc, ink):
    rows = LETTERS[letter]
    scale = 4
    glyph_w, glyph_h = 5 * scale, 7 * scale
    left = (SIZE - glyph_w) // 2
    top = (SIZE - glyph_h) // 2

    def pixel(x, y):
        centered = ((x + 0.5 - SIZE / 2) ** 2 + (y + 0.5 - SIZE / 2) ** 2) ** 0.5
        alpha = max(0.0, min(1.0, RADIUS - centered + 0.5))
        if alpha == 0.0:
            return (0, 0, 0, 0)
        column, row = (x - left) // scale, (y - top) // scale
        inked = 0 <= column < 5 and 0 <= row < 7 and rows[row][column] == "1"
        color = ink if inked else disc
        return (*color, round(alpha * 255))

    return png(SIZE, SIZE, pixel)


def main():
    here = pathlib.Path(__file__).parent
    (here / "avatars").mkdir(exist_ok=True)
    entries = []
    for name, (letter, disc, ink) in AVATARS.items():
        data = avatar(letter, disc, ink)
        relative = f"avatars/{name}.png"
        (here / relative).write_bytes(data)
        entries.append({"name": relative, "sha256": hashlib.sha256(data).hexdigest()})
    manifest = json.dumps({"assets": entries}, indent=1) + "\n"
    (here / "manifest.json").write_text(manifest)
    print(manifest, end="")


if __name__ == "__main__":
    main()
