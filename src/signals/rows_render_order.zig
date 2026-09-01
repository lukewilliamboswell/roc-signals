//! Sparse render-order topology for one live `Rows` site.
//!
//! The committed index is an implicit treap keyed by stable `RowId` handles.
//! Each node aggregates the count and endpoint roots of its subtree, so empty
//! rows do not force a scan to find the next rendered row. Candidate changes
//! use a path-copy overlay: preparation allocates only for edited paths and
//! removed rows, queries observe the final candidate order, and publication
//! writes the overlay into the committed table without allocating.

const std = @import("std");
const RowId = @import("rows_ids.zig").RowId;

/// Builds a site-local order index for a durable row span type. `Span` must
/// expose `first_root: ?u64`, `last_root: ?u64`, and `root_count` fields.
pub fn OrderIndex(comptime Span: type) type {
    comptime {
        const span: Span = undefined;
        if (@TypeOf(span.first_root) != ?u64 or @TypeOf(span.last_root) != ?u64) {
            @compileError("Rows render spans must expose optional u64 root anchors");
        }
        if (@TypeOf(span.root_count) != u32) {
            @compileError("Rows render span root_count must be u32");
        }
    }

    return struct {
        const Self = @This();

        const Node = struct {
            left: ?RowId = null,
            right: ?RowId = null,
            parent: ?RowId = null,
            priority: u64,
            subtree_rows: usize = 1,
            subtree_roots: usize,
            subtree_first_root: ?u64,
            subtree_last_root: ?u64,
            span: Span,
        };

        /// One row used to seed a snapshot-built site in committed order.
        pub const Entry = struct {
            row_id: RowId,
            span: Span,
        };

        /// A direct root together with the stable row whose span owns it.
        pub const RootAnchor = struct {
            row_id: RowId,
            root_id: u64,
        };

        /// Work performed by the complete candidate overlay. Node touches are
        /// distinct row-order records changed at least once during preparation.
        pub const Stats = struct {
            nodes_touched: usize = 0,
            roots_moved: usize = 0,
            effective_moves: usize = 0,
        };

        /// Result of removing a contiguous row range.
        pub const RemoveResult = struct {
            rows_removed: usize,
            roots_removed: usize,
        };

        /// Result of a move after exact already-in-position normalization.
        pub const MoveResult = struct {
            effective: bool,
            roots_moved: usize,
        };

        pub const Error = std.mem.Allocator.Error || error{
            AnchorInsideRange,
            DuplicateRow,
            InvalidRange,
            InvalidRow,
            InvalidSpan,
            ResourceLimit,
        };

        allocator: std.mem.Allocator,
        nodes: std.AutoHashMapUnmanaged(RowId, Node) = .empty,
        root: ?RowId = null,

        /// Creates an empty committed index. All storage remains owned by the
        /// caller-supplied allocator until `deinit`.
        pub fn init(allocator: std.mem.Allocator) Self {
            return .{ .allocator = allocator };
        }

        /// Releases committed topology storage. Candidate overlays must be
        /// destroyed separately before their base index is destroyed.
        pub fn deinit(self: *Self) void {
            self.nodes.deinit(self.allocator);
            self.* = undefined;
        }

        /// Returns the number of live rows without walking the order.
        pub fn len(self: *const Self) usize {
            return self.nodeRows(self.root);
        }

        /// Returns the number of direct render roots without walking rows.
        pub fn rootCount(self: *const Self) usize {
            return self.nodeRoots(self.root);
        }

        /// Returns the final direct root in committed site order without
        /// walking trailing rows that render no roots.
        pub fn lastRoot(self: *const Self) ?u64 {
            const root_id = self.root orelse return null;
            return (self.nodes.get(root_id) orelse unreachable).subtree_last_root;
        }

        /// Reports whether a generation-checked row participates in this
        /// committed render order.
        pub fn contains(self: *const Self, row_id: RowId) bool {
            return self.nodes.contains(row_id);
        }

        /// Removes one committed row without allocating. This narrow path is
        /// used only when an enclosing scope retires a row outside a Rows
        /// generation transition; ordinary collection edits use
        /// `PreparedEdits` so abort can preserve the committed topology.
        pub fn removeCommitted(self: *Self, row_id: RowId) error{InvalidRow}!void {
            const removed = self.nodes.get(row_id) orelse return error.InvalidRow;
            const parent = removed.parent;
            const replacement = self.mergeCommitted(removed.left, removed.right, parent);
            if (parent) |parent_id| {
                const parent_node = self.nodes.getPtr(parent_id) orelse unreachable;
                if (parent_node.left == row_id) {
                    parent_node.left = replacement;
                } else if (parent_node.right == row_id) {
                    parent_node.right = replacement;
                } else unreachable;
            } else {
                self.root = replacement;
            }
            _ = self.nodes.remove(row_id);
            var current = parent;
            while (current) |id| {
                const next = (self.nodes.get(id) orelse unreachable).parent;
                self.refreshCommitted(id);
                current = next;
            }
        }

        /// Returns the row occupying `index` in committed order.
        pub fn rowAt(self: *const Self, index: usize) error{InvalidRange}!RowId {
            if (index >= self.len()) return error.InvalidRange;
            var current = self.root.?;
            var remaining = index;
            while (true) {
                const node = self.nodes.get(current) orelse unreachable;
                const left_rows = self.nodeRows(node.left);
                if (remaining < left_rows) {
                    current = node.left.?;
                } else if (remaining == left_rows) {
                    return current;
                } else {
                    remaining -= left_rows + 1;
                    current = node.right.?;
                }
            }
        }

        /// Resolves the committed rank of a stable row in logarithmic expected
        /// time without scanning preceding rows.
        pub fn rank(self: *const Self, row_id: RowId) error{InvalidRow}!usize {
            const start = self.nodes.get(row_id) orelse return error.InvalidRow;
            var result = self.nodeRows(start.left);
            var current = row_id;
            var parent = start.parent;
            while (parent) |parent_id| {
                const parent_node = self.nodes.get(parent_id) orelse unreachable;
                if (parent_node.right == current) {
                    result += self.nodeRows(parent_node.left) + 1;
                } else if (parent_node.left != current) {
                    unreachable;
                }
                current = parent_id;
                parent = parent_node.parent;
            }
            return result;
        }

        /// Finds the first committed direct root owned by `row_id` or a later
        /// row. Aggregates skip arbitrarily long runs of zero-root rows.
        pub fn firstRootAtOrAfter(self: *const Self, row_id: RowId) error{InvalidRow}!?RootAnchor {
            const target = try self.rank(row_id);
            return self.findFirstRoot(self.root, 0, target);
        }

        /// Returns the durable span associated with a committed row.
        pub fn span(self: *const Self, row_id: RowId) error{InvalidRow}!Span {
            return (self.nodes.get(row_id) orelse return error.InvalidRow).span;
        }

        /// Seeds an empty index from snapshot order. All fallible work happens
        /// in a candidate overlay; the committed index remains empty on error.
        pub fn seed(self: *Self, entries: []const Entry) Error!Stats {
            if (self.len() != 0 or self.nodes.count() != 0) return error.DuplicateRow;
            var prepared = self.prepare();
            defer prepared.deinit();

            try prepared.overlay.ensureUnusedCapacity(self.allocator, std.math.cast(u32, entries.len) orelse return error.ResourceLimit);
            var stack: std.ArrayListUnmanaged(RowId) = .empty;
            defer stack.deinit(self.allocator);
            try stack.ensureTotalCapacity(self.allocator, entries.len);
            var total_roots: usize = 0;
            for (entries) |entry| {
                if (!spanValid(entry.span)) return error.InvalidSpan;
                if (prepared.overlay.contains(entry.row_id)) return error.DuplicateRow;
                total_roots = std.math.add(usize, total_roots, spanRoots(entry.span)) catch return error.ResourceLimit;
                prepared.overlay.putAssumeCapacity(entry.row_id, nodeFromSpan(entry.row_id, entry.span));

                var left: ?RowId = null;
                while (stack.items.len != 0) {
                    const top_id = stack.items[stack.items.len - 1];
                    const current_node = prepared.overlay.get(entry.row_id).?;
                    const top_node = prepared.overlay.get(top_id).?;
                    if (!precedes(entry.row_id, current_node, top_id, top_node)) break;
                    left = stack.pop().?;
                }

                const current = prepared.overlay.getPtr(entry.row_id).?;
                current.left = left;
                if (left) |left_id| prepared.overlay.getPtr(left_id).?.parent = entry.row_id;
                if (stack.items.len != 0) {
                    const parent_id = stack.items[stack.items.len - 1];
                    prepared.overlay.getPtr(parent_id).?.right = entry.row_id;
                    current.parent = parent_id;
                }
                stack.appendAssumeCapacity(entry.row_id);
            }
            prepared.root = if (stack.items.len == 0) null else stack.items[0];
            if (prepared.root) |root_id| try prepared.rebuildAggregates(root_id);
            try prepared.preflightCommit();
            const stats = prepared.stats();
            prepared.commitAssumePreflighted();
            return stats;
        }

        /// Starts a sparse candidate overlay. The returned value borrows this
        /// index until it is committed or destroyed.
        pub fn prepare(self: *Self) PreparedEdits {
            return .{
                .base = self,
                .allocator = self.allocator,
                .root = self.root,
            };
        }

        fn nodeRows(self: *const Self, row_id: ?RowId) usize {
            return if (row_id) |id| (self.nodes.get(id) orelse unreachable).subtree_rows else 0;
        }

        fn nodeRoots(self: *const Self, row_id: ?RowId) usize {
            return if (row_id) |id| (self.nodes.get(id) orelse unreachable).subtree_roots else 0;
        }

        fn findFirstRoot(self: *const Self, row_id: ?RowId, base_rank: usize, target: usize) ?RootAnchor {
            const id = row_id orelse return null;
            const node = self.nodes.get(id) orelse unreachable;
            if (node.subtree_roots == 0) return null;
            const left_rows = self.nodeRows(node.left);
            const node_rank = base_rank + left_rows;
            if (target < node_rank) {
                if (self.findFirstRoot(node.left, base_rank, target)) |found| return found;
            }
            if (target <= node_rank and node.span.root_count != 0) {
                return .{ .row_id = id, .root_id = node.span.first_root.? };
            }
            return self.findFirstRoot(node.right, node_rank + 1, target);
        }

        fn mergeCommitted(self: *Self, left_id: ?RowId, right_id: ?RowId, parent: ?RowId) ?RowId {
            if (left_id == null) {
                if (right_id) |id| self.nodes.getPtr(id).?.parent = parent;
                return right_id;
            }
            if (right_id == null) {
                self.nodes.getPtr(left_id.?).?.parent = parent;
                return left_id;
            }
            const left = self.nodes.get(left_id.?).?;
            const right = self.nodes.get(right_id.?).?;
            if (precedes(left_id.?, left, right_id.?, right)) {
                const node = self.nodes.getPtr(left_id.?).?;
                node.parent = parent;
                node.right = self.mergeCommitted(node.right, right_id, left_id);
                self.refreshCommitted(left_id.?);
                return left_id;
            }
            const node = self.nodes.getPtr(right_id.?).?;
            node.parent = parent;
            node.left = self.mergeCommitted(left_id, node.left, right_id);
            self.refreshCommitted(right_id.?);
            return right_id;
        }

        fn refreshCommitted(self: *Self, row_id: RowId) void {
            const node = self.nodes.getPtr(row_id) orelse unreachable;
            const left = if (node.left) |id| self.nodes.get(id).? else null;
            const right = if (node.right) |id| self.nodes.get(id).? else null;
            node.subtree_rows = 1 + (if (left) |value| value.subtree_rows else 0) + (if (right) |value| value.subtree_rows else 0);
            node.subtree_roots = (if (left) |value| value.subtree_roots else 0) + spanRoots(node.span) + (if (right) |value| value.subtree_roots else 0);
            node.subtree_first_root = if (left != null and left.?.subtree_first_root != null)
                left.?.subtree_first_root
            else if (node.span.first_root) |root_id|
                root_id
            else if (right) |value|
                value.subtree_first_root
            else
                null;
            node.subtree_last_root = if (right != null and right.?.subtree_last_root != null)
                right.?.subtree_last_root
            else if (node.span.last_root) |root_id|
                root_id
            else if (left) |value|
                value.subtree_last_root
            else
                null;
        }

        fn priorityFor(row_id: RowId) u64 {
            // Row ids are host-minted rather than app-controlled. SplitMix64
            // removes their sequential slot pattern while remaining exactly
            // deterministic across hosts and runs.
            var value = row_id.raw() +% 0x9e37_79b9_7f4a_7c15;
            value = (value ^ (value >> 30)) *% 0xbf58_476d_1ce4_e5b9;
            value = (value ^ (value >> 27)) *% 0x94d0_49bb_1331_11eb;
            return value ^ (value >> 31);
        }

        fn precedes(left_id: RowId, left: Node, right_id: RowId, right: Node) bool {
            return left.priority < right.priority or
                (left.priority == right.priority and left_id.raw() < right_id.raw());
        }

        /// A provisional, path-copy view of a committed order. Allocation
        /// failure can only damage this disposable overlay, never its base.
        pub const PreparedEdits = struct {
            const Prepared = @This();

            base: *Self,
            allocator: std.mem.Allocator,
            overlay: std.AutoHashMapUnmanaged(RowId, Node) = .empty,
            removed: std.AutoHashMapUnmanaged(RowId, void) = .empty,
            root: ?RowId,
            roots_moved: usize = 0,
            effective_moves: usize = 0,
            commit_preflighted: bool = false,
            committed: bool = false,

            /// Releases provisional storage. Destroying an uncommitted overlay
            /// leaves the committed order and spans byte-for-byte unchanged.
            pub fn deinit(self: *Prepared) void {
                self.overlay.deinit(self.allocator);
                self.removed.deinit(self.allocator);
                self.* = undefined;
            }

            /// Returns candidate row count from the overlay aggregate.
            pub fn len(self: *const Prepared) usize {
                return self.nodeRows(self.root);
            }

            /// Returns candidate direct-root count from the overlay aggregate.
            pub fn rootCount(self: *const Prepared) usize {
                return self.nodeRoots(self.root);
            }

            /// Returns the final direct root in candidate order without
            /// walking trailing rows that render no roots.
            pub fn lastRoot(self: *const Prepared) ?u64 {
                const root_id = self.root orelse return null;
                return (self.get(root_id) orelse unreachable).subtree_last_root;
            }

            /// Returns exact distinct topology records touched so far and the
            /// direct roots covered by effective move operations.
            pub fn stats(self: *const Prepared) Stats {
                var touched = self.overlay.count();
                var iterator = self.removed.iterator();
                while (iterator.next()) |entry| {
                    if (!self.overlay.contains(entry.key_ptr.*)) touched += 1;
                }
                return .{
                    .nodes_touched = touched,
                    .roots_moved = self.roots_moved,
                    .effective_moves = self.effective_moves,
                };
            }

            /// Returns the row occupying `index` in candidate order.
            pub fn rowAt(self: *const Prepared, index: usize) error{InvalidRange}!RowId {
                if (index >= self.len()) return error.InvalidRange;
                var current = self.root.?;
                var remaining = index;
                while (true) {
                    const node = self.get(current) orelse unreachable;
                    const left_rows = self.nodeRows(node.left);
                    if (remaining < left_rows) {
                        current = node.left.?;
                    } else if (remaining == left_rows) {
                        return current;
                    } else {
                        remaining -= left_rows + 1;
                        current = node.right.?;
                    }
                }
            }

            /// Resolves a stable row's rank against the final candidate order.
            pub fn rank(self: *const Prepared, row_id: RowId) error{InvalidRow}!usize {
                const start = self.get(row_id) orelse return error.InvalidRow;
                var result = self.nodeRows(start.left);
                var current = row_id;
                var parent = start.parent;
                while (parent) |parent_id| {
                    const parent_node = self.get(parent_id) orelse unreachable;
                    if (parent_node.right == current) {
                        result += self.nodeRows(parent_node.left) + 1;
                    } else if (parent_node.left != current) {
                        unreachable;
                    }
                    current = parent_id;
                    parent = parent_node.parent;
                }
                return result;
            }

            /// Finds the first candidate direct root owned by `row_id` or a
            /// later row without visiting intervening zero-root rows.
            pub fn firstRootAtOrAfter(self: *const Prepared, row_id: RowId) error{InvalidRow}!?RootAnchor {
                const target = try self.rank(row_id);
                return self.findFirstRoot(self.root, 0, target);
            }

            /// Returns the candidate durable span for a stable row.
            pub fn span(self: *const Prepared, row_id: RowId) error{InvalidRow}!Span {
                return (self.get(row_id) orelse return error.InvalidRow).span;
            }

            /// Inserts a new stable row before `before`, or at the end for
            /// null. Only provisional storage can allocate.
            pub fn insertBefore(self: *Prepared, row_id: RowId, before: ?RowId, span_value: Span) Error!void {
                self.invalidatePreflight();
                if (!spanValid(span_value)) return error.InvalidSpan;
                const resurrecting = self.removed.contains(row_id);
                if (!resurrecting and (self.base.nodes.contains(row_id) or self.overlay.contains(row_id))) return error.DuplicateRow;
                const insertion_rank = if (before) |anchor| try self.rank(anchor) else self.len();
                _ = std.math.add(usize, self.rootCount(), spanRoots(span_value)) catch return error.ResourceLimit;

                if (resurrecting) {
                    if (!self.overlay.contains(row_id)) try self.overlay.ensureUnusedCapacity(self.allocator, 1);
                    _ = self.removed.remove(row_id);
                    if (self.overlay.getPtr(row_id)) |node| {
                        node.* = nodeFromSpan(row_id, span_value);
                    } else {
                        self.overlay.putAssumeCapacity(row_id, nodeFromSpan(row_id, span_value));
                    }
                } else {
                    try self.overlay.ensureUnusedCapacity(self.allocator, 1);
                    self.overlay.putAssumeCapacity(row_id, nodeFromSpan(row_id, span_value));
                }
                const halves = try self.split(self.root, insertion_rank);
                self.root = try self.merge(try self.merge(halves.left, row_id), halves.right);
            }

            /// Removes `count` rows beginning at `first`. Removed rows remain
            /// readable only inside preparation long enough to finish the
            /// detach; candidate queries reject them afterward.
            pub fn removeRange(self: *Prepared, first: RowId, count: usize) Error!RemoveResult {
                self.invalidatePreflight();
                if (count == 0) return error.InvalidRange;
                const first_rank = try self.rank(first);
                if (count > self.len() - first_rank) return error.InvalidRange;
                try self.removed.ensureUnusedCapacity(self.allocator, std.math.cast(u32, count) orelse return error.ResourceLimit);

                const prefix_and_tail = try self.split(self.root, first_rank);
                const middle_and_suffix = try self.split(prefix_and_tail.right, count);
                const middle = middle_and_suffix.left orelse unreachable;
                const roots_removed = self.nodeRoots(middle);
                self.root = try self.merge(prefix_and_tail.left, middle_and_suffix.right);
                self.markRemovedSubtree(middle);
                return .{ .rows_removed = count, .roots_removed = roots_removed };
            }

            /// Moves a contiguous range before `before` in the post-removal
            /// order, or to the end for null. Exact already-positioned moves
            /// leave the overlay and work counters unchanged.
            pub fn moveRange(self: *Prepared, first: RowId, count: usize, before: ?RowId) Error!MoveResult {
                self.invalidatePreflight();
                if (count == 0) return error.InvalidRange;
                const source_rank = try self.rank(first);
                if (count > self.len() - source_rank) return error.InvalidRange;
                const source_end = source_rank + count;
                const before_rank = if (before) |anchor| try self.rank(anchor) else self.len();
                if (before_rank >= source_rank and before_rank < source_end) return error.AnchorInsideRange;
                const target_rank = if (before_rank >= source_end) before_rank - count else before_rank;
                if (target_rank == source_rank) return .{ .effective = false, .roots_moved = 0 };

                const prefix_and_tail = try self.split(self.root, source_rank);
                const middle_and_suffix = try self.split(prefix_and_tail.right, count);
                const middle = middle_and_suffix.left orelse unreachable;
                const moved_roots = self.nodeRoots(middle);
                const remaining = try self.merge(prefix_and_tail.left, middle_and_suffix.right);
                const target = try self.split(remaining, target_rank);
                self.root = try self.merge(try self.merge(target.left, middle), target.right);
                self.roots_moved = std.math.add(usize, self.roots_moved, moved_roots) catch return error.ResourceLimit;
                self.effective_moves += 1;
                return .{ .effective = true, .roots_moved = moved_roots };
            }

            /// Replaces one row's durable render span and refreshes only its
            /// ancestor aggregates. Equal spans are exact no-ops. This does
            /// not invalidate committed-table capacity preflight because it
            /// cannot introduce a new row id; all path-copy allocation occurs
            /// synchronously before this function returns.
            pub fn updateSpan(self: *Prepared, row_id: RowId, span_value: Span) Error!bool {
                if (self.committed) @panic("Rows render-order overlay edited after commit");
                const old = (self.get(row_id) orelse return error.InvalidRow).span;
                if (!spanValid(span_value)) return error.InvalidSpan;
                if (std.meta.eql(old, span_value)) return false;
                const without_old = self.rootCount() - spanRoots(old);
                _ = std.math.add(usize, without_old, spanRoots(span_value)) catch return error.ResourceLimit;

                const node = try self.mutable(row_id);
                node.span = span_value;
                var current: ?RowId = row_id;
                while (current) |id| {
                    const parent = (self.get(id) orelse unreachable).parent;
                    try self.refresh(id);
                    current = parent;
                }
                return true;
            }

            /// Reserves every committed-table bucket needed by publication.
            /// No committed state changes until `commitAssumePreflighted`.
            pub fn preflightCommit(self: *Prepared) Error!void {
                var fresh_count: usize = 0;
                var iterator = self.overlay.iterator();
                while (iterator.next()) |entry| {
                    const id = entry.key_ptr.*;
                    if (!self.removed.contains(id) and !self.base.nodes.contains(id)) fresh_count += 1;
                }
                try self.base.nodes.ensureUnusedCapacity(self.base.allocator, std.math.cast(u32, fresh_count) orelse return error.ResourceLimit);
                self.commit_preflighted = true;
            }

            /// Publishes the prepared topology without allocation. The caller
            /// must have completed `preflightCommit` after its last edit.
            pub fn commitAssumePreflighted(self: *Prepared) void {
                if (!self.commit_preflighted or self.committed) @panic("Rows render-order commit was not prepared exactly once");

                var overlay_iterator = self.overlay.iterator();
                while (overlay_iterator.next()) |entry| {
                    const id = entry.key_ptr.*;
                    if (self.removed.contains(id)) continue;
                    if (self.base.nodes.getPtr(id)) |committed_node| {
                        committed_node.* = entry.value_ptr.*;
                    } else {
                        self.base.nodes.putAssumeCapacity(id, entry.value_ptr.*);
                    }
                }
                var removed_iterator = self.removed.iterator();
                while (removed_iterator.next()) |entry| {
                    _ = self.base.nodes.remove(entry.key_ptr.*);
                }
                self.base.root = self.root;
                self.committed = true;
            }

            fn invalidatePreflight(self: *Prepared) void {
                if (self.committed) @panic("Rows render-order overlay edited after commit");
                self.commit_preflighted = false;
            }

            fn get(self: *const Prepared, row_id: RowId) ?Node {
                if (self.removed.contains(row_id)) return null;
                if (self.overlay.get(row_id)) |node| return node;
                return self.base.nodes.get(row_id);
            }

            fn mutable(self: *Prepared, row_id: RowId) Error!*Node {
                if (self.removed.contains(row_id)) return error.InvalidRow;
                if (self.overlay.getPtr(row_id)) |node| return node;
                const committed = self.base.nodes.get(row_id) orelse return error.InvalidRow;
                try self.overlay.put(self.allocator, row_id, committed);
                return self.overlay.getPtr(row_id).?;
            }

            fn nodeRows(self: *const Prepared, row_id: ?RowId) usize {
                return if (row_id) |id| (self.get(id) orelse unreachable).subtree_rows else 0;
            }

            fn nodeRoots(self: *const Prepared, row_id: ?RowId) usize {
                return if (row_id) |id| (self.get(id) orelse unreachable).subtree_roots else 0;
            }

            fn setParent(self: *Prepared, row_id: ?RowId, parent: ?RowId) Error!void {
                const id = row_id orelse return;
                if ((self.get(id) orelse unreachable).parent == parent) return;
                (try self.mutable(id)).parent = parent;
            }

            fn setLeft(self: *Prepared, row_id: RowId, child: ?RowId) Error!void {
                if ((self.get(row_id) orelse unreachable).left != child) (try self.mutable(row_id)).left = child;
                try self.setParent(child, row_id);
            }

            fn setRight(self: *Prepared, row_id: RowId, child: ?RowId) Error!void {
                if ((self.get(row_id) orelse unreachable).right != child) (try self.mutable(row_id)).right = child;
                try self.setParent(child, row_id);
            }

            fn refresh(self: *Prepared, row_id: RowId) Error!void {
                const snapshot = self.get(row_id) orelse return error.InvalidRow;
                const left = if (snapshot.left) |id| self.get(id).? else null;
                const right = if (snapshot.right) |id| self.get(id).? else null;
                const subtree_rows = 1 + (if (left) |node| node.subtree_rows else 0) + (if (right) |node| node.subtree_rows else 0);
                const subtree_roots = (if (left) |node| node.subtree_roots else 0) + spanRoots(snapshot.span) + (if (right) |node| node.subtree_roots else 0);
                const subtree_first_root = if (left != null and left.?.subtree_first_root != null)
                    left.?.subtree_first_root
                else if (snapshot.span.first_root) |root_id|
                    root_id
                else if (right) |node|
                    node.subtree_first_root
                else
                    null;
                const subtree_last_root = if (right != null and right.?.subtree_last_root != null)
                    right.?.subtree_last_root
                else if (snapshot.span.last_root) |root_id|
                    root_id
                else if (left) |node|
                    node.subtree_last_root
                else
                    null;

                if (snapshot.subtree_rows == subtree_rows and
                    snapshot.subtree_roots == subtree_roots and
                    snapshot.subtree_first_root == subtree_first_root and
                    snapshot.subtree_last_root == subtree_last_root) return;
                const node = try self.mutable(row_id);
                node.subtree_rows = subtree_rows;
                node.subtree_roots = subtree_roots;
                node.subtree_first_root = subtree_first_root;
                node.subtree_last_root = subtree_last_root;
            }

            const Split = struct { left: ?RowId, right: ?RowId };

            fn split(self: *Prepared, root_id: ?RowId, left_count: usize) Error!Split {
                const id = root_id orelse return .{ .left = null, .right = null };
                const snapshot = self.get(id) orelse unreachable;
                const existing_left = self.nodeRows(snapshot.left);
                if (left_count <= existing_left) {
                    const halves = try self.split(snapshot.left, left_count);
                    try self.setLeft(id, halves.right);
                    try self.setParent(id, null);
                    try self.setParent(halves.left, null);
                    try self.refresh(id);
                    return .{ .left = halves.left, .right = id };
                }

                const halves = try self.split(snapshot.right, left_count - existing_left - 1);
                try self.setRight(id, halves.left);
                try self.setParent(id, null);
                try self.setParent(halves.right, null);
                try self.refresh(id);
                return .{ .left = id, .right = halves.right };
            }

            fn merge(self: *Prepared, left_id: ?RowId, right_id: ?RowId) Error!?RowId {
                if (left_id == null) {
                    try self.setParent(right_id, null);
                    return right_id;
                }
                if (right_id == null) {
                    try self.setParent(left_id, null);
                    return left_id;
                }

                const left = self.get(left_id.?) orelse unreachable;
                const right = self.get(right_id.?) orelse unreachable;
                if (precedes(left_id.?, left, right_id.?, right)) {
                    const merged = try self.merge(left.right, right_id);
                    try self.setRight(left_id.?, merged);
                    try self.setParent(left_id, null);
                    try self.refresh(left_id.?);
                    return left_id;
                }

                const merged = try self.merge(left_id, right.left);
                try self.setLeft(right_id.?, merged);
                try self.setParent(right_id, null);
                try self.refresh(right_id.?);
                return right_id;
            }

            fn markRemovedSubtree(self: *Prepared, row_id: RowId) void {
                const node = self.get(row_id) orelse unreachable;
                if (node.left) |left| self.markRemovedSubtree(left);
                if (node.right) |right| self.markRemovedSubtree(right);
                self.removed.putAssumeCapacity(row_id, {});
            }

            fn rebuildAggregates(self: *Prepared, row_id: RowId) Error!void {
                const node = self.overlay.get(row_id) orelse unreachable;
                if (node.left) |left| try self.rebuildAggregates(left);
                if (node.right) |right| try self.rebuildAggregates(right);
                try self.refresh(row_id);
            }

            fn findFirstRoot(self: *const Prepared, row_id: ?RowId, base_rank: usize, target: usize) ?RootAnchor {
                const id = row_id orelse return null;
                const node = self.get(id) orelse unreachable;
                if (node.subtree_roots == 0) return null;
                const left_rows = self.nodeRows(node.left);
                const node_rank = base_rank + left_rows;
                if (target < node_rank) {
                    if (self.findFirstRoot(node.left, base_rank, target)) |found| return found;
                }
                if (target <= node_rank and node.span.root_count != 0) {
                    return .{ .row_id = id, .root_id = node.span.first_root.? };
                }
                return self.findFirstRoot(node.right, node_rank + 1, target);
            }
        };

        fn spanRoots(span_value: Span) usize {
            return span_value.root_count;
        }

        fn spanValid(span_value: Span) bool {
            const has_first = span_value.first_root != null;
            const has_last = span_value.last_root != null;
            return has_first == has_last and has_first == (span_value.root_count != 0);
        }

        fn nodeFromSpan(row_id: RowId, span_value: Span) Node {
            const roots = spanRoots(span_value);
            return .{
                .priority = priorityFor(row_id),
                .subtree_roots = roots,
                .subtree_first_root = span_value.first_root,
                .subtree_last_root = span_value.last_root,
                .span = span_value,
            };
        }
    };
}

