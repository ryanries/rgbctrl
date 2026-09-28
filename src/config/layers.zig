const std = @import("std");
const json = @import("json.zig");
const Diagnostics = @import("diagnostics.zig").Diagnostics;

const Layer = struct {
    label: []const u8,
    root: ?*const json.Node,
    trusted: bool,
};

const Merged = struct {
    root: *const json.Node,
    untrusted_enable_requests: []const []const u8,
};

const exclusive_plugin = "sudokoo_sk700v";
const lcd_plugin = "gigabyte_gpu";
const common_privileged_keys = [_][]const u8{ "enabled", "persist", "extra_ids" };

fn isPrivileged(plugin: []const u8, key: []const u8) bool {
    for (common_privileged_keys) |privileged| {
        if (std.mem.eql(u8, key, privileged)) return true;
    }
    if (std.mem.eql(u8, plugin, exclusive_plugin) and std.mem.eql(u8, key, "exclusive")) return true;
    return std.mem.eql(u8, plugin, lcd_plugin) and std.mem.eql(u8, key, "lcd");
}

fn merge(arena: std.mem.Allocator, lower: ?*const json.Node, upper: ?*const json.Node) error{OutOfMemory}!?*const json.Node {
    const top = upper orelse {
        const bottom = lower orelse return null;
        if (bottom.isNull()) return null;
        if (bottom.kind() != .object) return bottom;
        return merge(arena, null, bottom);
    };
    if (top.isNull()) return null;
    const top_members = top.objectMembers() orelse return top;
    const bottom_members: []const json.Member = if (lower) |bottom| (bottom.objectMembers() orelse &.{}) else &.{};
    var members: std.ArrayList(json.Member) = .empty;
    for (bottom_members) |member| {
        const combined = if (top.get(member.key)) |override| try merge(arena, member.value, override) else try merge(arena, member.value, null);
        if (combined) |value| try members.append(arena, .{ .key = member.key, .value = value });
    }
    for (top_members) |member| {
        const in_bottom = if (lower) |bottom| bottom.get(member.key) != null else false;
        if (in_bottom) continue;
        if (try merge(arena, null, member.value)) |value| try members.append(arena, .{ .key = member.key, .value = value });
    }
    return try json.objectNode(arena, top.line, top.column, members.items);
}

fn withMember(arena: std.mem.Allocator, object: ?*const json.Node, key: []const u8, value: ?*const json.Node) error{OutOfMemory}!*const json.Node {
    const existing: []const json.Member = if (object) |node| (node.objectMembers() orelse &.{}) else &.{};
    var members: std.ArrayList(json.Member) = .empty;
    var replaced = false;
    for (existing) |member| {
        if (std.mem.eql(u8, member.key, key)) {
            replaced = true;
            if (value) |new_value| try members.append(arena, .{ .key = key, .value = new_value });
        } else {
            try members.append(arena, member);
        }
    }
    if (!replaced) {
        if (value) |new_value| try members.append(arena, .{ .key = key, .value = new_value });
    }
    const line = if (object) |node| node.line else 1;
    const column = if (object) |node| node.column else 1;
    return json.objectNode(arena, line, column, members.items);
}

fn privilegedValue(root: *const json.Node, plugin: []const u8, key: []const u8) ?*const json.Node {
    const plugins = root.get("plugins") orelse return null;
    const settings = plugins.get(plugin) orelse return null;
    return settings.get(key);
}

fn setPrivileged(arena: std.mem.Allocator, root: *const json.Node, plugin: []const u8, key: []const u8, value: ?*const json.Node) error{OutOfMemory}!*const json.Node {
    const plugins = root.get("plugins");
    const usable_plugins = if (plugins) |node| (if (node.kind() == .object) node else null) else null;
    const settings = if (usable_plugins) |node| node.get(plugin) else null;
    const usable_settings = if (settings) |node| (if (node.kind() == .object) node else null) else null;
    if (value == null and (usable_settings == null or usable_settings.?.get(key) == null)) return root;
    const new_settings = try withMember(arena, usable_settings, key, value);
    const new_plugins = try withMember(arena, usable_plugins, plugin, new_settings);
    return withMember(arena, root, "plugins", new_plugins);
}

const Decision = enum { accept, ignore, no_change, request_enable };

