"""Structural helper rejection tests; no opaque object hashes authorize removal."""
import struct
import unittest
import tempfile
from pathlib import Path
from unittest.mock import patch
from windows_gnu_coff import classify, identity, separate, validate_separation


def null_descriptor(name='__NULL_IMPORT_DESCRIPTOR_kernel32'):
    strings = name.encode() + b'\0'
    return (struct.pack('<HHIIIHH', 0x8664, 1, 0, 80, 1, 0, 0)
            + struct.pack('<8sIIIIIIHHI', b'.idata$3', 0, 0, 20, 60, 0, 0, 0, 0, 0xc0300040)
            + bytes(20) + struct.pack('<IIIhHBB', 0, 4, 0, 1, 0, 2, 0)
            + struct.pack('<I', len(strings) + 4) + strings)


def descriptor():
    dll = b'kernel32.dll\0'
    names = ['__IMPORT_DESCRIPTOR_kernel32', '.idata$2', '.idata$6',
             '.idata$4', '.idata$5', '__NULL_IMPORT_DESCRIPTOR_kernel32',
             '\x7fkernel32_NULL_THUNK_DATA']
    strings = bytearray(4)
    records = bytearray()
    for name, section, storage in zip(names, [1, 1, 2, 0, 0, 0, 0], [2, 104, 3, 104, 104, 2, 2]):
        offset = len(strings)
        strings.extend(name.encode() + b'\0')
        records.extend(struct.pack('<IIIhHBB', 0, offset, 0, section, 0, storage, 0))
    struct.pack_into('<I', strings, 0, len(strings))
    return (struct.pack('<HHIIIHH', 0x8664, 2, 0, 150 + len(dll), 7, 0, 0)
            + struct.pack('<8sIIIIIIHHI', b'.idata$2', 0, 0, 20, 100, 120, 0, 3, 0, 0xc0300040)
            + struct.pack('<8sIIIIIIHHI', b'.idata$6', 0, 0, len(dll), 150, 0, 0, 0, 0, 0xc0200040)
            + bytes(20) + b''.join(struct.pack('<IIH', *r) for r in [(12, 2, 3), (0, 3, 3), (16, 4, 3)])
            + dll + records + strings)


class StructuralTests(unittest.TestCase):
    inventory = {'kernel32.dll': {'Sleep': 4}}

    def test_short_import_requires_provider_symbol_and_type(self):
        names = b'Sleep\0kernel32.dll\0'
        data = struct.pack('<HHHHIIHH', 0, 65535, 0, 0x8664, 0, len(names), 0, 4) + names
        self.assertEqual(classify(data, self.inventory)['kind'], 'short-import')
        for inventory in ({}, {'kernel32.dll': {'Other': 4}}, {'kernel32.dll': {'Sleep': 5}}):
            with self.assertRaises(ValueError):
                classify(data, inventory)

    def test_null_descriptor_requires_zero_payload_and_exact_symbol(self):
        valid = null_descriptor()
        self.assertEqual(classify(valid, self.inventory)['kind'], 'structural-import-helper')
        for data in (null_descriptor('kernel32'), null_descriptor('__NULL_IMPORT_DESCRIPTOR_unknown')):
            with self.assertRaises(ValueError):
                classify(data, self.inventory)
        for offset in (60, 56, 8, 92, 94, 96, 97):
            changed = bytearray(valid)
            changed[offset] ^= 1
            with self.subTest(offset=offset), self.assertRaises((ValueError, UnicodeDecodeError)):
                classify(bytes(changed), self.inventory)

    def test_descriptor_relocations_and_symbol_classes_are_exact(self):
        data = descriptor()
        self.assertEqual(classify(data, self.inventory)['kind'], 'structural-import-helper')
        # A descriptor pointing at a different symbol, relocation kind, payload,
        # or executable section must never authorize discarding an object.
        for offset in (100, 124, 128, 138, 56, 179):
            changed = bytearray(data)
            changed[offset] ^= 1
            with self.subTest(offset=offset), self.assertRaises(ValueError):
                classify(bytes(changed), self.inventory)

    def test_mixed_import_and_implementation_is_not_removable(self):
        data = bytearray(null_descriptor())
        data[20:28] = b'.idata$7'
        with self.assertRaises(ValueError):
            classify(bytes(data), self.inventory)
        # Ordinary code remains an implementation even if member names resemble helpers.
        data[20:28] = b'.text\0\0\0'
        self.assertIsNone(classify(bytes(data), self.inventory))


class ReceiptTests(unittest.TestCase):
    def test_output_and_raw_ledgers_reject_substitution(self):
        code = bytearray(null_descriptor())
        code[20:28] = b'.text\0\0\0'
        payloads = [bytes(code), null_descriptor()]
        archive = bytearray(b'!<arch>\n')
        for index, body in enumerate(payloads):
            archive.extend((str(index) + '.o/').encode().ljust(16) + b'0'.ljust(12)
                           + b'0'.ljust(6) + b'0'.ljust(6) + b'644'.ljust(8)
                           + str(len(body)).encode().ljust(10) + b'`\n' + body)
            if len(body) % 2:
                archive.extend(b'\n')
        with tempfile.TemporaryDirectory() as temporary:
            raw, final = Path(temporary) / 'raw.a', Path(temporary) / 'final.a'
            raw.write_bytes(archive)
            with patch('windows_gnu_coff.subprocess.run'):
                receipt = separate(raw, final, StructuralTests.inventory, Path(__file__))
            validate_separation(receipt, final.read_bytes(), raw=raw.read_bytes(), inventory=StructuralTests.inventory)
            receipt['removed'][0]['kind'] = 'unvalidated'
            with self.assertRaises(ValueError):
                validate_separation(receipt, final, raw=raw, inventory=StructuralTests.inventory)
            changed = bytearray(final.read_bytes())
            changed[-2] ^= 1
            final.write_bytes(changed)
            receipt['output'] = identity(changed)
            with self.assertRaises(ValueError):
                validate_separation(receipt, final)
