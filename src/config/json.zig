const std = @import("std");
const sdk = @import("sdk");
const formatting = @import("../diag/format.zig");

pub const max_source_bytes = 1024 * 1024;
const max_depth = 64;

const Kind = enum(u8) { null, boolean, number, string, array, object };

pub const Member = struct {
    key: []const u8,
    value: *const Node,
};

pub const Node = struct {
    line: u32,
    column: u32,
    value: Value,
    key_slots: []const u32 = &.{},

    const Value = union(Kind) {
        null: void,
        boolean: bool,
        number: f64,
        string: []const u8,
        array: []const *const Node,
        object: []const Member,
    };

    pub fn kind(self: *const Node) Kind {
        return std.meta.activeTag(self.value);
    }

    pub fn get(self: *const Node, key: []const u8) ?*const Node {
        const members = self.objectMembers() orelse return null;
        const index = findKey(self.key_slots, members, key) orelse return null;
        return members[index].value;
    }

    pub fn objectMembers(self: *const Node) ?[]const Member {
        return switch (self.value) {
            .object => |members| members,
            else => null,
        };
    }

    pub fn arrayItems(self: *const Node) ?[]const *const Node {
        return switch (self.value) {
            .array => |items| items,
            else => null,
        };
    }

    pub fn string(self: *const Node) ?[]const u8 {
        return switch (self.value) {
            .string => |text| text,
            else => null,
        };
    }

    pub fn number(self: *const Node) ?f64 {
        return switch (self.value) {
            .number => |value| value,
            else => null,
        };
    }

    pub fn boolean(self: *const Node) ?bool {
        return switch (self.value) {
            .boolean => |value| value,
            else => null,
        };
    }

    pub fn isNull(self: *const Node) bool {
        return self.kind() == .null;
    }
};

pub const Issue = struct {
    line: u32,
    column: u32,
    message: []const u8,
};

const Outcome = union(enum) {
    document: *const Node,
    failure: Issue,
};

pub const empty_object = Node{ .line = 1, .column = 1, .value = .{ .object = &.{} } };

pub fn parse(arena: std.mem.Allocator, source: []const u8, warnings: *std.ArrayList(Issue)) error{OutOfMemory}!Outcome {
    var parser = Parser{ .arena = arena, .source = source, .warnings = warnings };
    const document = parser.parseDocument() catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.Syntax => return .{ .failure = parser.failure.? },
    };
    return .{ .document = document };
}

const Error = error{ OutOfMemory, Syntax };

const linear_key_limit = 8;
const max_warnings = 100;
const max_object_members = 4096;
const max_array_items = 8192;

extern "advapi32" fn SystemFunction036(buffer: *anyopaque, length: u32) callconv(.winapi) u8;

var key_seed = std.atomic.Value(u64).init(0);

fn keySeed() u64 {
    const current = key_seed.load(.acquire);
    if (current != 0) return current;
    var generated: u64 = 0;
    if (SystemFunction036(&generated, @sizeOf(u64)) == 0) {
        var counter: i64 = 0;
        _ = sdk.win32.QueryPerformanceCounter(&counter);
        generated = @as(u64, @bitCast(counter)) ^ (@intFromPtr(&generated) *% 0x9e3779b97f4a7c15);
    }
    generated |= 1;
    return key_seed.cmpxchgStrong(0, generated, .acq_rel, .acquire) orelse generated;
}

fn hashKey(key: []const u8) usize {
    var state: u64 = fnv_offset_basis ^ keySeed();
    for (key) |byte| {
        state ^= byte;
        state *%= 0x100000001b3;
    }
    state ^= state >> 33;
    state *%= 0xff51afd7ed558ccd;
    state ^= state >> 33;
    return @truncate(state);
}

fn findKey(slots: []const u32, members: []const Member, key: []const u8) ?usize {
    if (slots.len == 0) {
        for (members, 0..) |member, index| {
            if (std.mem.eql(u8, member.key, key)) return index;
        }
        return null;
    }
    const mask = slots.len - 1;
    var slot = hashKey(key) & mask;
    while (true) : (slot = (slot + 1) & mask) {
        const entry = slots[slot];
        if (entry == 0) return null;
        if (std.mem.eql(u8, members[entry - 1].key, key)) return entry - 1;
    }
}

