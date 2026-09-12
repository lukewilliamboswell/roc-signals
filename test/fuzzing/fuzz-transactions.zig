//! Model-based fuzzing for every host transaction source under allocation failure.
//!
//! # Why this target exists
//!
//! design.md, "Memory management and allocation failure", makes every mount,
//! event, timer tick, effect result, source update, and unmount a *host
//! transaction* with prepare, mutate, and publish phases, and says a
//! preparation failure is recoverable when the allocating call has an
//! error-and-unwind channel: it publishes nothing, runs no effectful callback,
//! releases every provisional result, and leaves the engine ready to retry.
//! `structural` sweeps that contract over one transaction source, a state-list
//! write. Nothing swept the others, and the native fault campaign's known
//! failures all sit there: hundreds of coordinates in the coordinated-writes
//! and event-actions specs end in `out of memory preparing atomic state
//! transaction`, the spec host's fatal classification of a refusal it could
//! not retry. That is the class this target reproduces at the engine seam,
//! with an oracle that says what a refusal must have left behind.
//!
//! # What is generated
//!
//! A program is a small mounted app plus a sequence of host transactions.
//!
//! The app nests one to `max_scalars` root scalar state cells around a list
//! state cell, whose body shows each scalar (through a `map` that adds one), an
//! `each` over the list keyed by item, a `when` on the list's length, up to
//! `max_root_buttons` buttons, and an interval source. The `when`'s true branch
//! owns a scoped scalar state cell, a scoped interval source, and a scoped
//! button; its false branch is static text. Flipping the `when` therefore
//! retires and re-instantiates a state, a timer, and an event binding in the
//! same transaction that re-diffs the rows, which is what gives the effect
//! lifecycle oracles something to see.
//!
//! Every button binds a `click` (unit payload) or `input` (string payload)
//! event to one of three handler kinds:
//!
//!  - **reduce**: a reducer on one state, adding a generated amount and the
//!    payload to the current value;
//!  - **action**: a command builder reading a snapshot of one state and
//!    returning an `UpdateChanges` command, one to three `Set` or `Transform`
//!    changes over distinct states - the atomic multi-state write path;
//!  - **then**: the same changes inside a `Then`, which also queues an effect.
//!
//! Only the scoped button may name the scoped state, so a handler-time batch
//! never targets a state the engine has retired.
//!
//! An effect's result is itself generated: a list of `Set` and `Transform`
//! changes the target builds into an `UpdateChanges` command when it delivers
//! the result. The fuzz build has no Roc application to run the thunk, so the
//! host's `prepareEffect` stands in for the export by handing back the closure
//! itself; the closure's capture names the effect, and delivery is what the
//! spec host's `completeEffectJob` does, split so a refusal can be retried.
//!
//! Steps interleave: an event dispatch with a payload, a list write, a direct
//! scalar write, a coordinated write of several scalars through
//! `tryDispatchStateWrites`, a timer tick on either interval, a source result
//! delivered to either interval (the seam a task result enters through),
//! starting the oldest queued effect, completing a chosen running effect, and
//! an unmount followed by a fresh mount.
//!
//! # Reference model
//!
//! `Model` holds every scalar, the list, the scoped state (present only while
//! the branch is shown, re-initialized on every instantiation), both timer
//! values, the queue of pending and running effects, and the branch's
//! instantiation counter. Each step is applied to it by hand:
//!
//!  - a reducer adds its amount and payload; an action or `Then` applies its
//!    changes atomically, a `Set` from the snapshot of its declared read and
//!    a `Transform` from the state's settled value;
//!  - a `Then` queues an effect owned by the branch instance it ran in, or by
//!    the root; the engine hands effects out oldest first with ascending ids;
//!  - an effect result writes to every root state it names, and to the scoped
//!    state only if the branch instance that queued it is still the live one.
//!    design.md, "Requests, effects, and cancellation": a write whose
//!    destination was retired with its scope is skipped, the rest commit;
//!  - a tick adds one, a source result replaces; neither can reach a timer
//!    the branch retired - the oracle checks the registry count instead;
//!  - a list write re-diffs the rows and flips the branch; an unmount forgets
//!    every effect, and the fresh mount starts from the initial program.
//!
//! # Oracles
//!
//!  - **Every state holds the modelled value.** Each root scalar, the scoped
//!    state when the branch is shown, and the count of live states.
//!  - **The document reads exactly as the model.** The published render tree
//!    is walked in document order and its text sequence must equal the model's:
//!    scalar texts, row labels, the branch or its off text, the timer texts.
//!  - **Effect and timer lifecycles.** The pending and running effect counts,
//!    the id and identity of every started effect, and the interval registry
//!    count all follow the model after every step.
//!  - **A refused transaction publishes nothing.** After an injected failure
//!    the full model oracle is re-run against the previous model, the active
//!    event table, effect queues, and interval registry are unchanged, the
//!    closure retain/release delta is zero, and the Roc allocation ledger is
//!    back where it started.
//!  - **The engine is still usable.** The same transaction, rebuilt and retried
//!    on the same host with the fault disarmed, must publish the model.
//!  - **Refusals are `OutOfMemory` only.** As in `structural`: every other
//!    `CollectionError` names a contract the generator did not break.
//!  - **Nothing leaks.** Every unmount, including the final one, runs the
//!    host's safety-checked allocator leak check.
//!
//! # Fault placement and fatal boundaries
//!
//! Every input first runs unfaulted, recording the engine-allocator attempt
//! count of each step's transaction. Each count is then swept independently,
//! exhaustively when small and at one input-chosen attempt otherwise, exactly
//! as `structural` does; a swept step replays the earlier steps unfaulted
//! first. Faults land through the recoverable seams only: `tryDispatchStateValue`,
//! `tryDispatchStateWrites`, `tryRunCommand` behind an event or an effect
//! result, and `tryDispatchEffectSourceValue`. Two boundaries are fatal by the
//! engine's declaration and are classified rather than faulted: starting an
//! effect (`trackRunningEffect` panics on exhaustion) and the timer tick entry
//! `tickIntervalSourceByRuntimeToken`, which panics rather than refuses. A
//! faulted tick therefore runs the same source transaction through its
//! recoverable seam with the tick's next value computed here; an attempt that
//! falls in the pure tick evaluation outside that seam is accepted as a
//! successful transaction. The initial mount is swept by `structural` and is
//! not swept again here.
//!
//! # Not yet covered
//!
//!  - `Then` commands returned by an effect result, so chains of effects.
//!  - Effects owned by row scopes, and reducers on row states.
//!  - Change sinks (`OnChange`) as a command source.
//!  - Faults during the mount and unmount that a remount step performs.
//!
//! To replay a crash:
//!   python3 scripts/fuzz.py repro transactions <crash-file> --verbose

const std = @import("std");
const signals = @import("signals");
const native_host = @import("native_host");
const FuzzReader = @import("FuzzReader.zig");

/// The AFL++ executable is built with this file as its root. A panic there
/// must end at once: symbolizing a stack trace takes seconds, and so does a
/// core dump piped to a crash reporter, either of which AFL++ classifies as
/// a hang rather than the crash it is. The repro executable has its own root
/// and keeps the full trace for debugging.
pub const panic = std.debug.FullPanic(aflPanic);

