//! Small, data-only S-expression reader for native host specifications.

const std = @import("std");

pub const Span = struct {
    start: usize,
    len: usize,
    line: usize,
    column: usize,
};

pub const Atom = union(enum) {
    symbol: []const u8,
    string: []const u8,
    integer: i64,
    boolean: bool,
};

pub const Expr = struct {
    span: Span,
    value: union(enum) {
        atom: Atom,
        list: []Expr,
    },

    pub fn deinit(self: Expr, allocator: std.mem.Allocator) void {
        switch (self.value) {
            .atom => |atom| switch (atom) {
                .string => |value| allocator.free(value),
                else => {},
            },
            .list => |items| {
                for (items) |item| item.deinit(allocator);
                allocator.free(items);
            },
        }
    }
};

pub const Diagnostic = struct {
    span: Span,
    message: []const u8,
};

pub const ReadError = error{ InvalidSyntax, OutOfMemory };

pub const Reader = struct {
    allocator: std.mem.Allocator,
    input: []const u8,
    index: usize = 0,
    line: usize = 1,
    column: usize = 1,
    diagnostic: ?Diagnostic = null,

    pub fn init(allocator: std.mem.Allocator, input: []const u8) Reader {
        return .{ .allocator = allocator, .input = input };
    }

    pub fn readOne(self: *Reader) ReadError!Expr {
        self.skipTrivia();
        if (self.index == self.input.len) return self.fail("expected one S-expression");
        const expr = try self.readExpr();
        errdefer expr.deinit(self.allocator);
        self.skipTrivia();
        if (self.index != self.input.len) return self.fail("expected exactly one top-level S-expression");
        return expr;
    }

    fn readExpr(self: *Reader) ReadError!Expr {
        self.skipTrivia();
        if (self.index == self.input.len) return self.fail("unexpected end of file");
        return switch (self.input[self.index]) {
            '(' => self.readList(),
            ')' => self.fail("unexpected closing parenthesis"),
            '"' => self.readString(),
            else => self.readBareAtom(),
        };
    }

    fn readList(self: *Reader) ReadError!Expr {
        const start = self.position();
        self.advance();
        var items: std.ArrayListUnmanaged(Expr) = .empty;
        errdefer {
            for (items.items) |item| item.deinit(self.allocator);
            items.deinit(self.allocator);
        }

        while (true) {
            self.skipTrivia();
            if (self.index == self.input.len) return self.failAt(start, "unterminated list");
            if (self.input[self.index] == ')') {
                self.advance();
                break;
            }
            try items.append(self.allocator, try self.readExpr());
        }

        return .{
            .span = self.spanFrom(start),
            .value = .{ .list = try items.toOwnedSlice(self.allocator) },
        };
    }

    fn readString(self: *Reader) ReadError!Expr {
        const start = self.position();
        self.advance();
        var bytes: std.ArrayListUnmanaged(u8) = .empty;
        errdefer bytes.deinit(self.allocator);

        while (self.index < self.input.len) {
            const byte = self.input[self.index];
            if (byte == '"') {
                self.advance();
                return .{
                    .span = self.spanFrom(start),
                    .value = .{ .atom = .{ .string = try bytes.toOwnedSlice(self.allocator) } },
                };
            }
            if (byte == '\n' or byte == '\r') return self.failAt(start, "strings cannot contain literal newlines");
            if (byte != '\\') {
                try bytes.append(self.allocator, byte);
                self.advance();
                continue;
            }

            self.advance();
            if (self.index == self.input.len) return self.failAt(start, "unterminated string escape");
            const escaped: u8 = switch (self.input[self.index]) {
                'n' => '\n',
                'r' => '\r',
                't' => '\t',
                '"' => '"',
                '\\' => '\\',
                else => return self.fail("unsupported string escape"),
            };
            try bytes.append(self.allocator, escaped);
            self.advance();
        }

        return self.failAt(start, "unterminated string");
    }

    fn readBareAtom(self: *Reader) ReadError!Expr {
        const start = self.position();
        while (self.index < self.input.len) {
            const byte = self.input[self.index];
            if (isDelimiter(byte)) break;
            self.advance();
        }
        if (self.index == start.start) return self.fail("expected an atom");
        const text = self.input[start.start..self.index];
        const atom: Atom = if (std.mem.eql(u8, text, "true"))
            .{ .boolean = true }
        else if (std.mem.eql(u8, text, "false"))
            .{ .boolean = false }
        else if (std.fmt.parseInt(i64, text, 10)) |value|
            .{ .integer = value }
        else |_| if (text[0] == ':')
            .{ .symbol = text }
        else
            .{ .symbol = text };
        return .{ .span = self.spanFrom(start), .value = .{ .atom = atom } };
    }

    fn skipTrivia(self: *Reader) void {
        while (self.index < self.input.len) {
            switch (self.input[self.index]) {
                ' ', '\t', '\r', '\n' => self.advance(),
                ';' => {
                    while (self.index < self.input.len and self.input[self.index] != '\n') self.advance();
                },
                else => return,
            }
        }
    }

    fn advance(self: *Reader) void {
        if (self.input[self.index] == '\n') {
            self.line += 1;
            self.column = 1;
        } else {
            self.column += 1;
        }
        self.index += 1;
    }

    fn position(self: *const Reader) Span {
        return .{ .start = self.index, .len = 0, .line = self.line, .column = self.column };
    }

    fn spanFrom(self: *const Reader, start: Span) Span {
        return .{ .start = start.start, .len = self.index - start.start, .line = start.line, .column = start.column };
    }

    fn fail(self: *Reader, message: []const u8) ReadError {
        return self.failAt(self.position(), message);
    }

    fn failAt(self: *Reader, span: Span, message: []const u8) ReadError {
        self.diagnostic = .{ .span = span, .message = message };
        return error.InvalidSyntax;
    }
};

fn isDelimiter(byte: u8) bool {
    return switch (byte) {
        ' ', '\t', '\r', '\n', '(', ')', '"', ';' => true,
        else => false,
    };
}