fn insertSlot(slots: []u32, members: []const Member, member_index: usize) void {
    const mask = slots.len - 1;
    var slot = hashKey(members[member_index].key) & mask;
    while (slots[slot] != 0) slot = (slot + 1) & mask;
    slots[slot] = @intCast(member_index + 1);
}

fn buildSlots(arena: std.mem.Allocator, members: []const Member) error{OutOfMemory}![]u32 {
    if (members.len <= linear_key_limit) return &.{};
    var capacity: usize = 64;
    while (capacity < members.len * 2) capacity *= 2;
    const slots = try arena.alloc(u32, capacity);
    @memset(slots, 0);
    for (0..members.len) |index| insertSlot(slots, members, index);
    return slots;
}

pub fn objectNode(arena: std.mem.Allocator, line: u32, column: u32, members: []const Member) error{OutOfMemory}!*const Node {
    const node = try arena.create(Node);
    node.* = .{ .line = line, .column = column, .value = .{ .object = members }, .key_slots = try buildSlots(arena, members) };
    return node;
}

const KeyIndex = struct {
    slots: []u32 = &.{},

    fn find(self: *const KeyIndex, members: []const Member, key: []const u8) ?usize {
        return findKey(self.slots, members, key);
    }

    fn add(self: *KeyIndex, arena: std.mem.Allocator, members: []const Member) error{OutOfMemory}!void {
        if (self.slots.len == 0) {
            if (members.len > linear_key_limit) self.slots = try buildSlots(arena, members);
            return;
        }
        if (members.len * 2 > self.slots.len) {
            self.slots = try buildSlots(arena, members);
            return;
        }
        insertSlot(self.slots, members, members.len - 1);
    }
};
const Parser = struct {
    arena: std.mem.Allocator,
    source: []const u8,
    warnings: *std.ArrayList(Issue),
    index: usize = 0,
    depth: u32 = 0,
    failure: ?Issue = null,
    cached_offset: usize = 0,
    cached_position: Position = .{ .line = 1, .column = 1 },

    fn parseDocument(self: *Parser) Error!*const Node {
        if (self.source.len > max_source_bytes) return self.fail(0, "file is larger than 1 MiB");
        if (invalidUtf8Offset(self.source)) |offset| return self.fail(offset, "file is not valid UTF-8");
        if (std.mem.startsWith(u8, self.source, "\xEF\xBB\xBF")) {
            self.index = 3;
            self.cached_offset = 3;
        }
        try self.skipTrivia();
        if (self.index == self.source.len) return &empty_object;
        const root = try self.parseValue();
        try self.skipTrivia();
        if (self.index != self.source.len) return self.fail(self.index, "unexpected content after the top-level value");
        if (root.kind() != .object) return self.fail(0, "the top-level value must be an object");
        return root;
    }

    fn positionAt(self: *Parser, offset: usize) Position {
        if (offset < self.cached_offset) return positionOf(self.source, offset);
        const end = @min(offset, self.source.len);
        self.cached_position = advancePosition(self.cached_position, self.source[self.cached_offset..end]);
        self.cached_offset = end;
        return self.cached_position;
    }

    fn fail(self: *Parser, offset: usize, message: []const u8) Error {
        const position = self.positionAt(offset);
        self.failure = .{ .line = position.line, .column = position.column, .message = message };
        return error.Syntax;
    }

    fn warn(self: *Parser, position: Position, comptime format: []const u8, args: anytype) Error!void {
        if (self.warnings.items.len > max_warnings) return;
        if (self.warnings.items.len == max_warnings) {
            try self.warnings.append(self.arena, .{ .line = position.line, .column = position.column, .message = "further duplicate keys are not reported" });
            return;
        }
        const message = try formatting.allocPrint(self.arena, format, args);
        try self.warnings.append(self.arena, .{ .line = position.line, .column = position.column, .message = message });
    }

    fn skipTrivia(self: *Parser) Error!void {
        while (self.index < self.source.len) {
            const char = self.source[self.index];
            switch (char) {
                ' ', '\t', '\r', '\n' => self.index += 1,
                '/' => {
                    const start = self.index;
                    if (self.index + 1 >= self.source.len) return self.fail(start, "unexpected '/'");
                    const next = self.source[self.index + 1];
                    if (next == '/') {
                        self.index += 2;
                        while (self.index < self.source.len and self.source[self.index] != '\n') self.index += 1;
                    } else if (next == '*') {
                        self.index += 2;
                        const end = std.mem.indexOfPos(u8, self.source, self.index, "*/") orelse return self.fail(start, "unterminated /* comment");
                        self.index = end + 2;
                    } else {
                        return self.fail(start, "unexpected '/'");
                    }
                },
                else => return,
            }
        }
    }

    fn newNode(self: *Parser, position: Position, value: Node.Value) Error!*const Node {
        const node = try self.arena.create(Node);
        node.* = .{ .line = position.line, .column = position.column, .value = value };
        return node;
    }

    fn parseValue(self: *Parser) Error!*const Node {
        if (self.index >= self.source.len) return self.fail(self.index, "unexpected end of file");
        const start = self.index;
        const position = self.positionAt(start);
        return switch (self.source[start]) {
            '{' => self.parseObject(position),
            '[' => self.parseArray(position),
            '"' => self.newNode(position, .{ .string = try self.parseString() }),
            't' => self.parseLiteral(position, "true", .{ .boolean = true }),
            'f' => self.parseLiteral(position, "false", .{ .boolean = false }),
            'n' => self.parseLiteral(position, "null", .{ .null = {} }),
            '-', '0'...'9' => self.newNode(position, .{ .number = try self.parseNumber() }),
            else => self.fail(start, "expected a value"),
        };
    }

    fn parseLiteral(self: *Parser, position: Position, comptime word: []const u8, value: Node.Value) Error!*const Node {
        const start = self.index;
        if (!std.mem.startsWith(u8, self.source[start..], word)) return self.fail(start, "expected a value");
        self.index += word.len;
        if (self.index < self.source.len and isIdentifierChar(self.source[self.index])) return self.fail(start, "expected a value");
        return self.newNode(position, value);
    }

    fn enter(self: *Parser) Error!void {
        self.depth += 1;
        if (self.depth > max_depth) return self.fail(self.index, "nesting is deeper than 64 levels");
    }

    fn parseObject(self: *Parser, position: Position) Error!*const Node {
        const start = self.index;
        try self.enter();
        self.index += 1;
        var members: std.ArrayList(Member) = .empty;
        var key_index = KeyIndex{};
        while (true) {
            try self.skipTrivia();
            if (self.index >= self.source.len) return self.fail(start, "unterminated object");
            if (self.source[self.index] == '}') {
                self.index += 1;
                break;
            }
            if (self.source[self.index] != '"') return self.fail(self.index, "expected a string key or '}'");
            const key_position = self.positionAt(self.index);
            const key = try self.parseString();
            try self.skipTrivia();
            if (self.index >= self.source.len or self.source[self.index] != ':') return self.fail(self.index, "expected ':' after the key");
            self.index += 1;
            try self.skipTrivia();
            const value = try self.parseValue();
            if (key_index.find(members.items, key)) |existing| {
                members.items[existing].value = value;
                try self.warn(key_position, "duplicate key \"{s}\"; the later value wins", .{key});
            } else {
                if (members.items.len == max_object_members) return self.fail(start, "object has more than 4096 members");
                try members.append(self.arena, .{ .key = key, .value = value });
                try key_index.add(self.arena, members.items);
            }
            try self.skipTrivia();
            if (self.index >= self.source.len) return self.fail(start, "unterminated object");
            switch (self.source[self.index]) {
                ',' => self.index += 1,
                '}' => {
                    self.index += 1;
                    break;
                },
                else => return self.fail(self.index, "expected ',' or '}'"),
            }
        }
        self.depth -= 1;
        const node = try self.arena.create(Node);
        node.* = .{ .line = position.line, .column = position.column, .value = .{ .object = members.items }, .key_slots = key_index.slots };
        return node;
    }

    fn parseArray(self: *Parser, position: Position) Error!*const Node {
        const start = self.index;
        try self.enter();
        self.index += 1;
        var items: std.ArrayList(*const Node) = .empty;
        while (true) {
            try self.skipTrivia();
            if (self.index >= self.source.len) return self.fail(start, "unterminated array");
            if (self.source[self.index] == ']') {
                self.index += 1;
                break;
            }
            if (items.items.len == max_array_items) return self.fail(start, "array has more than 8192 items");
            try items.append(self.arena, try self.parseValue());
            try self.skipTrivia();
            if (self.index >= self.source.len) return self.fail(start, "unterminated array");
            switch (self.source[self.index]) {
                ',' => self.index += 1,
                ']' => {
                    self.index += 1;
                    break;
                },
                else => return self.fail(self.index, "expected ',' or ']'"),
            }
        }
        self.depth -= 1;
        return self.newNode(position, .{ .array = try items.toOwnedSlice(self.arena) });
    }

    fn parseString(self: *Parser) Error![]const u8 {
        const start = self.index;
        self.index += 1;
        const content_start = self.index;
        while (self.index < self.source.len) {
            const char = self.source[self.index];
            if (char == '"') {
                const text = self.source[content_start..self.index];
                self.index += 1;
                return text;
            }
            if (char == '\\') break;
            if (char < 0x20) return self.fail(self.index, "control character in string");
            self.index += 1;
        }
        var decoded: std.ArrayList(u8) = .empty;
        try decoded.appendSlice(self.arena, self.source[content_start..self.index]);
        while (self.index < self.source.len) {
            const char = self.source[self.index];
            switch (char) {
                '"' => {
                    self.index += 1;
                    return decoded.toOwnedSlice(self.arena);
                },
                '\\' => try self.parseEscape(&decoded),
                else => {
                    if (char < 0x20) return self.fail(self.index, "control character in string");
                    try decoded.append(self.arena, char);
                    self.index += 1;
                },
            }
        }
        return self.fail(start, "unterminated string");
    }

    fn parseEscape(self: *Parser, decoded: *std.ArrayList(u8)) Error!void {
        const start = self.index;
        if (self.index + 1 >= self.source.len) return self.fail(start, "unterminated escape");
        const escape = self.source[self.index + 1];
        self.index += 2;
        const simple: ?u8 = switch (escape) {
            '"' => '"',
            '\\' => '\\',
            '/' => '/',
            'b' => 0x08,
            'f' => 0x0C,
            'n' => '\n',
            'r' => '\r',
            't' => '\t',
            'u' => null,
            else => return self.fail(start, "invalid escape"),
        };
        if (simple) |byte| return decoded.append(self.arena, byte);
        var code_point: u21 = try self.parseHex4(start);
        if (code_point >= 0xD800 and code_point <= 0xDBFF) {
            if (self.index + 1 >= self.source.len or self.source[self.index] != '\\' or self.source[self.index + 1] != 'u') return self.fail(start, "unpaired surrogate");
            self.index += 2;
            const low = try self.parseHex4(start);
            if (low < 0xDC00 or low > 0xDFFF) return self.fail(start, "unpaired surrogate");
            code_point = 0x10000 + ((code_point - 0xD800) << 10) + (low - 0xDC00);
        } else if (code_point >= 0xDC00 and code_point <= 0xDFFF) {
            return self.fail(start, "unpaired surrogate");
        }
        var buffer: [4]u8 = undefined;
        const length = std.unicode.utf8Encode(code_point, &buffer) catch return self.fail(start, "invalid code point");
        try decoded.appendSlice(self.arena, buffer[0..length]);
    }

    fn parseHex4(self: *Parser, escape_start: usize) Error!u21 {
        if (self.index + 4 > self.source.len) return self.fail(escape_start, "invalid \\u escape");
        var value: u21 = 0;
        for (self.source[self.index .. self.index + 4]) |char| {
            const digit = std.fmt.charToDigit(char, 16) catch return self.fail(escape_start, "invalid \\u escape");
            value = value * 16 + digit;
        }
        self.index += 4;
        return value;
    }

    fn parseNumber(self: *Parser) Error!f64 {
        const start = self.index;
        var negative = false;
        if (self.source[self.index] == '-') {
            negative = true;
            self.index += 1;
        }
        var mantissa: u64 = 0;
        var significant_digits: u32 = 0;
        var decimal_exponent: i32 = 0;
        if (self.index >= self.source.len or !std.ascii.isDigit(self.source[self.index])) return self.fail(start, "invalid number");
        if (self.source[self.index] == '0') {
            self.index += 1;
        } else {
            while (self.index < self.source.len and std.ascii.isDigit(self.source[self.index])) : (self.index += 1) {
                accumulateDigit(&mantissa, &significant_digits, &decimal_exponent, self.source[self.index], false);
            }
        }
        if (self.index < self.source.len and self.source[self.index] == '.') {
            self.index += 1;
            if (self.index >= self.source.len or !std.ascii.isDigit(self.source[self.index])) return self.fail(start, "invalid number");
            while (self.index < self.source.len and std.ascii.isDigit(self.source[self.index])) : (self.index += 1) {
                accumulateDigit(&mantissa, &significant_digits, &decimal_exponent, self.source[self.index], true);
            }
        }
        if (self.index < self.source.len and (self.source[self.index] == 'e' or self.source[self.index] == 'E')) {
            self.index += 1;
            var exponent_negative = false;
            if (self.index < self.source.len and (self.source[self.index] == '+' or self.source[self.index] == '-')) {
                exponent_negative = self.source[self.index] == '-';
                self.index += 1;
            }
            if (self.index >= self.source.len or !std.ascii.isDigit(self.source[self.index])) return self.fail(start, "invalid number");
            var exponent: i32 = 0;
            while (self.index < self.source.len and std.ascii.isDigit(self.source[self.index])) : (self.index += 1) {
                if (exponent < 10000) exponent = exponent * 10 + (self.source[self.index] - '0');
            }
            decimal_exponent += if (exponent_negative) -exponent else exponent;
        }
        if (self.index < self.source.len and isIdentifierChar(self.source[self.index])) return self.fail(start, "invalid number");
        const magnitude = scaleByPowerOfTen(@floatFromInt(mantissa), decimal_exponent);
        if (!std.math.isFinite(magnitude)) return self.fail(start, "number is out of range");
        return if (negative) -magnitude else magnitude;
    }
};

