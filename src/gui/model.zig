const std = @import("std");
const sdk = @import("sdk");
const json = @import("../config/json.zig");
const layers = @import("../config/layers.zig");
const lighting_config = @import("../config/lighting_config.zig");
const Diagnostics = @import("../config/diagnostics.zig").Diagnostics;
const inventory = @import("../runtime/inventory.zig");
const jsonc_edit = @import("jsonc_edit.zig");

const abi = sdk.abi;
const Rgb = abi.Rgb;

// What rgbctrl-gui shows and changes: one node per configuration level it edits (all devices,
// a device, a zone), the plugins, and the edits that a Save writes to the files.

pub const max_colors = 16;
const wildcard = "*";
const white = Rgb{ .r = 255, .g = 255, .b = 255 };
const spec_keys = [_][]const u8{ "effect", "color", "colors", "speed", "brightness" };
const advanced_keys = [_][]const u8{ "engine", "reverse", "led_colors" };

pub const Choice = enum(u8) {
    inherit,
    untouched,
    off,
    static,
    breathing,
    flash,
    cycle,
    rainbow,
    gradient,

    pub fn effect(self: Choice) ?abi.Effect {
        return switch (self) {
            .inherit, .untouched => null,
            .off => .off,
            .static => .static,
            .breathing => .breathing,
            .flash => .flash,
            .cycle => .cycle,
            .rainbow => .rainbow,
            .gradient => .gradient,
        };
    }

    fn fromEffect(value: abi.Effect) Choice {
        return switch (value) {
            .off => .off,
            .static => .static,
            .breathing => .breathing,
            .flash => .flash,
            .cycle => .cycle,
            .rainbow => .rainbow,
            .gradient => .gradient,
        };
    }

    pub fn usesColors(self: Choice) bool {
        return switch (self) {
            .static, .breathing, .flash, .cycle, .gradient => true,
            else => false,
        };
    }

    pub fn usesSpeed(self: Choice) bool {
        return switch (self) {
            .breathing, .flash, .cycle, .rainbow => true,
            else => false,
        };
    }

    pub fn usesBrightness(self: Choice) bool {
        return self.effect() != null and self != .off;
    }
};

const effect_choices = [_]Choice{ .off, .static, .breathing, .flash, .cycle, .rainbow, .gradient };

pub const Settings = struct {
    choice: Choice = .inherit,
    colors: [max_colors]Rgb = @splat(white),
    color_count: u8 = 1,
    speed: u8 = 50,
    brightness: u8 = 100,

    pub fn activeColors(self: *const Settings) []const Rgb {
        return self.colors[0..self.color_count];
    }

    /// Equal as far as the choice uses the values; what a choice ignores is not written.
    pub fn eql(self: *const Settings, other: *const Settings) bool {
        if (self.choice != other.choice) return false;
        if (self.choice.usesColors()) {
            if (self.color_count != other.color_count) return false;
            for (self.activeColors(), other.activeColors()) |a, b| {
                if (!a.eql(b)) return false;
            }
        }
        if (self.choice.usesSpeed() and self.speed != other.speed) return false;
        if (self.choice.usesBrightness() and self.brightness != other.brightness) return false;
        return true;
    }
};

pub const Level = enum { all, device, zone };

pub const Node = struct {
    level: Level,
    device_key: []const u8,
    zone_name: []const u8,
    label: []const u8,
    parent: ?usize,
    /// The zone as the running rgbctrl reported it; null for levels above zones and for zones
    /// that are only in the configuration.
    zone: ?inventory.Zone = null,
    device_name: []const u8 = "",
    plugin: []const u8 = "",
    detected: bool = true,
    saved: Settings = .{},
    current: Settings = .{},
    /// What rgbctrl shows at this level according to the files, for levels that follow the one
    /// above.
    effective_choice: Choice = .untouched,
    /// engine, reverse or led_colors at this level, which rgbctrl-gui keeps as they are.
    has_advanced_keys: bool = false,
    leds_saved: ?u32 = null,
    leds_current: ?u32 = null,

    pub fn isDirty(self: *const Node) bool {
        return !self.saved.eql(&self.current) or !std.meta.eql(self.leds_saved, self.leds_current);
    }

    pub fn resizable(self: *const Node) bool {
        const zone = self.zone orelse return false;
        return zone.flags & abi.zone_resizable != 0;
    }

    fn shape(self: *const Node) lighting_config.ZoneShape {
        const zone = self.zone orelse return .{ .flags = abi.zone_host_frames };
        return .{ .flags = zone.flags, .led_count = zone.leds, .max_leds = zone.max_leds, .hw_effects = zone.hardware_effects, .hw_max_colors = zone.hardware_max_colors };
    }
};

pub const PluginRow = struct {
    info: inventory.Plugin,
    device_count: usize = 0,
    user_enabled: ?bool = null,
    base_enabled: ?bool = null,
    /// Whether the settings files turn the plugin on (see Model.enabledByFiles); the check box
    /// starts there, while the Status column shows what the running rgbctrl does.
    saved: bool,
    desired: bool,

    pub fn isDirty(self: *const PluginRow) bool {
        return self.desired != self.saved;
    }
};

