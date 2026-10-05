const std = @import("std");
const sdk = @import("sdk");
const json = @import("../config/json.zig");
const formatting = @import("../diag/format.zig");

const abi = sdk.abi;

// What a resident rgbctrl found: its plugins, their devices and zones, and the problems of the
// configuration it uses. rgbctrl-gui reads it, because only one rgbctrl may open the devices.
pub const file_name = "rgbctrl.inventory.json";
pub const format_version: u32 = 1;
const max_problems = 200;

pub const Account = enum { system, elevated, standard };

pub const ConfigFile = struct {
    path: []const u8 = "",
    status: []const u8 = "",
    /// rgbctrl takes the privileged keys, such as plugins.<name>.enabled = true, from the file:
    /// both files while rgbctrl runs as a standard user, else only an admin-only base file.
    privileged: bool = false,
    /// rgbctrl could not use the file the last time it read the configuration.
    failed: bool = false,
    /// The write time and size (see formatStamp) of the file version rgbctrl runs, empty when
    /// there was no file.
    applied_stamp: []const u8 = "",
    /// The same for the version rgbctrl read last; it differs from applied_stamp when rgbctrl
    /// refused that version and kept the configuration from before (kept_previous).
    attempted_stamp: []const u8 = "",
};

pub const Severity = enum { warning, @"error" };

pub const Problem = struct {
    severity: Severity,
    message: []const u8,
};

pub const PluginState = enum { active, disabled, opening, failed, closed };

pub const Plugin = struct {
    name: []const u8,
    version: []const u8 = "",
    file: []const u8 = "",
    transports: u32 = 0,
    opt_in: bool = false,
    sensors: bool = false,
    enabled: bool = false,
    state: PluginState = .disabled,
};

pub const Zone = struct {
    name: []const u8,
    leds: u32 = 0,
    max_leds: u32 = 0,
    flags: u32 = 0,
    hardware_effects: u32 = 0,
    hardware_max_colors: u32 = 0,
};

pub const Device = struct {
    key: []const u8,
    name: []const u8 = "",
    plugin: []const u8 = "",
    zones: []const Zone = &.{},
};

pub const Inventory = struct {
    rgbctrl_version: []const u8 = "",
    account: Account = .standard,
    base: ConfigFile = .{},
    user: ConfigFile = .{},
    /// The last reload was refused (a file could not be used), so rgbctrl still runs the
    /// configuration from before it; base, user and problems describe the refused files.
    kept_previous: bool = false,
    problems: []const Problem = &.{},
    plugins: []const Plugin = &.{},
    devices: []const Device = &.{},
};

/// "<write time>:<size>" in decimal; text because write times exceed what a JSON number keeps.
pub fn formatStamp(buffer: []u8, exists: bool, write_time: u64, size: u64) []const u8 {
    if (!exists) return "";
    return formatting.print(buffer, "{d}:{d}", .{ write_time, size });
}

const transport_names = [_]struct { bit: u32, name: []const u8 }{
    .{ .bit = abi.transport_hid, .name = "HID" },
    .{ .bit = abi.transport_smbus, .name = "SMBus" },
    .{ .bit = abi.transport_i2c, .name = "I2C" },
    .{ .bit = abi.transport_os, .name = "OS" },
};