fn accumulateDigit(mantissa: *u64, significant_digits: *u32, decimal_exponent: *i32, char: u8, fractional: bool) void {
    const digit = char - '0';
    if (significant_digits.* == 0 and digit == 0) {
        if (fractional) decimal_exponent.* -= 1;
        return;
    }
    if (significant_digits.* < 19) {
        mantissa.* = mantissa.* * 10 + digit;
        significant_digits.* += 1;
        if (fractional) decimal_exponent.* -= 1;
    } else if (!fractional) {
        decimal_exponent.* += 1;
    }
}

const exact_powers_of_ten = [_]f64{ 1e0, 1e1, 1e2, 1e3, 1e4, 1e5, 1e6, 1e7, 1e8, 1e9, 1e10, 1e11, 1e12, 1e13, 1e14, 1e15, 1e16, 1e17, 1e18, 1e19, 1e20, 1e21, 1e22 };

fn scaleByPowerOfTen(value: f64, exponent: i32) f64 {
    if (value == 0) return 0;
    var result = value;
    var remaining = exponent;
    while (remaining > 22) : (remaining -= 22) {
        result *= 1e22;
        if (!std.math.isFinite(result)) return result;
    }
    while (remaining < -22) : (remaining += 22) {
        result /= 1e22;
        if (result == 0) return 0;
    }
    if (remaining >= 0) return result * exact_powers_of_ten[@intCast(remaining)];
    return result / exact_powers_of_ten[@intCast(-remaining)];
}

