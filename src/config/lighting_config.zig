const std = @import("std");
const formatting = @import("../diag/format.zig");
const sdk = @import("sdk");
const json = @import("json.zig");
const suggest = @import("suggest.zig");
const Diagnostics = @import("diagnostics.zig").Diagnostics;

const abi = sdk.abi;
const Rgb = abi.Rgb;

const wildcard = "*";
const max_colors = 16;
const max_led_colors = 4096;
const default_speed: u8 = 50;
const default_brightness: u8 = 100;
const default_colors = [_]Rgb{.{ .r = 255, .g = 255, .b = 255 }};

const spec_keys = [_][]const u8{ "effect", "color", "colors", "speed", "brightness", "engine", "leds", "reverse", "led_colors" };
const effect_names = [_][]const u8{ "off", "static", "breathing", "flash", "cycle", "rainbow", "gradient" };

const Engine = enum { auto, host, hardware };

pub const Spec = struct {
    effect: abi.Effect,
    colors: []const Rgb = &default_colors,
    speed: u8 = default_speed,
    brightness: u8 = default_brightness,
    engine: Engine = .auto,
    leds: ?u32 = null,
    reverse: bool = false,
    led_colors: []const Rgb = &.{},

    pub fn eql(self: *const Spec, other: *const Spec) bool {
        if (self.effect != other.effect or self.speed != other.speed or self.brightness != other.brightness) return false;
        if (self.engine != other.engine or self.reverse != other.reverse or !std.meta.eql(self.leds, other.leds)) return false;
        return colorsEqual(self.colors, other.colors) and colorsEqual(self.led_colors, other.led_colors);
    }

    pub fn isSpatial(self: *const Spec) bool {
        return switch (self.effect) {
            .rainbow, .gradient => true,
            .static => self.led_colors.len > 0,
            else => false,
        };
    }
};

fn colorsEqual(first: []const Rgb, second: []const Rgb) bool {
    if (first.len != second.len) return false;
    for (first, second) |a, b| {
        if (!a.eql(b)) return false;
    }
    return true;
}

pub const Resolution = union(enum) {
    untouched,
    invalid,
    spec: Spec,
};

pub const ZoneShape = struct {
    flags: u32 = 0,
    led_count: u32 = 0,
    max_leds: u32 = 0,
    hw_effects: u32 = 0,
    hw_max_colors: u32 = 0,

    fn resizable(self: ZoneShape) bool {
        return self.flags & abi.zone_resizable != 0;
    }

    fn hostFrames(self: ZoneShape) bool {
        return self.flags & abi.zone_host_frames != 0;
    }

    fn supports(self: ZoneShape, effect: abi.Effect) bool {
        return self.hw_effects & abi.effectBit(effect) != 0;
    }
};

const level_labels = [_][2]bool{ .{ false, false }, .{ false, true }, .{ true, false }, .{ true, true } };

const Levels = struct {
    nodes: [4]?*const json.Node,
    device_key: []const u8,
    zone_name: []const u8,

    fn pick(self: *const Levels, key: []const u8) ?Picked {
        var level: usize = 4;
        while (level > 0) {
            level -= 1;
            const node = self.nodes[level] orelse continue;
            if (node.get(key)) |value| return .{ .node = value, .level = level };
        }
        return null;
    }

    fn pickColors(self: *const Levels) ?Picked {
        var level: usize = 4;
        while (level > 0) {
            level -= 1;
            const node = self.nodes[level] orelse continue;
            if (node.get("colors")) |value| return .{ .node = value, .level = level, .is_list = true };
            if (node.get("color")) |value| return .{ .node = value, .level = level, .is_list = false };
        }
        return null;
    }

    fn deviceLabel(self: *const Levels, level: usize) []const u8 {
        return if (level_labels[level][0]) self.device_key else wildcard;
    }

    fn zoneLabel(self: *const Levels, level: usize) []const u8 {
        return if (level_labels[level][1]) self.zone_name else wildcard;
    }
};

const Picked = struct {
    node: *const json.Node,
    level: usize,
    is_list: bool = false,
};

fn childObject(parent: ?*const json.Node, key: []const u8) ?*const json.Node {
    const node = (parent orelse return null).get(key) orelse return null;
    return if (node.kind() == .object) node else null;
}

