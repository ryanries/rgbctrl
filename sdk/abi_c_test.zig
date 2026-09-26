const std = @import("std");
const abi = @import("abi.zig");
const c = @cImport({
    @cInclude("rgbctrl_plugin.h");
});

fn expectSameLayout(comptime Zig: type, comptime C: type, comptime fields: []const []const u8) !void {
    try std.testing.expectEqual(@sizeOf(C), @sizeOf(Zig));
    inline for (fields) |field| {
        try std.testing.expectEqual(@offsetOf(C, field), @offsetOf(Zig, field));
    }
}

test "the Zig ABI mirror matches the C header for every v1 struct" {
    try expectSameLayout(abi.Rgb, c.rgbctrl_rgb, &.{ "r", "g", "b" });
    try expectSameLayout(abi.Host, c.rgbctrl_host, &.{ "struct_size", "abi_version", "ctx", "host_dir", "mode", "log", "now_ms", "sensor_set", "sensor_get", "json_type", "json_get", "json_len", "json_at", "json_member", "json_number", "json_bool", "json_string" });
    try expectSameLayout(abi.ZoneInfo, c.rgbctrl_zone_info, &.{ "struct_size", "flags", "name", "led_count", "max_leds", "hw_effects", "hw_max_colors", "led_x" });
    try expectSameLayout(abi.DeviceInfo, c.rgbctrl_device_info, &.{ "struct_size", "zone_count", "id", "name", "zones", "max_fps" });
    try expectSameLayout(abi.HwEffect, c.rgbctrl_hw_effect, &.{ "struct_size", "effect", "speed", "brightness", "color_count", "colors" });
    try expectSameLayout(abi.Plugin, c.rgbctrl_plugin, &.{ "struct_size", "abi_version", "name", "version", "flags", "tick_interval_ms", "transports", "open", "close", "device_count", "device_info", "set_zone_size", "set_hw_effect", "set_leds", "flush", "tick", "rescan", "persist" });
}

test "the Zig ABI constants match the C header macros" {
    try std.testing.expectEqual(@as(u32, c.RGBCTRL_ABI_VERSION), abi.abi_version);
    try std.testing.expectEqual(@as(i32, c.RGBCTRL_E_BUSY), abi.status_busy);
    try std.testing.expectEqual(@as(i32, c.RGBCTRL_E_DEVICE_LOST), abi.status_device_lost);
    try std.testing.expectEqual(@as(i32, c.RGBCTRL_RESCAN_CHANGED), abi.rescan_changed);
    try std.testing.expectEqual(@as(u32, c.RGBCTRL_ZONE_HOST_FRAMES), abi.zone_host_frames);
    try std.testing.expectEqual(@as(u32, c.RGBCTRL_ZONE_GLOBAL_BRIGHTNESS_ONLY), abi.zone_global_brightness_only);
    try std.testing.expectEqual(@as(u32, c.RGBCTRL_PLUGIN_OPT_IN), abi.plugin_opt_in);
    try std.testing.expectEqual(@as(u32, c.RGBCTRL_TRANSPORT_OS), abi.transport_os);
    try std.testing.expectEqual(@as(u32, c.RGBCTRL_MODE_LIST), abi.mode_list);
    try std.testing.expectEqual(@as(u32, c.RGBCTRL_CLOSE_EXIT), abi.close_exit);
    try std.testing.expectEqual(@as(u32, c.RGBCTRL_JSON_OBJECT), abi.json_object);
    try std.testing.expectEqual(@as(u32, c.RGBCTRL_EFFECT_GRADIENT), @intFromEnum(abi.Effect.gradient));
    try std.testing.expectEqual(@as(u32, 1) << 5, abi.effectBit(.rainbow));
}