fn isIdentifierChar(char: u8) bool {
    return std.ascii.isAlphanumeric(char) or char == '_' or char == '.';
}

const Position = struct { line: u32, column: u32 };

fn positionOf(source: []const u8, offset: usize) Position {
    return advancePosition(.{ .line = 1, .column = 1 }, source[0..@min(offset, source.len)]);
}

fn advancePosition(start: Position, bytes: []const u8) Position {
    var position = start;
    for (bytes) |byte| {
        if (byte == '\n') {
            position.line += 1;
            position.column = 1;
        } else if (byte & 0xC0 != 0x80) {
            position.column += 1;
        }
    }
    return position;
}

fn invalidUtf8Offset(source: []const u8) ?usize {
    var index: usize = 0;
    while (index < source.len) {
        const length = std.unicode.utf8ByteSequenceLength(source[index]) catch return index;
        if (index + length > source.len) return index;
        _ = std.unicode.utf8Decode(source[index .. index + length]) catch return index;
        index += length;
    }
    return null;
}

pub fn hash(node: ?*const Node, seed: u64) u64 {
    var state = seed;
    hashInto(&state, node);
    return state;
}

fn hashBytes(state: *u64, bytes: []const u8) void {
    for (bytes) |byte| {
        state.* ^= byte;
        state.* *%= 0x100000001b3;
    }
}