pub const Sources = struct {
    inventory_text: ?[]const u8 = null,
    user_text: ?[]const u8 = null,
    base_text: ?[]const u8 = null,
};

pub const Model = struct {
    inventory: ?inventory.Inventory = null,
    inventory_unreadable: bool = false,
    account: inventory.Account = .standard,
    /// Why the user file cannot be edited (it does not parse), with its position.
    user_issue: ?json.Issue = null,
    base_issue: ?json.Issue = null,
    user_root: ?*const json.Node = null,
    base_root: ?*const json.Node = null,
    /// The user file as read, for previews of unsaved edits (see preview).
    user_text: ?[]const u8 = null,
    lighting: ?*const json.Node = null,
    nodes: []Node = &.{},
    plugins: []PluginRow = &.{},

    /// Everything is allocated with arena and lives as long as it.
    pub fn load(arena: std.mem.Allocator, sources: Sources) error{OutOfMemory}!Model {
        var model = Model{};
        if (sources.inventory_text) |text| {
            if (inventory.parse(arena, text)) |parsed| {
                model.inventory = parsed;
                model.account = parsed.account;
            } else |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => model.inventory_unreadable = true,
            }
        }
        model.user_root = try parseLayer(arena, sources.user_text, &model.user_issue);
        model.base_root = try parseLayer(arena, sources.base_text, &model.base_issue);
        model.user_text = sources.user_text;
        var diagnostics = Diagnostics.init(arena);
        const merged = try layers.mergeLayers(arena, .{ .label = "base", .root = model.base_root, .trusted = true }, .{ .label = "user", .root = model.user_root, .trusted = true }, false, &diagnostics);
        if (merged.root.get("lighting")) |lighting| {
            if (lighting.kind() == .object) model.lighting = lighting;
        }
        model.nodes = try model.buildNodes(arena);
        for (model.nodes) |*node| model.readNode(arena, node);
        model.plugins = try model.buildPlugins(arena);
        return model;
    }

    pub fn canEdit(self: *const Model) bool {
        return self.user_issue == null;
    }

    pub fn isDirty(self: *const Model) bool {
        for (self.nodes) |*node| {
            if (node.isDirty()) return true;
        }
        for (self.plugins) |*row| {
            if (row.isDirty()) return true;
        }
        return false;
    }

    /// The settings rgbctrl uses at this level, from every layer and level above it.
    pub fn effective(self: *const Model, scratch: std.mem.Allocator, index: usize) lighting_config.Resolution {
        const node = &self.nodes[index];
        var diagnostics = Diagnostics.init(scratch);
        return lighting_config.resolve(scratch, self.lighting, node.device_key, node.zone_name, node.shape(), &diagnostics) catch .invalid;
    }

    /// The choices that make sense for the node: effects the zone can show (by the hardware or
    /// with host frames), and for devices and zones following the level above.
    pub fn choices(self: *const Model, index: usize, buffer: *[9]Choice) []const Choice {
        const node = &self.nodes[index];
        var count: usize = 0;
        buffer[count] = .inherit;
        count += 1;
        if (node.level != .all) {
            buffer[count] = .untouched;
            count += 1;
        }
        for (effect_choices) |choice| {
            if (!zoneCanShow(node, choice)) continue;
            buffer[count] = choice;
            count += 1;
        }
        return buffer[0..count];
    }

    pub fn maxColors(self: *const Model, index: usize, choice: Choice) u8 {
        if (!choice.usesColors()) return 0;
        if (choice == .static) return 1;
        const zone = self.nodes[index].zone orelse return max_colors;
        if (zone.flags & abi.zone_host_frames != 0) return max_colors;
        return @intCast(std.math.clamp(zone.hardware_max_colors, 1, max_colors));
    }

    pub fn minColors(choice: Choice) u8 {
        return if (choice == .gradient) 2 else if (choice.usesColors()) 1 else 0;
    }

    /// Changes the effect of a node; the colors fit the new effect's limits afterwards.
    pub fn setChoice(self: *Model, index: usize, choice: Choice) void {
        const node = &self.nodes[index];
        node.current.choice = choice;
        self.fitColors(index);
    }

    pub fn fitColors(self: *Model, index: usize) void {
        const node = &self.nodes[index];
        const choice = node.current.choice;
        if (!choice.usesColors()) return;
        const upper = self.maxColors(index, choice);
        const lower = minColors(choice);
        while (node.current.color_count < lower and node.current.color_count < max_colors) {
            node.current.colors[node.current.color_count] = companionColor(node.current.colors[node.current.color_count - 1]);
            node.current.color_count += 1;
        }
        if (node.current.color_count > upper) node.current.color_count = upper;
    }

    /// Adds a color after the last one, within the effect's limit.
    pub fn addColor(self: *Model, index: usize) void {
        const node = &self.nodes[index];
        if (node.current.color_count >= self.maxColors(index, node.current.choice)) return;
        node.current.colors[node.current.color_count] = companionColor(node.current.colors[node.current.color_count - 1]);
        node.current.color_count += 1;
    }

    pub fn removeColor(self: *Model, index: usize) void {
        const node = &self.nodes[index];
        if (node.current.color_count <= @max(minColors(node.current.choice), 1)) return;
        node.current.color_count -= 1;
    }

    pub fn setPluginDesired(self: *Model, row_index: usize, desired: bool) void {
        self.plugins[row_index].desired = desired;
    }

    /// Whether turning the plugin on needs plugins.<name>.enabled = true in the admin-only base
    /// file: rgbctrl runs elevated (it then ignores enabling in the user file) and neither the
    /// default nor the base file turns the plugin on.
    pub fn enableNeedsBase(self: *const Model, row: *const PluginRow) bool {
        if (!row.desired or row.saved or self.account == .standard) return false;
        return !(row.base_enabled orelse !row.info.opt_in);
    }

    /// Whether rgbctrl takes privileged keys, such as enabled = true, from the base file: always
    /// when it runs as a standard user, else only when the base file is admin-only, which the
    /// inventory reports.
    fn baseIsPrivileged(self: *const Model) bool {
        if (self.account == .standard) return true;
        const found = self.inventory orelse return true;
        return found.base.privileged;
    }

    /// Follows a change of how rgbctrl runs, such as from a standard account to the SYSTEM task,
    /// while edits are unsaved: what the files turn on is worked out again, the choices stay.
    pub fn setAccount(self: *Model, account: inventory.Account, base_privileged: bool) void {
        self.account = account;
        if (self.inventory) |*found| found.base.privileged = base_privileged;
        for (self.plugins) |*row| {
            row.base_enabled = if (self.baseIsPrivileged()) enabledIn(self.base_root, row.info.name) else null;
            row.saved = self.enabledByFiles(row.user_enabled, row.base_enabled, row.info.opt_in);
        }
    }

    /// Whether the settings files turn a plugin on, read the way rgbctrl reads them: running
    /// elevated or as SYSTEM, the user file can only turn a plugin off.
    pub fn enabledByFiles(self: *const Model, user_enabled: ?bool, base_enabled: ?bool, opt_in: bool) bool {
        const default = !opt_in;
        if (self.account == .standard) return user_enabled orelse base_enabled orelse default;
        if (user_enabled == false) return false;
        return base_enabled orelse default;
    }

    pub fn needsElevation(self: *const Model) bool {
        for (self.plugins) |*row| {
            if (self.enableNeedsBase(row)) return true;
        }
        return false;
    }

    /// Writes every change to the user file, as edits that keep the rest of its text.
    pub fn applyUserEdits(self: *const Model, editor: *jsonc_edit.Editor) jsonc_edit.Error!void {
        for (self.nodes) |*node| {
            if (!node.saved.eql(&node.current)) try applyLighting(editor, node);
            if (!std.meta.eql(node.leds_saved, node.leds_current)) {
                const path = [_][]const u8{ "lighting", node.device_key, node.zone_name, "leds" };
                if (node.leds_current) |count| {
                    var buffer: [16]u8 = undefined;
                    try editor.set(&path, decimal(&buffer, count));
                } else {
                    try editor.remove(&path);
                    try pruneLevel(editor, node);
                }
            }
        }
        for (self.plugins) |*row| {
            if (!row.isDirty()) continue;
            const path = [_][]const u8{ "plugins", row.info.name, "enabled" };
            if (!row.desired) {
                try editor.set(&path, "false");
                continue;
            }
            if (row.user_enabled == false) {
                try editor.remove(&path);
                try editor.removeIfEmpty(path[0..2]);
                try editor.removeIfEmpty(path[0..1]);
            }
            const base_value = row.base_enabled orelse !row.info.opt_in;
            if (self.account == .standard and !base_value) try editor.set(&path, "true");
        }
    }

    /// The plugins whose enabled = true has to go into the base file (see enableNeedsBase).
    pub fn pluginsToEnableInBase(self: *const Model, buffer: [][]const u8) []const []const u8 {
        var count: usize = 0;
        for (self.plugins) |*row| {
            if (!self.enableNeedsBase(row) or count == buffer.len) continue;
            buffer[count] = row.info.name;
            count += 1;
        }
        return buffer[0..count];
    }

    fn buildNodes(self: *const Model, arena: std.mem.Allocator) error{OutOfMemory}![]Node {
        var nodes: std.ArrayList(Node) = .empty;
        try nodes.append(arena, .{ .level = .all, .device_key = wildcard, .zone_name = wildcard, .label = "All devices", .parent = null });
        if (self.inventory) |found| {
            for (found.devices) |device| {
                const device_index = nodes.items.len;
                try nodes.append(arena, .{ .level = .device, .device_key = device.key, .zone_name = wildcard, .label = if (device.name.len > 0) device.name else device.key, .parent = 0, .device_name = device.name, .plugin = device.plugin });
                for (device.zones) |zone| {
                    try nodes.append(arena, .{ .level = .zone, .device_key = device.key, .zone_name = zone.name, .label = zoneLabel(zone.name), .parent = device_index, .zone = zone, .device_name = device.name, .plugin = device.plugin });
                }
            }
        }
        const user_lighting = childObject(self.user_root, "lighting");
        for (objectMembers(user_lighting)) |device_member| {
            if (std.mem.eql(u8, device_member.key, wildcard) or device_member.value.kind() != .object) continue;
            if (findDevice(nodes.items, device_member.key) != null) continue;
            const device_index = nodes.items.len;
            const label = try std.mem.concat(arena, u8, &.{ device_member.key, " (not detected)" });
            try nodes.append(arena, .{ .level = .device, .device_key = device_member.key, .zone_name = wildcard, .label = label, .parent = 0, .detected = false });
            for (objectMembers(device_member.value)) |zone_member| {
                if (std.mem.eql(u8, zone_member.key, wildcard) or zone_member.value.kind() != .object) continue;
                try nodes.append(arena, .{ .level = .zone, .device_key = device_member.key, .zone_name = zone_member.key, .label = zoneLabel(zone_member.key), .parent = device_index, .detected = false });
            }
        }
        return nodes.items;
    }

    /// Whether the files set lighting.*.<zone> for the zone's name, a level for the zones of that
    /// name on every device that the tree does not show; resolution counts it all the same.
    pub fn zoneNameLevel(self: *const Model, index: usize) bool {
        const node = &self.nodes[index];
        if (node.level != .zone) return false;
        const level = childObject(childObject(self.lighting, "*"), node.zone_name);
        return hasAnyKey(level, &spec_keys) or hasAnyKey(level, &advanced_keys);
    }

    /// What rgbctrl will show at the node once the edits are saved: the edits applied to a copy
    /// of the user file, merged with the base file and resolved the way rgbctrl resolves them, so
    /// that every level counts, lighting.*.<zone> included. The choice is the effect shown. Null
    /// when the edits cannot be applied.
    pub fn preview(self: *const Model, scratch: std.mem.Allocator, index: usize) ?Settings {
        const node = &self.nodes[index];
        var lighting = self.lighting;
        if (self.isDirty()) {
            var editor = jsonc_edit.Editor.init(scratch, self.user_text orelse "") catch return null;
            self.applyUserEdits(&editor) catch return null;
            var issue: ?json.Issue = null;
            const user_root = parseLayer(scratch, editor.text(), &issue) catch return null;
            if (issue != null) return null;
            var merge_diagnostics = Diagnostics.init(scratch);
            const merged = layers.mergeLayers(scratch, .{ .label = "base", .root = self.base_root, .trusted = true }, .{ .label = "user", .root = user_root, .trusted = true }, false, &merge_diagnostics) catch return null;
            lighting = null;
            if (merged.root.get("lighting")) |object| {
                if (object.kind() == .object) lighting = object;
            }
        }
        var diagnostics = Diagnostics.init(scratch);
        const resolution = lighting_config.resolve(scratch, lighting, node.device_key, node.zone_name, node.shape(), &diagnostics) catch return null;
        return settingsFrom(resolution);
    }

    fn readNode(self: *const Model, arena: std.mem.Allocator, node: *Node) void {
        const level = childObject(childObject(childObject(self.user_root, "lighting"), node.device_key), node.zone_name);
        const resolution = blk: {
            var diagnostics = Diagnostics.init(arena);
            break :blk lighting_config.resolve(arena, self.lighting, node.device_key, node.zone_name, node.shape(), &diagnostics) catch .invalid;
        };
        var settings = settingsFrom(resolution);
        const effective_choice = settings.choice;
        settings.choice = .inherit;
        if (hasAnyKey(level, &spec_keys)) {
            settings.choice = effective_choice;
            if (level.?.get("effect")) |effect_node| {
                const name = effect_node.string() orelse "";
                if (std.mem.eql(u8, name, "none")) settings.choice = .untouched;
            }
        }
        node.has_advanced_keys = hasAnyKey(level, &advanced_keys);
        node.effective_choice = effective_choice;
        node.saved = settings;
        node.current = settings;
        if (node.level == .zone) {
            if (level) |object| {
                if (object.get("leds")) |leds| {
                    if (leds.number()) |value| {
                        if (value >= 0) node.leds_saved = @intFromFloat(@min(value, @as(f64, std.math.maxInt(u32))));
                    }
                }
            }
            node.leds_current = node.leds_saved;
        }
    }

    fn buildPlugins(self: *const Model, arena: std.mem.Allocator) error{OutOfMemory}![]PluginRow {
        const found = self.inventory orelse return &.{};
        const rows = try arena.alloc(PluginRow, found.plugins.len);
        for (found.plugins, rows) |plugin, *row| {
            var devices: usize = 0;
            for (found.devices) |device| {
                if (std.mem.eql(u8, device.plugin, plugin.name)) devices += 1;
            }
            const user_enabled = enabledIn(self.user_root, plugin.name);
            const base_enabled = if (self.baseIsPrivileged()) enabledIn(self.base_root, plugin.name) else null;
            const saved = self.enabledByFiles(user_enabled, base_enabled, plugin.opt_in);
            row.* = .{
                .info = plugin,
                .device_count = devices,
                .user_enabled = user_enabled,
                .base_enabled = base_enabled,
                .saved = saved,
                .desired = saved,
            };
        }
        return rows;
    }
};