fn decide(key: []const u8, current: ?*const json.Node, attempt: *const json.Node) Decision {
    if (std.mem.eql(u8, key, "extra_ids")) return decideSubset(current, attempt);
    const requested = attempt.boolean() orelse return .ignore;
    const current_value: ?bool = if (current) |node| node.boolean() else null;
    if (std.mem.eql(u8, key, "exclusive")) {
        if (requested) return .accept;
        return if (current_value == false) .no_change else .ignore;
    }
    if (!requested) return .accept;
    if (current_value == true) return .no_change;
    if (std.mem.eql(u8, key, "enabled") and current_value == null) return .request_enable;
    return .ignore;
}

fn decideSubset(current: ?*const json.Node, attempt: *const json.Node) Decision {
    const requested = attempt.arrayItems() orelse return .ignore;
    const allowed: []const *const json.Node = if (current) |node| (node.arrayItems() orelse &.{}) else &.{};
    for (requested) |item| {
        const text = item.string() orelse return .ignore;
        var found = false;
        for (allowed) |allowed_item| {
            if (allowed_item.string()) |allowed_text| {
                if (std.ascii.eqlIgnoreCase(allowed_text, text)) found = true;
            }
        }
        if (!found) return .ignore;
    }
    return .accept;
}

const Attempt = struct {
    layer: []const u8,
    plugin: []const u8,
    key: []const u8,
    node: *const json.Node,
};

const max_untrusted_plugins = 256;

fn limitUntrustedPlugins(arena: std.mem.Allocator, layer: Layer, diagnostics: *Diagnostics) error{OutOfMemory}!Layer {
    if (layer.trusted) return layer;
    const root = layer.root orelse return layer;
    const plugins = root.get("plugins") orelse return layer;
    const members = plugins.objectMembers() orelse return layer;
    if (members.len <= max_untrusted_plugins) return layer;
    diagnostics.warnAt(plugins, "plugins in the {s} config has {d} entries, more than the 256 allowed while rgbctrl runs elevated; the section is ignored", .{ layer.label, members.len });
    return .{ .label = layer.label, .root = try withMember(arena, root, "plugins", null), .trusted = false };
}

pub fn mergeLayers(arena: std.mem.Allocator, given_base: Layer, given_user: Layer, elevated: bool, diagnostics: *Diagnostics) error{OutOfMemory}!Merged {
    if (!elevated) {
        const plain = (try merge(arena, given_base.root, given_user.root)) orelse &json.empty_object;
        return .{ .root = plain, .untrusted_enable_requests = &.{} };
    }
    const base = try limitUntrustedPlugins(arena, given_base, diagnostics);
    const user = try limitUntrustedPlugins(arena, given_user, diagnostics);
    const merged = (try merge(arena, base.root, user.root)) orelse &json.empty_object;
    var root = merged;
    var names: std.ArrayList([]const u8) = .empty;
    for ([_]?*const json.Node{ merged, base.root, user.root }) |maybe_layer_root| {
        const layer_root = maybe_layer_root orelse continue;
        const plugins = layer_root.get("plugins") orelse continue;
        for (plugins.objectMembers() orelse &.{}) |member| try appendUnique(arena, &names, member.key);
    }
    for (names.items) |plugin| {
        for (applicableKeys(plugin)) |key| {
            const trusted_value = if (base.trusted and base.root != null) privilegedValue(base.root.?, plugin, key) else null;
            const usable = if (trusted_value) |node| (if (node.isNull()) null else node) else null;
            root = try setPrivileged(arena, root, plugin, key, usable);
        }
    }
    var attempts: std.ArrayList(Attempt) = .empty;
    for ([_]Layer{ base, user }) |layer| {
        if (layer.trusted) continue;
        const layer_root = layer.root orelse continue;
        try collectAttempts(arena, &attempts, layer, layer_root, base, diagnostics);
    }
    var requests: std.ArrayList([]const u8) = .empty;
    for (attempts.items) |attempt| {
        const current = privilegedValue(root, attempt.plugin, attempt.key);
        switch (decide(attempt.key, current, attempt.node)) {
            .accept => root = try setPrivileged(arena, root, attempt.plugin, attempt.key, attempt.node),
            .no_change => {},
            .request_enable => try appendUnique(arena, &requests, attempt.plugin),
            .ignore => diagnostics.warnAt(attempt.node, "plugins.{s}.{s} in the {s} config was ignored: while rgbctrl runs elevated an untrusted config can only make privileged settings more restrictive (set it in %ProgramData%\\rgbctrl\\rgbctrl.json)", .{ attempt.plugin, attempt.key, attempt.layer }),
        }
    }
    return .{ .root = root, .untrusted_enable_requests = try requests.toOwnedSlice(arena) };
}