pub fn resolve(arena: std.mem.Allocator, lighting: ?*const json.Node, device_key: []const u8, zone_name: []const u8, shape: ZoneShape, diagnostics: *Diagnostics) error{OutOfMemory}!Resolution {
    const any_device = childObject(lighting, wildcard);
    const this_device = childObject(lighting, device_key);
    const levels = Levels{
        .nodes = .{ childObject(any_device, wildcard), childObject(any_device, zone_name), childObject(this_device, wildcard), childObject(this_device, zone_name) },
        .device_key = device_key,
        .zone_name = zone_name,
    };
    var spec = Spec{ .effect = .static };
    const led_colors_pick = levels.pick("led_colors");
    if (levels.pick("effect")) |picked| {
        const name = picked.node.string() orelse return invalidValue(diagnostics, &levels, picked, "effect", "must be a string");
        if (std.mem.eql(u8, name, "none")) return .untouched;
        spec.effect = parseEffect(name) orelse return invalidValue(diagnostics, &levels, picked, "effect", "must be one of off, static, breathing, flash, cycle, rainbow, gradient, none");
    } else if (led_colors_pick == null) {
        return .untouched;
    }
    if (spec.effect != .off) {
        if (levels.pickColors()) |picked| {
            spec.colors = (try parseColorList(arena, diagnostics, &levels, picked)) orelse return .invalid;
        }
    }
    if (levels.pick("speed")) |picked| {
        spec.speed = (percent(diagnostics, &levels, picked, "speed")) orelse return .invalid;
    }
    if (levels.pick("brightness")) |picked| {
        spec.brightness = (percent(diagnostics, &levels, picked, "brightness")) orelse return .invalid;
    }
    if (levels.pick("engine")) |picked| {
        const name = picked.node.string() orelse return invalidValue(diagnostics, &levels, picked, "engine", "must be auto, host or hardware");
        spec.engine = std.meta.stringToEnum(Engine, name) orelse return invalidValue(diagnostics, &levels, picked, "engine", "must be auto, host or hardware");
    }
    if (levels.pick("reverse")) |picked| {
        spec.reverse = picked.node.boolean() orelse return invalidValue(diagnostics, &levels, picked, "reverse", "must be true or false");
    }
    var led_count = shape.led_count;
    if (levels.pick("leds")) |picked| {
        const value = picked.node.number() orelse return invalidValue(diagnostics, &levels, picked, "leds", "must be a number");
        const rounded = sdk.text.roundToInt(i64, value);
        if (rounded < 0) return invalidValue(diagnostics, &levels, picked, "leds", "must be 0 or more");
        if (!shape.resizable()) {
            diagnostics.warnAt(picked.node, "{s}: leds applies only to resizable zones; zone {s}.{s} has a fixed size of {d}", .{ keyPath(arena, &levels, picked.level, "leds"), device_key, zone_name, shape.led_count });
        } else {
            var requested: u32 = @intCast(@min(rounded, std.math.maxInt(u32)));
            if (requested > shape.max_leds) {
                diagnostics.warnAt(picked.node, "{s}: {d} is more than zone {s}.{s} supports; using {d}", .{ keyPath(arena, &levels, picked.level, "leds"), requested, device_key, zone_name, shape.max_leds });
                requested = shape.max_leds;
            }
            spec.leds = requested;
            led_count = requested;
        }
    }
    if (led_colors_pick) |picked| {
        const parsed = (try parseLedColors(arena, diagnostics, &levels, picked)) orelse return .invalid;
        if (spec.effect != .static) {
            diagnostics.warnAt(picked.node, "{s}: led_colors only applies to the static effect; ignored for {s} on {s}.{s}", .{ keyPath(arena, &levels, picked.level, "led_colors"), @tagName(spec.effect), device_key, zone_name });
        } else {
            if (parsed.len > led_count) {
                diagnostics.warnAt(picked.node, "{s}: led_colors has {d} entries but zone {s}.{s} has {d} LEDs; the extra entries are ignored", .{ keyPath(arena, &levels, picked.level, "led_colors"), parsed.len, device_key, zone_name, led_count });
            }
            spec.led_colors = parsed;
        }
    }
    if (spec.brightness == 0) spec.effect = .off;
    if (shape.resizable() and led_count == 0) {
        diagnostics.warn("zone {s}.{s} has 0 LEDs; set \"leds\" in lighting.{s}.{s} to the number of LEDs connected", .{ device_key, zone_name, device_key, zone_name });
    }
    return .{ .spec = spec };
}