const TestSpan = struct {
    first_root: ?u64 = null,
    last_root: ?u64 = null,
    root_count: u32 = 0,
};

const TestOrder = OrderIndex(TestSpan);

fn row(index: usize) RowId {
    return RowId.init(index, 1);
}

fn oneRoot(root_id: u64) TestSpan {
    return .{ .first_root = root_id, .last_root = root_id, .root_count = 1 };
}

fn expectOrder(view: anytype, expected: []const RowId) !void {
    try std.testing.expectEqual(expected.len, view.len());
    for (expected, 0..) |expected_row, index| {
        try std.testing.expectEqual(expected_row, try view.rowAt(index));
        try std.testing.expectEqual(index, try view.rank(expected_row));
    }
}

test "prepared render order exposes candidate anchors without mutating committed order" {
    var order = TestOrder.init(std.testing.allocator);
    defer order.deinit();
    _ = try order.seed(&.{
        .{ .row_id = row(0), .span = .{} },
        .{ .row_id = row(1), .span = .{ .first_root = 10, .last_root = 11, .root_count = 2 } },
        .{ .row_id = row(2), .span = .{} },
        .{ .row_id = row(3), .span = oneRoot(20) },
    });

    try expectOrder(&order, &.{ row(0), row(1), row(2), row(3) });
    try std.testing.expectEqual(@as(?u64, 20), order.lastRoot());
    try std.testing.expectEqual(TestOrder.RootAnchor{ .row_id = row(1), .root_id = 10 }, (try order.firstRootAtOrAfter(row(0))).?);
    try std.testing.expectEqual(TestOrder.RootAnchor{ .row_id = row(3), .root_id = 20 }, (try order.firstRootAtOrAfter(row(2))).?);

    var prepared = order.prepare();
    defer prepared.deinit();
    const moved = try prepared.moveRange(row(1), 2, null);
    try std.testing.expect(moved.effective);
    try std.testing.expectEqual(@as(usize, 2), moved.roots_moved);
    try expectOrder(&prepared, &.{ row(0), row(3), row(1), row(2) });
    try std.testing.expectEqual(@as(?u64, 11), prepared.lastRoot());
    try std.testing.expectEqual(TestOrder.RootAnchor{ .row_id = row(3), .root_id = 20 }, (try prepared.firstRootAtOrAfter(row(0))).?);

    // Candidate preparation is isolated until the allocation-free commit.
    try expectOrder(&order, &.{ row(0), row(1), row(2), row(3) });
    try prepared.preflightCommit();
    prepared.commitAssumePreflighted();
    try expectOrder(&order, &.{ row(0), row(3), row(1), row(2) });
    try std.testing.expectEqual(@as(usize, 3), order.rootCount());
    try std.testing.expectEqual(@as(?u64, 11), order.lastRoot());
}

