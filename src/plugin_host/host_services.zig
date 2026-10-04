const std = @import("std");
const sdk = @import("sdk");
const json = @import("../config/json.zig");
const log = @import("../diag/log.zig");
const sensors = @import("../runtime/sensors.zig");
const clock_module = @import("../runtime/clock.zig");

const abi = sdk.abi;
const win32 = sdk.win32;

pub const Shared = struct {
    logger: *log.Logger,
    sensor_table: *sensors.SensorTable,
    clock: *const clock_module.Clock,
};

const warned_capacity = 16;

pub const Context = struct {
    host: abi.Host,
    shared: *Shared,
    plugin_index: u16,
    plugin_name: []const u8,
    lock: win32.SRWLOCK = .{},
    last_problem: [240]u8 = undefined,
    last_problem_len: usize = 0,
    warned_sensors: [warned_capacity]u64 = @splat(0),
    warned_count: usize = 0,

    pub fn init(self: *Context, shared: *Shared, plugin_index: u16, plugin_name: []const u8, host_dir: [*:0]const u16, mode: u32) void {
        self.* = .{
            .host = .{
                .struct_size = @sizeOf(abi.Host),
                .abi_version = abi.abi_version,
                .ctx = self,
                .host_dir = host_dir,
                .mode = mode,
                .reserved = 0,
                .log = hostLog,
                .now_ms = hostNowMs,
                .sensor_set = hostSensorSet,
                .sensor_get = hostSensorGet,
                .json_type = hostJsonType,
                .json_get = hostJsonGet,
                .json_len = hostJsonLen,
                .json_at = hostJsonAt,
                .json_member = hostJsonMember,
                .json_number = hostJsonNumber,
                .json_bool = hostJsonBool,
                .json_string = hostJsonString,
            },
            .shared = shared,
            .plugin_index = plugin_index,
            .plugin_name = plugin_name,
        };
    }

    pub fn lastProblem(self: *Context, buffer: []u8) []const u8 {
        win32.AcquireSRWLockExclusive(&self.lock);
        defer win32.ReleaseSRWLockExclusive(&self.lock);
        const length = @min(self.last_problem_len, buffer.len);
        @memcpy(buffer[0..length], self.last_problem[0..length]);
        return buffer[0..length];
    }

    fn recordProblem(self: *Context, message: []const u8) void {
        win32.AcquireSRWLockExclusive(&self.lock);
        defer win32.ReleaseSRWLockExclusive(&self.lock);
        const length = @min(message.len, self.last_problem.len);
        @memcpy(self.last_problem[0..length], message[0..length]);
        self.last_problem_len = length;
    }

    fn firstWarning(self: *Context, name: []const u8) bool {
        const key = std.hash.Fnv1a_64.hash(name);
        win32.AcquireSRWLockExclusive(&self.lock);
        defer win32.ReleaseSRWLockExclusive(&self.lock);
        for (self.warned_sensors[0..self.warned_count]) |existing| {
            if (existing == key) return false;
        }
        if (self.warned_count == warned_capacity) return false;
        self.warned_sensors[self.warned_count] = key;
        self.warned_count += 1;
        return true;
    }
};

fn contextFrom(ctx: ?*anyopaque) *Context {
    return @ptrCast(@alignCast(ctx.?));
}

fn nodeFrom(node: ?*const abi.Json) ?*const json.Node {
    return @ptrCast(@alignCast(node));
}

fn toJson(node: ?*const json.Node) ?*const abi.Json {
    return @ptrCast(node);
}

fn slice(pointer: ?[*]const u8, length: usize) []const u8 {
    const start = pointer orelse return "";
    return start[0..length];
}

fn hostLog(ctx: ?*anyopaque, level: u32, message: ?[*]const u8, message_len: usize) callconv(.c) void {
    const self = contextFrom(ctx);
    const clamped: abi.LogLevel = if (level > @intFromEnum(abi.LogLevel.trace)) .trace else @enumFromInt(level);
    const text = slice(message, @min(message_len, 4096));
    self.shared.logger.write(clamped, self.plugin_name, text);
    if (clamped == .err or clamped == .warn) self.recordProblem(text);
}

fn hostNowMs(ctx: ?*anyopaque) callconv(.c) u64 {
    return contextFrom(ctx).shared.clock.nowMs();
}

fn hostSensorSet(ctx: ?*anyopaque, name: ?[*]const u8, name_len: usize, value: f64) callconv(.c) void {
    const self = contextFrom(ctx);
    const sensor_name = slice(name, @min(name_len, 64));
    const outcome = self.shared.sensor_table.set(self.plugin_index, self.plugin_name, sensor_name, value, self.shared.clock.nowMs());
    const problem: ?[]const u8 = switch (outcome) {
        .stored => null,
        .replaced_other_publisher => "was published by another plugin; the latest value wins",
        .invalid_name => "is not a valid sensor name (a-z, 0-9, '.', '_', up to 31 bytes)",
        .reserved_name => "is reserved for its documented source or lacks the plugin name prefix",
        .not_finite => "received a value that is not a finite number",
        .table_full => "cannot be stored because 64 sensors already exist",
    };
    if (problem) |text| {
        if (self.firstWarning(sensor_name)) self.shared.logger.log(.warn, self.plugin_name, "sensor \"{s}\" {s}", .{ sensor_name, text });
    }
}

fn hostSensorGet(ctx: ?*anyopaque, name: ?[*]const u8, name_len: usize, value: ?*f64, age_ms: ?*u64) callconv(.c) i32 {
    const self = contextFrom(ctx);
    const reading = self.shared.sensor_table.get(slice(name, @min(name_len, 64)), self.shared.clock.nowMs()) orelse return abi.status_fail;
    if (value) |out| out.* = reading.value;
    if (age_ms) |out| out.* = reading.age_ms;
    return abi.status_ok;
}