fn parseEffect(name: []const u8) ?abi.Effect {
    for (effect_names, 0..) |effect_name, index| {
        if (std.mem.eql(u8, name, effect_name)) return @enumFromInt(index);
    }
    return null;
}

fn keyPath(arena: std.mem.Allocator, levels: *const Levels, level: usize, key: []const u8) []const u8 {
    return formatting.allocPrint(arena, "lighting.{s}.{s}.{s}", .{ levels.deviceLabel(level), levels.zoneLabel(level), key }) catch key;
}

fn invalidValue(diagnostics: *Diagnostics, levels: *const Levels, picked: Picked, key: []const u8, problem: []const u8) Resolution {
    diagnostics.failAt(picked.node, "{s}: {s}; zone {s}.{s} left unchanged", .{ keyPath(diagnostics.arena, levels, picked.level, key), problem, levels.device_key, levels.zone_name });
    return .invalid;
}

fn percent(diagnostics: *Diagnostics, levels: *const Levels, picked: Picked, key: []const u8) ?u8 {
    const value = picked.node.number() orelse {
        _ = invalidValue(diagnostics, levels, picked, key, "must be a number from 0 to 100");
        return null;
    };
    const rounded = sdk.text.roundToInt(i64, value);
    if (rounded < 0 or rounded > 100) {
        const clamped = std.math.clamp(rounded, 0, 100);
        diagnostics.warnAt(picked.node, "{s} = {d} is outside 0..100; using {d}", .{ keyPath(diagnostics.arena, levels, picked.level, key), rounded, clamped });
        return @intCast(clamped);
    }
    return @intCast(rounded);
}

fn parseColorList(arena: std.mem.Allocator, diagnostics: *Diagnostics, levels: *const Levels, picked: Picked) error{OutOfMemory}!?[]const Rgb {
    const key: []const u8 = if (picked.is_list) "colors" else "color";
    if (!picked.is_list) {
        const text = picked.node.string() orelse {
            _ = invalidValue(diagnostics, levels, picked, key, "must be a color string like \"#FF8800\"");
            return null;
        };
        const parsed = sdk.color.parseHex(text) orelse {
            _ = invalidValue(diagnostics, levels, picked, key, "must be a color string like \"#FF8800\"");
            return null;
        };
        const single = try arena.alloc(Rgb, 1);
        single[0] = parsed;
        return single;
    }
    const items = picked.node.arrayItems() orelse {
        _ = invalidValue(diagnostics, levels, picked, key, "must be an array of 1 to 16 color strings");
        return null;
    };
    if (items.len == 0 or items.len > max_colors) {
        _ = invalidValue(diagnostics, levels, picked, key, "must contain 1 to 16 colors");
        return null;
    }
    return parseColorItems(arena, diagnostics, levels, picked, key, items);
}

fn parseLedColors(arena: std.mem.Allocator, diagnostics: *Diagnostics, levels: *const Levels, picked: Picked) error{OutOfMemory}!?[]const Rgb {
    const items = picked.node.arrayItems() orelse {
        _ = invalidValue(diagnostics, levels, picked, "led_colors", "must be an array of 1 to 4096 color strings");
        return null;
    };
    if (items.len == 0 or items.len > max_led_colors) {
        _ = invalidValue(diagnostics, levels, picked, "led_colors", "must contain 1 to 4096 colors");
        return null;
    }
    return parseColorItems(arena, diagnostics, levels, picked, "led_colors", items);
}

fn parseColorItems(arena: std.mem.Allocator, diagnostics: *Diagnostics, levels: *const Levels, picked: Picked, key: []const u8, items: []const *const json.Node) error{OutOfMemory}!?[]const Rgb {
    const colors = try arena.alloc(Rgb, items.len);
    for (items, 0..) |item, index| {
        const text = item.string() orelse "";
        colors[index] = sdk.color.parseHex(text) orelse {
            diagnostics.failAt(item, "{s}[{d}]: must be a color string like \"#FF8800\"; zone {s}.{s} left unchanged", .{ keyPath(arena, levels, picked.level, key), index, levels.device_key, levels.zone_name });
            return null;
        };
    }
    return colors;
}