/// The settings a resolution amounts to, with the effect it shows as the choice.
fn settingsFrom(resolution: lighting_config.Resolution) Settings {
    var settings = Settings{ .choice = .untouched };
    switch (resolution) {
        .spec => |spec| {
            settings.choice = Choice.fromEffect(spec.effect);
            const count = @min(spec.colors.len, max_colors);
            @memcpy(settings.colors[0..count], spec.colors[0..count]);
            settings.color_count = @intCast(@max(count, 1));
            settings.speed = spec.speed;
            settings.brightness = spec.brightness;
        },
        .untouched, .invalid => {},
    }
    return settings;
}

fn zoneCanShow(node: *const Node, choice: Choice) bool {
    const effect = choice.effect() orelse return true;
    const zone = node.zone orelse return true;
    if (zone.flags & abi.zone_host_frames != 0) return true;
    return zone.hardware_effects & abi.effectBit(effect) != 0;
}

fn findDevice(nodes: []const Node, key: []const u8) ?usize {
    for (nodes, 0..) |node, index| {
        if (node.level == .device and std.mem.eql(u8, node.device_key, key)) return index;
    }
    return null;
}

fn parseLayer(arena: std.mem.Allocator, text: ?[]const u8, issue: *?json.Issue) error{OutOfMemory}!?*const json.Node {
    const source = text orelse return null;
    var warnings: std.ArrayList(json.Issue) = .empty;
    return switch (try json.parse(arena, source, &warnings)) {
        .document => |document| document,
        .failure => |failure| blk: {
            issue.* = failure;
            break :blk null;
        },
    };
}

