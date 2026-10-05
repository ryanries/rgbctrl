const std = @import("std");
const sdk = @import("sdk");
const json = @import("config/json.zig");
const settings_module = @import("config/settings.zig");
const lighting_config = @import("config/lighting_config.zig");
const Diagnostics = @import("config/diagnostics.zig").Diagnostics;

const abi = sdk.abi;

test {
    _ = @import("heap.zig");
    _ = @import("config/json.zig");
    _ = @import("config/suggest.zig");
    _ = @import("config/diagnostics.zig");
    _ = @import("config/layers.zig");
    _ = @import("config/settings.zig");
    _ = @import("config/lighting_config.zig");
    _ = @import("lighting/effects.zig");
    _ = @import("diag/format.zig");
    _ = @import("diag/log.zig");
    _ = @import("diag/console.zig");
    _ = @import("diag/event_log.zig");
    _ = @import("security/safe_open.zig");
    _ = @import("security/acl_policy.zig");
    _ = @import("security/install_check.zig");
    _ = @import("security/named_objects.zig");
    _ = @import("runtime/sensors.zig");
    _ = @import("runtime/clock.zig");
    _ = @import("runtime/persist_policy.zig");
    _ = @import("runtime/bindings.zig");
    _ = @import("runtime/inventory.zig");
    _ = @import("gui/jsonc_edit.zig");
    _ = @import("gui/files.zig");
    _ = @import("gui/model.zig");
    _ = @import("gui/win32_ui.zig");
    _ = @import("gui/elevate.zig");
    _ = @import("plugin_host/validate.zig");
    _ = @import("plugin_host/loader.zig");
    _ = @import("plugin_host/host_services.zig");
    _ = @import("config/generation.zig");
    _ = @import("platform.zig");
    _ = @import("cli/args.zig");
    _ = @import("runtime/worker.zig");
    _ = @import("runtime/supervisor.zig");
}

const ExpectedZone = struct {
    device: []const u8,
    zone: []const u8,
    shape: lighting_config.ZoneShape,
    effect: ?abi.Effect,
    engine: lighting_config.EngineChoice,
    leds: ?u32 = null,
};

fn effects(comptime list: []const abi.Effect) u32 {
    var mask: u32 = 0;
    for (list) |effect| mask |= abi.effectBit(effect);
    return mask;
}