test "insert remove move and span updates preserve exact aggregates" {
    var order = TestOrder.init(std.testing.allocator);
    defer order.deinit();
    _ = try order.seed(&.{
        .{ .row_id = row(0), .span = oneRoot(100) },
        .{ .row_id = row(1), .span = .{} },
        .{ .row_id = row(2), .span = oneRoot(200) },
    });

    var prepared = order.prepare();
    defer prepared.deinit();
    try prepared.insertBefore(row(3), row(2), .{ .first_root = 300, .last_root = 302, .root_count = 3 });
    try expectOrder(&prepared, &.{ row(0), row(1), row(3), row(2) });
    try std.testing.expectEqual(@as(usize, 5), prepared.rootCount());

    const no_op = try prepared.moveRange(row(3), 1, row(2));
    try std.testing.expect(!no_op.effective);
    const after_no_op = prepared.stats();
    try std.testing.expectEqual(@as(usize, 0), after_no_op.effective_moves);
    try std.testing.expectEqual(@as(usize, 0), after_no_op.roots_moved);
    const moved = try prepared.moveRange(row(0), 2, null);
    try std.testing.expectEqual(@as(usize, 1), moved.roots_moved);
    try expectOrder(&prepared, &.{ row(3), row(2), row(0), row(1) });

    try std.testing.expect(try prepared.updateSpan(row(1), oneRoot(400)));
    try std.testing.expect(!(try prepared.updateSpan(row(1), oneRoot(400))));
    try std.testing.expectEqual(@as(usize, 6), prepared.rootCount());
    const removed = try prepared.removeRange(row(3), 2);
    try std.testing.expectEqual(@as(usize, 2), removed.rows_removed);
    try std.testing.expectEqual(@as(usize, 4), removed.roots_removed);
    try expectOrder(&prepared, &.{ row(0), row(1) });
    try std.testing.expectEqual(TestOrder.RootAnchor{ .row_id = row(0), .root_id = 100 }, (try prepared.firstRootAtOrAfter(row(0))).?);
    try std.testing.expectEqual(TestOrder.RootAnchor{ .row_id = row(1), .root_id = 400 }, (try prepared.firstRootAtOrAfter(row(1))).?);

    const stats = prepared.stats();
    try std.testing.expectEqual(@as(usize, 1), stats.effective_moves);
    try std.testing.expectEqual(@as(usize, 1), stats.roots_moved);
    try prepared.preflightCommit();
    prepared.commitAssumePreflighted();
    try expectOrder(&order, &.{ row(0), row(1) });
    try std.testing.expectError(error.InvalidRow, order.rank(row(2)));
    try std.testing.expectError(error.InvalidRow, order.rank(row(3)));
}