pub const EngineChoice = enum { untouched, hardware, host };

const Fallback = enum { none, host_instead_of_hardware, hardware_instead_of_host, no_engine, off_unsupported };

const Selection = struct {
    choice: EngineChoice,
    fallback: Fallback = .none,
    reverse_ignored: bool = false,
};

pub fn selectEngine(spec: *const Spec, shape: ZoneShape) Selection {
    if (spec.effect == .off) {
        if (shape.supports(.off)) return .{ .choice = .hardware };
        if (shape.hostFrames()) return .{ .choice = .host };
        return .{ .choice = .untouched, .fallback = .off_unsupported };
    }
    const spatial = spec.isSpatial();
    const reverse_ignored = spec.reverse and !spatial;
    const colors_fit = spec.effect == .rainbow or spec.colors.len <= shape.hw_max_colors;
    const hardware_possible = shape.supports(spec.effect) and colors_fit and spec.led_colors.len == 0 and !(spec.reverse and spatial);
    const host_possible = shape.hostFrames();
    var selection: Selection = switch (spec.engine) {
        .auto => if (hardware_possible) .{ .choice = .hardware } else if (host_possible) .{ .choice = .host } else .{ .choice = .untouched, .fallback = .no_engine },
        .hardware => if (hardware_possible) .{ .choice = .hardware } else if (host_possible) .{ .choice = .host, .fallback = .host_instead_of_hardware } else .{ .choice = .untouched, .fallback = .no_engine },
        .host => if (host_possible) .{ .choice = .host } else if (hardware_possible) .{ .choice = .hardware, .fallback = .hardware_instead_of_host } else .{ .choice = .untouched, .fallback = .no_engine },
    };
    selection.reverse_ignored = reverse_ignored;
    return selection;
}

pub const DeviceShape = struct {
    key: []const u8,
    zone_names: []const []const u8,
};

pub fn validateTree(arena: std.mem.Allocator, lighting: ?*const json.Node, devices: []const DeviceShape, diagnostics: *Diagnostics) error{OutOfMemory}!void {
    const root = lighting orelse return;
    const device_members = root.objectMembers() orelse return;
    var device_keys: std.ArrayList([]const u8) = .empty;
    var all_zones: std.ArrayList([]const u8) = .empty;
    for (devices) |device| {
        try device_keys.append(arena, device.key);
        for (device.zone_names) |zone| try all_zones.append(arena, zone);
    }
    for (device_members) |device_member| {
        if (diagnostics.isFull()) return;
        const device = findDevice(devices, device_member.key);
        if (!std.mem.eql(u8, device_member.key, wildcard) and device == null) {
            if (suggest.closest(device_member.key, device_keys.items)) |suggestion| {
                diagnostics.warnAt(device_member.value, "lighting.{s} matches no connected device; did you mean \"{s}\"?", .{ device_member.key, suggestion });
            } else {
                diagnostics.warnAt(device_member.value, "lighting.{s} matches no connected device", .{device_member.key});
            }
        }
        const zone_members = device_member.value.objectMembers() orelse {
            diagnostics.failAt(device_member.value, "lighting.{s} must be an object of zones", .{device_member.key});
            continue;
        };
        for (zone_members) |zone_member| {
            if (diagnostics.isFull()) return;
            if (!std.mem.eql(u8, zone_member.key, wildcard)) {
                const candidates: []const []const u8 = if (device) |found| found.zone_names else all_zones.items;
                if (!contains(candidates, zone_member.key) and (device != null or std.mem.eql(u8, device_member.key, wildcard))) {
                    const owner: []const u8 = if (device != null) device_member.key else "any connected device";
                    if (suggest.closest(zone_member.key, candidates)) |suggestion| {
                        diagnostics.warnAt(zone_member.value, "lighting.{s}.{s} matches no zone of {s}; did you mean \"{s}\"?", .{ device_member.key, zone_member.key, owner, suggestion });
                    } else {
                        diagnostics.warnAt(zone_member.value, "lighting.{s}.{s} matches no zone of {s}", .{ device_member.key, zone_member.key, owner });
                    }
                }
            }
            const spec_members = zone_member.value.objectMembers() orelse {
                diagnostics.failAt(zone_member.value, "lighting.{s}.{s} must be an object with effect settings", .{ device_member.key, zone_member.key });
                continue;
            };
            for (spec_members) |spec_member| {
                if (contains(&spec_keys, spec_member.key)) continue;
                if (suggest.closest(spec_member.key, &spec_keys)) |suggestion| {
                    diagnostics.warnAt(spec_member.value, "unknown key \"lighting.{s}.{s}.{s}\"; did you mean \"{s}\"?", .{ device_member.key, zone_member.key, spec_member.key, suggestion });
                } else {
                    diagnostics.warnAt(spec_member.value, "unknown key \"lighting.{s}.{s}.{s}\"", .{ device_member.key, zone_member.key, spec_member.key });
                }
            }
        }
    }
}