fn childObject(parent: ?*const json.Node, key: []const u8) ?*const json.Node {
    const node = (parent orelse return null).get(key) orelse return null;
    return if (node.kind() == .object) node else null;
}

fn objectMembers(node: ?*const json.Node) []const json.Member {
    const object = node orelse return &.{};
    return object.objectMembers() orelse &.{};
}

fn hasAnyKey(object: ?*const json.Node, keys: []const []const u8) bool {
    const node = object orelse return false;
    for (keys) |key| {
        if (node.get(key) != null) return true;
    }
    return false;
}

fn enabledIn(root: ?*const json.Node, plugin: []const u8) ?bool {
    const settings = childObject(childObject(root, "plugins"), plugin) orelse return null;
    const enabled = settings.get("enabled") orelse return null;
    return enabled.boolean();
}

fn decimal(buffer: []u8, value: u32) []const u8 {
    return std.fmt.bufPrint(buffer, "{d}", .{value}) catch unreachable;
}

/// "#RRGGBB" with capital hex digits, as in the example configuration.
pub fn hexColor(buffer: *[7]u8, color: Rgb) []const u8 {
    const digits = "0123456789ABCDEF";
    buffer.* = .{ '#', digits[color.r >> 4], digits[color.r & 0xF], digits[color.g >> 4], digits[color.g & 0xF], digits[color.b >> 4], digits[color.b & 0xF] };
    return buffer;
}

