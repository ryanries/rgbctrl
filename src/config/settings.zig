const std = @import("std");
const sdk = @import("sdk");
const json = @import("json.zig");
const suggest = @import("suggest.zig");
const Diagnostics = @import("diagnostics.zig").Diagnostics;

pub const LogLevel = sdk.abi.LogLevel;

pub const default_log_file = "rgbctrl.log";
const default_log_max_size_kb: u32 = 1024;
const default_frame_rate: u32 = 30;

const top_level_keys = [_][]const u8{ "log", "frame_rate", "plugins", "lighting" };
const log_keys = [_][]const u8{ "file", "level", "max_size_kb" };
const level_names = [_][]const u8{ "error", "warn", "info", "debug", "trace" };
const dos_device_names = [_][]const u8{ "CON", "PRN", "AUX", "NUL", "COM0", "COM1", "COM2", "COM3", "COM4", "COM5", "COM6", "COM7", "COM8", "COM9", "LPT0", "LPT1", "LPT2", "LPT3", "LPT4", "LPT5", "LPT6", "LPT7", "LPT8", "LPT9" };

pub const Settings = struct {
    log_file: []const u8 = default_log_file,
    log_level: LogLevel = .debug,
    log_max_size_kb: u32 = default_log_max_size_kb,
    frame_rate: u32 = default_frame_rate,
    lighting: ?*const json.Node = null,
    plugins: ?*const json.Node = null,
    untrusted_enable_requests: []const []const u8 = &.{},

    pub fn pluginConfig(self: *const Settings, name: []const u8) ?*const json.Node {
        const plugins = self.plugins orelse return null;
        const node = plugins.get(name) orelse return null;
        return if (node.kind() == .object) node else null;
    }

    pub fn pluginEnabled(self: *const Settings, name: []const u8, opt_in: bool) bool {
        const config = self.pluginConfig(name) orelse return !opt_in;
        const node = config.get("enabled") orelse return !opt_in;
        return node.boolean() orelse !opt_in;
    }

    pub fn pluginPersist(self: *const Settings, name: []const u8) bool {
        const config = self.pluginConfig(name) orelse return false;
        const node = config.get("persist") orelse return false;
        return node.boolean() orelse false;
    }

    pub fn enableRequestedByUntrustedLayer(self: *const Settings, name: []const u8) bool {
        for (self.untrusted_enable_requests) |requested| {
            if (std.mem.eql(u8, requested, name)) return true;
        }
        return false;
    }

    pub fn pluginHash(self: *const Settings, name: []const u8) u64 {
        var state: u64 = json.fnv_offset_basis;
        const config = self.pluginConfig(name) orelse return state;
        for (config.objectMembers().?) |member| {
            if (std.mem.eql(u8, member.key, "enabled") or std.mem.eql(u8, member.key, "persist")) continue;
            state = json.hash(member.value, state ^ std.hash.Fnv1a_64.hash(member.key));
        }
        return state;
    }

    pub fn configuredPluginNames(self: *const Settings) []const json.Member {
        const plugins = self.plugins orelse return &.{};
        return plugins.objectMembers() orelse &.{};
    }
};

fn isValidLogFileName(name: []const u8) bool {
    if (name.len < 5 or name.len > 63) return false;
    if (!std.mem.endsWith(u8, name, ".log")) return false;
    const base = name[0 .. name.len - 4];
    if (!std.ascii.isAlphanumeric(base[0])) return false;
    for (base[1..]) |char| {
        if (!std.ascii.isAlphanumeric(char) and char != '_' and char != '-') return false;
    }
    for (dos_device_names) |device| {
        if (std.ascii.eqlIgnoreCase(base, device)) return false;
    }
    return true;
}

fn parseLevel(name: []const u8) ?LogLevel {
    for (level_names, 0..) |level_name, index| {
        if (std.ascii.eqlIgnoreCase(name, level_name)) return @enumFromInt(index);
    }
    return null;
}

fn levelName(level: LogLevel) []const u8 {
    return level_names[@intFromEnum(level)];
}