fn findDevice(devices: []const DeviceShape, key: []const u8) ?*const DeviceShape {
    for (devices) |*device| {
        if (std.mem.eql(u8, device.key, key)) return device;
    }
    return null;
}

fn contains(list: []const []const u8, value: []const u8) bool {
    for (list) |item| {
        if (std.mem.eql(u8, item, value)) return true;
    }
    return false;
}

const testing = std.testing;

const TestContext = struct {
    arena_state: std.heap.ArenaAllocator,
    diagnostics: Diagnostics,

    fn init() TestContext {
        return .{ .arena_state = std.heap.ArenaAllocator.init(testing.allocator), .diagnostics = undefined };
    }

    fn deinit(self: *TestContext) void {
        self.arena_state.deinit();
    }

    fn lighting(self: *TestContext, source: []const u8) !*const json.Node {
        self.diagnostics = Diagnostics.init(self.arena_state.allocator());
        var warnings: std.ArrayList(json.Issue) = .empty;
        const root = switch (try json.parse(self.arena_state.allocator(), source, &warnings)) {
            .document => |document| document,
            .failure => return error.TestUnexpectedResult,
        };
        return root.get("lighting").?;
    }

    fn resolveZone(self: *TestContext, lighting_node: *const json.Node, device: []const u8, zone: []const u8, shape: ZoneShape) !Resolution {
        return resolve(self.arena_state.allocator(), lighting_node, device, zone, shape, &self.diagnostics);
    }
};

const strip_shape = ZoneShape{ .flags = abi.zone_host_frames | abi.zone_resizable, .led_count = 16, .max_leds = 256, .hw_effects = abi.effectBit(.off) | abi.effectBit(.static) | abi.effectBit(.breathing), .hw_max_colors = 1 };

test "each key resolves from the most specific level that sets it" {
    var context = TestContext.init();
    defer context.deinit();
    const lighting = try context.lighting(
        \\{"lighting": {
        \\  "*": {"*": {"effect": "static", "color": "#010101", "speed": 10, "brightness": 20},
        \\        "argb1": {"speed": 30}},
        \\  "motherboard": {"*": {"brightness": 40, "colors": ["#020202", "#030303"]},
        \\                  "argb1": {"effect": "breathing", "color": "#040404"}}}}
    );
    const resolved = (try context.resolveZone(lighting, "motherboard", "argb1", strip_shape)).spec;
    try testing.expectEqual(abi.Effect.breathing, resolved.effect);
    try testing.expectEqual(@as(usize, 1), resolved.colors.len);
    try testing.expectEqual(@as(u8, 4), resolved.colors[0].r);
    try testing.expectEqual(@as(u8, 30), resolved.speed);
    try testing.expectEqual(@as(u8, 40), resolved.brightness);
    const other = (try context.resolveZone(lighting, "motherboard", "argb2", strip_shape)).spec;
    try testing.expectEqual(abi.Effect.static, other.effect);
    try testing.expectEqual(@as(usize, 2), other.colors.len);
    try testing.expectEqual(@as(u8, 10), other.speed);
    const elsewhere = (try context.resolveZone(lighting, "gpu", "logo", strip_shape)).spec;
    try testing.expectEqual(@as(u8, 1), elsewhere.colors[0].r);
    try testing.expectEqual(@as(u8, 20), elsewhere.brightness);
}

test "colors wins over color within one level" {
    var context = TestContext.init();
    defer context.deinit();
    const lighting = try context.lighting("{\"lighting\": {\"*\": {\"*\": {\"effect\": \"static\", \"color\": \"#111111\", \"colors\": [\"#222222\"]}}}}");
    const resolved = (try context.resolveZone(lighting, "d", "z", strip_shape)).spec;
    try testing.expectEqual(@as(u8, 0x22), resolved.colors[0].r);
}

