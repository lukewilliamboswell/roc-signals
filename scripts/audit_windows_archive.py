#!/usr/bin/env python3
"""Inventory Windows archive imports and linker directives without extracting files.

This is review evidence, not an admission validator: a listed import need not be
reachable in the final executable, and an ordinary COFF member may contain code.
"""

import argparse
from collections import Counter
import hashlib
import json
from pathlib import Path
import struct


def members(data):
    """Walk regular COFF archives, rejecting truncated headers and payloads."""
    if not data.startswith(b"!<arch>\n"):
        raise ValueError("expected a regular COFF archive")
    offset = 8
    while offset < len(data):
        header = data[offset:offset + 60]
        if len(header) != 60 or header[58:] != b"`\n":
            raise ValueError("invalid archive member header")
        try:
            size = int(header[48:58])
        except ValueError as error:
            raise ValueError("invalid archive member size") from error
        if size < 0 or offset + 60 + size > len(data):
            raise ValueError("truncated archive member")
        name = header[:16].decode("ascii").strip()
        yield name, data[offset + 60:offset + 60 + size]
        offset += 60 + size
        if size % 2:
            if data[offset:offset + 1] != b"\n":
                raise ValueError("invalid archive member padding")
            offset += 1


def audit(data):
    """Report archive identity, imports and unmodified COFF directive strings.

    Unsupported object formats are counted explicitly. This does not claim that
    those members are implementation code, harmless, or covered by a license.
    """
    counts = Counter()
    dlls = Counter()
    directives = Counter()
    for name, payload in members(data):
        if name in ("/", "//"):
            counts["archive_tables"] += 1
            continue
        if len(payload) >= 20 and payload[:4] == b"\x00\x00\xff\xff" and payload[4:6] == b"\x00\x00":
            length = struct.unpack_from("<I", payload, 12)[0]
            if len(payload) != 20 + length:
                raise ValueError("invalid short import payload size")
            fields = payload[20:].split(b"\0")
            if len(fields) != 3 or fields[-1] or not all(fields[:2]):
                raise ValueError("unsupported short import names")
            dlls[fields[1].decode("ascii").lower()] += 1
            counts["short_imports"] += 1
            continue
        if len(payload) < 20 or payload[:2] != b"\x64\x86":
            counts["other_members"] += 1
            continue
        sections = struct.unpack_from("<H", payload, 2)[0]
        optional_size = struct.unpack_from("<H", payload, 16)[0]
        start = 20 + optional_size
        if start + sections * 40 > len(payload):
            raise ValueError("truncated COFF section table")
        counts["amd64_coff_members"] += 1
        for index in range(sections):
            section = payload[start + index * 40:start + (index + 1) * 40]
            size, pointer = struct.unpack_from("<II", section, 16)
            if section[:8] == b".drectve":
                if pointer + size > len(payload):
                    raise ValueError("truncated COFF directives")
                text = payload[pointer:pointer + size].decode("ascii").strip("\0 ")
                directives[text] += 1
    return {"schema_version": 1, "sha256": hashlib.sha256(data).hexdigest(),
            "size": len(data), "members": dict(sorted(counts.items())),
            "dll_import_records": dict(sorted(dlls.items())),
            "coff_directives": dict(sorted(directives.items()))}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("archive", type=Path)
    args = parser.parse_args()
    print(json.dumps(audit(args.archive.read_bytes()), indent=2, sort_keys=True))


if __name__ == "__main__":
    main()
