"""Admit the deliberately narrow x64 import format emitted by pinned Zig.

This is not a general COFF reader. New definition syntax or object layouts need
review before a toolchain/recipe update can publish them. Format reference:
https://learn.microsoft.com/en-us/windows/win32/debug/pe-format
"""

from collections import Counter
import re
import struct


def definition_exports(text):
    """Read the complete preprocessed definition without ignoring unknown syntax."""
    lines = [line.split(";", 1)[0].strip() for line in text.splitlines()]
    lines = [line for line in lines if line]
    if len(lines) < 3 or not re.fullmatch(r'LIBRARY "[A-Za-z0-9_.-]+"', lines[0]) or lines[1] != "EXPORTS":
        raise ValueError("unsupported Windows definition header")
    dll = lines[0].split('"')[1]
    exports = {}
    for line in lines[2:]:
        match = re.fullmatch(r"([A-Za-z_][A-Za-z_0-9]*)\s*(?:@(\d+))?", line)
        if not match:
            raise ValueError(f"unsupported Windows export syntax: {line}")
        name, ordinal = match.groups()
        if name in exports:
            raise ValueError(f"duplicate Windows export: {name}")
        exports[name] = int(ordinal) if ordinal else 0
    return dll, exports


def archive_members(data):
    """Read bounded regular archive members; thin archives cannot be admitted."""
    if not data.startswith(b"!<arch>\n"):
        raise ValueError("expected regular COFF archive")
    offset = 8
    while offset < len(data):
        header = data[offset:offset + 60]
        if len(header) != 60 or header[58:] != b"`\n" or not header[48:58].strip().isdigit():
            raise ValueError("invalid COFF archive member header")
        size = int(header[48:58])
        start = offset + 60
        end = start + size
        if end + size % 2 > len(data) or (size % 2 and data[end:end + 1] != b"\n"):
            raise ValueError("truncated COFF archive member")
        yield header[:16].rstrip(), data[start:end]
        offset = end + size % 2


def validate_import_library(data, definition):
    """Reject implementation sections, foreign DLLs, and incomplete export sets.

    Only named x64 short imports and the three standard descriptor helpers are
    accepted. Hints (including explicit ordinals in the current definition) are
    checked too. This producer check supplements hashing and native link tests;
    it does not replace consumers' provenance verification.
    """
    dll, expected = definition_exports(definition)
    found = {}
    helpers = Counter()
    indexes = 0
    for member_name, body in archive_members(data):
        if member_name == b"/":
            indexes += 1
            continue
        if member_name != (dll + "/").encode():
            raise ValueError("unexpected Windows import archive member")
        if len(body) < 20:
            raise ValueError("truncated COFF object")
        if body[:4] == b"\0\0\xff\xff":
            _, _, version, machine, timestamp, size, hint, flags = struct.unpack("<HHHHIIHH", body[:20])
            if (version, machine, timestamp, flags) != (0, 0x8664, 0, 4) or size != len(body) - 20:
                raise ValueError("unsupported Windows short import")
            fields = body[20:].split(b"\0")
            if len(fields) != 3 or fields[1] != dll.encode() or fields[2]:
                raise ValueError("foreign DLL or malformed Windows import")
            name = fields[0].decode("ascii")
            if name in found:
                raise ValueError("duplicate Windows short import")
            found[name] = hint
            continue
        machine, sections, timestamp, symbols_at, symbols, optional, flags = struct.unpack("<HHIIIHH", body[:20])
        if (machine, timestamp, optional, flags) != (0x8664, 0, 0, 0) or sections not in (1, 2):
            raise ValueError("unsupported Windows import helper")
        table_end = 20 + 40 * sections
        strings_at = symbols_at + 18 * symbols
        if table_end > symbols_at or strings_at + 4 > len(body):
            raise ValueError("invalid Windows helper symbol table")
        strings_size = struct.unpack_from("<I", body, strings_at)[0]
        if strings_size < 4 or strings_at + strings_size != len(body):
            raise ValueError("invalid Windows helper string table")
        names = []
        for index in range(sections):
            section = struct.unpack_from("<8sIIIIIIHHI", body, 20 + 40 * index)
            name, virtual_size, address, size, start, relocations, line_numbers, reloc_count, line_count, characteristics = section
            name = name.rstrip(b"\0")
            if (virtual_size or address or line_numbers or line_count or
                    characteristics & (0x20 | 0x20000000) or name not in
                    (b".idata$2", b".idata$3", b".idata$4", b".idata$5", b".idata$6")):
                raise ValueError("implementation section in Windows import library")
            if start < table_end or start + size > symbols_at:
                raise ValueError("invalid Windows helper section bounds")
            payload = body[start:start + size]
            expected_payload = dll.encode() + b"\0" if name == b".idata$6" else bytes(20 if name in (b".idata$2", b".idata$3") else 8)
            if payload != expected_payload:
                raise ValueError("unexpected Windows helper section payload")
            if name == b".idata$2":
                if reloc_count != 3 or relocations < start + size or relocations + 30 > symbols_at:
                    raise ValueError("invalid Windows descriptor relocations")
            elif reloc_count or relocations:
                raise ValueError("unexpected Windows helper relocations")
            names.append(name)
        helpers[tuple(names)] += 1
    if indexes != 2 or helpers != Counter({(b".idata$2", b".idata$6"): 1, (b".idata$3",): 1, (b".idata$5", b".idata$4"): 1}):
        raise ValueError("incomplete Windows import infrastructure")
    if found != expected:
        raise ValueError("Windows imports do not match the complete DLL definition")
    return len(found)
