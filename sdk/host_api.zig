const std = @import("std");
const abi = @import("abi.zig");
const text = @import("text.zig");

pub const Sensor = struct {
    value: f64,
    age_ms: u64,
};

pub const HostApi = struct {
    host: *const abi.Host,

    pub fn log(self: HostApi, level: abi.LogLevel, comptime format: []const u8, args: anytype) void {
        var buffer: [1024]u8 = undefined;
        const message = text.print(&buffer, format, args);
        self.host.log(self.host.ctx, @intFromEnum(level), message.ptr, message.len);
    }

    pub fn err(self: HostApi, comptime format: []const u8, args: anytype) void {
        self.log(.err, format, args);
    }

    pub fn warn(self: HostApi, comptime format: []const u8, args: anytype) void {
        self.log(.warn, format, args);
    }

    pub fn info(self: HostApi, comptime format: []const u8, args: anytype) void {
        self.log(.info, format, args);
    }

    pub fn debug(self: HostApi, comptime format: []const u8, args: anytype) void {
        self.log(.debug, format, args);
    }

    pub fn trace(self: HostApi, comptime format: []const u8, args: anytype) void {
        self.log(.trace, format, args);
    }

    pub fn logMessage(self: HostApi, level: abi.LogLevel, message: []const u8) void {
        self.host.log(self.host.ctx, @intFromEnum(level), message.ptr, message.len);
    }

    pub fn nowMs(self: HostApi) u64 {
        return self.host.now_ms(self.host.ctx);
    }

    pub fn mode(self: HostApi) u32 {
        return self.host.mode;
    }

    pub fn hostDir(self: HostApi) []const u16 {
        const directory = self.host.host_dir orelse return &.{};
        return std.mem.span(directory);
    }

    pub fn setSensor(self: HostApi, name: []const u8, value: f64) void {
        self.host.sensor_set(self.host.ctx, name.ptr, name.len, value);
    }

    pub fn getSensor(self: HostApi, name: []const u8) ?Sensor {
        var value: f64 = 0;
        var age_ms: u64 = 0;
        if (self.host.sensor_get(self.host.ctx, name.ptr, name.len, &value, &age_ms) != abi.status_ok) return null;
        return .{ .value = value, .age_ms = age_ms };
    }

    pub fn member(self: HostApi, object: ?*const abi.Json, key: []const u8) ?*const abi.Json {
        if (object == null) return null;
        return self.host.json_get(self.host.ctx, object, key.ptr, key.len);
    }

    pub fn kind(self: HostApi, node: ?*const abi.Json) u32 {
        return self.host.json_type(self.host.ctx, node);
    }

    pub fn length(self: HostApi, node: ?*const abi.Json) u32 {
        return self.host.json_len(self.host.ctx, node);
    }

    pub fn at(self: HostApi, node: ?*const abi.Json, index: u32) ?*const abi.Json {
        return self.host.json_at(self.host.ctx, node, index);
    }

    pub fn asNumber(self: HostApi, node: ?*const abi.Json) ?f64 {
        var value: f64 = 0;
        if (self.host.json_number(self.host.ctx, node, &value) != abi.status_ok) return null;
        return value;
    }

    pub fn asBool(self: HostApi, node: ?*const abi.Json) ?bool {
        var value: i32 = 0;
        if (self.host.json_bool(self.host.ctx, node, &value) != abi.status_ok) return null;
        return value != 0;
    }

    pub fn asString(self: HostApi, node: ?*const abi.Json) ?[]const u8 {
        var pointer: ?[*]const u8 = null;
        var text_length: usize = 0;
        if (self.host.json_string(self.host.ctx, node, &pointer, &text_length) != abi.status_ok) return null;
        const start = pointer orelse return null;
        return start[0..text_length];
    }

    pub fn configBool(self: HostApi, config: ?*const abi.Json, key: []const u8, default: bool) bool {
        const node = self.member(config, key) orelse return default;
        return self.asBool(node) orelse blk: {
            self.warn("config key \"{s}\" must be true or false; using {}", .{ key, default });
            break :blk default;
        };
    }

    pub fn configInt(self: HostApi, config: ?*const abi.Json, key: []const u8, default: i64, min: i64, max: i64) i64 {
        const node = self.member(config, key) orelse return default;
        const value = self.asNumber(node) orelse {
            self.warn("config key \"{s}\" must be a number; using {d}", .{ key, default });
            return default;
        };
        const rounded = text.roundToInt(i64, value);
        if (rounded < min or rounded > max) {
            const clamped = std.math.clamp(rounded, min, max);
            self.warn("config key \"{s}\" = {d} is outside {d}..{d}; using {d}", .{ key, rounded, min, max, clamped });
            return clamped;
        }
        return rounded;
    }

    pub fn configString(self: HostApi, config: ?*const abi.Json, key: []const u8, buffer: []u8) ?[]const u8 {
        const node = self.member(config, key) orelse return null;
        const value = self.asString(node) orelse {
            self.warn("config key \"{s}\" must be a string; ignored", .{key});
            return null;
        };
        if (value.len > buffer.len) {
            self.warn("config key \"{s}\" is longer than {d} bytes; ignored", .{ key, buffer.len });
            return null;
        }
        @memcpy(buffer[0..value.len], value);
        return buffer[0..value.len];
    }
};