// A second color for effects that need two: the first one's hue turned a third of the wheel,
// or blue after white or black.
fn companionColor(color: Rgb) Rgb {
    if (color.r == color.g and color.g == color.b) return .{ .r = 0, .g = 0x60, .b = 0xFF };
    return .{ .r = color.b, .g = color.r, .b = color.g };
}

fn quoted(arena: std.mem.Allocator, text: []const u8) error{OutOfMemory}![]const u8 {
    var bytes: std.ArrayList(u8) = .empty;
    try json.appendString(arena, &bytes, text);
    return bytes.items;
}

fn applyLighting(editor: *jsonc_edit.Editor, node: *const Node) jsonc_edit.Error!void {
    const settings = &node.current;
    const arena = editor.allocator;
    const level = [_][]const u8{ "lighting", node.device_key, node.zone_name };
    const choice = settings.choice;
    if (choice == .inherit) {
        for (spec_keys) |key| try editor.remove(&(level ++ [_][]const u8{key}));
        try pruneLevel(editor, node);
        return;
    }
    const effect_name: []const u8 = if (choice.effect()) |effect| @tagName(effect) else "none";
    try editor.set(&(level ++ [_][]const u8{"effect"}), try quoted(arena, effect_name));
    if (choice.usesColors() and settings.color_count == 1) {
        var buffer: [7]u8 = undefined;
        try editor.set(&(level ++ [_][]const u8{"color"}), try quoted(arena, hexColor(&buffer, settings.colors[0])));
        try editor.remove(&(level ++ [_][]const u8{"colors"}));
    } else if (choice.usesColors()) {
        var list: std.ArrayList(u8) = .empty;
        try list.append(arena, '[');
        for (settings.activeColors(), 0..) |color, index| {
            if (index > 0) try list.appendSlice(arena, ", ");
            var buffer: [7]u8 = undefined;
            try json.appendString(arena, &list, hexColor(&buffer, color));
        }
        try list.append(arena, ']');
        try editor.set(&(level ++ [_][]const u8{"colors"}), list.items);
        try editor.remove(&(level ++ [_][]const u8{"color"}));
    } else {
        try editor.remove(&(level ++ [_][]const u8{"color"}));
        try editor.remove(&(level ++ [_][]const u8{"colors"}));
    }
    var number: [8]u8 = undefined;
    if (choice.usesSpeed()) {
        try editor.set(&(level ++ [_][]const u8{"speed"}), decimal(&number, settings.speed));
    } else {
        try editor.remove(&(level ++ [_][]const u8{"speed"}));
    }
    if (choice.usesBrightness()) {
        try editor.set(&(level ++ [_][]const u8{"brightness"}), decimal(&number, settings.brightness));
    } else {
        try editor.remove(&(level ++ [_][]const u8{"brightness"}));
    }
}