fn aflPanic(message: []const u8, _: ?usize) noreturn {
    @branchHint(.cold);
    const stderr = &std.debug.lockStderr(&.{}).file_writer.interface;
    stderr.writeAll("panic: ") catch {};
    stderr.writeAll(message) catch {};
    stderr.writeAll("\n") catch {};
    if (@import("builtin").os.tag == .linux) {
        _ = std.os.linux.prctl(@intFromEnum(std.os.linux.PR.SET_DUMPABLE), 0, 0, 0, 0);
    }
    @trap();
}

const fixtures = native_host.fuzz_fixtures;
const abi = signals.abi;
const HostValue = signals.host_values.HostValue;
const FaultAllocator = signals.fault_allocator.FaultAllocator;
const Host = fixtures.Host;
const ValueCapability = fixtures.ValueCapability;
const BinderToken = fixtures.BinderToken;

const max_scalars = 3;
const max_list = 4;
const max_root_buttons = 4;
const max_steps = 10;
const max_writes = max_scalars + 1;
const max_effects = max_steps;
const root_timer_period: u64 = 100;
const branch_timer_period: u64 = 200;
/// Full sweeps are quadratic in the attempt count, so past this bound one attempt
/// per input keeps the fuzzer fast and lets coverage pick the position.
const max_full_sweep_attempts = 40;
const off_text = "off";
/// The engine numbers effects from one.
const first_effect_id: u64 = 1;

const StateRef = union(enum) {
    scalar: u8,
    scoped,
};

const WriteOp = union(enum) {
    /// Write a constant.
    set: i64,
    /// Write the handler's snapshot of its declared read plus a delta.
    set_from_snapshot: i64,
    /// Add a delta to the state's settled value at commit.
    transform: i64,
};

const WriteSpec = struct {
    target: StateRef,
    op: WriteOp,
};

/// The changes an effect's result carries. `set_from_snapshot` never appears
/// here: a result has no handler snapshot to read.
const EffectSpec = struct {
    writes: []const WriteSpec,
};

const ActionSpec = struct {
    reads: StateRef,
    writes: []const WriteSpec,
};

const Handler = union(enum) {
    reduce: struct { target: StateRef, amount: i64 },
    action: ActionSpec,
    then: struct { action: ActionSpec, effect: EffectSpec },
};

const ButtonSpec = struct {
    /// Index into `Program.buttons`; the scoped button is the last entry.
    index: u8,
    scoped: bool,
    kind: fixtures.EventKind,
    handler: Handler,

    fn testId(self: ButtonSpec, buffer: []u8) []const u8 {
        return if (self.scoped) "btn-s" else std.fmt.bufPrint(buffer, "btn-{d}", .{self.index}) catch unreachable;
    }
};

const Step = union(enum) {
    dispatch: struct { button: u8, payload: i64 },
    write_list: []const i64,
    write_scalar: struct { index: u8, value: i64 },
    write_many: struct { mask: u8, values: [max_scalars]i64 },
    tick_root,
    tick_branch,
    source_root: i64,
    source_branch: i64,
    start_effect,
    complete_effect: u8,
    remount,
};

const Program = struct {
    scalar_count: u8,
    initial: [max_scalars]i64,
    list: []const i64,
    /// The branch shows while the list holds at least this many items.
    threshold: u8,
    scoped_initial: i64,
    root_timer_initial: i64,
    branch_timer_initial: i64,
    /// Root buttons first, then the scoped button.
    buttons: []const ButtonSpec,
    steps: []const Step,

    fn branchShown(self: Program, list: []const i64) bool {
        return list.len >= self.threshold;
    }

    fn scopedButton(self: Program) ButtonSpec {
        return self.buttons[self.buttons.len - 1];
    }
};

const EffectRecord = struct {
    id: u64,
    spec: *const EffectSpec,
    /// The branch instantiation that queued the effect, or null for the root.
    owner_instance: ?u32,
};

const EffectQueue = struct {
    items: [max_effects]EffectRecord = undefined,
    len: usize = 0,

    fn push(self: *EffectQueue, record: EffectRecord) void {
        if (self.len == max_effects) fail("model effect queue overflowed", .{});
        self.items[self.len] = record;
        self.len += 1;
    }

    fn remove(self: *EffectQueue, index: usize) EffectRecord {
        const record = self.items[index];
        std.mem.copyForwards(EffectRecord, self.items[index .. self.len - 1], self.items[index + 1 .. self.len]);
        self.len -= 1;
        return record;
    }
};

const Model = struct {
    scalars: [max_scalars]i64,
    list: []const i64,
    scoped: ?i64,
    /// Counts branch instantiations, so an effect can tell whether the branch
    /// that queued it is the one still shown.
    branch_instance: u32,
    root_timer: i64,
    branch_timer: ?i64,
    pending: EffectQueue,
    running: EffectQueue,
    next_effect_id: u64,

    fn init(program: Program) Model {
        var model = Model{
            .scalars = program.initial,
            .list = program.list,
            .scoped = null,
            .branch_instance = 0,
            .root_timer = program.root_timer_initial,
            .branch_timer = null,
            .pending = .{},
            .running = .{},
            .next_effect_id = first_effect_id,
        };
        model.settleBranch(program);
        return model;
    }

    fn branchShown(self: *const Model, program: Program) bool {
        return program.branchShown(self.list);
    }

    /// Instantiates or retires the branch after the list changed.
    fn settleBranch(self: *Model, program: Program) void {
        const shown = self.branchShown(program);
        if (shown and self.scoped == null) {
            self.scoped = program.scoped_initial;
            self.branch_timer = program.branch_timer_initial;
            self.branch_instance += 1;
        } else if (!shown and self.scoped != null) {
            self.scoped = null;
            self.branch_timer = null;
        }
    }

    fn read(self: *const Model, target: StateRef) i64 {
        return switch (target) {
            .scalar => |index| self.scalars[index],
            .scoped => self.scoped orelse fail("model read a scoped state while the branch is hidden", .{}),
        };
    }

    fn write(self: *Model, target: StateRef, value: i64) void {
        switch (target) {
            .scalar => |index| self.scalars[index] = value,
            .scoped => self.scoped = value,
        }
    }

    /// Applies a handler-time batch: every destination is live, and a
    /// `set_from_snapshot` reads the snapshot taken before the batch.
    fn applyAction(self: *Model, action: ActionSpec, payload: i64) void {
        const snapshot = self.read(action.reads);
        for (action.writes) |spec| {
            const value = switch (spec.op) {
                .set => |constant| constant + payload,
                .set_from_snapshot => |d| snapshot + d + payload,
                .transform => |d| self.read(spec.target) + d + payload,
            };
            self.write(spec.target, value);
        }
    }

    fn applyDispatch(self: *Model, program: Program, button: ButtonSpec, payload: i64) void {
        switch (button.handler) {
            .reduce => |reduce| self.write(reduce.target, self.read(reduce.target) + reduce.amount + payload),
            .action => |action| self.applyAction(action, payload),
            .then => |then| {
                self.applyAction(then.action, payload);
                self.pending.push(.{
                    .id = self.next_effect_id,
                    .spec = &program.buttons[button.index].handler.then.effect,
                    .owner_instance = if (button.scoped) self.branch_instance else null,
                });
                self.next_effect_id += 1;
            },
        }
    }

    /// Applies an effect's result: writes to a state the branch retired since
    /// the effect was queued are skipped, the rest commit together.
    fn applyEffectResult(self: *Model, record: EffectRecord) void {
        for (record.spec.writes) |spec| {
            if (spec.target == .scoped) {
                const owner = record.owner_instance orelse fail("a root-owned effect names the scoped state", .{});
                if (self.scoped == null or owner != self.branch_instance) continue;
            }
            const value = switch (spec.op) {
                .set => |constant| constant,
                .set_from_snapshot => fail("an effect result carries a snapshot write", .{}),
                .transform => |d| self.read(spec.target) + d,
            };
            self.write(spec.target, value);
        }
    }

    /// Appends the text every DOM text node shows, in document order.
    fn texts(self: *const Model, program: Program, arena: std.mem.Allocator, out: *std.ArrayListUnmanaged([]const u8)) error{OutOfMemory}!void {
        for (self.scalars[0..program.scalar_count]) |value| try out.append(arena, try std.fmt.allocPrint(arena, "{d}", .{value + 1}));
        for (self.list) |item| try out.append(arena, try std.fmt.allocPrint(arena, "row-{d}", .{item}));
        if (self.scoped) |scoped| {
            try out.append(arena, try std.fmt.allocPrint(arena, "{d}", .{scoped + 1}));
            try out.append(arena, try std.fmt.allocPrint(arena, "{d}", .{self.branch_timer.?}));
        } else {
            try out.append(arena, off_text);
        }
        try out.append(arena, try std.fmt.allocPrint(arena, "{d}", .{self.root_timer}));
    }
};