const Output = struct {
    allocator: std.mem.Allocator,
    bytes: std.ArrayList(u8) = .empty,

    fn raw(self: *Output, text: []const u8) error{OutOfMemory}!void {
        try self.bytes.appendSlice(self.allocator, text);
    }

    fn unsigned(self: *Output, value: u64) error{OutOfMemory}!void {
        var buffer: [24]u8 = undefined;
        try self.raw(formatting.print(&buffer, "{d}", .{value}));
    }

    fn boolean(self: *Output, value: bool) error{OutOfMemory}!void {
        try self.raw(if (value) "true" else "false");
    }

    fn string(self: *Output, text: []const u8) error{OutOfMemory}!void {
        try json.appendString(self.allocator, &self.bytes, text);
    }

    fn member(self: *Output, comptime separator: []const u8, comptime key: []const u8) error{OutOfMemory}!void {
        try self.raw(separator ++ "\"" ++ key ++ "\": ");
    }

    fn configFile(self: *Output, file: ConfigFile) error{OutOfMemory}!void {
        try self.member("{ ", "path");
        try self.string(file.path);
        try self.member(", ", "status");
        try self.string(file.status);
        try self.member(", ", "privileged");
        try self.boolean(file.privileged);
        try self.member(", ", "failed");
        try self.boolean(file.failed);
        try self.member(", ", "applied_stamp");
        try self.string(file.applied_stamp);
        try self.member(", ", "attempted_stamp");
        try self.string(file.attempted_stamp);
        try self.raw(" }");
    }

    fn effectNames(self: *Output, mask: u32) error{OutOfMemory}!void {
        try self.raw("[");
        var first = true;
        for (0..abi.effect_count) |index| {
            const effect: abi.Effect = @enumFromInt(index);
            if (mask & abi.effectBit(effect) == 0) continue;
            if (!first) try self.raw(", ");
            first = false;
            try self.string(@tagName(effect));
        }
        try self.raw("]");
    }

    fn transportNames(self: *Output, mask: u32) error{OutOfMemory}!void {
        try self.raw("[");
        var first = true;
        for (transport_names) |entry| {
            if (mask & entry.bit == 0) continue;
            if (!first) try self.raw(", ");
            first = false;
            try self.string(entry.name);
        }
        try self.raw("]");
    }

    fn plugin(self: *Output, entry: Plugin) error{OutOfMemory}!void {
        try self.member("{ ", "name");
        try self.string(entry.name);
        try self.member(", ", "version");
        try self.string(entry.version);
        try self.member(", ", "file");
        try self.string(entry.file);
        try self.member(", ", "transports");
        try self.transportNames(entry.transports);
        try self.member(", ", "opt_in");
        try self.boolean(entry.opt_in);
        try self.member(", ", "sensors");
        try self.boolean(entry.sensors);
        try self.member(", ", "enabled");
        try self.boolean(entry.enabled);
        try self.member(", ", "state");
        try self.string(@tagName(entry.state));
        try self.raw(" }");
    }

    fn zone(self: *Output, entry: Zone) error{OutOfMemory}!void {
        try self.member("{ ", "name");
        try self.string(entry.name);
        try self.member(", ", "leds");
        try self.unsigned(entry.leds);
        try self.member(", ", "max_leds");
        try self.unsigned(entry.max_leds);
        try self.member(", ", "resizable");
        try self.boolean(entry.flags & abi.zone_resizable != 0);
        try self.member(", ", "host_frames");
        try self.boolean(entry.flags & abi.zone_host_frames != 0);
        try self.member(", ", "global_brightness_only");
        try self.boolean(entry.flags & abi.zone_global_brightness_only != 0);
        try self.member(", ", "hardware_effects");
        try self.effectNames(entry.hardware_effects);
        try self.member(", ", "hardware_max_colors");
        try self.unsigned(entry.hardware_max_colors);
        try self.raw(" }");
    }
};

