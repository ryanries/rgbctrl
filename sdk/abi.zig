const std = @import("std");

pub const abi_version: u32 = 1;
pub const entry_name = "rgbctrl_plugin_entry";

pub const status_ok: i32 = 0;
pub const status_fail: i32 = -1;
pub const status_unsupported: i32 = -2;
pub const status_argument: i32 = -3;
pub const status_device_lost: i32 = -4;
pub const status_access: i32 = -5;
pub const status_busy: i32 = -6;
pub const rescan_changed: i32 = 1;

pub const LogLevel = enum(u32) {
    err = 0,
    warn = 1,
    info = 2,
    debug = 3,
    trace = 4,
};

pub const Effect = enum(u32) {
    off = 0,
    static = 1,
    breathing = 2,
    flash = 3,
    cycle = 4,
    rainbow = 5,
    gradient = 6,
};

pub const effect_count = 7;

pub fn effectBit(effect: Effect) u32 {
    return @as(u32, 1) << @as(u5, @intCast(@intFromEnum(effect)));
}

pub const zone_resizable: u32 = 0x1;
pub const zone_global_brightness_only: u32 = 0x2;
pub const zone_host_frames: u32 = 0x4;

pub const plugin_opt_in: u32 = 0x1;
pub const plugin_sensor_source: u32 = 0x2;

pub const transport_hid: u32 = 0x1;
pub const transport_smbus: u32 = 0x2;
pub const transport_i2c: u32 = 0x4;
pub const transport_os: u32 = 0x8;

pub const mode_run: u32 = 1;
pub const mode_apply: u32 = 2;
pub const mode_list: u32 = 3;

pub const close_keep: u32 = 0;
pub const close_exit: u32 = 1;

pub const rescan_hotplug: u32 = 1;
pub const rescan_resume: u32 = 2;
pub const rescan_recover: u32 = 3;

pub const json_none: u32 = 0;
pub const json_null: u32 = 1;
pub const json_bool: u32 = 2;
pub const json_number: u32 = 3;
pub const json_string: u32 = 4;
pub const json_array: u32 = 5;
pub const json_object: u32 = 6;

pub const Rgb = extern struct {
    r: u8,
    g: u8,
    b: u8,

    pub const black: Rgb = .{ .r = 0, .g = 0, .b = 0 };

    pub fn eql(a: Rgb, b: Rgb) bool {
        return a.r == b.r and a.g == b.g and a.b == b.b;
    }
};

pub const Json = opaque {};

pub const Host = extern struct {
    struct_size: u32,
    abi_version: u32,
    ctx: ?*anyopaque,
    host_dir: ?[*:0]const u16,
    mode: u32,
    reserved: u32,
    log: *const fn (ctx: ?*anyopaque, level: u32, msg: ?[*]const u8, msg_len: usize) callconv(.c) void,
    now_ms: *const fn (ctx: ?*anyopaque) callconv(.c) u64,
    sensor_set: *const fn (ctx: ?*anyopaque, name: ?[*]const u8, name_len: usize, value: f64) callconv(.c) void,
    sensor_get: *const fn (ctx: ?*anyopaque, name: ?[*]const u8, name_len: usize, value: ?*f64, age_ms: ?*u64) callconv(.c) i32,
    json_type: *const fn (ctx: ?*anyopaque, node: ?*const Json) callconv(.c) u32,
    json_get: *const fn (ctx: ?*anyopaque, object: ?*const Json, key: ?[*]const u8, key_len: usize) callconv(.c) ?*const Json,
    json_len: *const fn (ctx: ?*anyopaque, node: ?*const Json) callconv(.c) u32,
    json_at: *const fn (ctx: ?*anyopaque, array: ?*const Json, index: u32) callconv(.c) ?*const Json,
    json_member: *const fn (ctx: ?*anyopaque, object: ?*const Json, index: u32, key: ?*?[*]const u8, key_len: ?*usize) callconv(.c) ?*const Json,
    json_number: *const fn (ctx: ?*anyopaque, node: ?*const Json, value: ?*f64) callconv(.c) i32,
    json_bool: *const fn (ctx: ?*anyopaque, node: ?*const Json, value: ?*i32) callconv(.c) i32,
    json_string: *const fn (ctx: ?*anyopaque, node: ?*const Json, text: ?*?[*]const u8, text_len: ?*usize) callconv(.c) i32,
};

pub const ZoneInfo = extern struct {
    struct_size: u32 = @sizeOf(ZoneInfo),
    flags: u32 = 0,
    name: ?[*:0]const u8,
    led_count: u32,
    max_leds: u32,
    hw_effects: u32 = 0,
    hw_max_colors: u32 = 0,
    led_x: ?[*]const u16 = null,
};

pub const DeviceInfo = extern struct {
    struct_size: u32 = @sizeOf(DeviceInfo),
    zone_count: u32,
    id: ?[*:0]const u8,
    name: ?[*:0]const u8,
    zones: ?[*]const *const ZoneInfo,
    max_fps: u32 = 0,
    reserved: u32 = 0,
};