test "prepared commit remains allocation free after reservation" {
    var order = TestOrder.init(std.testing.allocator);
    defer order.deinit();
    _ = try order.seed(&.{
        .{ .row_id = row(0), .span = oneRoot(10) },
        .{ .row_id = row(1), .span = .{} },
    });

    var prepared = order.prepare();
    defer prepared.deinit();
    try prepared.insertBefore(row(2), row(1), oneRoot(20));
    try prepared.preflightCommit();
    try std.testing.expect(try prepared.updateSpan(row(0), oneRoot(11)));

    const normal_allocator = order.allocator;
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    order.allocator = failing.allocator();
    prepared.commitAssumePreflighted();
    order.allocator = normal_allocator;

    try std.testing.expect(!failing.has_induced_failure);
    try expectOrder(&order, &.{ row(0), row(2), row(1) });
    try std.testing.expectEqual(oneRoot(11), try order.span(row(0)));
}

test "committed scope retirement removes one row without allocation" {
    var order = TestOrder.init(std.testing.allocator);
    defer order.deinit();
    _ = try order.seed(&.{
        .{ .row_id = row(0), .span = oneRoot(10) },
        .{ .row_id = row(1), .span = .{} },
        .{ .row_id = row(2), .span = .{ .first_root = 20, .last_root = 21, .root_count = 2 } },
        .{ .row_id = row(3), .span = oneRoot(30) },
    });

    const normal_allocator = order.allocator;
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    order.allocator = failing.allocator();
    try order.removeCommitted(row(2));
    order.allocator = normal_allocator;

    try std.testing.expect(!failing.has_induced_failure);
    try expectOrder(&order, &.{ row(0), row(1), row(3) });
    try std.testing.expectEqual(@as(usize, 2), order.rootCount());
    try std.testing.expectEqual(TestOrder.RootAnchor{ .row_id = row(3), .root_id = 30 }, (try order.firstRootAtOrAfter(row(1))).?);
}

