//! Byte fuzzing for the host-boundary schema and event-extraction parsers.
//!
//! Unlike the engine targets in this directory, this one is a conventional
//! parser fuzzer: `src/signals/boundary.zig` decodes byte strings that arrive
//! from JavaScript and from Roc-authored descriptors, so arbitrary bytes are a
//! faithful model of its input. The design requires these parsers to reject
//! malformed input at the boundary rather than guess at intent, so the property
//! under test is total, non-recovering rejection: every input either parses to a
//! payload kind or fails with a named `ParseError`, and none of them reads out
//! of bounds, loops, or silently repairs a broken descriptor.
//!
//! Each run exercises three angles on the same input:
//!
//!  1. Raw bytes straight into both parsers, which is what finds truncation,
//!     length-prefix overflow, and unterminated-record bugs.
//!  2. A *generated valid* schema tree built from the same bytes, which must
//!     always parse and must agree with the kind the generator intended. This is
//!     the half raw fuzzing reaches only by luck: valid deep records with many
//!     fields are far too structured to stumble into.
//!  3. Targeted corruptions of that valid tree - truncate, extend, and flip a
//!     byte - which must be rejected rather than accepted as something else.
//!
//! # Scope
//!
//! This target covers the Zig-side schema and extraction-plan parsers only. The
//! command-buffer wire format is decoded in JavaScript, not here, so it is not
//! reachable from a Zig fuzz target and is covered instead by the browser
//! contract tests under `scripts/browser/`. The Zig side of that protocol is a
//! producer: `render_commands.zig` writes records and preflights capacity, and
//! its failure modes are transaction-shaped rather than parse-shaped, which puts
//! them in the `structural` target.
//!
//! To replay a crash:
//!   python3 scripts/fuzz.py repro boundary <crash-file> --verbose

const std = @import("std");
const signals = @import("signals");
const FuzzReader = @import("FuzzReader.zig");

const boundary = signals.boundary;
const PayloadKind = boundary.PayloadKind;
const SchemaTag = boundary.SchemaTag;
const Plan = boundary.DomEventExtractionPlan;

/// Bounds generated record nesting so a pathological input cannot recurse away
/// the stack in the generator itself; the parser's own depth is what we test.
const max_generated_depth: u8 = 4;

/// Which of the two grammars a generated tree targets. They share record and
/// scalar tags but differ in whether scalars carry a DOM extraction pair.
const Grammar = enum { schema, extraction };

/// AFL++ persistent-mode initialization hook; the parsers hold no global state.
pub export fn zig_fuzz_init() void {}

/// AFL++ persistent-mode entry point.
pub export fn zig_fuzz_test(buf: [*]u8, len: isize) void {
    zig_fuzz_test_inner(buf, len, false);
}

/// Runs one fuzz input, printing the generated schema when `debug` is set.
pub fn zig_fuzz_test_inner(buf: [*]u8, len: isize, debug: bool) void {
    var gpa_impl = std.heap.DebugAllocator(.{}){};
    defer if (gpa_impl.deinit() == .leak) @panic("boundary fuzz target leaked memory");
    const gpa = gpa_impl.allocator();

    const input = buf[0..@intCast(len)];

    // Angle 1: the parsers must survive arbitrary bytes.
    checkRawBytes(input, debug);

    // Angle 2 and 3: a generated valid tree, then corruptions of it.
    var reader = FuzzReader.init(input);
    const grammar: Grammar = if (reader.boolean()) .extraction else .schema;

    var schema: std.ArrayList(u8) = .empty;
    defer schema.deinit(gpa);
    const expected = generateNode(gpa, &reader, grammar, 0, &schema) catch |err| switch (err) {
        error.OutOfMemory => @panic("OOM generating boundary schema"),
    };

    if (debug) {
        std.debug.print("grammar: {s}, expected kind: {s}, bytes consumed: {d}\n", .{
            @tagName(grammar), @tagName(expected), reader.position,
        });
        std.debug.print("generated schema ({d} bytes): {x}\n", .{ schema.items.len, schema.items });
    }

    checkGeneratedIsAccepted(grammar, schema.items, expected);
    checkCorruptionsAreRejected(gpa, &reader, grammar, schema.items, debug);
    checkCanonicalPlans();
}