test "the shipped example configuration resolves every phase-1 zone without errors" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var warnings: std.ArrayList(json.Issue) = .empty;
    const root = switch (try json.parse(arena, @embedFile("example_config"), &warnings)) {
        .document => |document| document,
        .failure => return error.TestUnexpectedResult,
    };
    var diagnostics = Diagnostics.init(arena);
    const settings = settings_module.extract(root, &.{}, &diagnostics);
    const fusion_effects = effects(&.{ .off, .static, .breathing, .flash, .cycle });
    const argb = lighting_config.ZoneShape{ .flags = abi.zone_resizable | abi.zone_host_frames, .led_count = 0, .max_leds = 256, .hw_effects = fusion_effects, .hw_max_colors = 1 };
    const onboard = lighting_config.ZoneShape{ .flags = abi.zone_host_frames, .led_count = 1, .max_leds = 1, .hw_effects = fusion_effects, .hw_max_colors = 1 };
    const gpu_effects = effects(&.{ .off, .static, .breathing, .flash, .cycle, .rainbow });
    const fan = lighting_config.ZoneShape{ .flags = abi.zone_host_frames, .led_count = 8, .max_leds = 8, .hw_effects = gpu_effects, .hw_max_colors = 1 };
    const logo = lighting_config.ZoneShape{ .flags = abi.zone_host_frames, .led_count = 1, .max_leds = 1, .hw_effects = gpu_effects, .hw_max_colors = 1 };
    const keys = lighting_config.ZoneShape{ .flags = abi.zone_host_frames | abi.zone_global_brightness_only, .led_count = 108, .max_leds = 113, .hw_effects = effects(&.{ .off, .static, .breathing, .cycle, .rainbow }), .hw_max_colors = 1 };
    const dimm = lighting_config.ZoneShape{ .flags = abi.zone_host_frames, .led_count = 10, .max_leds = 10 };
    const apex_keys = lighting_config.ZoneShape{ .flags = abi.zone_host_frames, .led_count = 112, .max_leds = 112 };
    const cases = [_]ExpectedZone{
        .{ .device = "motherboard", .zone = "argb1", .shape = argb, .effect = .rainbow, .engine = .host, .leds = 30 },
        .{ .device = "motherboard", .zone = "argb2", .shape = argb, .effect = .gradient, .engine = .host, .leds = 30 },
        .{ .device = "motherboard", .zone = "argb3", .shape = argb, .effect = null, .engine = .untouched },
        .{ .device = "motherboard", .zone = "rgb12v", .shape = onboard, .effect = .breathing, .engine = .hardware },
        .{ .device = "motherboard", .zone = "io_cover", .shape = onboard, .effect = .static, .engine = .hardware },
        .{ .device = "motherboard", .zone = "chipset", .shape = onboard, .effect = .static, .engine = .hardware },
        .{ .device = "gpu", .zone = "fan_left", .shape = fan, .effect = .cycle, .engine = .hardware },
        .{ .device = "gpu", .zone = "fan_middle", .shape = fan, .effect = .cycle, .engine = .hardware },
        .{ .device = "gpu", .zone = "fan_right", .shape = fan, .effect = .cycle, .engine = .hardware },
        .{ .device = "gpu", .zone = "logo_side", .shape = logo, .effect = .static, .engine = .hardware },
        .{ .device = "gpu", .zone = "logo_top", .shape = logo, .effect = .static, .engine = .hardware },
        .{ .device = "gpu", .zone = "extra", .shape = logo, .effect = .off, .engine = .hardware },
        .{ .device = "keyboard", .zone = "keys", .shape = keys, .effect = .rainbow, .engine = .hardware },
        .{ .device = "apex_pro", .zone = "keys", .shape = apex_keys, .effect = .gradient, .engine = .host },
        .{ .device = "ram", .zone = "dimm1", .shape = dimm, .effect = .gradient, .engine = .host },
        .{ .device = "ram", .zone = "dimm2", .shape = dimm, .effect = .gradient, .engine = .host },
    };
    for (cases) |case| {
        const resolution = try lighting_config.resolve(arena, settings.lighting, case.device, case.zone, case.shape, &diagnostics);
        if (case.effect) |expected_effect| {
            const spec = resolution.spec;
            try std.testing.expectEqual(expected_effect, spec.effect);
            try std.testing.expectEqual(case.leds, spec.leds);
            try std.testing.expectEqual(case.engine, lighting_config.selectEngine(&spec, case.shape).choice);
        } else {
            try std.testing.expect(resolution == .untouched);
        }
    }
    const devices = [_]lighting_config.DeviceShape{
        .{ .key = "motherboard", .zone_names = &.{ "argb1", "argb2", "argb3", "rgb12v", "io_cover", "chipset" } },
        .{ .key = "gpu", .zone_names = &.{ "fan_right", "fan_left", "fan_middle", "logo_side", "logo_top", "extra" } },
        .{ .key = "keyboard", .zone_names = &.{"keys"} },
        .{ .key = "apex_pro", .zone_names = &.{"keys"} },
        .{ .key = "ram", .zone_names = &.{ "dimm1", "dimm2" } },
    };
    try lighting_config.validateTree(arena, settings.lighting, &devices, &diagnostics);
    for (diagnostics.entries.items) |entry| std.debug.print("unexpected diagnostic: {s}\n", .{entry.message});
    try std.testing.expectEqual(@as(usize, 0), diagnostics.entries.items.len);
    try std.testing.expectEqual(@as(usize, 0), warnings.items.len);
    try std.testing.expectEqual(settings_module.LogLevel.debug, settings.log_level);
}
