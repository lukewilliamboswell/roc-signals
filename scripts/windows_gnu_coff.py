"""Candidate-only COFF import separation, preserving every implementation byte.

The accepted descriptor templates are LLVM COFF import-library records: zero
import-descriptor/thunk sections, their exact relocations, and linker symbols.
No archive-member name or private hash allowlist authorizes removal.
"""
import hashlib
from pathlib import Path
import struct
import subprocess


def identity(data):
    return {"sha256": hashlib.sha256(data).hexdigest(), "size": len(data)}


def members(data):
    if not data.startswith(b"!<arch>\n"):
        raise ValueError("expected regular archive")
    offset = 8
    while offset < len(data):
        header = data[offset:offset + 60]
        if len(header) != 60 or header[58:] != b"`\n":
            raise ValueError("invalid archive header")
        size = int(header[48:58])
        if size < 0 or offset + 60 + size > len(data):
            raise ValueError("invalid archive size")
        yield header[:16].decode().strip(), data[offset + 60:offset + 60 + size]
        offset += 60 + size
        if size % 2:
            if data[offset:offset + 1] != b"\n":
                raise ValueError("invalid archive padding")
            offset += 1


def coff(data):
    if len(data) < 20:
        raise ValueError("truncated COFF header")
    machine, count, stamp, symbol_at, symbol_count, optional, flags = struct.unpack_from('<HHIIIHH', data)
    if machine != 0x8664 or optional or 20 + 40 * count > len(data):
        raise ValueError("unsupported COFF object")
    strings_at = symbol_at + 18 * symbol_count
    if strings_at + 4 > len(data):
        raise ValueError("truncated COFF symbols")
    length = struct.unpack_from('<I', data, strings_at)[0]
    if length < 4 or strings_at + length != len(data):
        raise ValueError("invalid COFF strings")
    strings = data[strings_at:]
    def string(offset):
        if not 4 <= offset < len(strings) or b'\0' not in strings[offset:]:
            raise ValueError("invalid COFF string offset")
        return strings[offset:].split(b'\0')[0].decode('ascii')
    sections = []
    for i in range(count):
        values = struct.unpack_from('<8sIIIIIIHHI', data, 20 + i * 40)
        name = values[0].rstrip(b'\0').decode('ascii')
        if name.startswith('/'):
            name = string(int(name[1:]))
        sections.append((name, *values[1:]))
    return (machine, count, stamp, symbol_at, symbol_count, optional, flags), sections, string