pub fn extract(root: *const json.Node, untrusted_enable_requests: []const []const u8, diagnostics: *Diagnostics) Settings {
    var settings = Settings{ .untrusted_enable_requests = untrusted_enable_requests };
    for (root.objectMembers() orelse &.{}) |member| {
        if (!isKnown(&top_level_keys, member.key)) warnUnknownKey(diagnostics, member.value, "", member.key, &top_level_keys);
    }
    if (root.get("log")) |log| {
        if (log.objectMembers()) |members| {
            for (members) |member| {
                if (!isKnown(&log_keys, member.key)) warnUnknownKey(diagnostics, member.value, "log.", member.key, &log_keys);
            }
            if (log.get("file")) |file| {
                if (file.string()) |name| {
                    if (isValidLogFileName(name)) {
                        settings.log_file = name;
                    } else {
                        diagnostics.warnAt(file, "log.file \"{s}\" must be a plain file name like rgbctrl.log (letters, digits, '_' or '-', ending in .log, not a device name); using {s}", .{ name, default_log_file });
                    }
                } else {
                    diagnostics.warnAt(file, "log.file must be a string; using {s}", .{default_log_file});
                }
            }
            if (log.get("level")) |level| {
                const parsed = if (level.string()) |name| parseLevel(name) else null;
                if (parsed) |value| {
                    settings.log_level = value;
                } else {
                    diagnostics.warnAt(level, "log.level must be one of error, warn, info, debug, trace; using debug", .{});
                }
            }
            if (log.get("max_size_kb")) |size| {
                settings.log_max_size_kb = clampedInteger(diagnostics, size, "log.max_size_kb", 64, 65536, default_log_max_size_kb);
            }
        } else {
            diagnostics.warnAt(log, "log must be an object; using the defaults", .{});
        }
    }
    if (root.get("frame_rate")) |rate| {
        settings.frame_rate = clampedInteger(diagnostics, rate, "frame_rate", 1, 60, default_frame_rate);
    }
    if (root.get("plugins")) |plugins| {
        if (plugins.objectMembers()) |members| {
            settings.plugins = plugins;
            for (members) |member| {
                const config = member.value;
                if (config.objectMembers() == null) {
                    diagnostics.warnAt(config, "plugins.{s} must be an object; ignored", .{member.key});
                    continue;
                }
                for ([_][]const u8{ "enabled", "persist" }) |key| {
                    if (config.get(key)) |value| {
                        if (value.boolean() == null) diagnostics.warnAt(value, "plugins.{s}.{s} must be true or false; using the default", .{ member.key, key });
                    }
                }
            }
        } else {
            diagnostics.warnAt(plugins, "plugins must be an object; ignored", .{});
        }
    }
    if (root.get("lighting")) |lighting| {
        if (lighting.objectMembers() != null) {
            settings.lighting = lighting;
        } else {
            diagnostics.warnAt(lighting, "lighting must be an object; ignored", .{});
        }
    }
    return settings;
}

fn clampedInteger(diagnostics: *Diagnostics, node: *const json.Node, path: []const u8, min: i64, max: i64, default: u32) u32 {
    const value = node.number() orelse {
        diagnostics.warnAt(node, "{s} must be a number; using {d}", .{ path, default });
        return default;
    };
    const rounded = sdk.text.roundToInt(i64, value);
    if (rounded < min or rounded > max) {
        const clamped = std.math.clamp(rounded, min, max);
        diagnostics.warnAt(node, "{s} = {d} is outside {d}..{d}; using {d}", .{ path, rounded, min, max, clamped });
        return @intCast(clamped);
    }
    return @intCast(rounded);
}

fn isKnown(known: []const []const u8, key: []const u8) bool {
    for (known) |candidate| {
        if (std.mem.eql(u8, candidate, key)) return true;
    }
    return false;
}

fn warnUnknownKey(diagnostics: *Diagnostics, node: *const json.Node, prefix: []const u8, key: []const u8, known: []const []const u8) void {
    if (diagnostics.isFull()) return;
    if (suggest.closest(key, known)) |suggestion| {
        diagnostics.warnAt(node, "unknown key \"{s}{s}\"; did you mean \"{s}\"?", .{ prefix, key, suggestion });
    } else {
        diagnostics.warnAt(node, "unknown key \"{s}{s}\"", .{ prefix, key });
    }
}

const testing = std.testing;

fn parseTestDocument(arena: std.mem.Allocator, source: []const u8) !*const json.Node {
    var warnings: std.ArrayList(json.Issue) = .empty;
    return switch (try json.parse(arena, source, &warnings)) {
        .document => |document| document,
        .failure => error.TestUnexpectedResult,
    };
}