fn hashInto(state: *u64, maybe_node: ?*const Node) void {
    const node = maybe_node orelse {
        hashBytes(state, "absent");
        return;
    };
    hashBytes(state, &.{@intFromEnum(node.kind())});
    switch (node.value) {
        .null => {},
        .boolean => |value| hashBytes(state, &.{@intFromBool(value)}),
        .number => |value| hashBytes(state, std.mem.asBytes(&value)),
        .string => |text| {
            hashBytes(state, std.mem.asBytes(&text.len));
            hashBytes(state, text);
        },
        .array => |items| {
            hashBytes(state, std.mem.asBytes(&items.len));
            for (items) |item| hashInto(state, item);
        },
        .object => |members| {
            hashBytes(state, std.mem.asBytes(&members.len));
            for (members) |member| {
                hashBytes(state, std.mem.asBytes(&member.key.len));
                hashBytes(state, member.key);
                hashInto(state, member.value);
            }
        },
    }
}

pub const fnv_offset_basis: u64 = 0xcbf29ce484222325;

const testing = std.testing;

fn parseForTest(arena: std.mem.Allocator, source: []const u8, warnings: *std.ArrayList(Issue)) !*const Node {
    return switch (try parse(arena, source, warnings)) {
        .document => |document| document,
        .failure => |issue| {
            std.debug.print("unexpected failure {d}:{d} {s}\n", .{ issue.line, issue.column, issue.message });
            return error.TestUnexpectedResult;
        },
    };
}