pub fn render(allocator: std.mem.Allocator, inventory: *const Inventory) error{OutOfMemory}![]u8 {
    var out = Output{ .allocator = allocator };
    errdefer out.bytes.deinit(allocator);
    try out.member("{\n  ", "format");
    try out.unsigned(format_version);
    try out.member(",\n  ", "rgbctrl");
    try out.string(inventory.rgbctrl_version);
    try out.member(",\n  ", "account");
    try out.string(@tagName(inventory.account));
    try out.member(",\n  ", "config");
    try out.member("{\n    ", "base");
    try out.configFile(inventory.base);
    try out.member(",\n    ", "user");
    try out.configFile(inventory.user);
    try out.member(",\n    ", "kept_previous");
    try out.boolean(inventory.kept_previous);
    try out.raw("\n  }");
    try out.member(",\n  ", "problems");
    try out.raw("[");
    const problems = inventory.problems[0..@min(inventory.problems.len, max_problems)];
    for (problems, 0..) |problem, index| {
        try out.raw(if (index == 0) "\n    " else ",\n    ");
        try out.member("{ ", "severity");
        try out.string(@tagName(problem.severity));
        try out.member(", ", "message");
        try out.string(problem.message);
        try out.raw(" }");
    }
    try out.raw(if (problems.len == 0) "]" else "\n  ]");
    try out.member(",\n  ", "plugins");
    try out.raw("[");
    for (inventory.plugins, 0..) |entry, index| {
        try out.raw(if (index == 0) "\n    " else ",\n    ");
        try out.plugin(entry);
    }
    try out.raw(if (inventory.plugins.len == 0) "]" else "\n  ]");
    try out.member(",\n  ", "devices");
    try out.raw("[");
    for (inventory.devices, 0..) |device, index| {
        try out.raw(if (index == 0) "\n    " else ",\n    ");
        try out.member("{\n      ", "key");
        try out.string(device.key);
        try out.member(",\n      ", "name");
        try out.string(device.name);
        try out.member(",\n      ", "plugin");
        try out.string(device.plugin);
        try out.member(",\n      ", "zones");
        try out.raw("[");
        for (device.zones, 0..) |entry, zone_index| {
            try out.raw(if (zone_index == 0) "\n        " else ",\n        ");
            try out.zone(entry);
        }
        try out.raw(if (device.zones.len == 0) "]" else "\n      ]");
        try out.raw("\n    }");
    }
    try out.raw(if (inventory.devices.len == 0) "]" else "\n  ]");
    try out.raw("\n}\n");
    return out.bytes.toOwnedSlice(allocator);
}

pub const ParseError = error{ OutOfMemory, Malformed, UnsupportedFormat };

/// Reads an inventory written by render. Unknown keys are ignored, so a newer rgbctrl may add
/// some; it raises the format number only for changes an older reader would misread.
pub fn parse(arena: std.mem.Allocator, text: []const u8) ParseError!Inventory {
    var warnings: std.ArrayList(json.Issue) = .empty;
    const root = switch (try json.parse(arena, text, &warnings)) {
        .document => |document| document,
        .failure => return error.Malformed,
    };
    const format = (root.get("format") orelse return error.Malformed).number() orelse return error.Malformed;
    if (format != format_version) return error.UnsupportedFormat;
    var inventory = Inventory{
        .rgbctrl_version = stringField(root, "rgbctrl"),
        .account = enumField(Account, root, "account") orelse .standard,
    };
    if (root.get("config")) |config| {
        inventory.base = configFileFrom(config.get("base"));
        inventory.user = configFileFrom(config.get("user"));
        inventory.kept_previous = boolField(config, "kept_previous");
    }
    const problem_items = arrayField(root, "problems");
    const problems = try arena.alloc(Problem, problem_items.len);
    for (problem_items, problems) |item, *problem| {
        problem.* = .{ .severity = enumField(Severity, item, "severity") orelse .warning, .message = stringField(item, "message") };
    }
    inventory.problems = problems;
    const plugin_items = arrayField(root, "plugins");
    const plugins = try arena.alloc(Plugin, plugin_items.len);
    for (plugin_items, plugins) |item, *entry| {
        entry.* = .{
            .name = stringField(item, "name"),
            .version = stringField(item, "version"),
            .file = stringField(item, "file"),
            .transports = transportMask(arrayField(item, "transports")),
            .opt_in = boolField(item, "opt_in"),
            .sensors = boolField(item, "sensors"),
            .enabled = boolField(item, "enabled"),
            .state = enumField(PluginState, item, "state") orelse .disabled,
        };
    }
    inventory.plugins = plugins;
    const device_items = arrayField(root, "devices");
    const devices = try arena.alloc(Device, device_items.len);
    for (device_items, devices) |item, *device| {
        const zone_items = arrayField(item, "zones");
        const zones = try arena.alloc(Zone, zone_items.len);
        for (zone_items, zones) |zone_item, *entry| {
            var flags: u32 = 0;
            if (boolField(zone_item, "resizable")) flags |= abi.zone_resizable;
            if (boolField(zone_item, "host_frames")) flags |= abi.zone_host_frames;
            if (boolField(zone_item, "global_brightness_only")) flags |= abi.zone_global_brightness_only;
            entry.* = .{
                .name = stringField(zone_item, "name"),
                .leds = countField(zone_item, "leds"),
                .max_leds = countField(zone_item, "max_leds"),
                .flags = flags,
                .hardware_effects = effectMask(arrayField(zone_item, "hardware_effects")),
                .hardware_max_colors = countField(zone_item, "hardware_max_colors"),
            };
        }
        device.* = .{ .key = stringField(item, "key"), .name = stringField(item, "name"), .plugin = stringField(item, "plugin"), .zones = zones };
    }
    inventory.devices = devices;
    return inventory;
}

