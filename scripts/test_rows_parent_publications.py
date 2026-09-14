#!/usr/bin/env python3
"""Instrument a private Rows copy to check exact parent publications.

Counters are excluded from production. Each table_set publishes one parent
chunk, so the trace checks both entry writes and chunk publications, including
repeated writes to the same chunk. The oracle compares old and final parent
relationships independently, requiring exactly one publication per change.
"""
import argparse
from pathlib import Path
import subprocess

from prepare_platforms import prepare_platform

ROOT = Path(__file__).resolve().parents[1]


def instrument(source):
    source = source.replace('RowsOrder : {\n', 'RowsOrder : {\n\tparent_publications : List(U64),\n', 1)
    source = source.replace('{ root: 1, nodes, parents,', '{ parent_publications: [], root: 1, nodes, parents,', 1)
    source = source.replace('\n\t\t\troot,\n\t\t\tnodes:', '\n\t\t\tparent_publications: [],\n\t\t\troot,\n\t\t\tnodes:', 1)
    source = source.replace('var $parents = order.parents', 'var $parents = order.parents\n\tvar $publications = order.parent_publications', 1)
    source = source.replace('$parents = rows_order_table_set($parents, child_id, OrderParent({ node: parent_id, child: $index }))', '$parents = rows_order_table_set($parents, child_id, OrderParent({ node: parent_id, child: $index }))\n\t\t\t$publications = $publications.append(child_id)', 1)
    source = source.replace('{ ..order, parents: $parents }', '{ ..order, parents: $parents, parent_publications: $publications }', 1)
    source = source.replace('rooted = { ..allocation.order, root: root_id, nodes, parents }', 'rooted = { ..allocation.order, root: root_id, nodes, parents, parent_publications: allocation.order.parent_publications.append(root_id) }', 1)
    return source + '''
expect {
    var $valid = True
    for size in [1000, 1024, 10000, 32768] {
        var $slots = List.with_capacity(size)
        var $slot = 1.U64
        while $slot <= size {
            $slots = $slots.append($slot)
            $slot = $slot + 1
        }
        original = rows_order_from_slots($slots)
        for position in [0, size.div_trunc_by(2), size] {
            before = { ..original, parent_publications: [] }
            after = rows_order_insert(before, position, size + 1)
            var $changed = 0.U64
            var $id = 1.U64
            while $id < after.next_node {
                old_parent = rows_order_table_get(before.parents, $id)
                new_parent = rows_order_table_get(after.parents, $id)
                same = match (old_parent, new_parent) {
                    (Ok(OrderRoot), Ok(OrderRoot)) => True
                    (Ok(OrderParent(left)), Ok(OrderParent(right))) => left.node == right.node and left.child == right.child
                    (Err(_), Err(_)) => True
                    _ => False
                }
                var $published = 0.U64
                for published_id in after.parent_publications {
                    if published_id == $id { $published = $published + 1 }
                }
                if same {
                    $valid = $valid and $published == 0
                } else {
                    $changed = $changed + 1
                    $valid = $valid and $published == 1
                }
                $id = $id + 1
            }
            dbg (size, position, $changed, after.parent_publications.len())
            $valid = $valid and $changed == after.parent_publications.len() and rows_order_len(after) == size + 1 and rows_order_get(after, position)? == size + 1 and rows_order_len(before) == size and rows_order_get(before, size - 1)? == size
        }
    }
    $valid
}

expect {
    var $valid = True
    var $slots = List.with_capacity(1000)
    var $slot = 1.U64
    while $slot <= 1000 {
        $slots = $slots.append($slot)
        $slot = $slot + 1
    }
    original = rows_order_from_slots($slots)
    for count in [1000, 10000] {
        for mode in [0.U64, 1, 2] {
            var $order = original
            var $step = 0.U64
            var $ordinary = 0.U64
            var $leaf_splits = 0.U64
            var $branch_splits = 0.U64
            var $publications = 0.U64
            while $step < count {
                before = { ..$order, parent_publications: [] }
                position = if mode == 0 { 0 } else if mode == 1 { rows_order_len(before).div_trunc_by(2) } else { rows_order_len(before) }
                inserted = 1001 + $step
                after = rows_order_insert(before, position, inserted)
                allocated = after.next_node - before.next_node
                if allocated == 0 {
                    $ordinary = $ordinary + 1
                    $valid = $valid and after.parent_publications.is_empty()
                } else if allocated == 1 {
                    $leaf_splits = $leaf_splits + 1
                } else {
                    $branch_splits = $branch_splits + 1
                }
                $publications = $publications + after.parent_publications.len()
                $valid = $valid and rows_order_get(after, position)? == inserted and rows_order_rank(after, inserted)? == position
                $order = after
                $step = $step + 1
            }
            dbg (count, mode, $ordinary, $leaf_splits, $branch_splits, $publications)
            $valid = $valid and rows_order_len($order) == 1000 + count and rows_order_len(original) == 1000 and rows_order_get(original, 999)? == 1000
        }
    }
    $valid
}
'''


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--roc-bin', default='roc')
    args = parser.parse_args()
    output = ROOT / '.test-out/rows-parent-publications'
    prepare_platform(ROOT / 'platform-web', output)
    source = instrument((ROOT / 'platform-shared/Rows.roc').read_text())
    (output / 'Rows.roc').write_text(source)
    command = [args.roc_bin, 'test', str(output / 'main.roc')]
    subprocess.run(command, cwd=ROOT, check=True)
    # Restore redundant sibling writes on a split; the independent oracle must
    # reject publications whose relationship did not change.
    mutant = source.replace('if !unchanged {', 'if unchanged or !unchanged {', 1)
    (output / 'Rows.roc').write_text(mutant)
    result = subprocess.run(command, cwd=ROOT, capture_output=True, text=True)
    (output / 'mutation.log').write_text(result.stdout + result.stderr)
    if result.returncode == 0 or 'failed' not in result.stdout + result.stderr:
        raise AssertionError('Parent-publication oracle did not reject redundant writes')
    print('Parent-publication mutation rejected.')


if __name__ == '__main__':
    main()