fn collectAttempts(arena: std.mem.Allocator, attempts: *std.ArrayList(Attempt), layer: Layer, layer_root: *const json.Node, base: Layer, diagnostics: *Diagnostics) error{OutOfMemory}!void {
    const plugins = layer_root.get("plugins") orelse return;
    const members = plugins.objectMembers() orelse {
        warnRemoval(diagnostics, plugins, layer.label, "plugins", base);
        return;
    };
    for (members) |member| {
        const settings = member.value.objectMembers() orelse {
            warnRemoval(diagnostics, member.value, layer.label, member.key, base);
            continue;
        };
        for (settings) |setting| {
            if (!isPrivileged(member.key, setting.key)) continue;
            try attempts.append(arena, .{ .layer = layer.label, .plugin = member.key, .key = setting.key, .node = setting.value });
        }
    }
}

fn warnRemoval(diagnostics: *Diagnostics, node: *const json.Node, layer: []const u8, path: []const u8, base: Layer) void {
    if (!base.trusted or base.root == null) return;
    diagnostics.warnAt(node, "replacing \"{s}\" in the {s} config does not remove privileged settings from the trusted base config while rgbctrl runs elevated", .{ path, layer });
}

fn applicableKeys(plugin: []const u8) []const []const u8 {
    const with_exclusive = comptime common_privileged_keys ++ [_][]const u8{"exclusive"};
    const with_lcd = comptime common_privileged_keys ++ [_][]const u8{"lcd"};
    if (std.mem.eql(u8, plugin, exclusive_plugin)) return &with_exclusive;
    if (std.mem.eql(u8, plugin, lcd_plugin)) return &with_lcd;
    return &common_privileged_keys;
}

fn appendUnique(arena: std.mem.Allocator, list: *std.ArrayList([]const u8), value: []const u8) error{OutOfMemory}!void {
    for (list.items) |existing| {
        if (std.mem.eql(u8, existing, value)) return;
    }
    try list.append(arena, value);
}

const testing = std.testing;

fn parseTestDocument(arena: std.mem.Allocator, source: []const u8) !*const json.Node {
    var warnings: std.ArrayList(json.Issue) = .empty;
    return switch (try json.parse(arena, source, &warnings)) {
        .document => |document| document,
        .failure => error.TestUnexpectedResult,
    };
}

test "merge combines objects recursively, replaces arrays and scalars and removes keys set to null" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const base = try parseTestDocument(arena, "{\"a\": {\"x\": 1, \"y\": [1, 2], \"z\": 3}, \"b\": true, \"c\": null}");
    const user = try parseTestDocument(arena, "{\"a\": {\"y\": [9], \"z\": null, \"w\": {\"q\": null, \"r\": 2}}, \"b\": false}");
    const merged = (try merge(arena, base, user)).?;
    const a = merged.get("a").?;
    try testing.expectEqual(@as(f64, 1), a.get("x").?.number().?);
    try testing.expectEqual(@as(usize, 1), a.get("y").?.arrayItems().?.len);
    try testing.expect(a.get("z") == null);
    try testing.expect(a.get("w").?.get("q") == null);
    try testing.expectEqual(@as(f64, 2), a.get("w").?.get("r").?.number().?);
    try testing.expect(!merged.get("b").?.boolean().?);
    try testing.expect(merged.get("c") == null);
}

test "without elevation the user layer overrides privileged keys like any other key" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var diagnostics = Diagnostics.init(arena);
    const base = try parseTestDocument(arena, "{\"plugins\": {\"keychron\": {\"persist\": false}}}");
    const user = try parseTestDocument(arena, "{\"plugins\": {\"keychron\": {\"persist\": true}}}");
    const merged = try mergeLayers(arena, .{ .label = "base", .root = base, .trusted = true }, .{ .label = "user", .root = user, .trusted = true }, false, &diagnostics);
    try testing.expect(privilegedValue(merged.root, "keychron", "persist").?.boolean().?);
    try testing.expectEqual(@as(usize, 0), diagnostics.entries.items.len);
}