fn hostJsonType(ctx: ?*anyopaque, node: ?*const abi.Json) callconv(.c) u32 {
    _ = ctx;
    const resolved = nodeFrom(node) orelse return abi.json_none;
    return switch (resolved.kind()) {
        .null => abi.json_null,
        .boolean => abi.json_bool,
        .number => abi.json_number,
        .string => abi.json_string,
        .array => abi.json_array,
        .object => abi.json_object,
    };
}

fn hostJsonGet(ctx: ?*anyopaque, object: ?*const abi.Json, key: ?[*]const u8, key_len: usize) callconv(.c) ?*const abi.Json {
    _ = ctx;
    const resolved = nodeFrom(object) orelse return null;
    return toJson(resolved.get(slice(key, key_len)));
}

fn hostJsonLen(ctx: ?*anyopaque, node: ?*const abi.Json) callconv(.c) u32 {
    _ = ctx;
    const resolved = nodeFrom(node) orelse return 0;
    return switch (resolved.value) {
        .array => |items| @intCast(items.len),
        .object => |members| @intCast(members.len),
        else => 0,
    };
}

fn hostJsonAt(ctx: ?*anyopaque, array: ?*const abi.Json, index: u32) callconv(.c) ?*const abi.Json {
    _ = ctx;
    const items = (nodeFrom(array) orelse return null).arrayItems() orelse return null;
    if (index >= items.len) return null;
    return toJson(items[index]);
}

fn hostJsonMember(ctx: ?*anyopaque, object: ?*const abi.Json, index: u32, key: ?*?[*]const u8, key_len: ?*usize) callconv(.c) ?*const abi.Json {
    _ = ctx;
    const members = (nodeFrom(object) orelse return null).objectMembers() orelse return null;
    if (index >= members.len) return null;
    const member = members[index];
    if (key) |out| out.* = member.key.ptr;
    if (key_len) |out| out.* = member.key.len;
    return toJson(member.value);
}

fn hostJsonNumber(ctx: ?*anyopaque, node: ?*const abi.Json, value: ?*f64) callconv(.c) i32 {
    _ = ctx;
    const number = (nodeFrom(node) orelse return abi.status_argument).number() orelse return abi.status_argument;
    if (value) |out| out.* = number;
    return abi.status_ok;
}

fn hostJsonBool(ctx: ?*anyopaque, node: ?*const abi.Json, value: ?*i32) callconv(.c) i32 {
    _ = ctx;
    const boolean = (nodeFrom(node) orelse return abi.status_argument).boolean() orelse return abi.status_argument;
    if (value) |out| out.* = @intFromBool(boolean);
    return abi.status_ok;
}

fn hostJsonString(ctx: ?*anyopaque, node: ?*const abi.Json, text: ?*?[*]const u8, text_len: ?*usize) callconv(.c) i32 {
    _ = ctx;
    const string = (nodeFrom(node) orelse return abi.status_argument).string() orelse return abi.status_argument;
    if (text) |out| out.* = string.ptr;
    if (text_len) |out| out.* = string.len;
    return abi.status_ok;
}

const testing = std.testing;

test "host services expose config nodes, sensors and logging to a plugin through the ABI table" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    var warnings: std.ArrayList(json.Issue) = .empty;
    const root = switch (try json.parse(arena_state.allocator(), "{\"unit\": \"F\", \"max\": 162, \"on\": true, \"ids\": [\"a\", \"b\"]}", &warnings)) {
        .document => |document| document,
        .failure => return error.TestUnexpectedResult,
    };
    var logger = log.Logger{};
    var table = sensors.SensorTable{};
    const clock = clock_module.Clock.init();
    var shared = Shared{ .logger = &logger, .sensor_table = &table, .clock = &clock };
    var context: Context = undefined;
    context.init(&shared, 3, "sudokoo_sk700v", win32.L("C:\\rgbctrl"), abi.mode_run);
    const api = sdk.HostApi{ .host = &context.host };
    const config = toJson(root);
    var buffer: [8]u8 = undefined;
    try testing.expectEqualStrings("F", api.configString(config, "unit", &buffer).?);
    try testing.expectEqual(@as(i64, 162), api.configInt(config, "max", 0, 0, 1000));
    try testing.expect(api.configBool(config, "on", false));
    const ids = api.member(config, "ids");
    try testing.expectEqual(@as(u32, 2), api.length(ids));
    try testing.expectEqualStrings("b", api.asString(api.at(ids, 1)).?);
    try testing.expect(api.at(ids, 2) == null);
    try testing.expectEqual(abi.json_array, api.kind(ids));
    try testing.expectEqual(abi.json_none, api.kind(null));
    var key: ?[*]const u8 = null;
    var key_len: usize = 0;
    try testing.expect(context.host.json_member(context.host.ctx, config, 1, &key, &key_len) != null);
    try testing.expectEqualStrings("max", key.?[0..key_len]);
    api.setSensor("sudokoo_sk700v.fan", 1200);
    try testing.expectEqual(@as(f64, 1200), api.getSensor("sudokoo_sk700v.fan").?.value);
    api.setSensor("cpu.temp", 50);
    try testing.expect(api.getSensor("cpu.temp") == null);
    api.warn("device {s} busy", .{"x"});
    var problem: [64]u8 = undefined;
    try testing.expectEqualStrings("device x busy", context.lastProblem(&problem));
    try testing.expectEqualSlices(u16, win32.L("C:\\rgbctrl"), api.hostDir());
}