fn stringField(node: *const json.Node, key: []const u8) []const u8 {
    const value = node.get(key) orelse return "";
    return value.string() orelse "";
}

fn boolField(node: *const json.Node, key: []const u8) bool {
    const value = node.get(key) orelse return false;
    return value.boolean() orelse false;
}

fn countField(node: *const json.Node, key: []const u8) u32 {
    const value = (node.get(key) orelse return 0).number() orelse return 0;
    if (!(value >= 0)) return 0;
    return @intFromFloat(@min(value, @as(f64, std.math.maxInt(u32))));
}

fn arrayField(node: *const json.Node, key: []const u8) []const *const json.Node {
    const value = node.get(key) orelse return &.{};
    return value.arrayItems() orelse &.{};
}

fn enumField(comptime Enum: type, node: *const json.Node, key: []const u8) ?Enum {
    return std.meta.stringToEnum(Enum, stringField(node, key));
}

fn configFileFrom(node: ?*const json.Node) ConfigFile {
    const file = node orelse return .{};
    return .{
        .path = stringField(file, "path"),
        .status = stringField(file, "status"),
        .privileged = boolField(file, "privileged"),
        .failed = boolField(file, "failed"),
        .applied_stamp = stringField(file, "applied_stamp"),
        .attempted_stamp = stringField(file, "attempted_stamp"),
    };
}

fn effectMask(items: []const *const json.Node) u32 {
    var mask: u32 = 0;
    for (items) |item| {
        const effect = std.meta.stringToEnum(abi.Effect, item.string() orelse continue) orelse continue;
        mask |= abi.effectBit(effect);
    }
    return mask;
}

fn transportMask(items: []const *const json.Node) u32 {
    var mask: u32 = 0;
    for (items) |item| {
        const name = item.string() orelse continue;
        for (transport_names) |entry| {
            if (std.mem.eql(u8, entry.name, name)) mask |= entry.bit;
        }
    }
    return mask;
}

const testing = std.testing;