// Removes the level's object, its device's object and the lighting object once nothing, not
// even a comment, is left in them.
fn pruneLevel(editor: *jsonc_edit.Editor, node: *const Node) jsonc_edit.Error!void {
    try editor.removeIfEmpty(&.{ "lighting", node.device_key, node.zone_name });
    try editor.removeIfEmpty(&.{ "lighting", node.device_key });
    try editor.removeIfEmpty(&.{"lighting"});
}

const zone_labels = [_]struct { name: []const u8, label: []const u8 }{
    .{ .name = "argb1", .label = "ARGB header 1" },
    .{ .name = "argb2", .label = "ARGB header 2" },
    .{ .name = "argb3", .label = "ARGB header 3" },
    .{ .name = "rgb12v", .label = "12 V RGB header" },
    .{ .name = "io_cover", .label = "I/O shield logo" },
    .{ .name = "chipset", .label = "Chipset light" },
    .{ .name = "fan_left", .label = "Left fan" },
    .{ .name = "fan_middle", .label = "Middle fan" },
    .{ .name = "fan_right", .label = "Right fan" },
    .{ .name = "logo_side", .label = "Side logo" },
    .{ .name = "logo_top", .label = "Top logo" },
    .{ .name = "extra", .label = "Extra light" },
    .{ .name = "keys", .label = "Keys" },
    .{ .name = "dimm1", .label = "Memory module 1" },
    .{ .name = "dimm2", .label = "Memory module 2" },
    .{ .name = "dimm3", .label = "Memory module 3" },
    .{ .name = "dimm4", .label = "Memory module 4" },
    .{ .name = "strip", .label = "LED strip" },
};

/// A readable name for the zones of the supported devices; others keep their configuration name.
pub fn zoneLabel(name: []const u8) []const u8 {
    for (zone_labels) |entry| {
        if (std.mem.eql(u8, entry.name, name)) return entry.label;
    }
    return name;
}

const plugin_descriptions = [_]struct { name: []const u8, text: []const u8 }{
    .{ .name = "gigabyte_fusion2", .text = "Gigabyte motherboard lighting" },
    .{ .name = "gigabyte_gpu", .text = "Gigabyte graphics card lighting and LCD" },
    .{ .name = "corsair_ddr5", .text = "Corsair DDR5 memory lighting" },
    .{ .name = "keychron", .text = "Keychron keyboard lighting" },
    .{ .name = "steelseries_apex", .text = "SteelSeries Apex Pro keyboard lighting" },
    .{ .name = "sudokoo_sk700v", .text = "Sudokoo SK700V cooler display" },
    .{ .name = "amd_cpu", .text = "AMD processor temperature and power readings" },
    .{ .name = "windows_metrics", .text = "Processor load, memory and other Windows readings" },
    .{ .name = "nvidia_gpu", .text = "NVIDIA graphics card readings" },
    .{ .name = "virtual_led", .text = "Virtual LED strip (for testing)" },
};

pub fn pluginDescription(name: []const u8) []const u8 {
    for (plugin_descriptions) |entry| {
        if (std.mem.eql(u8, entry.name, name)) return entry.text;
    }
    return "";
}

const testing = std.testing;

const sample_inventory =
    \\{ "format": 1, "account": "system",
    \\  "plugins": [
    \\    { "name": "gigabyte_fusion2", "enabled": true, "state": "active" },
    \\    { "name": "corsair_ddr5", "opt_in": true, "enabled": false, "state": "disabled" },
    \\    { "name": "keychron", "enabled": true, "state": "active" }
    \\  ],
    \\  "devices": [
    \\    { "key": "motherboard", "name": "Gigabyte X870E AORUS PRO ICE", "plugin": "gigabyte_fusion2", "zones": [
    \\      { "name": "argb1", "leds": 0, "max_leds": 256, "resizable": true, "host_frames": true, "hardware_effects": ["off", "static", "breathing", "flash", "cycle"], "hardware_max_colors": 1 },
    \\      { "name": "io_cover", "leds": 1, "max_leds": 1, "host_frames": false, "hardware_effects": ["off", "static", "breathing"], "hardware_max_colors": 1 }
    \\    ] }
    \\  ] }
;

const sample_user =
    \\{
    \\  // every device blue
    \\  "lighting": {
    \\    "*": {
    \\      "*": { "effect": "static", "color": "#0000FF" }
    \\    },
    \\    "motherboard": {
    \\      "argb1": { "leds": 30 }
    \\    },
    \\    "gpu": {
    \\      "fan_left": { "effect": "cycle", "speed": 20 }
    \\    }
    \\  }
    \\}
    \\
;

fn loadSample(arena: std.mem.Allocator, user: []const u8) !Model {
    return Model.load(arena, .{ .inventory_text = sample_inventory, .user_text = user, .base_text = "{ \"plugins\": {} }" });
}