test "while elevated an untrusted user layer can only tighten privileged keys" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var diagnostics = Diagnostics.init(arena);
    const base = try parseTestDocument(arena,
        \\{"plugins": {"keychron": {"persist": true, "extra_ids": ["3434:0870", "3434:0871"]},
        \\             "gigabyte_gpu": {"persist": false}}}
    );
    const user = try parseTestDocument(arena,
        \\{"plugins": {"keychron": {"persist": false, "extra_ids": ["3434:0870"], "custom": 5},
        \\             "gigabyte_gpu": {"persist": true, "enabled": false},
        \\             "corsair_ddr5": {"enabled": true},
        \\             "sudokoo_sk700v": {"exclusive": false}}}
    );
    const merged = try mergeLayers(arena, .{ .label = "base", .root = base, .trusted = true }, .{ .label = "user", .root = user, .trusted = false }, true, &diagnostics);
    try testing.expect(!privilegedValue(merged.root, "keychron", "persist").?.boolean().?);
    try testing.expectEqual(@as(usize, 1), privilegedValue(merged.root, "keychron", "extra_ids").?.arrayItems().?.len);
    try testing.expectEqual(@as(f64, 5), privilegedValue(merged.root, "keychron", "custom").?.number().?);
    try testing.expect(!privilegedValue(merged.root, "gigabyte_gpu", "persist").?.boolean().?);
    try testing.expect(!privilegedValue(merged.root, "gigabyte_gpu", "enabled").?.boolean().?);
    try testing.expect(privilegedValue(merged.root, "corsair_ddr5", "enabled") == null);
    try testing.expectEqual(@as(usize, 1), merged.untrusted_enable_requests.len);
    try testing.expectEqualStrings("corsair_ddr5", merged.untrusted_enable_requests[0]);
    try testing.expect(privilegedValue(merged.root, "sudokoo_sk700v", "exclusive") == null);
    try testing.expect(diagnostics.contains("plugins.gigabyte_gpu.persist in the user config was ignored"));
    try testing.expect(diagnostics.contains("plugins.sudokoo_sk700v.exclusive in the user config was ignored"));
    try testing.expectEqual(@as(usize, 2), diagnostics.entries.items.len);
}

test "while elevated an untrusted layer cannot widen extra_ids, remove trusted values or use an untrusted base" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var diagnostics = Diagnostics.init(arena);
    const base = try parseTestDocument(arena, "{\"plugins\": {\"keychron\": {\"extra_ids\": [\"3434:0870\"], \"persist\": true}}}");
    const user = try parseTestDocument(arena, "{\"plugins\": {\"keychron\": null}}");
    const kept = try mergeLayers(arena, .{ .label = "base", .root = base, .trusted = true }, .{ .label = "user", .root = user, .trusted = false }, true, &diagnostics);
    try testing.expectEqual(@as(usize, 1), privilegedValue(kept.root, "keychron", "extra_ids").?.arrayItems().?.len);
    try testing.expect(privilegedValue(kept.root, "keychron", "persist").?.boolean().?);
    try testing.expect(diagnostics.contains("does not remove privileged settings"));

    const widen = try parseTestDocument(arena, "{\"plugins\": {\"keychron\": {\"extra_ids\": [\"3434:0870\", \"3434:0999\"]}}}");
    const widened = try mergeLayers(arena, .{ .label = "base", .root = base, .trusted = true }, .{ .label = "user", .root = widen, .trusted = false }, true, &diagnostics);
    try testing.expectEqual(@as(usize, 1), privilegedValue(widened.root, "keychron", "extra_ids").?.arrayItems().?.len);

    var untrusted_diagnostics = Diagnostics.init(arena);
    const untrusted_base = try mergeLayers(arena, .{ .label = "base", .root = base, .trusted = false }, .{ .label = "user", .root = null, .trusted = false }, true, &untrusted_diagnostics);
    try testing.expect(privilegedValue(untrusted_base.root, "keychron", "persist") == null);
    try testing.expect(privilegedValue(untrusted_base.root, "keychron", "extra_ids") == null);
    try testing.expect(untrusted_diagnostics.contains("plugins.keychron.persist in the base config was ignored"));
}