def classify(data, inventory):
    """Return removable import evidence or None for an ordinary implementation."""
    if data[:6] == b'\0\0\xff\xff\0\0':
        if len(data) < 20:
            raise ValueError('truncated short import')
        values = struct.unpack_from('<HHHHIIHH', data)
        if values[:7] != (0, 65535, 0, 0x8664, 0, len(data) - 20, 0):
            raise ValueError('unsupported short import header')
        names = data[20:].split(b'\0')
        if len(names) != 3 or names[-1]:
            raise ValueError('unsupported import names')
        symbol, dll = [n.decode('ascii') for n in names[:2]]
        if inventory.get(dll.lower(), {}).get(symbol) != values[7]:
            raise ValueError('import missing or differently typed in complete provider inventory')
        return {'kind': 'short-import', 'dll': dll, 'symbol': symbol, 'type': values[7]}
    header, sections, string = coff(data)
    if not any(s[0].startswith('.idata') for s in sections):
        return None
    _, count, stamp, symbol_at, symbol_count, _, flags = header
    if stamp or flags:
        raise ValueError('noncanonical import helper header')
    symbols = []
    for i in range(symbol_count):
        record = data[symbol_at + 18 * i:symbol_at + 18 * (i + 1)]
        name = string(struct.unpack_from('<I', record, 4)[0]) if record[:4] == bytes(4) else record[:8].rstrip(b'\0').decode('ascii')
        symbols.append((name, *struct.unpack_from('<IhHBB', record, 8)))
    stems = {Path(dll).stem for dll in inventory}
    names = [s[0] for s in sections]
    if names == ['.idata$2', '.idata$6']:
        dll = data[150:symbol_at]
        if not dll.endswith(b'\0') or dll[:-1].decode('ascii').lower() not in inventory:
            raise ValueError('descriptor provider is not inventoried')
        stem = Path(dll[:-1].decode('ascii')).stem
        expected_sections = [('.idata$2', 0, 0, 20, 100, 120, 0, 3, 0, 0xc0300040),
                             ('.idata$6', 0, 0, len(dll), 150, 0, 0, 0, 0, 0xc0200040)]
        null = symbols[5][0] if len(symbols) == 7 else ''
        if null not in ('__NULL_IMPORT_DESCRIPTOR', '__NULL_IMPORT_DESCRIPTOR_' + stem):
            raise ValueError('unexpected null descriptor reference')
        expected_symbols = [('__IMPORT_DESCRIPTOR_' + stem, 0, 1, 0, 2, 0),
                            ('.idata$2', 0, 1, 0, 104, 0), ('.idata$6', 0, 2, 0, 3, 0),
                            ('.idata$4', 0, 0, 0, 104, 0), ('.idata$5', 0, 0, 0, 104, 0),
                            (null, 0, 0, 0, 2, 0), ('\x7f' + stem + '_NULL_THUNK_DATA', 0, 0, 0, 2, 0)]
        if data[100:120] != bytes(20) or data[120:150] != b''.join(struct.pack('<IIH', *r) for r in [(12, 2, 3), (0, 3, 3), (16, 4, 3)]):
            raise ValueError('descriptor contains noncanonical data or relocations')
    elif names == ['.idata$3']:
        name = symbols[0][0] if len(symbols) == 1 else ''
        if name != '__NULL_IMPORT_DESCRIPTOR' and (not name.startswith('__NULL_IMPORT_DESCRIPTOR_')
                or name.removeprefix('__NULL_IMPORT_DESCRIPTOR_') not in stems):
            raise ValueError('unknown null descriptor provider')
        expected_sections = [('.idata$3', 0, 0, 20, 60, 0, 0, 0, 0, 0xc0300040)]
        expected_symbols = [(name, 0, 1, 0, 2, 0)]
        if symbol_at != 80 or data[60:80] != bytes(20):
            raise ValueError('nonempty null descriptor')
    elif names == ['.idata$5', '.idata$4']:
        name = symbols[0][0] if len(symbols) == 1 else ''
        if name not in {'\x7f' + stem + '_NULL_THUNK_DATA' for stem in stems}:
            raise ValueError('unknown null thunk provider')
        expected_sections = [('.idata$5', 0, 0, 8, 100, 0, 0, 0, 0, 0xc0400040),
                             ('.idata$4', 0, 0, 8, 108, 0, 0, 0, 0, 0xc0400040)]
        expected_symbols = [(name, 0, 1, 0, 2, 0)]
        if symbol_at != 116 or data[100:116] != bytes(16):
            raise ValueError('nonempty null thunk')
    else:
        raise ValueError('mixed or unknown import helper object')
    if sections != expected_sections or symbols != expected_symbols:
        raise ValueError('import helper sections or symbols differ from structural contract')
    return {'kind': 'structural-import-helper', 'sections': names}


def separate(source, output, inventory, zig):
    raw = source.read_bytes()
    kept, removed = [], []
    for index, (name, data) in enumerate(members(raw)):
        if name in ('/', '//'):
            continue
        classification = classify(data, inventory)
        record = {'index': index, 'sha256': identity(data)['sha256']}
        if classification is not None:
            removed.append(dict(record, **classification))
        else:
            kept.append((record, data))
    with output.open('xb') as stream:
        stream.write(b'!<arch>\n')
        for record, data in kept:
            name = (str(record['index']) + '.obj/').encode()
            header = name.ljust(16) + b'0'.ljust(12) + b'0'.ljust(6) + b'0'.ljust(6) + b'644'.ljust(8) + str(len(data)).encode().ljust(10) + b'`\n'
            if len(header) != 60:
                raise ValueError('archive member index too long')
            stream.write(header + data + (b'\n' if len(data) % 2 else b''))
    subprocess.run([str(zig), 'ar', 's', str(output)], check=True)
    after = [identity(data)['sha256'] for name, data in members(output.read_bytes()) if name not in ('/', '//')]
    if after != [record['sha256'] for record, data in kept]:
        raise ValueError('implementation bytes or order changed')
    return {'schema_version': 1, 'candidate_only': True, 'input': identity(raw),
            'output': identity(output.read_bytes()), 'removed': removed,
            'retained': [record for record, data in kept], 'index_tool': identity(Path(zig).read_bytes())}