test "candidate operations reject inconsistent render spans" {
    var order = TestOrder.init(std.testing.allocator);
    defer order.deinit();
    var prepared = order.prepare();
    defer prepared.deinit();

    try std.testing.expectError(error.InvalidSpan, prepared.insertBefore(row(0), null, .{ .first_root = 10, .root_count = 1 }));
    try std.testing.expectEqual(@as(usize, 0), prepared.len());
}

test "remove and reinsert in one preparation preserves stable row identity" {
    var order = TestOrder.init(std.testing.allocator);
    defer order.deinit();
    _ = try order.seed(&.{
        .{ .row_id = row(0), .span = oneRoot(10) },
        .{ .row_id = row(1), .span = oneRoot(20) },
        .{ .row_id = row(2), .span = oneRoot(30) },
    });

    var prepared = order.prepare();
    defer prepared.deinit();
    _ = try prepared.removeRange(row(1), 1);
    try prepared.insertBefore(row(1), row(0), oneRoot(21));
    try expectOrder(&prepared, &.{ row(1), row(0), row(2) });
    try std.testing.expectEqual(oneRoot(21), try prepared.span(row(1)));

    try prepared.preflightCommit();
    prepared.commitAssumePreflighted();
    try expectOrder(&order, &.{ row(1), row(0), row(2) });
    try std.testing.expectEqual(oneRoot(21), try order.span(row(1)));
}