test "while elevated only the trusted base can turn on the GPU LCD and the user layer can turn it off" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var diagnostics = Diagnostics.init(arena);
    const empty_base = try parseTestDocument(arena, "{}");
    const enable = try parseTestDocument(arena, "{\"plugins\": {\"gigabyte_gpu\": {\"lcd\": true, \"lcd_seconds\": 6}}}");
    const refused = try mergeLayers(arena, .{ .label = "base", .root = empty_base, .trusted = true }, .{ .label = "user", .root = enable, .trusted = false }, true, &diagnostics);
    try testing.expect(privilegedValue(refused.root, "gigabyte_gpu", "lcd") == null);
    try testing.expectEqual(@as(f64, 6), privilegedValue(refused.root, "gigabyte_gpu", "lcd_seconds").?.number().?);
    try testing.expect(diagnostics.contains("plugins.gigabyte_gpu.lcd in the user config was ignored"));

    const trusted_base = try parseTestDocument(arena, "{\"plugins\": {\"gigabyte_gpu\": {\"lcd\": true}}}");
    const disable = try parseTestDocument(arena, "{\"plugins\": {\"gigabyte_gpu\": {\"lcd\": false}}}");
    const kept = try mergeLayers(arena, .{ .label = "base", .root = trusted_base, .trusted = true }, .{ .label = "user", .root = null, .trusted = false }, true, &diagnostics);
    try testing.expect(privilegedValue(kept.root, "gigabyte_gpu", "lcd").?.boolean().?);
    const tightened = try mergeLayers(arena, .{ .label = "base", .root = trusted_base, .trusted = true }, .{ .label = "user", .root = disable, .trusted = false }, true, &diagnostics);
    try testing.expect(!privilegedValue(tightened.root, "gigabyte_gpu", "lcd").?.boolean().?);
}

test "decide treats null and wrong types from an untrusted layer as ignored attempts" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const document = try parseTestDocument(arena, "{\"n\": null, \"s\": \"yes\", \"t\": true, \"f\": false}");
    try testing.expectEqual(Decision.ignore, decide("persist", null, document.get("n").?));
    try testing.expectEqual(Decision.ignore, decide("enabled", null, document.get("s").?));
    try testing.expectEqual(Decision.accept, decide("enabled", null, document.get("f").?));
    try testing.expectEqual(Decision.request_enable, decide("enabled", null, document.get("t").?));
    try testing.expectEqual(Decision.no_change, decide("enabled", document.get("t").?, document.get("t").?));
    try testing.expectEqual(Decision.ignore, decide("enabled", document.get("f").?, document.get("t").?));
    try testing.expectEqual(Decision.accept, decide("exclusive", null, document.get("t").?));
    try testing.expectEqual(Decision.ignore, decide("extra_ids", null, document.get("n").?));
}

test "while elevated an untrusted layer with more than 256 plugin entries loses its plugins section" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var source: std.ArrayList(u8) = .empty;
    try source.appendSlice(arena, "{\"frame_rate\": 20, \"plugins\": {");
    for (0..300) |index| {
        var buffer: [48]u8 = undefined;
        try source.appendSlice(arena, try std.fmt.bufPrint(&buffer, "\"p{d}\": {{\"enabled\": false}},", .{index}));
    }
    try source.appendSlice(arena, "}}");
    const user = try parseTestDocument(arena, source.items);
    var diagnostics = Diagnostics.init(arena);
    const merged = try mergeLayers(arena, .{ .label = "base", .root = null, .trusted = true }, .{ .label = "user", .root = user, .trusted = false }, true, &diagnostics);
    try testing.expect(merged.root.get("plugins") == null);
    try testing.expectEqual(@as(f64, 20), merged.root.get("frame_rate").?.number().?);
    try testing.expect(diagnostics.contains("more than the 256 allowed"));
    var trusted_diagnostics = Diagnostics.init(arena);
    const unelevated = try mergeLayers(arena, .{ .label = "base", .root = null, .trusted = true }, .{ .label = "user", .root = user, .trusted = true }, false, &trusted_diagnostics);
    try testing.expectEqual(@as(usize, 300), unelevated.root.get("plugins").?.objectMembers().?.len);
}