fn expectFailure(source: []const u8, line: u32, column: u32, message: []const u8) !void {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    var warnings: std.ArrayList(Issue) = .empty;
    switch (try parse(arena_state.allocator(), source, &warnings)) {
        .document => return error.TestUnexpectedResult,
        .failure => |issue| {
            try testing.expectEqualStrings(message, issue.message);
            try testing.expectEqual(line, issue.line);
            try testing.expectEqual(column, issue.column);
        },
    }
}

test "parse accepts comments, trailing commas and nested values" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    var warnings: std.ArrayList(Issue) = .empty;
    const source =
        \\// header comment
        \\{
        \\  "frame_rate": 30, /* inline */
        \\  "lighting": { "*": { "*": { "effect": "static", "colors": ["#FF0000", "#00FF00",], }, }, },
        \\  "flag": true, "nothing": null, "neg": -1.5e2, "tiny": 0.25,
        \\}
    ;
    const root = try parseForTest(arena_state.allocator(), source, &warnings);
    try testing.expectEqual(@as(f64, 30), root.get("frame_rate").?.number().?);
    try testing.expectEqual(@as(f64, -150), root.get("neg").?.number().?);
    try testing.expectEqual(@as(f64, 0.25), root.get("tiny").?.number().?);
    try testing.expect(root.get("flag").?.boolean().?);
    try testing.expect(root.get("nothing").?.isNull());
    const spec = root.get("lighting").?.get("*").?.get("*").?;
    try testing.expectEqualStrings("static", spec.get("effect").?.string().?);
    try testing.expectEqual(@as(usize, 2), spec.get("colors").?.arrayItems().?.len);
    try testing.expectEqual(@as(u32, 3), root.get("frame_rate").?.line);
    try testing.expectEqual(@as(usize, 0), warnings.items.len);
}