fn saveUser(arena: std.mem.Allocator, model: *const Model, user: []const u8) ![]const u8 {
    var editor = try jsonc_edit.Editor.init(arena, user);
    try model.applyUserEdits(&editor);
    return editor.text();
}

test "the tree has all devices, the detected devices and zones, and configured devices not found" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const model = try loadSample(arena_state.allocator(), sample_user);
    try testing.expectEqual(@as(usize, 6), model.nodes.len);
    try testing.expectEqualStrings("All devices", model.nodes[0].label);
    try testing.expectEqualStrings("Gigabyte X870E AORUS PRO ICE", model.nodes[1].label);
    try testing.expectEqualStrings("ARGB header 1", model.nodes[2].label);
    try testing.expectEqualStrings("I/O shield logo", model.nodes[3].label);
    try testing.expectEqualStrings("gpu (not detected)", model.nodes[4].label);
    try testing.expectEqualStrings("fan_left", model.nodes[5].zone_name);
    try testing.expect(!model.nodes[5].detected);
    try testing.expectEqual(@as(?usize, 4), model.nodes[5].parent);
}

test "levels without effect keys follow the level above and show its effective settings" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const model = try loadSample(arena_state.allocator(), sample_user);
    try testing.expectEqual(Choice.static, model.nodes[0].saved.choice);
    try testing.expectEqual(Choice.inherit, model.nodes[2].saved.choice);
    try testing.expect(model.nodes[2].saved.colors[0].eql(.{ .r = 0, .g = 0, .b = 0xFF }));
    try testing.expectEqual(@as(?u32, 30), model.nodes[2].leds_saved);
    try testing.expectEqual(Choice.cycle, model.nodes[5].saved.choice);
    try testing.expectEqual(@as(u8, 20), model.nodes[5].saved.speed);
    try testing.expect(!model.isDirty());
}

test "a zone that only the hardware drives offers only its hardware effects and color count" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const model = try loadSample(arena_state.allocator(), sample_user);
    var buffer: [9]Choice = undefined;
    try testing.expectEqualSlices(Choice, &.{ .inherit, .untouched, .off, .static, .breathing }, model.choices(3, &buffer));
    try testing.expectEqual(@as(u8, 1), model.maxColors(3, .breathing));
    try testing.expectEqual(@as(usize, 9), model.choices(2, &buffer).len);
    try testing.expectEqual(@as(u8, 16), model.maxColors(2, .breathing));
    try testing.expectEqualSlices(Choice, &.{ .inherit, .off, .static, .breathing, .flash, .cycle, .rainbow, .gradient }, model.choices(0, &buffer));
}

test "colors are added and removed within the limits of the effect and the zone" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    var model = try loadSample(arena_state.allocator(), sample_user);
    model.setChoice(3, .breathing);
    try testing.expectEqual(@as(u8, 1), model.nodes[3].current.color_count);
    model.addColor(3);
    try testing.expectEqual(@as(u8, 1), model.nodes[3].current.color_count);
    model.setChoice(2, .gradient);
    try testing.expectEqual(@as(u8, 2), model.nodes[2].current.color_count);
    model.removeColor(2);
    try testing.expectEqual(@as(u8, 2), model.nodes[2].current.color_count);
    model.addColor(2);
    try testing.expectEqual(@as(u8, 3), model.nodes[2].current.color_count);
    try testing.expect(!model.nodes[2].current.colors[2].eql(model.nodes[2].current.colors[1]));
    for (0..20) |_| model.addColor(2);
    try testing.expectEqual(@as(u8, 16), model.nodes[2].current.color_count);
    model.setChoice(2, .breathing);
    model.removeColor(2);
    try testing.expectEqual(@as(u8, 15), model.nodes[2].current.color_count);
    for (0..20) |_| model.removeColor(2);
    try testing.expectEqual(@as(u8, 1), model.nodes[2].current.color_count);
}

test "the effective choice of a level that follows the one above is what rgbctrl shows there" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const model = try loadSample(arena_state.allocator(), sample_user);
    try testing.expectEqual(Choice.static, model.nodes[2].effective_choice);
    try testing.expectEqual(Choice.cycle, model.nodes[5].effective_choice);
}

test "a level that follows the ones above previews what rgbctrl resolves, lighting.*.<zone> and unsaved edits included" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const user = "{ \"lighting\": { \"*\": { \"*\": { \"effect\": \"static\", \"color\": \"#0000FF\" }, \"io_cover\": { \"color\": \"#FF0000\" } } } }";
    var model = try loadSample(arena, user);
    const red = Rgb{ .r = 0xFF, .g = 0, .b = 0 };
    const green = Rgb{ .r = 0, .g = 0xFF, .b = 0 };
    try testing.expect(model.zoneNameLevel(3));
    try testing.expect(!model.zoneNameLevel(2));
    try testing.expect(model.preview(arena, 3).?.colors[0].eql(red));
    model.nodes[0].current.colors[0] = green;
    try testing.expect(model.isDirty());
    const io_cover = model.preview(arena, 3).?;
    try testing.expectEqual(Choice.static, io_cover.choice);
    try testing.expect(io_cover.colors[0].eql(red));
    try testing.expect(model.preview(arena, 2).?.colors[0].eql(green));
}