/// AFL++ persistent-mode initialization hook.
pub export fn zig_fuzz_init() void {}

/// AFL++ persistent-mode entry point.
pub export fn zig_fuzz_test(buf: [*]u8, len: isize) void {
    zig_fuzz_test_inner(buf, len, false);
}

/// Runs one fuzz input.
pub fn zig_fuzz_test_inner(buf: [*]u8, len: isize, debug: bool) void {
    var reader = FuzzReader.init(buf[0..@intCast(len)]);

    var arena_state = std.heap.ArenaAllocator.init(std.heap.c_allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    verbose = debug;
    const program = generate(&reader, arena) catch fail("program arena exhausted", .{});
    if (debug) printProgram(program);

    const step_attempts = arena.alloc(usize, program.steps.len) catch fail("program arena exhausted", .{});
    @memset(step_attempts, 0);
    run(program, .{ .step_attempts = step_attempts });
    if (debug) {
        for (step_attempts, 0..) |attempts, index| std.debug.print("step {d} attempts: {d}\n", .{ index, attempts });
    }

    for (step_attempts, 0..) |attempts, step_index| {
        if (attempts == 0) continue;
        if (attempts <= max_full_sweep_attempts and reader.boolean()) {
            if (debug) std.debug.print("sweeping every attempt of step {d}\n", .{step_index});
            for (1..attempts + 1) |failure_number| run(program, .{ .faulted_step = step_index, .failure = failure_number });
        } else {
            const failure_number = 1 + reader.intRangeAtMost(usize, 0, attempts - 1);
            if (debug) std.debug.print("injecting step {d} failure at attempt {d}\n", .{ step_index, failure_number });
            run(program, .{ .faulted_step = step_index, .failure = failure_number });
        }
    }
}

// ---- Generation -----------------------------------------------------------

fn generate(reader: *FuzzReader, arena: std.mem.Allocator) error{OutOfMemory}!Program {
    var program: Program = undefined;
    program.scalar_count = reader.intRangeAtMost(u8, 1, max_scalars);
    for (&program.initial) |*value| value.* = smallValue(reader);
    program.list = try generateList(reader, arena);
    program.threshold = reader.intRangeAtMost(u8, 0, max_list + 1);
    program.scoped_initial = smallValue(reader);
    program.root_timer_initial = smallValue(reader);
    program.branch_timer_initial = smallValue(reader);

    const root_count = reader.intRangeAtMost(u8, 0, max_root_buttons);
    const buttons = try arena.alloc(ButtonSpec, root_count + 1);
    for (buttons, 0..) |*button, index| {
        const scoped = index == buttons.len - 1;
        button.* = .{
            .index = @intCast(index),
            .scoped = scoped,
            .kind = if (reader.boolean()) .click else .input,
            .handler = try generateHandler(reader, arena, program.scalar_count, scoped),
        };
    }
    program.buttons = buttons;

    const step_count = reader.intRangeAtMost(u8, 0, max_steps);
    const steps = try arena.alloc(Step, step_count);
    for (steps) |*step| step.* = try generateStep(reader, arena, program);
    program.steps = steps;
    return program;
}

fn smallValue(reader: *FuzzReader) i64 {
    return reader.intRangeAtMost(i64, -20, 20);
}

fn delta(reader: *FuzzReader) i64 {
    return reader.intRangeAtMost(i64, -5, 5);
}

/// Strictly increasing items, so every row key is distinct.
fn generateList(reader: *FuzzReader, arena: std.mem.Allocator) error{OutOfMemory}![]const i64 {
    const items = try arena.alloc(i64, reader.intRangeAtMost(usize, 0, max_list));
    var next: i64 = 0;
    for (items) |*item| {
        next += reader.intRangeAtMost(i64, 1, 2);
        item.* = next;
    }
    return items;
}

fn generateTarget(reader: *FuzzReader, scalar_count: u8, allow_scoped: bool) StateRef {
    if (allow_scoped and reader.boolean()) return .scoped;
    return .{ .scalar = reader.intRangeAtMost(u8, 0, scalar_count - 1) };
}

/// Draws a batch over distinct destinations: each candidate state is included
/// or not, so a batch may be empty, one state, or every state at once.
fn generateWrites(reader: *FuzzReader, arena: std.mem.Allocator, scalar_count: u8, allow_scoped: bool, allow_snapshot: bool) error{OutOfMemory}![]const WriteSpec {
    var buffer: [max_writes]WriteSpec = undefined;
    var count: usize = 0;
    for (0..scalar_count) |index| {
        if (!reader.boolean()) continue;
        buffer[count] = .{ .target = .{ .scalar = @intCast(index) }, .op = generateOp(reader, allow_snapshot) };
        count += 1;
    }
    if (allow_scoped and reader.boolean()) {
        buffer[count] = .{ .target = .scoped, .op = generateOp(reader, allow_snapshot) };
        count += 1;
    }
    return try arena.dupe(WriteSpec, buffer[0..count]);
}

fn generateOp(reader: *FuzzReader, allow_snapshot: bool) WriteOp {
    return switch (reader.intRangeAtMost(u8, 0, if (allow_snapshot) 2 else 1)) {
        0 => .{ .set = smallValue(reader) },
        1 => .{ .transform = delta(reader) },
        else => .{ .set_from_snapshot = delta(reader) },
    };
}

fn generateHandler(reader: *FuzzReader, arena: std.mem.Allocator, scalar_count: u8, scoped: bool) error{OutOfMemory}!Handler {
    return switch (reader.intRangeAtMost(u8, 0, 2)) {
        0 => .{ .reduce = .{ .target = generateTarget(reader, scalar_count, scoped), .amount = delta(reader) } },
        1 => .{ .action = try generateAction(reader, arena, scalar_count, scoped) },
        else => .{ .then = .{
            .action = try generateAction(reader, arena, scalar_count, scoped),
            .effect = .{ .writes = try generateWrites(reader, arena, scalar_count, scoped, false) },
        } },
    };
}

fn generateAction(reader: *FuzzReader, arena: std.mem.Allocator, scalar_count: u8, scoped: bool) error{OutOfMemory}!ActionSpec {
    return .{
        .reads = generateTarget(reader, scalar_count, scoped),
        .writes = try generateWrites(reader, arena, scalar_count, scoped, true),
    };
}

fn generateStep(reader: *FuzzReader, arena: std.mem.Allocator, program: Program) error{OutOfMemory}!Step {
    return switch (reader.intRangeAtMost(u8, 0, 10)) {
        0, 1, 2 => .{ .dispatch = .{ .button = reader.intRangeAtMost(u8, 0, @intCast(program.buttons.len - 1)), .payload = delta(reader) } },
        3 => .{ .write_list = try generateList(reader, arena) },
        4 => .{ .write_scalar = .{ .index = reader.intRangeAtMost(u8, 0, program.scalar_count - 1), .value = smallValue(reader) } },
        5 => blk: {
            var values: [max_scalars]i64 = undefined;
            for (&values) |*value| value.* = smallValue(reader);
            break :blk .{ .write_many = .{ .mask = reader.intRangeAtMost(u8, 0, (@as(u8, 1) << @intCast(program.scalar_count)) - 1), .values = values } };
        },
        6 => if (reader.boolean()) .tick_root else .tick_branch,
        7 => if (reader.boolean()) .{ .source_root = smallValue(reader) } else .{ .source_branch = smallValue(reader) },
        8 => .start_effect,
        9 => .{ .complete_effect = reader.readByte() },
        else => .remount,
    };
}

// ---- Debug printing --------------------------------------------------------

fn printTarget(target: StateRef) void {
    switch (target) {
        .scalar => |index| std.debug.print("S{d}", .{index}),
        .scoped => std.debug.print("T", .{}),
    }
}

fn sign(value: i64) []const u8 {
    return if (value >= 0) "+" else "";
}

fn printWrites(writes: []const WriteSpec) void {
    std.debug.print("[", .{});
    for (writes, 0..) |spec, index| {
        if (index != 0) std.debug.print(", ", .{});
        printTarget(spec.target);
        switch (spec.op) {
            .set => |constant| std.debug.print("={d}", .{constant}),
            .set_from_snapshot => |d| std.debug.print("=snap{s}{d}", .{ sign(d), d }),
            .transform => |d| std.debug.print("{s}{d}", .{ sign(d), d }),
        }
    }
    std.debug.print("]", .{});
}

fn printProgram(program: Program) void {
    std.debug.print("program: {d} scalars, initial", .{program.scalar_count});
    for (program.initial[0..program.scalar_count]) |value| std.debug.print(" {d}", .{value});
    std.debug.print(", list", .{});
    for (program.list) |item| std.debug.print(" {d}", .{item});
    std.debug.print(", branch while len>={d}, T0={d}, timers {d}/{d}\n", .{ program.threshold, program.scoped_initial, program.root_timer_initial, program.branch_timer_initial });
    for (program.buttons) |button| {
        std.debug.print("  button {d}{s} {t} ", .{ button.index, if (button.scoped) " (scoped)" else "", button.kind });
        switch (button.handler) {
            .reduce => |reduce| {
                std.debug.print("reduce ", .{});
                printTarget(reduce.target);
                std.debug.print(" {s}{d}\n", .{ sign(reduce.amount), reduce.amount });
            },
            .action => |action| {
                std.debug.print("action reads ", .{});
                printTarget(action.reads);
                std.debug.print(" writes ", .{});
                printWrites(action.writes);
                std.debug.print("\n", .{});
            },
            .then => |then| {
                std.debug.print("then reads ", .{});
                printTarget(then.action.reads);
                std.debug.print(" writes ", .{});
                printWrites(then.action.writes);
                std.debug.print(" effect ", .{});
                printWrites(then.effect.writes);
                std.debug.print("\n", .{});
            },
        }
    }
    for (program.steps, 0..) |step, index| {
        std.debug.print("  step {d}: ", .{index});
        switch (step) {
            .dispatch => |dispatch| std.debug.print("dispatch button {d} payload {d}\n", .{ dispatch.button, dispatch.payload }),
            .write_list => |list| {
                std.debug.print("write list", .{});
                for (list) |item| std.debug.print(" {d}", .{item});
                std.debug.print("\n", .{});
            },
            .write_scalar => |write| std.debug.print("write S{d} = {d}\n", .{ write.index, write.value }),
            .write_many => |write| {
                std.debug.print("write many", .{});
                for (0..program.scalar_count) |index_in| if (write.mask & (@as(u8, 1) << @intCast(index_in)) != 0) std.debug.print(" S{d}={d}", .{ index_in, write.values[index_in] });
                std.debug.print("\n", .{});
            },
            .tick_root => std.debug.print("tick root timer\n", .{}),
            .tick_branch => std.debug.print("tick branch timer\n", .{}),
            .source_root => |value| std.debug.print("root source result {d}\n", .{value}),
            .source_branch => |value| std.debug.print("branch source result {d}\n", .{value}),
            .start_effect => std.debug.print("start next effect\n", .{}),
            .complete_effect => |choice| std.debug.print("complete running effect #{d}\n", .{choice}),
            .remount => std.debug.print("unmount and mount again\n", .{}),
        }
    }
}

// ---- The mounted app -------------------------------------------------------

/// Capture of a reducer callable: the target state's capability, the
/// generated amount, and whether the payload is a string to parse.
const ReduceCapture = extern struct {
    cap: ValueCapability,
    amount: i64,
    text_payload: bool,
};

/// Capture of an action's command builder: which button it belongs to.
const ActionCapture = extern struct {
    button: u8,
    text_payload: bool,
};

/// Capture of a `Transform` change: the delta and the state's capability.
const TransformCapture = extern struct {
    cap: ValueCapability,
    delta: i64,
};

/// Capture of an effect closure: which button queued it.
const EffectCapture = extern struct {
    button: u8,
};

const RowCapture = extern struct {
    unused: u8 = 0,
};

/// One mounted instance of the program: the host, its Roc host table, and
/// the tokens and capabilities the callables resolve targets through.
const Mount = struct {
    host: Host,
    roc_host: abi.RocHost,
    tokens: [max_scalars]BinderToken,
    caps: [max_scalars]ValueCapability,
    list_token: BinderToken,
    list_cap: ValueCapability,
    scoped_token: BinderToken,
    scoped_cap: ValueCapability,
    root: abi.Elem,
    node_ids: [max_scalars]u64,
    list_node_id: u64,
    fault: FaultAllocator,

    /// Mounts `program` on a fresh host. The mount itself is not faulted.
    fn init(self: *Mount, program: Program) void {
        self.host = fixtures.createHost();
        self.roc_host = fixtures.bindHost(&self.host);
        self.host.engine.roc_host = &self.roc_host;
        current = self;
        const roc_host = &self.roc_host;
        for (self.tokens[0..program.scalar_count], self.caps[0..program.scalar_count]) |*token, *cap| {
            token.* = fixtures.newBinderToken(roc_host);
            cap.* = fixtures.valueCapability(roc_host);
        }
        self.list_token = fixtures.newBinderToken(roc_host);
        self.list_cap = fixtures.valueCapability(roc_host);
        self.scoped_token = fixtures.newBinderToken(roc_host);
        self.scoped_cap = fixtures.valueCapability(roc_host);
        self.root = buildRoot(self, program);

        self.fault = FaultAllocator.init(self.host.gpa.allocator());
        self.host.engine_allocator_override = self.fault.allocator();
        self.fault.configure(null);
        phase = "mount";
        _ = fixtures.renderInitialRootWithArmedPublication(&self.host, roc_host, self.root, &self.fault) catch |err| fail("unfaulted mount failed: {t}", .{err});

        const sites = self.host.engine.active_stream.scope_sites.items;
        var found: usize = 0;
        for (sites) |site| {
            if (site.kind != .state) continue;
            if (found < program.scalar_count) {
                self.node_ids[found] = site.node_id.raw();
            } else if (found == program.scalar_count) {
                self.list_node_id = site.node_id.raw();
            }
            found += 1;
        }
        if (found < program.scalar_count + 1) fail("mount published {d} state sites, expected at least {d}", .{ found, program.scalar_count + 1 });
    }

    /// Unmounts the program and tears the host down, failing on any leak.
    fn deinit(self: *Mount) void {
        self.root.decref(&self.roc_host);
        if (fixtures.destroyHost(&self.host)) fail("host allocator leaked", .{});
        current = null;
    }

    fn tokenOf(self: *const Mount, target: StateRef) BinderToken {
        return switch (target) {
            .scalar => |index| self.tokens[index],
            .scoped => self.scoped_token,
        };
    }

    fn capOf(self: *const Mount, target: StateRef) ValueCapability {
        return switch (target) {
            .scalar => |index| self.caps[index],
            .scoped => self.scoped_cap,
        };
    }

    /// The node id of the scoped state, which is the one live state site
    /// beyond the root's.
    fn scopedNodeId(self: *const Mount, program: Program) ?u64 {
        var found: usize = 0;
        for (self.host.engine.active_stream.scope_sites.items) |site| {
            if (site.kind != .state) continue;
            found += 1;
            if (found == program.scalar_count + 2) return site.node_id.raw();
        }
        return null;
    }
};

/// The mount the callables resolve through. A callable runs only inside a
/// transaction the target opened on this mount.
var current: ?*Mount = null;
var current_program: ?*const Program = null;

fn currentMount() *Mount {
    return current orelse fail("a callable ran with no mount", .{});
}

fn buildRoot(mount: *Mount, program: Program) abi.Elem {
    const roc_host = &mount.roc_host;
    var children: [max_scalars + 3 + max_root_buttons]abi.Elem = undefined;
    var count: usize = 0;
    for (mount.tokens[0..program.scalar_count]) |token| {
        children[count] = fixtures.i64TextSignal(roc_host, fixtures.mapExpr(roc_host, fixtures.refExpr(token)));
        count += 1;
    }
    children[count] = fixtures.eachOverStateListKeyOfRowAndCapture(RowCapture, roc_host, mount.list_token, mount.list_cap, &fixtures.bucketKeyCallable, .{ .amount = 1 }, &rowCallable, .{});
    count += 1;
    children[count] = fixtures.whenOnListPredicate(roc_host, mount.list_token, .length_at_least, program.threshold, buildBranch(mount, program), fixtures.text(roc_host, off_text));
    count += 1;
    for (program.buttons[0 .. program.buttons.len - 1]) |button| {
        children[count] = buildButton(mount, button);
        count += 1;
    }
    children[count] = fixtures.i64TextSignal(roc_host, fixtures.intervalSourceExpr(roc_host, root_timer_period, program.root_timer_initial));
    count += 1;

    var elem = fixtures.stateWithTokenInitialAndCapability(roc_host, mount.list_token, listValue(roc_host, program.list), fixtures.element(roc_host, children[0..count]), mount.list_cap);
    var index = program.scalar_count;
    while (index > 0) {
        index -= 1;
        elem = fixtures.stateWithTokenInitialAndCapability(roc_host, mount.tokens[index], fixtures.i64Value(program.initial[index]), elem, mount.caps[index]);
    }
    return elem;
}

fn buildBranch(mount: *Mount, program: Program) abi.Elem {
    const roc_host = &mount.roc_host;
    const children = [_]abi.Elem{
        fixtures.i64TextSignal(roc_host, fixtures.mapExpr(roc_host, fixtures.refExpr(mount.scoped_token))),
        fixtures.i64TextSignal(roc_host, fixtures.intervalSourceExpr(roc_host, branch_timer_period, program.branch_timer_initial)),
        buildButton(mount, program.scopedButton()),
    };
    return fixtures.stateWithTokenInitialAndCapability(roc_host, mount.scoped_token, fixtures.i64Value(program.scoped_initial), fixtures.element(roc_host, &children), mount.scoped_cap);
}

fn buildButton(mount: *Mount, button: ButtonSpec) abi.Elem {
    const roc_host = &mount.roc_host;
    var buffer: [16]u8 = undefined;
    const plan: fixtures.ExtractionPlan = if (button.kind == .input) .target_value else .none;
    const text_payload = button.kind == .input;
    const event_attr = switch (button.handler) {
        .reduce => |reduce| fixtures.eventReduceAttr(ReduceCapture, roc_host, button.kind, mount.tokenOf(reduce.target), plan, &reduceCallable, .{
            .cap = mount.capOf(reduce.target),
            .amount = reduce.amount,
            .text_payload = text_payload,
        }),
        .action => |action| fixtures.eventActionAttr(ActionCapture, roc_host, button.kind, plan, fixtures.refExpr(mount.tokenOf(action.reads)), &actionCallable, .{ .button = button.index, .text_payload = text_payload }),
        .then => |then| fixtures.eventActionAttr(ActionCapture, roc_host, button.kind, plan, fixtures.refExpr(mount.tokenOf(then.action.reads)), &actionCallable, .{ .button = button.index, .text_payload = text_payload }),
    };
    const attrs = [_]abi.NodeAttr{ fixtures.staticTextAttr(roc_host, .test_id, button.testId(&buffer)), event_attr };
    return fixtures.elementWith(roc_host, "button", &attrs, &.{});
}

fn listValue(roc_host: *abi.RocHost, items: []const i64) HostValue {
    var values: [max_list]HostValue = undefined;
    for (items, 0..) |item, index| values[index] = fixtures.i64Value(item);
    return fixtures.i64ListValue(roc_host, values[0..items.len]);
}

fn rowCallable(roc_host: *abi.RocHost, ret: ?[*]u8, args: ?[*]const u8, _: ?[*]u8, _: ?[*]u8, _: *?*const anyopaque) callconv(.c) void {
    const key = fixtures.eachRowKeyI64(roc_host, args);
    var buffer: [32]u8 = undefined;
    const label = std.fmt.bufPrint(&buffer, "row-{d}", .{key}) catch unreachable;
    fixtures.writeResult(abi.Elem, ret, fixtures.text(roc_host, label));
}

/// Decodes the payload a handler received: zero for a unit, the parsed
/// integer for a string.
fn payloadValue(roc_host: *abi.RocHost, raw: anytype, text_payload: bool) i64 {
    if (!text_payload) return 0;
    var text = fixtures.readStr(roc_host, raw);
    defer text.decref(roc_host);
    return std.fmt.parseInt(i64, text.asSlice(), 10) catch fail("event payload '{s}' is not an integer", .{text.asSlice()});
}

fn reduceCallable(roc_host: *abi.RocHost, ret: ?[*]u8, args: ?[*]const u8, capture_ptr: ?[*]u8, _: ?[*]u8, _: *?*const anyopaque) callconv(.c) void {
    const capture = fixtures.captureAs(ReduceCapture, capture_ptr);
    const values = fixtures.argsAs(signals.erased_calls.ErasedHostValueTernaryArgs, args);
    const next = fixtures.readI64(roc_host, values.arg0) + capture.amount + payloadValue(roc_host, values.arg2, capture.text_payload);
    fixtures.writeResult(HostValue, ret, fixtures.i64ValueWithCapability(roc_host, next, capture.cap));
}

fn transformCallable(roc_host: *abi.RocHost, ret: ?[*]u8, args: ?[*]const u8, capture_ptr: ?[*]u8, _: ?[*]u8, _: *?*const anyopaque) callconv(.c) void {
    const capture = fixtures.captureAs(TransformCapture, capture_ptr);
    const values = fixtures.argsAs(signals.erased_calls.ErasedHostValueUnaryArgs, args);
    const next = fixtures.readI64(roc_host, values.arg0) + capture.delta;
    fixtures.writeResult(HostValue, ret, fixtures.i64ValueWithCapability(roc_host, next, capture.cap));
}

/// The effect thunk. The fuzz build never runs a thunk: the target reads its
/// capture and delivers a generated result instead.
fn effectCallable(_: *abi.RocHost, _: ?[*]u8, _: ?[*]const u8, _: ?[*]u8, _: ?[*]u8, _: *?*const anyopaque) callconv(.c) void {
    fail("an effect thunk ran; the fuzz host delivers results itself", .{});
}

/// Builds the changes of a handler batch or an effect result. `snapshot` is
/// the handler's declared read, absent for a result; `payload` is added to
/// every handler-time value.
fn buildChanges(mount: *Mount, writes: []const WriteSpec, snapshot: ?i64, payload: i64, buffer: *[max_writes]abi.NodeStateChange) []const abi.NodeStateChange {
    const roc_host = &mount.roc_host;
    for (writes, 0..) |spec, index| {
        const token = mount.tokenOf(spec.target);
        const cap = mount.capOf(spec.target);
        buffer[index] = switch (spec.op) {
            .set => |constant| fixtures.stateSetChange(roc_host, token, cap, fixtures.i64ValueWithCapability(roc_host, constant + payload, cap)),
            .set_from_snapshot => |d| fixtures.stateSetChange(roc_host, token, cap, fixtures.i64ValueWithCapability(roc_host, (snapshot orelse fail("a result write reads a snapshot", .{})) + d + payload, cap)),
            .transform => |d| fixtures.stateTransformChange(TransformCapture, roc_host, token, cap, &transformCallable, .{ .cap = cap, .delta = d + payload }),
        };
    }
    return buffer[0..writes.len];
}

fn actionCallable(roc_host: *abi.RocHost, ret: ?[*]u8, args: ?[*]const u8, capture_ptr: ?[*]u8, _: ?[*]u8, _: *?*const anyopaque) callconv(.c) void {
    const capture = fixtures.captureAs(ActionCapture, capture_ptr);
    const values = fixtures.argsAs(signals.erased_calls.ErasedHostValueBinaryArgs, args);
    const mount = currentMount();
    const program = current_program orelse fail("an action ran with no program", .{});
    const snapshot = fixtures.readI64(roc_host, values.arg0);
    const payload = payloadValue(roc_host, values.arg1, capture.text_payload);
    var buffer: [max_writes]abi.NodeStateChange = undefined;
    const cmd = switch (program.buttons[capture.button].handler) {
        .reduce => fail("a reducer button ran an action callable", .{}),
        .action => |action| fixtures.updateChangesCmd(roc_host, buildChanges(mount, action.writes, snapshot, payload, &buffer)),
        .then => |then| fixtures.thenCmd(EffectCapture, roc_host, buildChanges(mount, then.action.writes, snapshot, payload, &buffer), &effectCallable, .{ .button = capture.button }),
    };
    fixtures.writeResult(fixtures.Cmd, ret, cmd);
}

// ---- Running a program -----------------------------------------------------

const Plan = struct {
    /// Index of the step whose transaction gets the injected failure.
    faulted_step: ?usize = null,
    failure: ?usize = null,
    /// Filled with each step's transaction attempt count on an unfaulted run.
    step_attempts: ?[]usize = null,
};

/// A running effect the target holds between starting and completing it.
const Started = struct {
    id: u64,
    button: u8,
};

const Run = struct {
    program: Program,
    mount: Mount = undefined,
    model: Model,
    started: [max_effects]Started = undefined,
    started_len: usize = 0,
};

fn run(program: Program, plan: Plan) void {
    var state = Run{ .program = program, .model = Model.init(program) };
    current_program = &state.program;
    defer current_program = null;
    state.mount.init(program);
    defer state.mount.deinit();
    expectModel(&state.mount, program, &state.model);

    for (program.steps, 0..) |step, index| {
        current_step = index;
        const failure = if (plan.faulted_step != null and plan.faulted_step.? == index) plan.failure else null;
        const attempts = runStep(&state, step, failure);
        if (plan.step_attempts) |slots| slots[index] = attempts;
        if (verbose and plan.step_attempts != null) printModel(index, &state.model);
    }
    current_step = null;
}

/// What one step does to the engine, in a form the fault wrapper can attempt
/// twice: once faulted, then again on the same host.
const Transaction = union(enum) {
    dispatch: struct { event_id: u64, button: ButtonSpec, payload: i64 },
    write_list: []const i64,
    write_scalar: struct { index: u8, value: i64 },
    write_many: struct { mask: u8, values: [max_scalars]i64 },
    /// A timer tick: unfaulted through the engine's tick entry, faulted
    /// through the source seam with the same next value.
    tick: struct { period: u64 },
    source: struct { period: u64, value: i64 },
    /// An effect result. The engine has already handed over the running
    /// record, so the model no longer counts the effect as running either;
    /// its writes apply once the command commits.
    complete_effect: struct { record: EffectRecord, running: *fixtures.RunningEffect, cmd: fixtures.Cmd },
};

fn attempt(mount: *Mount, txn: Transaction, faulted: bool) fixtures.NativeEngine.CollectionError!void {
    const host = &mount.host;
    const roc_host = &mount.roc_host;
    switch (txn) {
        .dispatch => |dispatch| {
            var buffer: [16]u8 = undefined;
            const payload: fixtures.EventPayload = if (dispatch.button.kind == .input)
                .{ .text = std.fmt.bufPrint(&buffer, "{d}", .{dispatch.payload}) catch unreachable }
            else
                .unit;
            _ = try fixtures.dispatchEvent(host, roc_host, dispatch.event_id, payload);
        },
        .write_list => |list| _ = try fixtures.dispatchStateValue(host, roc_host, mount.list_node_id, listValue(roc_host, list), mount.list_cap),
        .write_scalar => |write| _ = try fixtures.dispatchStateValue(host, roc_host, mount.node_ids[write.index], fixtures.i64Value(write.value), mount.caps[write.index]),
        .write_many => |write| {
            var writes: [max_scalars]fixtures.StateWrite = undefined;
            var count: usize = 0;
            for (0..max_scalars) |index| {
                if (write.mask & (@as(u8, 1) << @intCast(index)) == 0) continue;
                writes[count] = .{ .state_id = mount.node_ids[index], .value = fixtures.i64Value(write.values[index]), .cap = mount.caps[index] };
                count += 1;
            }
            _ = try fixtures.dispatchStateWrites(host, roc_host, writes[0..count]);
        },
        .tick => |tick| {
            if (faulted) {
                const record = fixtures.intervalRecord(host, tick.period) orelse fail("no interval with period {d} to tick", .{tick.period});
                const next = fixtures.intervalValue(host, roc_host, record) + 1;
                _ = try fixtures.dispatchEffectSourceValue(host, roc_host, record, fixtures.i64ValueWithCapability(roc_host, next, fixtures.intervalCapability(record)));
            } else {
                const token = fixtures.intervalRuntimeToken(host, tick.period) orelse fail("no interval with period {d} to tick", .{tick.period});
                _ = fixtures.tickInterval(host, roc_host, token);
            }
        },
        .source => |source| {
            const record = fixtures.intervalRecord(host, source.period) orelse fail("no interval with period {d} to deliver to", .{source.period});
            _ = try fixtures.dispatchEffectSourceValue(host, roc_host, record, fixtures.i64ValueWithCapability(roc_host, source.value, fixtures.intervalCapability(record)));
        },
        .complete_effect => |complete| _ = try fixtures.applyEffectResult(host, roc_host, complete.running, complete.cmd),
    }
}

/// Runs one step: builds its transaction, applies the plan's fault, checks
/// the refusal, retries, applies the model, and checks the publication.
/// Returns the transaction's attempt count, zero for a step that opened none.
fn runStep(state: *Run, step: Step, failure: ?usize) usize {
    const program = state.program;
    const model = &state.model;
    const mount = &state.mount;
    var buffer: [16]u8 = undefined;

    const txn: Transaction = switch (step) {
        .dispatch => |dispatch| blk: {
            const button = program.buttons[dispatch.button];
            if (button.scoped and model.scoped == null) {
                phase = "hidden scoped button";
                if (fixtures.activeEventIdByTestId(&mount.host, "btn-s", button.kind) != null) fail("the scoped button is bound while the branch is hidden", .{});
                return 0;
            }
            const event_id = fixtures.activeEventIdByTestId(&mount.host, button.testId(&buffer), button.kind) orelse fail("button {d} has no active {t} binding", .{ button.index, button.kind });
            // A click carries a unit payload; only an input event carries the
            // generated amount as text.
            break :blk .{ .dispatch = .{ .event_id = event_id, .button = button, .payload = if (button.kind == .input) dispatch.payload else 0 } };
        },
        .write_list => |list| .{ .write_list = list },
        .write_scalar => |write| .{ .write_scalar = .{ .index = write.index, .value = write.value } },
        .write_many => |write| .{ .write_many = .{ .mask = write.mask, .values = write.values } },
        .tick_root => .{ .tick = .{ .period = root_timer_period } },
        .tick_branch => if (model.scoped == null) return 0 else .{ .tick = .{ .period = branch_timer_period } },
        .source_root => |value| .{ .source = .{ .period = root_timer_period, .value = value } },
        .source_branch => |value| if (model.scoped == null) return 0 else .{ .source = .{ .period = branch_timer_period, .value = value } },
        .start_effect => {
            phase = "start effect";
            if (model.pending.len == 0) {
                if (fixtures.startNextEffect(&mount.host) != null) fail("engine handed out an effect the model has not queued", .{});
                return 0;
            }
            const expected = model.pending.remove(0);
            const started = fixtures.startNextEffect(&mount.host) orelse fail("engine has no pending effect, model expects id {d}", .{expected.id});
            defer fixtures.releaseCallable(&mount.roc_host, started.thunk);
            if (started.id != expected.id) fail("engine started effect {d}, model expects {d}", .{ started.id, expected.id });
            const capture = fixtures.callableCapture(EffectCapture, started.thunk);
            if (&program.buttons[capture.button].handler.then.effect != expected.spec) fail("effect {d} carries button {d}'s closure, model expects another", .{ started.id, capture.button });
            model.running.push(expected);
            state.started[state.started_len] = .{ .id = started.id, .button = capture.button };
            state.started_len += 1;
            expectModel(mount, program, model);
            return 0;
        },
        .complete_effect => |choice| blk: {
            if (model.running.len == 0) return 0;
            const record = model.running.remove(choice % model.running.len);
            const slot = for (state.started[0..state.started_len], 0..) |started, slot| {
                if (started.id == record.id) break slot;
            } else fail("running effect {d} was never started", .{record.id});
            std.mem.copyForwards(Started, state.started[slot .. state.started_len - 1], state.started[slot + 1 .. state.started_len]);
            state.started_len -= 1;
            const running = std.heap.c_allocator.create(fixtures.RunningEffect) catch fail("out of memory holding a running effect", .{});
            running.* = fixtures.finishRunningEffect(&mount.host, record.id);
            var changes: [max_writes]abi.NodeStateChange = undefined;
            const cmd = fixtures.updateChangesCmd(&mount.roc_host, buildChanges(mount, record.spec.writes, null, 0, &changes));
            break :blk .{ .complete_effect = .{ .record = record, .running = running, .cmd = cmd } };
        },
        .remount => {
            phase = "unmount";
            mount.deinit();
            model.* = Model.init(program);
            state.started_len = 0;
            mount.init(program);
            phase = "mount again";
            expectModel(mount, program, model);
            return 0;
        },
    };

    const host = &mount.host;
    const before = model.*;
    const allocations_before = host.roc_allocations.snapshot();
    const retains_before = closureRetains(host);
    const releases_before = closureReleases(host);
    const events_before = fixtures.activeEventCount(host);

    mount.fault.configure(failure);
    phase = if (failure != null) "faulted transaction" else "unfaulted transaction";
    const result = attempt(mount, txn, failure != null);
    const attempts = mount.fault.attempts;

    if (failure) |number| {
        if (mount.fault.induced_failures == 0) {
            // The fault fell outside the recoverable seam - for a tick, in
            // the pure evaluation the seam does not repeat - so the
            // transaction ran whole.
            if (txn != .tick) fail("failure at attempt {d} was never induced", .{number});
            _ = result catch |err| fail("tick with an uninduced fault at attempt {d} failed: {t}", .{ number, err });
        } else {
            expectRefusal(result, number);
            expectModel(mount, program, &before);
            if (fixtures.activeEventCount(host) != events_before) fail("refusal at attempt {d} changed the active event table", .{number});
            const retains = closureRetains(host) - retains_before;
            const releases = closureReleases(host) - releases_before;
            if (retains != releases) fail("refusal at attempt {d} left {d} retains against {d} releases", .{ number, retains, releases });
            if (host.roc_allocations.liveCountSince(allocations_before) != 0 or host.roc_allocations.snapshot().live_bytes != allocations_before.live_bytes) {
                fail("refusal at attempt {d} leaked Roc allocations", .{number});
            }
            mount.fault.configure(null);
            phase = "transaction retried after a refusal";
            attempt(mount, txn, false) catch |err| fail("retry after refusal at attempt {d} failed: {t}", .{ number, err });
        }
    } else {
        result catch |err| fail("unfaulted transaction failed: {t}", .{err});
    }

    switch (txn) {
        .dispatch => |dispatch| model.applyDispatch(program, dispatch.button, dispatch.payload),
        .write_list => |list| {
            model.list = list;
            model.settleBranch(program);
        },
        .write_scalar => |write| model.scalars[write.index] = write.value,
        .write_many => |write| for (0..max_scalars) |index| {
            if (write.mask & (@as(u8, 1) << @intCast(index)) != 0) model.scalars[index] = write.values[index];
        },
        .tick => |tick| if (tick.period == root_timer_period) {
            model.root_timer += 1;
        } else {
            model.branch_timer.? += 1;
        },
        .source => |source| if (source.period == root_timer_period) {
            model.root_timer = source.value;
        } else {
            model.branch_timer = source.value;
        },
        .complete_effect => |complete| {
            model.applyEffectResult(complete.record);
            fixtures.releaseFinishedEffect(host, complete.running);
            std.heap.c_allocator.destroy(complete.running);
            fixtures.releaseCmd(&mount.roc_host, complete.cmd);
        },
    }
    phase = "after the transaction";
    expectModel(mount, program, model);
    return attempts;
}

/// Closure retains so far on this host. The fixtures fold the pending
/// metrics of each transaction into the cumulative ones, so the sum is the
/// only count that is stable across a transaction boundary.
fn closureRetains(host: *const Host) u64 {
    return host.engine.last_runtime_metrics.closure_retains + host.engine.pending_roc_metrics.closure_retains;
}

fn closureReleases(host: *const Host) u64 {
    return host.engine.last_runtime_metrics.closure_releases + host.engine.pending_roc_metrics.closure_releases;
}

/// Asserts an injected allocation failure was refused, and refused honestly.
fn expectRefusal(result: anytype, failure_number: usize) void {
    if (result) |_| {
        fail("transaction with failure at attempt {d} did not refuse", .{failure_number});
    } else |err| if (err != error.OutOfMemory) {
        fail("transaction with failure at attempt {d} was refused as {t}, not an allocation failure", .{ failure_number, err });
    }
}

// ---- Oracles ---------------------------------------------------------------

fn expectModel(mount: *Mount, program: Program, model: *const Model) void {
    const host = &mount.host;
    const roc_host = &mount.roc_host;
    for (0..program.scalar_count) |index| {
        const raw = fixtures.stateValue(host, mount.node_ids[index]) orelse fail("root state S{d} is not live", .{index});
        const actual = fixtures.readI64(roc_host, raw);
        if (actual != model.scalars[index]) fail("S{d} holds {d}, model expects {d}", .{ index, actual, model.scalars[index] });
    }
    const expected_states: usize = @as(usize, program.scalar_count) + 1 + @as(usize, @intFromBool(model.scoped != null));
    if (host.engine.states.items.len != expected_states) fail("engine owns {d} states, model expects {d}", .{ host.engine.states.items.len, expected_states });
    if (model.scoped) |scoped| {
        const node_id = mount.scopedNodeId(program) orelse fail("the scoped state is not live", .{});
        const raw = fixtures.stateValue(host, node_id) orelse fail("the scoped state is not live", .{});
        const actual = fixtures.readI64(roc_host, raw);
        if (actual != scoped) fail("T holds {d}, model expects {d}", .{ actual, scoped });
    }
    const expected_intervals: usize = 1 + @as(usize, @intFromBool(model.scoped != null));
    if (fixtures.activeIntervalCount(host) != expected_intervals) fail("engine registers {d} intervals, model expects {d}", .{ fixtures.activeIntervalCount(host), expected_intervals });
    if (fixtures.intervalRuntimeToken(host, root_timer_period) == null) fail("the root interval is not registered", .{});
    if ((fixtures.intervalRuntimeToken(host, branch_timer_period) != null) != (model.scoped != null)) fail("the branch interval registration does not follow the branch", .{});
    if (fixtures.pendingEffectCount(host) != model.pending.len) fail("engine queues {d} pending effects, model expects {d}", .{ fixtures.pendingEffectCount(host), model.pending.len });
    if (fixtures.runningEffectCount(host) != model.running.len) fail("engine tracks {d} running effects, model expects {d}", .{ fixtures.runningEffectCount(host), model.running.len });
    expectDocumentOrder(mount, program, model);
    host.engine.validateActiveScopeSiteInsertIndexes();
}

/// Asserts the committed render tree reads exactly as the model does.
fn expectDocumentOrder(mount: *Mount, program: Program, model: *const Model) void {
    var arena_state = std.heap.ArenaAllocator.init(std.heap.c_allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var expected: std.ArrayListUnmanaged([]const u8) = .empty;
    model.texts(program, arena, &expected) catch fail("oracle arena exhausted", .{});
    var actual: std.ArrayListUnmanaged([]const u8) = .empty;
    collectRenderTexts(&mount.host, arena, &actual, fixtures.render_root) catch fail("oracle arena exhausted", .{});
    const mismatch = for (0..@min(expected.items.len, actual.items.len)) |index| {
        if (!std.mem.eql(u8, expected.items[index], actual.items[index])) break index;
    } else if (expected.items.len != actual.items.len) @min(expected.items.len, actual.items.len) else return;
    std.debug.print("expected document text order:", .{});
    for (expected.items) |text| std.debug.print(" {s}", .{text});
    std.debug.print("\nactual document text order:  ", .{});
    for (actual.items) |text| std.debug.print(" {s}", .{text});
    std.debug.print("\n", .{});
    fail("render tree text order diverges from the model at text {d}", .{mismatch});
}

fn collectRenderTexts(host: *const Host, arena: std.mem.Allocator, out: *std.ArrayListUnmanaged([]const u8), parent: signals.ids.ElemId) error{OutOfMemory}!void {
    for (fixtures.publishedChildren(host, parent)) |child_raw| {
        const child = signals.ids.ElemId.fromRaw(child_raw);
        if (fixtures.renderText(host, child)) |text| try out.append(arena, text);
        try collectRenderTexts(host, arena, out, child);
    }
}

/// Which transaction of the current run the oracles are judging, named in
/// every failure so a replay says where the model and engine parted.
var phase: []const u8 = "before the mount";
var current_step: ?usize = null;
var verbose = false;

fn printModel(step_index: usize, model: *const Model) void {
    std.debug.print("  after step {d}: S =", .{step_index});
    for (model.scalars) |value| std.debug.print(" {d}", .{value});
    std.debug.print(", list len {d}, T = ", .{model.list.len});
    if (model.scoped) |scoped| std.debug.print("{d}", .{scoped}) else std.debug.print("hidden", .{});
    std.debug.print(", timers {d}/", .{model.root_timer});
    if (model.branch_timer) |timer| std.debug.print("{d}", .{timer}) else std.debug.print("-", .{});
    std.debug.print(", pending {d}, running {d}\n", .{ model.pending.len, model.running.len });
}

fn fail(comptime fmt: []const u8, args: anytype) noreturn {
    if (current_step) |index| {
        std.debug.print("transactions fuzz oracle failed (step {d}, {s}): " ++ fmt ++ "\n", .{ index, phase } ++ args);
    } else {
        std.debug.print("transactions fuzz oracle failed ({s}): " ++ fmt ++ "\n", .{phase} ++ args);
    }
    @panic("transactions fuzz oracle failed");
}