test "an empty config yields the documented defaults" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    var diagnostics = Diagnostics.init(arena_state.allocator());
    const settings = extract(&json.empty_object, &.{}, &diagnostics);
    try testing.expectEqualStrings("rgbctrl.log", settings.log_file);
    try testing.expectEqual(LogLevel.debug, settings.log_level);
    try testing.expectEqual(@as(u32, 1024), settings.log_max_size_kb);
    try testing.expectEqual(@as(u32, 30), settings.frame_rate);
    try testing.expect(settings.pluginEnabled("keychron", false));
    try testing.expect(!settings.pluginEnabled("corsair_ddr5", true));
    try testing.expect(!settings.pluginPersist("keychron"));
    try testing.expectEqual(@as(usize, 0), diagnostics.entries.items.len);
}

test "settings are read, clamped and validated with suggestions for typos" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var diagnostics = Diagnostics.init(arena);
    const root = try parseTestDocument(arena,
        \\{"log": {"file": "lights.log", "level": "TRACE", "max_size_kb": 10, "levle": 1},
        \\ "frame_rate": 144, "lightning": {},
        \\ "plugins": {"corsair_ddr5": {"enabled": true, "persist": "yes"}, "keychron": {"persist": true}}}
    );
    const settings = extract(root, &.{}, &diagnostics);
    try testing.expectEqualStrings("lights.log", settings.log_file);
    try testing.expectEqual(LogLevel.trace, settings.log_level);
    try testing.expectEqual(@as(u32, 64), settings.log_max_size_kb);
    try testing.expectEqual(@as(u32, 60), settings.frame_rate);
    try testing.expect(settings.pluginEnabled("corsair_ddr5", true));
    try testing.expect(!settings.pluginPersist("corsair_ddr5"));
    try testing.expect(settings.pluginPersist("keychron"));
    try testing.expect(diagnostics.contains("unknown key \"log.levle\"; did you mean \"level\"?"));
    try testing.expect(diagnostics.contains("unknown key \"lightning\"; did you mean \"lighting\"?"));
    try testing.expect(diagnostics.contains("frame_rate = 144 is outside 1..60; using 60"));
    try testing.expect(diagnostics.contains("log.max_size_kb = 10 is outside 64..65536; using 64"));
    try testing.expect(diagnostics.contains("plugins.corsair_ddr5.persist must be true or false"));
}

test "log file names follow the strict grammar and never name a device" {
    try testing.expect(isValidLogFileName("rgbctrl.log"));
    try testing.expect(isValidLogFileName("a.log"));
    try testing.expect(isValidLogFileName("Lights_2-b.log"));
    try testing.expect(!isValidLogFileName(".log"));
    try testing.expect(!isValidLogFileName("_x.log"));
    try testing.expect(!isValidLogFileName("..\\x.log"));
    try testing.expect(!isValidLogFileName("x.txt"));
    try testing.expect(!isValidLogFileName("a b.log"));
    try testing.expect(!isValidLogFileName("nul.log"));
    try testing.expect(!isValidLogFileName("COM1.log"));
    try testing.expect(!isValidLogFileName("C:x.log"));
    try testing.expect(isValidLogFileName(@as([59]u8, @splat('a')) ++ ".log"));
    try testing.expect(!isValidLogFileName(@as([60]u8, @splat('a')) ++ ".log"));
}

test "plugin hashes ignore enabled and persist but see every other key" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var diagnostics = Diagnostics.init(arena);
    const first = extract(try parseTestDocument(arena, "{\"plugins\": {\"p\": {\"enabled\": true, \"x\": 1}}}"), &.{}, &diagnostics);
    const toggled = extract(try parseTestDocument(arena, "{\"plugins\": {\"p\": {\"enabled\": false, \"persist\": true, \"x\": 1}}}"), &.{}, &diagnostics);
    const changed = extract(try parseTestDocument(arena, "{\"plugins\": {\"p\": {\"x\": 2}}}"), &.{}, &diagnostics);
    try testing.expectEqual(first.pluginHash("p"), toggled.pluginHash("p"));
    try testing.expect(first.pluginHash("p") != changed.pluginHash("p"));
}