test "a changed zone is written with all its keys and the rest of the file stays" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var model = try loadSample(arena, sample_user);
    model.setChoice(2, .gradient);
    try testing.expectEqual(@as(u8, 2), model.nodes[2].current.color_count);
    model.nodes[2].current.colors[1] = .{ .r = 0xFF, .g = 0, .b = 0x40 };
    model.nodes[2].leds_current = 24;
    model.setChoice(5, .inherit);
    try testing.expect(model.isDirty());
    try testing.expectEqualStrings(
        \\{
        \\  // every device blue
        \\  "lighting": {
        \\    "*": {
        \\      "*": { "effect": "static", "color": "#0000FF" }
        \\    },
        \\    "motherboard": {
        \\      "argb1": { "leds": 24, "effect": "gradient", "colors": ["#0000FF", "#FF0040"], "brightness": 100 }
        \\    }
        \\  }
        \\}
        \\
    , try saveUser(arena, &model, sample_user));
}

test "leaving a zone unchanged and turning it off drop the keys those choices ignore" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var model = try loadSample(arena, sample_user);
    model.setChoice(0, .rainbow);
    model.nodes[0].current.speed = 80;
    model.setChoice(3, .off);
    model.setChoice(5, .untouched);
    const saved = try saveUser(arena, &model, sample_user);
    try testing.expect(std.mem.indexOf(u8, saved, "\"*\": { \"effect\": \"rainbow\", \"speed\": 80, \"brightness\": 100 }") != null);
    try testing.expect(std.mem.indexOf(u8, saved, "\"io_cover\": { \"effect\": \"off\" }") != null);
    try testing.expect(std.mem.indexOf(u8, saved, "\"fan_left\": { \"effect\": \"none\" }") != null);
    const reloaded = try loadSample(arena, saved);
    try testing.expectEqual(Choice.rainbow, reloaded.nodes[0].saved.choice);
    try testing.expectEqual(Choice.off, reloaded.nodes[3].saved.choice);
    try testing.expectEqual(Choice.untouched, reloaded.nodes[5].saved.choice);
}

test "turning plugins on and off picks the file that rgbctrl reads it from" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var model = try loadSample(arena, "{ \"plugins\": { \"keychron\": { \"enabled\": false } } }");
    model.setPluginDesired(2, false);
    model.setPluginDesired(1, true);
    try testing.expect(model.needsElevation());
    var names: [4][]const u8 = undefined;
    try testing.expectEqual(@as(usize, 1), model.pluginsToEnableInBase(&names).len);
    try testing.expectEqualStrings("corsair_ddr5", names[0]);
    try testing.expectEqualStrings("{ \"plugins\": { \"keychron\": { \"enabled\": false } } }", try saveUser(arena, &model, "{ \"plugins\": { \"keychron\": { \"enabled\": false } } }"));
    model.account = .standard;
    try testing.expect(!model.needsElevation());
    try testing.expectEqualStrings("{ \"plugins\": { \"keychron\": { \"enabled\": false }, \"corsair_ddr5\": { \"enabled\": true } } }", try saveUser(arena, &model, "{ \"plugins\": { \"keychron\": { \"enabled\": false } } }"));
}

test "turning a plugin off and on again, or a zone's own lighting off again, leaves the file as it was" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const original = "{\n  // lights\n  \"frame_rate\": 30\n}\n";
    var model = try loadSample(arena, original);
    model.setPluginDesired(2, false);
    model.setChoice(3, .breathing);
    const changed = try saveUser(arena, &model, original);
    try testing.expect(std.mem.indexOf(u8, changed, "\"keychron\": { \"enabled\": false }") != null);
    try testing.expect(std.mem.indexOf(u8, changed, "\"effect\": \"breathing\"") != null);
    var reloaded = try loadSample(arena, changed);
    reloaded.setPluginDesired(2, true);
    reloaded.setChoice(3, .inherit);
    try testing.expectEqualStrings(original, try saveUser(arena, &reloaded, changed));
}

test "the base file counts only where rgbctrl trusts it, and a change of account is followed" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    // The sample inventory comes from rgbctrl running as SYSTEM and reports no trusted base file.
    var model = try Model.load(arena_state.allocator(), .{ .inventory_text = sample_inventory, .user_text = "{}", .base_text = "{ \"plugins\": { \"corsair_ddr5\": { \"enabled\": true } } }" });
    try testing.expect(!model.plugins[1].saved);
    model.setAccount(.system, true);
    try testing.expect(model.plugins[1].saved);
    model.setPluginDesired(1, false);
    model.setAccount(.standard, false);
    try testing.expect(model.plugins[1].saved);
    try testing.expect(!model.plugins[1].desired);
    try testing.expect(model.isDirty());
}

test "a user file that does not parse makes the model read-only" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const model = try loadSample(arena_state.allocator(), "{ \"lighting\": ");
    try testing.expect(!model.canEdit());
    try testing.expectEqual(@as(u32, 1), model.user_issue.?.line);
}

test "colors are written as capital hex" {
    var buffer: [7]u8 = undefined;
    try testing.expectEqualStrings("#0A1BFF", hexColor(&buffer, .{ .r = 0x0A, .g = 0x1B, .b = 0xFF }));
}