test "none or a missing effect leaves the zone untouched and led_colors alone implies static" {
    var context = TestContext.init();
    defer context.deinit();
    const none = try context.lighting("{\"lighting\": {\"d\": {\"z\": {\"effect\": \"none\", \"brightness\": 0}}}}");
    try testing.expect(try context.resolveZone(none, "d", "z", strip_shape) == .untouched);
    const missing = try context.lighting("{\"lighting\": {\"d\": {\"z\": {\"speed\": 5}}}}");
    try testing.expect(try context.resolveZone(missing, "d", "z", strip_shape) == .untouched);
    const per_led = try context.lighting("{\"lighting\": {\"d\": {\"z\": {\"led_colors\": [\"#FF0000\", \"#00FF00\"]}}}}");
    const resolved = (try context.resolveZone(per_led, "d", "z", strip_shape)).spec;
    try testing.expectEqual(abi.Effect.static, resolved.effect);
    try testing.expectEqual(@as(usize, 2), resolved.led_colors.len);
}

test "brightness zero turns a resolved effect off and out of range values are clamped with a warning" {
    var context = TestContext.init();
    defer context.deinit();
    const dark = try context.lighting("{\"lighting\": {\"d\": {\"z\": {\"effect\": \"rainbow\", \"brightness\": 0}}}}");
    try testing.expectEqual(abi.Effect.off, (try context.resolveZone(dark, "d", "z", strip_shape)).spec.effect);
    const fast = try context.lighting("{\"lighting\": {\"d\": {\"z\": {\"effect\": \"cycle\", \"speed\": 250}}}}");
    try testing.expectEqual(@as(u8, 100), (try context.resolveZone(fast, "d", "z", strip_shape)).spec.speed);
    try testing.expect(context.diagnostics.contains("lighting.d.z.speed = 250 is outside 0..100; using 100"));
}

test "invalid values make the zone a config error with the JSON path" {
    var context = TestContext.init();
    defer context.deinit();
    const bad_effect = try context.lighting("{\"lighting\": {\"d\": {\"z\": {\"effect\": \"sparkle\"}}}}");
    try testing.expect(try context.resolveZone(bad_effect, "d", "z", strip_shape) == .invalid);
    try testing.expect(context.diagnostics.contains("lighting.d.z.effect: must be one of"));
    const bad_color = try context.lighting("{\"lighting\": {\"*\": {\"*\": {\"effect\": \"static\", \"colors\": [\"#FF0000\", \"red\"]}}}}");
    try testing.expect(try context.resolveZone(bad_color, "d", "z", strip_shape) == .invalid);
    try testing.expect(context.diagnostics.contains("lighting.*.*.colors[1]: must be a color string"));
    const too_many = try context.lighting("{\"lighting\": {\"d\": {\"z\": {\"effect\": \"gradient\", \"colors\": [" ++ ("\"#000000\"," ** 17) ++ "]}}}}");
    try testing.expect(try context.resolveZone(too_many, "d", "z", strip_shape) == .invalid);
    const empty = try context.lighting("{\"lighting\": {\"d\": {\"z\": {\"effect\": \"static\", \"colors\": []}}}}");
    try testing.expect(try context.resolveZone(empty, "d", "z", strip_shape) == .invalid);
    const bad_engine = try context.lighting("{\"lighting\": {\"d\": {\"z\": {\"effect\": \"static\", \"engine\": \"gpu\"}}}}");
    try testing.expect(try context.resolveZone(bad_engine, "d", "z", strip_shape) == .invalid);
}

test "leds is clamped to the zone maximum, ignored on fixed zones and a resizable zone without LEDs warns" {
    var context = TestContext.init();
    defer context.deinit();
    const big = try context.lighting("{\"lighting\": {\"d\": {\"z\": {\"effect\": \"static\", \"leds\": 999}}}}");
    try testing.expectEqual(@as(?u32, 256), (try context.resolveZone(big, "d", "z", strip_shape)).spec.leds);
    const fixed_shape = ZoneShape{ .flags = abi.zone_host_frames, .led_count = 1, .max_leds = 1 };
    const fixed = try context.lighting("{\"lighting\": {\"d\": {\"z\": {\"effect\": \"static\", \"leds\": 4}}}}");
    try testing.expectEqual(@as(?u32, null), (try context.resolveZone(fixed, "d", "z", fixed_shape)).spec.leds);
    try testing.expect(context.diagnostics.contains("leds applies only to resizable zones"));
    var empty_shape = strip_shape;
    empty_shape.led_count = 0;
    const unset = try context.lighting("{\"lighting\": {\"d\": {\"z\": {\"effect\": \"static\"}}}}");
    _ = try context.resolveZone(unset, "d", "z", empty_shape);
    try testing.expect(context.diagnostics.contains("zone d.z has 0 LEDs; set \"leds\""));
}

