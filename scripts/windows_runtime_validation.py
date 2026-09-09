"""Inventory complete Zig UCRT imports and canonical COFF weak aliases.

UCRT alias objects are linker instructions, not CRT implementation code. This
validator deliberately refuses all other ordinary objects in a UCRT archive.
"""

from collections import Counter
import struct
import re
from audit_windows_archive import members


def ucrt_inventory(data):
    result = {'imports': {}, 'aliases': {}}
    helpers = Counter()
    descriptor_dlls = set()
    indexes = 0
    for name, body in members(data):
        if name in ('/', '//'):
            indexes += name == '/'
            continue
        if body[:6] == b'\0\0\xff\xff\0\0':
            if len(body) < 20:
                raise ValueError('truncated UCRT import')
            sig, marker, version, machine, timestamp, size, hint, flags = struct.unpack('<HHHHIIHH', body[:20])
            if (sig, marker, version, machine, timestamp) != (0, 65535, 0, 0x8664, 0) or flags not in (4, 5) or size != len(body) - 20:
                raise ValueError('unsupported UCRT import record')
            fields = body[20:].split(b'\0')
            if len(fields) != 3 or fields[-1] or not all(fields[:2]):
                raise ValueError('invalid UCRT import names')
            symbol, dll = [value.decode('ascii') for value in fields[:2]]
            if not re.fullmatch(r'[A-Za-z0-9_?@$]+', symbol) or not re.fullmatch(r'api-ms-win-crt-[a-z0-9-]+\.dll', dll.lower()):
                raise ValueError('unexpected UCRT identity')
            key = dll.lower() + '!' + symbol
            if key in result['imports']:
                raise ValueError('duplicate UCRT import')
            result['imports'][key] = {'flags': flags, 'hint': hint}
            continue
        if len(body) < 20:
            raise ValueError('truncated UCRT COFF object')
        machine, count, timestamp, pointer, symbols, optional, flags = struct.unpack('<HHIIIHH', body[:20])
        if (machine, timestamp, optional, flags) != (0x8664, 0, 0, 0) or 20 + count * 40 > len(body):
            raise ValueError('unexpected UCRT object')
        string_start = pointer + symbols * 18
        if pointer < 20 + count * 40 or string_start + 4 > len(body):
            raise ValueError('invalid UCRT symbol bounds')
        string_size = struct.unpack_from('<I', body, string_start)[0]
        if string_size < 4 or string_start + string_size != len(body):
            raise ValueError('invalid UCRT string bounds')
        sections = [struct.unpack_from('<8sIIIIIIHHI', body, 20 + 40 * i) for i in range(count)]
        if count == 1 and sections[0][0] == b'.drectve':
            if pointer != 60 or symbols != 5 or sections[0][1:9] != (0,) * 8 or sections[0][9] != 0xA00:
                raise ValueError('UCRT alias contains unexpected section payload')

            def symbol(index):
                name, value, section, kind, storage, auxiliary = struct.unpack_from('<8sIhHBB', body, pointer + index * 18)
                if name[:4] == bytes(4):
                    offset = struct.unpack('<I', name[4:])[0]
                    if offset < 4 or offset >= string_size:
                        raise ValueError('invalid alias name offset')
                    name = body[string_start + offset:].split(b'\0')[0]
                return name.rstrip(b'\0').decode('ascii'), value, section, kind, storage, auxiliary

            if symbol(0) != ('@comp.id', 0, -1, 0, 3, 0) or symbol(1) != ('@feat.00', 0, -1, 0, 3, 0):
                raise ValueError('unexpected alias metadata symbols')
            target, alias = symbol(2), symbol(3)
            if target[1:] != (0, 0, 0, 2, 0) or alias[1:] != (0, 0, 0, 105, 1):
                raise ValueError('unexpected alias symbol classes')
            if body[pointer + 72:pointer + 90] != struct.pack('<II', 2, 3) + bytes(10):
                raise ValueError('unsupported weak external policy')
            if alias[0] in result['aliases']:
                raise ValueError('duplicate UCRT alias')
            result['aliases'][alias[0]] = target[0]
            continue
        profile = []
        for section in sections:
            name, virtual, address, size, start, reloc, lines, reloc_count, line_count, characteristics = section
            name = name.rstrip(b'\0')
            if virtual or address or lines or line_count or characteristics & (0x20 | 0x20000000) or start < 20 + count * 40 or start + size > pointer:
                raise ValueError('implementation or malformed UCRT descriptor')
            payload = body[start:start + size]
            if name == b'.idata$6':
                if payload.count(b'\0') != 1 or not payload.endswith(b'\0'):
                    raise ValueError('invalid UCRT descriptor name')
                descriptor_dlls.add(payload[:-1].decode('ascii').lower())
            elif name in (b'.idata$2', b'.idata$3'):
                if payload != bytes(20):
                    raise ValueError('unexpected UCRT directory payload')
            elif name in (b'.idata$4', b'.idata$5'):
                if payload != bytes(8):
                    raise ValueError('unexpected UCRT thunk payload')
            else:
                raise ValueError('unexpected UCRT implementation section')
            if name == b'.idata$2':
                if reloc_count != 3 or reloc < start + size or reloc + 30 > pointer:
                    raise ValueError('invalid UCRT relocations')
                for position in range(3):
                    offset, symbol_index, kind = struct.unpack_from('<IIH', body, reloc + position * 10)
                    if offset + 4 > size or symbol_index >= symbols or kind != 3:
                        raise ValueError('invalid UCRT relocation target')
            elif reloc or reloc_count:
                raise ValueError('unexpected UCRT relocation')
            profile.append(name)
        helpers[tuple(profile)] += 1
    if indexes != 2 or helpers != Counter({(b'.idata$2', b'.idata$6'): 1, (b'.idata$3',): 1, (b'.idata$5', b'.idata$4'): 1}):
        raise ValueError('incomplete UCRT import infrastructure')
    dlls = {key.split('!', 1)[0] for key in result['imports']}
    if len(dlls) != 1 or descriptor_dlls != dlls:
        raise ValueError('UCRT archive must contain one DLL identity')
    return result