pub const HwEffect = extern struct {
    struct_size: u32 = @sizeOf(HwEffect),
    effect: u32,
    speed: u32,
    brightness: u32,
    color_count: u32,
    reserved: u32 = 0,
    colors: ?[*]const Rgb,

    pub fn effectKind(self: *const HwEffect) ?Effect {
        return std.enums.fromInt(Effect, self.effect);
    }

    pub fn color(self: *const HwEffect, index: usize) Rgb {
        if (self.colors) |list| {
            if (index < self.color_count) return list[index];
        }
        return Rgb.black;
    }
};

pub const OpenFn = *const fn (host: *const Host, config: ?*const Json, instance: *?*anyopaque) callconv(.c) i32;
pub const CloseFn = *const fn (instance: ?*anyopaque, reason: u32) callconv(.c) void;
pub const DeviceCountFn = *const fn (instance: ?*anyopaque) callconv(.c) u32;
pub const DeviceInfoFn = *const fn (instance: ?*anyopaque, device_index: u32) callconv(.c) ?*const DeviceInfo;
pub const SetZoneSizeFn = *const fn (instance: ?*anyopaque, device_index: u32, zone_index: u32, led_count: u32) callconv(.c) i32;
pub const SetHwEffectFn = *const fn (instance: ?*anyopaque, device_index: u32, zone_index: u32, effect: *const HwEffect) callconv(.c) i32;
pub const SetLedsFn = *const fn (instance: ?*anyopaque, device_index: u32, zone_index: u32, colors: [*]const Rgb, count: u32) callconv(.c) i32;
pub const FlushFn = *const fn (instance: ?*anyopaque, device_index: u32) callconv(.c) i32;
pub const TickFn = *const fn (instance: ?*anyopaque, now_ms: u64) callconv(.c) i32;
pub const RescanFn = *const fn (instance: ?*anyopaque, reason: u32) callconv(.c) i32;
pub const PersistFn = *const fn (instance: ?*anyopaque, device_index: u32) callconv(.c) i32;

pub const Plugin = extern struct {
    struct_size: u32 = @sizeOf(Plugin),
    abi_version: u32 = abi_version,
    name: ?[*:0]const u8,
    version: ?[*:0]const u8,
    flags: u32 = 0,
    tick_interval_ms: u32 = 0,
    transports: u32 = 0,
    reserved: u32 = 0,
    open: ?OpenFn,
    close: ?CloseFn,
    device_count: ?DeviceCountFn,
    device_info: ?DeviceInfoFn,
    set_zone_size: ?SetZoneSizeFn = null,
    set_hw_effect: ?SetHwEffectFn = null,
    set_leds: ?SetLedsFn = null,
    flush: ?FlushFn = null,
    tick: ?TickFn = null,
    rescan: ?RescanFn = null,
    persist: ?PersistFn = null,
};

pub const EntryFn = *const fn (host_abi_version: u32) callconv(.c) ?*const Plugin;

pub const v1_size = struct {
    pub const host = 128;
    pub const zone_info = 40;
    pub const device_info = 40;
    pub const hw_effect = 32;
    pub const plugin = 128;
};

comptime {
    std.debug.assert(@sizeOf(Rgb) == 3);
    std.debug.assert(@sizeOf(Host) == v1_size.host);
    std.debug.assert(@offsetOf(Host, "ctx") == 8);
    std.debug.assert(@offsetOf(Host, "host_dir") == 16);
    std.debug.assert(@offsetOf(Host, "mode") == 24);
    std.debug.assert(@offsetOf(Host, "log") == 32);
    std.debug.assert(@offsetOf(Host, "json_string") == 120);
    std.debug.assert(@sizeOf(ZoneInfo) == v1_size.zone_info);
    std.debug.assert(@offsetOf(ZoneInfo, "name") == 8);
    std.debug.assert(@offsetOf(ZoneInfo, "led_count") == 16);
    std.debug.assert(@offsetOf(ZoneInfo, "led_x") == 32);
    std.debug.assert(@sizeOf(DeviceInfo) == v1_size.device_info);
    std.debug.assert(@offsetOf(DeviceInfo, "id") == 8);
    std.debug.assert(@offsetOf(DeviceInfo, "name") == 16);
    std.debug.assert(@offsetOf(DeviceInfo, "zones") == 24);
    std.debug.assert(@offsetOf(DeviceInfo, "max_fps") == 32);
    std.debug.assert(@sizeOf(HwEffect) == v1_size.hw_effect);
    std.debug.assert(@offsetOf(HwEffect, "colors") == 24);
    std.debug.assert(@sizeOf(Plugin) == v1_size.plugin);
    std.debug.assert(@offsetOf(Plugin, "flags") == 24);
    std.debug.assert(@offsetOf(Plugin, "tick_interval_ms") == 28);
    std.debug.assert(@offsetOf(Plugin, "transports") == 32);
    std.debug.assert(@offsetOf(Plugin, "open") == 40);
    std.debug.assert(@offsetOf(Plugin, "close") == 48);
    std.debug.assert(@offsetOf(Plugin, "rescan") == 112);
    std.debug.assert(@offsetOf(Plugin, "persist") == 120);
}