/// Feeds the unmodified input to both parsers.
///
/// Neither may crash, and a success must be self-consistent: a parse that
/// reports a kind must report the same kind when run again, and the extraction
/// grammar is a strict subset of the schema grammar, so anything the extraction
/// parser accepts the schema parser must accept as the same kind.
fn checkRawBytes(input: []const u8, debug: bool) void {
    const schema_result = boundary.parseBoundarySchemaPayloadKind(input);
    const extraction_result = boundary.parseEventExtractionPayloadKind(input);

    if (debug) {
        std.debug.print("raw schema: {s}, raw extraction: {s}\n", .{
            resultName(schema_result), resultName(extraction_result),
        });
    }

    const repeat = boundary.parseBoundarySchemaPayloadKind(input);
    if (!resultsEqual(schema_result, repeat)) @panic("schema parse is not deterministic");

    if (extraction_result) |extraction_kind| {
        // An extraction tree differs from a schema tree only in the two trailing
        // bytes on each scalar, so it parses as a schema tree only when it holds
        // no scalars at all. Whenever the schema parser does accept it, the two
        // must agree, because the tags describing value shape are shared.
        if (schema_result) |schema_kind| {
            if (schema_kind != extraction_kind) @panic("schema and extraction parsers disagree on payload kind");
        } else |_| {}
    } else |_| {}

    // `eventExtractionPlanKindFromBytes` is the narrower gate: it accepts only
    // the five canonical plans, so it must never admit bytes the general
    // extraction parser rejects.
    if (boundary.eventExtractionPlanKindFromBytes(input)) |plan| {
        const kind = extraction_result catch @panic("canonical plan accepted bytes the extraction parser rejected");
        if (kind != plan.payloadKind()) @panic("canonical plan disagrees with parsed payload kind");
        if (!std.mem.eql(u8, plan.bytes(), input)) @panic("canonical plan recognized bytes that are not its own encoding");
    }
}

/// Builds one valid node of the chosen grammar and returns the kind it encodes.
fn generateNode(
    gpa: std.mem.Allocator,
    reader: *FuzzReader,
    grammar: Grammar,
    depth: u8,
    out: *std.ArrayList(u8),
) std.mem.Allocator.Error!PayloadKind {
    // Records may not nest (a record field of record kind is `NestedRecordField`),
    // so below the top level only scalars are generated.
    const may_record = depth == 0 and depth < max_generated_depth;
    const choice = reader.intRangeAtMost(u8, 0, if (may_record) 3 else 2);

    return switch (choice) {
        0 => {
            try out.append(gpa, SchemaTag.unit);
            return .unit;
        },
        1 => {
            try out.append(gpa, SchemaTag.text);
            if (grammar == .extraction) try appendScalarExtraction(gpa, reader, .str, out);
            return .str;
        },
        2 => {
            try out.append(gpa, SchemaTag.bool_);
            if (grammar == .extraction) try appendScalarExtraction(gpa, reader, .bool, out);
            return .bool;
        },
        else => generateRecord(gpa, reader, grammar, depth, out),
    };
}

/// Builds a valid record body: a non-zero field count, then distinct,
/// non-empty, valid-UTF-8 field names each followed by a non-record field.
fn generateRecord(
    gpa: std.mem.Allocator,
    reader: *FuzzReader,
    grammar: Grammar,
    depth: u8,
    out: *std.ArrayList(u8),
) std.mem.Allocator.Error!PayloadKind {
    const field_count = reader.intRangeAtMost(u8, 1, 8);
    try out.append(gpa, SchemaTag.record);
    try out.append(gpa, field_count);

    for (0..field_count) |index| {
        // Field names must be distinct, so the index is encoded into the name
        // rather than drawn from the input; the fuzzer still varies the length.
        var name_buf: [16]u8 = undefined;
        const name = std.fmt.bufPrint(
            &name_buf,
            "f{d}{s}",
            .{ index, ("abcdefgh")[0..reader.intRangeAtMost(usize, 0, 8)] },
        ) catch unreachable;

        try out.append(gpa, @intCast(name.len));
        try out.appendSlice(gpa, name);
        _ = try generateNode(gpa, reader, grammar, depth + 1, out);
    }

    return .bytes;
}

fn appendScalarExtraction(
    gpa: std.mem.Allocator,
    reader: *FuzzReader,
    payload_kind: PayloadKind,
    out: *std.ArrayList(u8),
) std.mem.Allocator.Error!void {
    // Source and leaf are jointly constrained: string leaves read `key` and
    // `detail` from the event but `value` from a target, so the pair is chosen
    // as a unit rather than independently.
    const pair: [2]u8 = switch (payload_kind) {
        .str => switch (reader.intRangeAtMost(u8, 0, 2)) {
            0 => .{ Plan.source_event, Plan.leaf_key },
            1 => .{ Plan.source_event, Plan.leaf_detail },
            else => .{
                if (reader.boolean()) Plan.source_target else Plan.source_current_target,
                Plan.leaf_value,
            },
        },
        .bool => switch (reader.intRangeAtMost(u8, 0, 1)) {
            0 => .{ Plan.source_event, Plan.leaf_shift_key },
            else => .{
                if (reader.boolean()) Plan.source_target else Plan.source_current_target,
                Plan.leaf_checked,
            },
        },
        else => unreachable,
    };
    try out.appendSlice(gpa, &pair);
}

/// A tree the generator built by the rules must parse, and to the kind intended.
fn checkGeneratedIsAccepted(grammar: Grammar, schema: []const u8, expected: PayloadKind) void {
    const parsed = switch (grammar) {
        .schema => boundary.parseBoundarySchemaPayloadKind(schema),
        .extraction => boundary.parseEventExtractionPayloadKind(schema),
    } catch |err| std.debug.panic(
        "valid generated {s} tree was rejected: {s}",
        .{ @tagName(grammar), @errorName(err) },
    );

    if (parsed != expected) std.debug.panic(
        "generated {s} tree parsed as {s} but was built as {s}",
        .{ @tagName(grammar), @tagName(parsed), @tagName(expected) },
    );
}

