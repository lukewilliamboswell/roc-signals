#!/usr/bin/env python3
"""Regenerates the prepared "problem assets" root used by assets-problem.script.

This root deliberately disagrees with `assets/manifest.json` so one window shows
what verification does and does not decide:

  glyphs/folder.png  the shipped glyph plus a trailing tEXt chunk — a different
                     SHA-256, still a valid PNG, so folder rows keep their glyph
  glyphs/file.png    absent — verification reports it missing and the host, which
                     cannot resolve it, draws its neutral placeholder box on
                     every file row

Run from this directory: python3 generate.py
"""

import pathlib
import struct
import zlib

HERE = pathlib.Path(__file__).parent
SHIPPED = HERE.parent.parent / "assets"


def with_comment(png: bytes, comment: bytes) -> bytes:
    """Inserts an ancillary tEXt chunk before IEND: new bytes, same picture."""
    data = b"Comment\0" + comment
    chunk = struct.pack(">I", len(data)) + b"tEXt" + data
    chunk += struct.pack(">I", zlib.crc32(b"tEXt" + data))
    end = png.rindex(b"\x00\x00\x00\x00IEND")
    return png[:end] + chunk + png[end:]


def main():
    (HERE / "glyphs").mkdir(exist_ok=True)
    shipped = (SHIPPED / "glyphs/folder.png").read_bytes()
    altered = with_comment(shipped, b"altered but still a valid PNG")
    if altered == shipped:
        raise SystemExit("the altered glyph must differ from the shipped one")
    (HERE / "glyphs/folder.png").write_bytes(altered)
    (HERE / "glyphs/file.png").unlink(missing_ok=True)
    print("prepared", HERE)


if __name__ == "__main__":
    main()