test "led_colors is ignored with a warning for non-static effects and extra entries are reported" {
    var context = TestContext.init();
    defer context.deinit();
    const breathing = try context.lighting("{\"lighting\": {\"d\": {\"z\": {\"effect\": \"breathing\", \"led_colors\": [\"#FF0000\"]}}}}");
    try testing.expectEqual(@as(usize, 0), (try context.resolveZone(breathing, "d", "z", strip_shape)).spec.led_colors.len);
    try testing.expect(context.diagnostics.contains("led_colors only applies to the static effect"));
    var small = strip_shape;
    small.led_count = 1;
    small.flags = abi.zone_host_frames;
    const extra = try context.lighting("{\"lighting\": {\"d\": {\"z\": {\"led_colors\": [\"#FF0000\", \"#00FF00\"]}}}}");
    _ = try context.resolveZone(extra, "d", "z", small);
    try testing.expect(context.diagnostics.contains("led_colors has 2 entries but zone d.z has 1 LEDs"));
}

test "engine selection follows the auto, hardware and host preference tables" {
    const hardware_capable = strip_shape;
    var breathing = Spec{ .effect = .breathing };
    try testing.expectEqual(EngineChoice.hardware, selectEngine(&breathing, hardware_capable).choice);
    breathing.engine = .host;
    try testing.expectEqual(EngineChoice.host, selectEngine(&breathing, hardware_capable).choice);
    var rainbow = Spec{ .effect = .rainbow, .engine = .hardware };
    const rainbow_selection = selectEngine(&rainbow, hardware_capable);
    try testing.expectEqual(EngineChoice.host, rainbow_selection.choice);
    try testing.expectEqual(Fallback.host_instead_of_hardware, rainbow_selection.fallback);
    const two_colors = [_]Rgb{ Rgb.black, Rgb.black };
    const multi = Spec{ .effect = .static, .colors = &two_colors };
    try testing.expectEqual(EngineChoice.host, selectEngine(&multi, hardware_capable).choice);
    const hardware_only = ZoneShape{ .hw_effects = abi.effectBit(.static), .hw_max_colors = 1, .led_count = 1, .max_leds = 1 };
    var host_wanted = Spec{ .effect = .static, .engine = .host };
    const host_selection = selectEngine(&host_wanted, hardware_only);
    try testing.expectEqual(EngineChoice.hardware, host_selection.choice);
    try testing.expectEqual(Fallback.hardware_instead_of_host, host_selection.fallback);
    const flash = Spec{ .effect = .flash };
    try testing.expectEqual(Fallback.no_engine, selectEngine(&flash, hardware_only).fallback);
}

test "off prefers hardware off, then a black host frame, else leaves the zone untouched" {
    const off = Spec{ .effect = .off };
    try testing.expectEqual(EngineChoice.hardware, selectEngine(&off, strip_shape).choice);
    const host_only = ZoneShape{ .flags = abi.zone_host_frames, .led_count = 10, .max_leds = 10 };
    try testing.expectEqual(EngineChoice.host, selectEngine(&off, host_only).choice);
    const no_off = ZoneShape{ .hw_effects = abi.effectBit(.static), .hw_max_colors = 1 };
    const selection = selectEngine(&off, no_off);
    try testing.expectEqual(EngineChoice.untouched, selection.choice);
    try testing.expectEqual(Fallback.off_unsupported, selection.fallback);
}