test "candidate move sequence matches a dense reference order" {
    var order = TestOrder.init(std.testing.allocator);
    defer order.deinit();
    const count = 128;
    var entries: [count]TestOrder.Entry = undefined;
    var expected: [count]RowId = undefined;
    for (&entries, &expected, 0..) |*entry, *expected_row, index| {
        entry.* = .{ .row_id = row(index), .span = if (index % 5 == 0) oneRoot(@intCast(index + 1)) else .{} };
        expected_row.* = row(index);
    }
    _ = try order.seed(&entries);

    var prepared = order.prepare();
    defer prepared.deinit();
    for (0..400) |step| {
        const from = (step * 47 + 11) % count;
        const moved = expected[from];
        std.mem.copyForwards(RowId, expected[from .. count - 1], expected[from + 1 .. count]);
        const target = (step * 29 + 7) % count;
        const before: ?RowId = if (target == count - 1) null else expected[target];
        _ = try prepared.moveRange(moved, 1, before);
        std.mem.copyBackwards(RowId, expected[target + 1 .. count], expected[target .. count - 1]);
        expected[target] = moved;
        try expectOrder(&prepared, &expected);
    }

    try prepared.preflightCommit();
    prepared.commitAssumePreflighted();
    try expectOrder(&order, &expected);
}

