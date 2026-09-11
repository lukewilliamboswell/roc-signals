#!/usr/bin/env python3
"""Regenerates the prepared "problem assets" root used by the assets-problem scenario.

This root deliberately disagrees with `assets/manifest.json` in the three ways
a person can actually hit, so one window shows what verification does and does
not decide:

  avatars/maya.png  the shipped picture plus a trailing tEXt chunk — a different
                    SHA-256, still a valid PNG, so the host renders it
  avatars/jon.png   absent — verification reports it missing and the host, which
                    cannot resolve it, draws its neutral placeholder box
  avatars/sam.png   present but not an image at all — verification reports it
                    altered and the host, which cannot decode it, draws the
                    placeholder box

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
    (HERE / "avatars").mkdir(exist_ok=True)
    shipped = (SHIPPED / "avatars/maya.png").read_bytes()
    altered = with_comment(shipped, b"altered but still a valid PNG")
    if altered == shipped:
        raise SystemExit("the altered avatar must differ from the shipped one")
    (HERE / "avatars/maya.png").write_bytes(altered)
    (HERE / "avatars/sam.png").write_bytes(b"not a PNG at all\n")
    (HERE / "avatars/jon.png").unlink(missing_ok=True)
    print("prepared", HERE)


if __name__ == "__main__":
    main()
