"""Validate pure x64 import records and complete reviewed DLL inventories.

Only named CODE/DATA imports and canonical LLVM descriptor objects are accepted.
Implementation objects are never accepted as a system import dependency.
"""

from collections import Counter
import re
import struct

from audit_windows_archive import members


def short_import(body):
    """Decode the reviewed AMD64 named import format, rejecting extra payloads."""
    if len(body) < 20:
        raise ValueError("truncated import record")
    signature, marker, version, machine, timestamp, size, hint, flags = struct.unpack('<HHHHIIHH', body[:20])
    if (signature, marker, version, machine, timestamp) != (0, 65535, 0, 0x8664, 0) or flags not in (4, 5) or size != len(body) - 20:
        raise ValueError("unsupported import record header")
    fields = body[20:].split(b'\0')
    if len(fields) != 3 or fields[-1]:
        raise ValueError("malformed import record")
    symbol, dll = (field.decode('ascii') for field in fields[:2])
    if not re.fullmatch(r'[A-Za-z0-9_?@$]+', symbol) or not re.fullmatch(r'[A-Za-z0-9_.-]+', dll):
        raise ValueError("unsupported import identity")
    return dll.lower(), symbol, flags


def imports(data, *, pure=False):
    """Read compiler imports, optionally refusing every noncanonical helper."""
    result = {}
    helpers = []
    indexes = 0
    for name, body in members(data):
        if name in ('/', '//'):
            indexes += name == '/'
            continue
        if body[:6] == b'\0\0\xff\xff\0\0':
            dll, symbol, flags = short_import(body)
            previous = result.setdefault(dll, {}).setdefault(symbol, flags)
            if previous != flags:
                raise ValueError("conflicting import type")
        elif pure:
            helpers.append(body)
    if pure:
        if len(result) != 1 or len(helpers) != 3 or indexes != 2:
            raise ValueError("pure library requires one DLL and three descriptors")
        profiles = Counter(validate_helper(body, next(iter(result))) for body in helpers)
        if profiles != Counter({(b'.idata$2', b'.idata$6'): 1, (b'.idata$3',): 1, (b'.idata$5', b'.idata$4'): 1}):
            raise ValueError('incomplete descriptor infrastructure')
    return result


def validate_helper(body, dll):
    """Reject code, extra sections, malformed bounds and foreign DLL descriptors."""
    if len(body) < 20:
        raise ValueError('truncated COFF helper')
    machine, count, timestamp, symbols, symbol_count, optional, flags = struct.unpack('<HHIIIHH', body[:20])
    if (machine, timestamp, optional, flags) != (0x8664, 0, 0, 0) or 20 + count * 40 > len(body):
        raise ValueError('unsupported COFF helper')
    string_start = symbols + symbol_count * 18
    if symbols < 20 + count * 40 or string_start + 4 > len(body):
        raise ValueError('invalid COFF symbol bounds')
    string_size = struct.unpack_from('<I', body, string_start)[0]
    if string_size < 4 or string_start + string_size != len(body):
        raise ValueError('invalid COFF string bounds')
    sections = []
    for index in range(count):
        section = struct.unpack_from('<8sIIIIIIHHI', body, 20 + index * 40)
        name, virtual_size, address, size, pointer, reloc, lines, reloc_count, line_count, characteristics = section
        name = name.rstrip(b'\0')
        if virtual_size or address or characteristics & (0x20 | 0x20000000) or lines or line_count:
            raise ValueError('code or line data in import descriptor')
        if pointer < 20 + count * 40 or pointer + size > symbols or reloc_count and (reloc < pointer + size or reloc + reloc_count * 10 > symbols):
            raise ValueError('invalid descriptor data bounds')
        if not reloc_count and reloc:
            raise ValueError('unexpected relocation pointer')
        for position in range(reloc_count):
            offset, symbol, kind = struct.unpack_from('<IIH', body, reloc + position * 10)
            if offset + 4 > size or symbol >= symbol_count or kind != 3:
                raise ValueError('invalid descriptor relocation')
        payload = body[pointer:pointer + size]
        if name == b'.idata$6':
            if payload.lower() != dll.encode() + b'\0' or reloc_count:
                raise ValueError('foreign DLL descriptor')
        elif name == b'.idata$2':
            if payload != bytes(20) or reloc_count != 3:
                raise ValueError('invalid import directory')
        elif name == b'.idata$3':
            if payload != bytes(20) or reloc_count:
                raise ValueError('invalid null directory')
        elif name in (b'.idata$4', b'.idata$5'):
            if payload != bytes(8) or reloc_count:
                raise ValueError('invalid null thunk')
        else:
            raise ValueError('unexpected descriptor section')
        sections.append(name)
    if sections not in ([b'.idata$2', b'.idata$6'], [b'.idata$3'], [b'.idata$5', b'.idata$4']):
        raise ValueError('unexpected descriptor profile')
    return tuple(sections)


def merge(destination, source):
    """Union full source inventories without changing a symbol's import type."""
    for dll, symbols in source.items():
        for symbol, flags in symbols.items():
            previous = destination.setdefault(dll, {}).setdefault(symbol, flags)
            if previous != flags:
                raise ValueError(f'conflicting source import: {dll}!{symbol}')


def source_coverage(source, inventory):
    """Check every selected Windows declaration; rustc remains the generator.

    The pinned generated source uses one-line link macros in wrapper functions.
    Only an explicit x86-only wrapper excludes a declaration from x64 coverage.
    Any new macro form requires review, rather than silently skipping a record.
    """
    exclusions, aliases = [], []
    pattern = re.compile(r'windows_link::link!\("([^\"]+)" "[^\"]+" (?:"([^\"]+)" )?fn (\w+)')
    for path in sorted(source.rglob('*.rs')):
        lines = path.read_text().splitlines()
        for index, line in enumerate(lines):
            if 'windows_link::link!' not in line:
                continue
            match = pattern.search(line)
            if not match:
                raise ValueError(f'unsupported binding declaration: {path}:{index + 1}')
            dll, alias, symbol = match.groups()
            dll = dll.lower()
            if dll not in inventory:
                continue
            symbol = alias or symbol
            start = index
            while start and not lines[start - 1].startswith('}'):
                start -= 1
            context = '\n'.join(lines[start:index])
            identity = [path.relative_to(source).as_posix(), index + 1, dll, symbol]
            if '#[cfg(target_arch = "x86")]' in context:
                exclusions.append(identity)
            elif symbol not in inventory[dll]:
                raise ValueError(f'missing complete DLL declaration: {dll}!{symbol}')
            if alias:
                aliases.append(identity)
    return {'x86_only': exclusions, 'resolved_aliases': aliases}