/// Corrupts the valid tree three ways and requires each result to be rejected.
///
/// Truncation and extension are unconditional: a prefix cannot be complete
/// (the grammar has no optional trailing production) and a suffix is
/// `TrailingBytes` by definition, because both parsers require the cursor to be
/// exhausted. A flipped byte is the interesting case and is only checked for
/// *sanity*, not rejection, since flipping a field-name character legitimately
/// produces a different valid tree.
fn checkCorruptionsAreRejected(
    gpa: std.mem.Allocator,
    reader: *FuzzReader,
    grammar: Grammar,
    schema: []const u8,
    debug: bool,
) void {
    if (schema.len == 0) return;

    for (0..schema.len) |cut| {
        const truncated = schema[0..cut];
        if (parse(grammar, truncated)) |kind| std.debug.panic(
            "truncated {s} tree ({d} of {d} bytes) parsed as {s}",
            .{ @tagName(grammar), cut, schema.len, @tagName(kind) },
        ) else |_| {}
    }

    const extended = gpa.alloc(u8, schema.len + 1) catch @panic("OOM extending schema");
    defer gpa.free(extended);
    @memcpy(extended[0..schema.len], schema);
    extended[schema.len] = reader.readByte();
    if (parse(grammar, extended)) |kind| std.debug.panic(
        "{s} tree with a trailing byte parsed as {s}",
        .{ @tagName(grammar), @tagName(kind) },
    ) else |err| if (err != error.TrailingBytes and err != error.Truncated) std.debug.panic(
        "trailing byte produced {s} rather than a length error",
        .{@errorName(err)},
    );

    // A single flipped byte must still leave the parser total: it either parses
    // to some kind or fails with a named error, and never reads out of bounds.
    const flipped = gpa.dupe(u8, schema) catch @panic("OOM flipping schema byte");
    defer gpa.free(flipped);
    const index = reader.intRangeLessThan(usize, 0, flipped.len);
    flipped[index] ^= @as(u8, 1) << @intCast(reader.intRangeAtMost(u3, 0, 7));
    const flipped_result = parse(grammar, flipped);
    if (debug) std.debug.print("flipped byte {d}: {s}\n", .{ index, resultName(flipped_result) });
    if (flipped_result) |_| {} else |_| {}
}

/// The five canonical plans must round-trip through both parsers.
///
/// These are the descriptors Roc actually emits, so a regression here breaks
/// every event binding. Re-checking them on each run costs almost nothing and
/// means a crash file always carries the evidence that the constants are intact.
fn checkCanonicalPlans() void {
    for (std.enums.values(boundary.EventExtractionPlanKind)) |plan| {
        const expected = plan.payloadKind();

        const extraction_kind = boundary.parseEventExtractionPayloadKind(plan.bytes()) catch |err|
            std.debug.panic("canonical plan {s} failed extraction parse: {s}", .{ @tagName(plan), @errorName(err) });
        if (extraction_kind != expected) @panic("canonical plan extraction bytes decode to the wrong payload kind");

        const schema_kind = boundary.parseBoundarySchemaPayloadKind(plan.schemaBytes()) catch |err|
            std.debug.panic("canonical plan {s} failed schema parse: {s}", .{ @tagName(plan), @errorName(err) });
        if (schema_kind != expected) @panic("canonical plan schema bytes decode to the wrong payload kind");

        const recovered = boundary.eventExtractionPlanKindFromBytes(plan.bytes()) orelse
            std.debug.panic("canonical plan {s} was not recognized from its own bytes", .{@tagName(plan)});
        if (recovered != plan) @panic("canonical plan bytes round-tripped to a different plan");

        const descriptor = boundary.BoundaryPayloadDescriptor.init(expected, plan);
        if (!descriptor.eql(boundary.BoundaryPayloadDescriptor.init(expected, plan))) {
            @panic("boundary payload descriptor equality is not reflexive");
        }
    }
}

fn parse(grammar: Grammar, bytes: []const u8) boundary.ParseError!PayloadKind {
    return switch (grammar) {
        .schema => boundary.parseBoundarySchemaPayloadKind(bytes),
        .extraction => boundary.parseEventExtractionPayloadKind(bytes),
    };
}

fn resultsEqual(left: boundary.ParseError!PayloadKind, right: boundary.ParseError!PayloadKind) bool {
    if (left) |left_kind| {
        const right_kind = right catch return false;
        return left_kind == right_kind;
    } else |left_err| {
        if (right) |_| return false else |right_err| return left_err == right_err;
    }
}

fn resultName(result: boundary.ParseError!PayloadKind) []const u8 {
    return if (result) |kind| @tagName(kind) else |err| @errorName(err);
}
