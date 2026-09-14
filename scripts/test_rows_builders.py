"""Guard Rows' linear builders where allocation counters cannot see memmove.

List.prepend shifts an existing contiguous list even when uniquely owned and
preallocated. The two allowed receiver families below are audited exceptions:
RowsIdStack is a persistent AVL stack; slot patch writes have distinct offsets in
one 32-cell chunk. All unbounded List builders must append or reverse-iterate.
"""
from pathlib import Path
import re
import unittest

ROOT = Path(__file__).resolve().parents[1]
FREE_RECEIVERS = {
    'free', 'order.free_nodes', 'child_removal.order.free_nodes',
    'removal.order.free_nodes', 'vacant.free', 'state.touched_history',
    'entry_and_state.state.touched_history', '$touched_history', 'patches.chunk_ids',
}


def check_rows_builders(source: str) -> None:
    patch_start = source.index('rows_slots_patch =')
    patch_end = source.index('rows_slots_patched_cell :', patch_start)
    replacement_start = source.index('rows_build_replacement_loop =')
    replacement_end = source.index('rows_build_replacement :', replacement_start)
    for match in re.finditer(r'([\w.$]+)\.prepend\(', source):
        receiver = match.group(1)
        if receiver in FREE_RECEIVERS:
            continue
        if receiver == 'build.order_slots' and replacement_start < match.start() < replacement_end:
            continue
        if receiver == 'writes' and patch_start < match.start() < patch_end:
            continue
        line = source.count('\n', 0, match.start()) + 1
        raise AssertionError(f'Rows.roc:{line}: unbounded front insertion on {receiver}')


class RowsBuilderComplexityTests(unittest.TestCase):
    def test_unbounded_builders_do_not_shift_existing_lists(self):
        check_rows_builders((ROOT / 'platform-shared/Rows.roc').read_text())
        fixture = (ROOT / 'examples-web/_fixtures/js-framework-benchmark/main.roc').read_text()
        self.assertNotRegex(fixture, r'\.prepend\(')

    def test_restoring_quadratic_reverse_is_rejected(self):
        source = (ROOT / 'platform-shared/Rows.roc').read_text()
        start = source.index('rows_reverse =')
        end = source.index('\nrows_remove_at_loop :', start)
        mutant = source[:start] + '''rows_reverse = |items| {
    var $reversed = []
    for item in items { $reversed = $reversed.prepend(item) }
    $reversed
}
''' + source[end:]
        with self.assertRaisesRegex(AssertionError, 'unbounded front insertion'):
            check_rows_builders(mutant)


if __name__ == '__main__':
    unittest.main()