test "reverse forces spatial effects to the host and is ignored for non-spatial effects" {
    const shape = ZoneShape{ .flags = abi.zone_host_frames, .led_count = 8, .max_leds = 8, .hw_effects = abi.effectBit(.rainbow) | abi.effectBit(.breathing), .hw_max_colors = 1 };
    const reversed_rainbow = Spec{ .effect = .rainbow, .reverse = true };
    try testing.expectEqual(EngineChoice.host, selectEngine(&reversed_rainbow, shape).choice);
    const reversed_breathing = Spec{ .effect = .breathing, .reverse = true };
    const selection = selectEngine(&reversed_breathing, shape);
    try testing.expectEqual(EngineChoice.hardware, selection.choice);
    try testing.expect(selection.reverse_ignored);
}

test "validateTree reports unmatched devices, zones and unknown spec keys with suggestions" {
    var context = TestContext.init();
    defer context.deinit();
    const lighting = try context.lighting(
        \\{"lighting": {"motherbord": {"*": {}}, "motherboard": {"argb4": {}, "argb1": {"efect": "static"}},
        \\              "*": {"logo": {}}}}
    );
    const zones = [_][]const u8{ "argb1", "argb2", "argb3" };
    const devices = [_]DeviceShape{.{ .key = "motherboard", .zone_names = &zones }};
    try validateTree(context.arena_state.allocator(), lighting, &devices, &context.diagnostics);
    try testing.expect(context.diagnostics.contains("lighting.motherbord matches no connected device; did you mean \"motherboard\"?"));
    try testing.expect(context.diagnostics.contains("lighting.motherboard.argb4 matches no zone of motherboard; did you mean \"argb1\"?"));
    try testing.expect(context.diagnostics.contains("unknown key \"lighting.motherboard.argb1.efect\"; did you mean \"effect\"?"));
    try testing.expect(context.diagnostics.contains("lighting.*.logo matches no zone of any connected device"));
}

test "engine selection covers every preference against every capability combination" {
    const Row = struct { engine: Engine, hardware: bool, host: bool, choice: EngineChoice, fallback: Fallback };
    const rows = [_]Row{
        .{ .engine = .auto, .hardware = true, .host = true, .choice = .hardware, .fallback = .none },
        .{ .engine = .auto, .hardware = true, .host = false, .choice = .hardware, .fallback = .none },
        .{ .engine = .auto, .hardware = false, .host = true, .choice = .host, .fallback = .none },
        .{ .engine = .auto, .hardware = false, .host = false, .choice = .untouched, .fallback = .no_engine },
        .{ .engine = .hardware, .hardware = true, .host = true, .choice = .hardware, .fallback = .none },
        .{ .engine = .hardware, .hardware = true, .host = false, .choice = .hardware, .fallback = .none },
        .{ .engine = .hardware, .hardware = false, .host = true, .choice = .host, .fallback = .host_instead_of_hardware },
        .{ .engine = .hardware, .hardware = false, .host = false, .choice = .untouched, .fallback = .no_engine },
        .{ .engine = .host, .hardware = true, .host = true, .choice = .host, .fallback = .none },
        .{ .engine = .host, .hardware = true, .host = false, .choice = .hardware, .fallback = .hardware_instead_of_host },
        .{ .engine = .host, .hardware = false, .host = true, .choice = .host, .fallback = .none },
        .{ .engine = .host, .hardware = false, .host = false, .choice = .untouched, .fallback = .no_engine },
    };
    for (rows) |row| {
        const shape = ZoneShape{
            .flags = if (row.host) abi.zone_host_frames else 0,
            .led_count = 4,
            .max_leds = 4,
            .hw_effects = if (row.hardware) abi.effectBit(.breathing) else 0,
            .hw_max_colors = 1,
        };
        const spec = Spec{ .effect = .breathing, .engine = row.engine };
        const selection = selectEngine(&spec, shape);
        try testing.expectEqual(row.choice, selection.choice);
        try testing.expectEqual(row.fallback, selection.fallback);
    }
}

test "rainbow ignores the hardware color limit while other effects respect it" {
    const shape = ZoneShape{ .flags = 0, .led_count = 4, .max_leds = 4, .hw_effects = abi.effectBit(.rainbow) | abi.effectBit(.static), .hw_max_colors = 0 };
    const rainbow = Spec{ .effect = .rainbow };
    try testing.expectEqual(EngineChoice.hardware, selectEngine(&rainbow, shape).choice);
    const static = Spec{ .effect = .static };
    try testing.expectEqual(EngineChoice.untouched, selectEngine(&static, shape).choice);
}
