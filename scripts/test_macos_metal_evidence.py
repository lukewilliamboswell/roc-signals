"""Fresh shader evidence must bind actual outputs and the selected compiler."""

import copy
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

import macos_metal_evidence as metal


class MetalEvidenceTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.target = self.root / 'fresh-target'
        self.target.mkdir()
        self.shader = self.root / 'gpui/src/platform/mac/shaders.metal'
        self.shader.parent.mkdir(parents=True)
        self.shader.write_text('original GPUI shader')
        self.tool = self.root / 'metal'
        self.tool.write_bytes(b'compiler identity')
        self.metadata = {'packages': [{'name': 'gpui', 'version': '0.2.2',
                                       'manifest_path': str(self.root / 'gpui/Cargo.toml')}]}
        for name in ('shaders.h', 'shaders.air', 'shaders.metallib'):
            (self.target / name).write_bytes(name.encode())
        common = {'tool_file': metal.file_record(self.tool), 'resolved_tool': str(self.tool),
                  'xcrun_log': 'executing ' + str(self.tool), 'version': {'output': 'version 1'}, 'returncode': 0}
        self.records = [dict(common, tool='metal',
                        inputs={'shader': metal.file_record(self.shader),
                                'generated_header': metal.file_record(self.target / 'shaders.h')},
                        output=metal.file_record(self.target / 'shaders.air')),
                        dict(common, tool='metallib', inputs={'air': metal.file_record(self.target / 'shaders.air')},
                             output=metal.file_record(self.target / 'shaders.metallib'))]

    def test_only_complete_fresh_chain_is_accepted(self):
        self.assertEqual(set(metal.validate_invocations(self.records, self.metadata, self.target)), {'metal', 'metallib'})
        for records in ([], self.records[:1], self.records + self.records[:1]):
            with self.assertRaisesRegex(ValueError, 'fresh metal'):
                metal.validate_invocations(records, self.metadata, self.target)

    def test_unlogged_compiler_and_changed_outputs_are_rejected(self):
        records = copy.deepcopy(self.records)
        records[0]['xcrun_log'] = 'some other compiler'
        with self.assertRaisesRegex(ValueError, 'execution log'):
            metal.validate_invocations(records, self.metadata, self.target)
        (self.target / 'shaders.metallib').write_bytes(b'replaced')
        with self.assertRaisesRegex(ValueError, 'outside the fresh target or changed'):
            metal.validate_invocations(self.records, self.metadata, self.target)

    def test_wrong_shader_and_broken_air_chain_are_rejected(self):
        records = copy.deepcopy(self.records)
        records[0]['inputs']['shader']['sha256'] = '0' * 64
        with self.assertRaisesRegex(ValueError, 'selected Cargo'):
            metal.validate_invocations(records, self.metadata, self.target)
        records = copy.deepcopy(self.records)
        records[1]['inputs']['air']['sha256'] = '0' * 64
        with self.assertRaisesRegex(ValueError, 'recorded Metal output'):
            metal.validate_invocations(records, self.metadata, self.target)

    def test_existing_compiler_output_cannot_be_relabelled_as_fresh(self):
        with patch.object(metal, 'output', return_value=str(self.tool)):
            with self.assertRaisesRegex(ValueError, 'reuse an existing output'):
                metal.invoke(['-sdk', 'macosx', 'metal', '-c', str(self.shader),
                              '-o', str(self.target / 'shaders.air')], {'SIGNALS_REAL_XCRUN': '/usr/bin/xcrun'})


if __name__ == '__main__':
    unittest.main()