test "ten thousand row single-range move copies logarithmic topology paths" {
    var order = TestOrder.init(std.testing.allocator);
    defer order.deinit();

    const count = 10_000;
    const entries = try std.testing.allocator.alloc(TestOrder.Entry, count);
    defer std.testing.allocator.free(entries);
    for (entries, 0..) |*entry, index| {
        entry.* = .{ .row_id = row(index), .span = if (index % 3 == 0) oneRoot(@intCast(index + 1)) else .{} };
    }
    _ = try order.seed(entries);

    var prepared = order.prepare();
    defer prepared.deinit();
    const moved = try prepared.moveRange(row(5_000), 1, row(10));
    try std.testing.expect(moved.effective);
    try std.testing.expectEqual(@as(usize, 0), moved.roots_moved);
    try std.testing.expectEqual(row(5_000), try prepared.rowAt(10));
    try std.testing.expectEqual(row(10), try prepared.rowAt(11));
    try std.testing.expectEqual(row(9_999), try prepared.rowAt(9_999));

    // The bound is deliberately generous enough to tolerate deterministic
    // tree-shape variation while still failing any candidate-length copy.
    try std.testing.expect(prepared.stats().nodes_touched < 256);
    try prepared.preflightCommit();
    prepared.commitAssumePreflighted();
    try std.testing.expectEqual(row(5_000), try order.rowAt(10));
}