fn sampleInventory() Inventory {
    const S = struct {
        const fan_effects = abi.effectBit(.off) | abi.effectBit(.static) | abi.effectBit(.breathing) | abi.effectBit(.cycle) | abi.effectBit(.rainbow);
        const motherboard_zones = [_]Zone{
            .{ .name = "argb1", .leds = 30, .max_leds = 256, .flags = abi.zone_resizable | abi.zone_host_frames, .hardware_effects = abi.effectBit(.static), .hardware_max_colors = 1 },
            .{ .name = "io_cover", .leds = 1, .max_leds = 1, .flags = abi.zone_host_frames, .hardware_effects = fan_effects, .hardware_max_colors = 1 },
        };
        const devices = [_]Device{
            .{ .key = "motherboard", .name = "Gigabyte X870E AORUS PRO ICE", .plugin = "gigabyte_fusion2", .zones = &motherboard_zones },
            .{ .key = "ram", .name = "Corsair \"Vengeance\" RGB", .plugin = "corsair_ddr5" },
        };
        const plugins = [_]Plugin{
            .{ .name = "gigabyte_fusion2", .version = "0.1.0", .file = "gigabyte_fusion2.dll", .transports = abi.transport_hid, .enabled = true, .state = .active },
            .{ .name = "corsair_ddr5", .version = "0.1.0", .file = "corsair_ddr5.dll", .transports = abi.transport_smbus, .opt_in = true, .state = .disabled },
            .{ .name = "amd_cpu", .transports = abi.transport_os, .sensors = true, .enabled = true, .state = .failed },
        };
        const problems = [_]Problem{
            .{ .severity = .warning, .message = "line 3:5: lighting.gpu.fan matches no zone; did you mean \"fan_left\"?" },
            .{ .severity = .@"error", .message = "tab\there\nnewline \x01 control" },
        };
    };
    return .{
        .rgbctrl_version = "0.1.0",
        .account = .system,
        .base = .{ .path = "C:\\ProgramData\\rgbctrl\\rgbctrl.json", .status = "used", .privileged = true, .applied_stamp = "133713371337133713:24", .attempted_stamp = "133713371337133999:25" },
        .user = .{ .path = "C:\\Users\\Ünïcode\\AppData\\Local\\rgbctrl\\rgbctrl.json", .status = "ignored: line 1:2: expected a key", .failed = true },
        .problems = &S.problems,
        .plugins = &S.plugins,
        .devices = &S.devices,
    };
}

test "an inventory survives rendering and parsing unchanged" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const original = sampleInventory();
    const text = try render(arena, &original);
    const parsed = try parse(arena, text);
    try testing.expectEqualStrings(original.rgbctrl_version, parsed.rgbctrl_version);
    try testing.expectEqual(original.account, parsed.account);
    try testing.expectEqualStrings(original.base.path, parsed.base.path);
    try testing.expectEqualStrings(original.base.applied_stamp, parsed.base.applied_stamp);
    try testing.expectEqualStrings(original.base.attempted_stamp, parsed.base.attempted_stamp);
    try testing.expect(!parsed.base.failed);
    try testing.expect(parsed.base.privileged);
    try testing.expect(!parsed.user.privileged);
    try testing.expectEqualStrings(original.user.path, parsed.user.path);
    try testing.expectEqualStrings(original.user.status, parsed.user.status);
    try testing.expect(parsed.user.failed);
    try testing.expectEqualStrings("", parsed.user.applied_stamp);
    try testing.expectEqualStrings("", parsed.user.attempted_stamp);
    try testing.expect(!parsed.kept_previous);
    try testing.expectEqual(original.problems.len, parsed.problems.len);
    for (original.problems, parsed.problems) |expected, actual| {
        try testing.expectEqual(expected.severity, actual.severity);
        try testing.expectEqualStrings(expected.message, actual.message);
    }
    try testing.expectEqual(original.plugins.len, parsed.plugins.len);
    for (original.plugins, parsed.plugins) |expected, actual| {
        try testing.expectEqualStrings(expected.name, actual.name);
        try testing.expectEqualStrings(expected.file, actual.file);
        try testing.expectEqual(expected.transports, actual.transports);
        try testing.expectEqual(expected.opt_in, actual.opt_in);
        try testing.expectEqual(expected.sensors, actual.sensors);
        try testing.expectEqual(expected.enabled, actual.enabled);
        try testing.expectEqual(expected.state, actual.state);
    }
    try testing.expectEqual(original.devices.len, parsed.devices.len);
    for (original.devices, parsed.devices) |expected, actual| {
        try testing.expectEqualStrings(expected.key, actual.key);
        try testing.expectEqualStrings(expected.name, actual.name);
        try testing.expectEqualStrings(expected.plugin, actual.plugin);
        try testing.expectEqual(expected.zones.len, actual.zones.len);
        for (expected.zones, actual.zones) |expected_zone, actual_zone| {
            try testing.expectEqualStrings(expected_zone.name, actual_zone.name);
            try testing.expectEqual(expected_zone.leds, actual_zone.leds);
            try testing.expectEqual(expected_zone.max_leds, actual_zone.max_leds);
            try testing.expectEqual(expected_zone.flags, actual_zone.flags);
            try testing.expectEqual(expected_zone.hardware_effects, actual_zone.hardware_effects);
            try testing.expectEqual(expected_zone.hardware_max_colors, actual_zone.hardware_max_colors);
        }
    }
}