test "parse decodes escapes and surrogate pairs" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    var warnings: std.ArrayList(Issue) = .empty;
    const root = try parseForTest(arena_state.allocator(), "{\"a\": \"x\\n\\\"\\u00e9\\ud83d\\ude00\"}", &warnings);
    try testing.expectEqualStrings("x\n\"\xc3\xa9\xf0\x9f\x98\x80", root.get("a").?.string().?);
}

test "duplicate keys keep the later value and produce a warning with its position" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    var warnings: std.ArrayList(Issue) = .empty;
    const root = try parseForTest(arena_state.allocator(), "{\"a\": 1,\n \"a\": 2}", &warnings);
    try testing.expectEqual(@as(f64, 2), root.get("a").?.number().?);
    try testing.expectEqual(@as(usize, 1), root.objectMembers().?.len);
    try testing.expectEqual(@as(usize, 1), warnings.items.len);
    try testing.expectEqual(@as(u32, 2), warnings.items[0].line);
    try testing.expectEqual(@as(u32, 2), warnings.items[0].column);
}

test "an empty or comment-only document is an empty object" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    var warnings: std.ArrayList(Issue) = .empty;
    const root = try parseForTest(arena_state.allocator(), "\xEF\xBB\xBF  // nothing here\n", &warnings);
    try testing.expectEqual(@as(usize, 0), root.objectMembers().?.len);
}

test "syntax errors report line and column" {
    try expectFailure("{\n  \"a\": 1\n  \"b\": 2\n}", 3, 3, "expected ',' or '}'");
    try expectFailure("{\"a\": tru}", 1, 7, "expected a value");
    try expectFailure("{\"a\": \"x", 1, 7, "unterminated string");
    try expectFailure("{\"a\": 01}", 1, 7, "invalid number");
    try expectFailure("{\"a\": 1.}", 1, 7, "invalid number");
    try expectFailure("{\"a\": \"\\q\"}", 1, 8, "invalid escape");
    try expectFailure("{\"a\": \"\\ud800\"}", 1, 8, "unpaired surrogate");
    try expectFailure("[1, 2]", 1, 1, "the top-level value must be an object");
    try expectFailure("{} {}", 1, 4, "unexpected content after the top-level value");
    try expectFailure("{/* open", 1, 2, "unterminated /* comment");
    try expectFailure("{\"a\": 1e999}", 1, 7, "number is out of range");
    try expectFailure("{\"a\": \"\xff\"}", 1, 8, "file is not valid UTF-8");
    try expectFailure("{\"a\": \"tab\there\"}", 1, 11, "control character in string");
}

test "nesting deeper than 64 levels is rejected" {
    var source: [200]u8 = undefined;
    source[0] = '{';
    source[1] = '"';
    source[2] = 'a';
    source[3] = '"';
    source[4] = ':';
    for (0..65) |index| source[5 + index] = '[';
    try expectFailure(source[0..70], 1, 69, "nesting is deeper than 64 levels");
}

test "hash differs when any nested value changes and is stable otherwise" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    var warnings: std.ArrayList(Issue) = .empty;
    const first = try parseForTest(arena_state.allocator(), "{\"a\": [1, {\"b\": \"c\"}]}", &warnings);
    const same = try parseForTest(arena_state.allocator(), "{ \"a\" : [ 1 , { \"b\" : \"c\" } ] }", &warnings);
    const different = try parseForTest(arena_state.allocator(), "{\"a\": [1, {\"b\": \"d\"}]}", &warnings);
    try testing.expectEqual(hash(first, fnv_offset_basis), hash(same, fnv_offset_basis));
    try testing.expect(hash(first, fnv_offset_basis) != hash(different, fnv_offset_basis));
}

