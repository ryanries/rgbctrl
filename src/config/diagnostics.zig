const std = @import("std");
const formatting = @import("../diag/format.zig");
const json = @import("json.zig");

const Severity = enum { warning, failure };

const max_entries = 200;

const Entry = struct {
    severity: Severity,
    message: []const u8,
};

pub const Diagnostics = struct {
    arena: std.mem.Allocator,
    entries: std.ArrayList(Entry) = .empty,
    failure_count: u32 = 0,
    failure_seen: bool = false,

    pub fn init(arena: std.mem.Allocator) Diagnostics {
        return .{ .arena = arena };
    }

    pub fn warn(self: *Diagnostics, comptime format: []const u8, args: anytype) void {
        self.add(.warning, format, args);
    }

    pub fn fail(self: *Diagnostics, comptime format: []const u8, args: anytype) void {
        self.add(.failure, format, args);
    }

    pub fn warnAt(self: *Diagnostics, node: *const json.Node, comptime format: []const u8, args: anytype) void {
        self.add(.warning, "line {d}:{d}: " ++ format, .{ node.line, node.column } ++ args);
    }

    pub fn failAt(self: *Diagnostics, node: *const json.Node, comptime format: []const u8, args: anytype) void {
        self.add(.failure, "line {d}:{d}: " ++ format, .{ node.line, node.column } ++ args);
    }

    pub fn isFull(self: *const Diagnostics) bool {
        return self.entries.items.len >= max_entries;
    }

    fn add(self: *Diagnostics, severity: Severity, comptime format: []const u8, args: anytype) void {
        if (severity == .failure) self.failure_seen = true;
        if (self.entries.items.len > max_entries) return;
        if (self.entries.items.len == max_entries) {
            self.entries.append(self.arena, .{ .severity = .warning, .message = "further configuration problems are not shown" }) catch return;
            return;
        }
        var buffer: [1024]u8 = undefined;
        const formatted = formatting.print(&buffer, format, args);
        for (self.entries.items) |entry| {
            if (entry.severity == severity and std.mem.eql(u8, entry.message, formatted)) return;
        }
        const message = self.arena.dupe(u8, formatted) catch return;
        self.entries.append(self.arena, .{ .severity = severity, .message = message }) catch return;
        if (severity == .failure) self.failure_count += 1;
    }

    pub fn contains(self: *const Diagnostics, fragment: []const u8) bool {
        for (self.entries.items) |entry| {
            if (std.mem.indexOf(u8, entry.message, fragment) != null) return true;
        }
        return false;
    }
};

test "identical messages are recorded once and failures are counted" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var diagnostics = Diagnostics.init(arena_state.allocator());
    diagnostics.warn("zone {s} has no LEDs", .{"argb1"});
    diagnostics.warn("zone {s} has no LEDs", .{"argb1"});
    diagnostics.fail("bad {d}", .{1});
    try std.testing.expectEqual(@as(usize, 2), diagnostics.entries.items.len);
    try std.testing.expectEqual(@as(u32, 1), diagnostics.failure_count);
    try std.testing.expect(diagnostics.contains("no LEDs"));
}

test "diagnostics stop growing after 200 entries but still remember failures" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var diagnostics = Diagnostics.init(arena_state.allocator());
    for (0..300) |index| diagnostics.warn("problem {d}", .{index});
    try std.testing.expect(diagnostics.isFull());
    try std.testing.expectEqual(@as(usize, 201), diagnostics.entries.items.len);
    try std.testing.expect(diagnostics.contains("further configuration problems are not shown"));
    diagnostics.fail("late failure", .{});
    try std.testing.expect(diagnostics.failure_seen);
}