test "the rendered inventory is readable JSON with named effects and transports" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const original = sampleInventory();
    const text = try render(arena_state.allocator(), &original);
    try testing.expect(std.mem.indexOf(u8, text, "\"hardware_effects\": [\"off\", \"static\", \"breathing\", \"cycle\", \"rainbow\"]") != null);
    try testing.expect(std.mem.indexOf(u8, text, "\"transports\": [\"SMBus\"]") != null);
    try testing.expect(std.mem.indexOf(u8, text, "\"C:\\\\ProgramData\\\\rgbctrl\\\\rgbctrl.json\"") != null);
    try testing.expect(std.mem.indexOf(u8, text, "\\u0001") != null);
    try testing.expect(std.mem.indexOf(u8, text, "\"zones\": []") != null);
    try testing.expect(std.mem.endsWith(u8, text, "\n}\n"));
}

test "an empty inventory renders and parses" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const text = try render(arena, &Inventory{ .kept_previous = true });
    const parsed = try parse(arena, text);
    try testing.expect(parsed.kept_previous);
    try testing.expectEqual(@as(usize, 0), parsed.devices.len);
    try testing.expectEqual(@as(usize, 0), parsed.plugins.len);
}

test "a device name that is not UTF-8 still gives a readable inventory" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const devices = [_]Device{.{ .key = "keyboard", .name = "Logitech G915\x99" }};
    const text = try render(arena, &Inventory{ .devices = &devices });
    const parsed = try parse(arena, text);
    try testing.expectEqualStrings("Logitech G915\u{FFFD}", parsed.devices[0].name);
}

test "other formats and broken files are refused, missing optional keys get defaults" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    try testing.expectError(error.UnsupportedFormat, parse(arena, "{ \"format\": 2 }"));
    try testing.expectError(error.Malformed, parse(arena, "{ \"devices\": [] }"));
    try testing.expectError(error.Malformed, parse(arena, "{ \"format\": 1, "));
    const minimal = try parse(arena, "{ \"format\": 1, \"devices\": [ { \"key\": \"gpu\", \"zones\": [ { \"name\": \"logo\", \"leds\": -3, \"hardware_effects\": [\"static\", \"sparkle\"] } ] } ], \"future\": true }");
    try testing.expectEqual(Account.standard, minimal.account);
    try testing.expectEqual(@as(usize, 1), minimal.devices.len);
    try testing.expectEqual(@as(u32, 0), minimal.devices[0].zones[0].leds);
    try testing.expectEqual(abi.effectBit(.static), minimal.devices[0].zones[0].hardware_effects);
}

test "stamps are the write time and size in decimal, empty for a missing file" {
    var buffer: [48]u8 = undefined;
    try testing.expectEqualStrings("133713371337133713:1024", formatStamp(&buffer, true, 133713371337133713, 1024));
    try testing.expectEqualStrings("", formatStamp(&buffer, false, 5, 5));
}