test "positions after a byte order mark start at column one" {
    try expectFailure("\xEF\xBB\xBF/x", 1, 1, "unexpected '/'");
}

test "duplicate keys are found in large objects through the key index" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    var source: std.ArrayList(u8) = .empty;
    try source.appendSlice(arena_state.allocator(), "{");
    for (0..40) |index| {
        var buffer: [32]u8 = undefined;
        try source.appendSlice(arena_state.allocator(), try std.fmt.bufPrint(&buffer, "\"k{d}\": {d},", .{ index, index }));
    }
    try source.appendSlice(arena_state.allocator(), "\"k7\": 700}");
    var warnings: std.ArrayList(Issue) = .empty;
    const root = try parseForTest(arena_state.allocator(), source.items, &warnings);
    try testing.expectEqual(@as(usize, 40), root.objectMembers().?.len);
    try testing.expectEqual(@as(f64, 700), root.get("k7").?.number().?);
    try testing.expectEqual(@as(f64, 39), root.get("k39").?.number().?);
    try testing.expectEqual(@as(usize, 1), warnings.items.len);
}

test "a 1 MiB document of large objects parses quickly" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var source: std.ArrayList(u8) = .empty;
    try source.append(arena, '{');
    var group: usize = 0;
    var total_keys: usize = 0;
    outer: while (true) : (group += 1) {
        var header: [32]u8 = undefined;
        try source.appendSlice(arena, try std.fmt.bufPrint(&header, "\"g{d}\":{{", .{group}));
        for (0..max_object_members - 1) |index| {
            if (source.items.len > max_source_bytes - 64) {
                try source.appendSlice(arena, "\"end\":0}");
                break :outer;
            }
            var buffer: [32]u8 = undefined;
            try source.appendSlice(arena, try std.fmt.bufPrint(&buffer, "\"k{d}\":1,", .{index}));
            total_keys += 1;
        }
        try source.appendSlice(arena, "\"end\":0},");
    }
    try source.append(arena, '}');
    var warnings: std.ArrayList(Issue) = .empty;
    const started = sdk.win32.GetTickCount64();
    const root = try parseForTest(arena, source.items, &warnings);
    const elapsed = sdk.win32.GetTickCount64() - started;
    try testing.expect(total_keys > 50_000);
    try testing.expect(root.get("g0").?.get("k4000") != null);
    try testing.expectEqual(@as(usize, 0), warnings.items.len);
    try testing.expect(elapsed < 10_000);
}

test "objects and arrays beyond the size caps are rejected" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var object_source: std.ArrayList(u8) = .empty;
    try object_source.append(arena, '{');
    for (0..max_object_members + 1) |index| {
        var buffer: [32]u8 = undefined;
        try object_source.appendSlice(arena, try std.fmt.bufPrint(&buffer, "\"k{d}\":1,", .{index}));
    }
    try object_source.append(arena, '}');
    var warnings: std.ArrayList(Issue) = .empty;
    switch (try parse(arena, object_source.items, &warnings)) {
        .document => return error.TestUnexpectedResult,
        .failure => |issue| try testing.expectEqualStrings("object has more than 4096 members", issue.message),
    }
    var array_source: std.ArrayList(u8) = .empty;
    try array_source.appendSlice(arena, "{\"a\":[");
    for (0..max_array_items + 1) |_| try array_source.appendSlice(arena, "1,");
    try array_source.appendSlice(arena, "]}");
    switch (try parse(arena, array_source.items, &warnings)) {
        .document => return error.TestUnexpectedResult,
        .failure => |issue| try testing.expectEqualStrings("array has more than 8192 items", issue.message),
    }
}

test "the key hash seed is chosen once per process and is never zero" {
    const first = keySeed();
    try testing.expect(first != 0);
    try testing.expectEqual(first, keySeed());
    try testing.expectEqual(hashKey("frame_rate"), hashKey("frame_rate"));
}
