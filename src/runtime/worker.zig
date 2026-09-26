const std = @import("std");
const sdk = @import("sdk");
const heap = @import("../heap.zig");
const log = @import("../diag/log.zig");
const loader = @import("../plugin_host/loader.zig");
const host_services = @import("../plugin_host/host_services.zig");
const validate = @import("../plugin_host/validate.zig");
const bindings = @import("bindings.zig");
const lighting_config = @import("../config/lighting_config.zig");
const generation = @import("../config/generation.zig");
const effects = @import("../lighting/effects.zig");
const persist_policy = @import("persist_policy.zig");
const clock_module = @import("clock.zig");

const abi = sdk.abi;
const win32 = sdk.win32;
const Rgb = abi.Rgb;

extern "kernel32" fn CancelWaitableTimer(timer: win32.HANDLE) callconv(.winapi) win32.BOOL;

pub const Mode = enum {
    run,
    apply,
    list,

    pub fn abiMode(self: Mode) u32 {
        return switch (self) {
            .run => abi.mode_run,
            .apply => abi.mode_apply,
            .list => abi.mode_list,
        };
    }
};

pub const OpenState = enum { idle, opened, failed, closed };

pub const Shared = struct {
    mode: Mode,
    clock: *const clock_module.Clock,
    logger: *log.Logger,
    persist_registry: *persist_policy.Registry,
    supervisor_event: win32.HANDLE,
};

const rescan_hotplug_bit: u8 = 1;
const rescan_resume_bit: u8 = 2;
const first_recover_delay_ms: u64 = 5_000;
const max_recover_delay_ms: u64 = 300_000;
const max_idle_wait_ms: u64 = 5_000;
const list_tick_interval_ms: u32 = 1000;
const overrun_log_interval_ms: u64 = 60_000;
const failed_flush_retry_ms: u64 = 1000;

const ZoneRuntime = struct {
    name: []const u8,
    flags: u32,
    led_count: u32,
    max_leds: u32,
    hw_effects: u32,
    hw_max_colors: u32,
    led_x: ?[]u16 = null,
    frame: []Rgb = &.{},
    applied: ?lighting_config.Resolution = null,
    engine: lighting_config.EngineChoice = .untouched,
    needs_send: bool = false,
    set_leds_failed: bool = false,
    pending_apply: bool = false,
    pending_changed: bool = false,

    fn shape(self: *const ZoneRuntime) lighting_config.ZoneShape {
        return .{ .flags = self.flags, .led_count = self.led_count, .max_leds = self.max_leds, .hw_effects = self.hw_effects, .hw_max_colors = self.hw_max_colors };
    }

    fn hostSpec(self: *const ZoneRuntime) ?*const lighting_config.Spec {
        if (self.engine != .host) return null;
        const applied = &(self.applied orelse return null);
        return switch (applied.*) {
            .spec => |*spec| spec,
            else => null,
        };
    }

    fn deinit(self: *ZoneRuntime) void {
        if (self.led_x) |positions| heap.allocator.free(positions);
        if (self.frame.len > 0) heap.allocator.free(self.frame);
        self.* = undefined;
    }

    fn adopt(self: *ZoneRuntime, meta: validate.ZoneMeta) void {
        self.flags = meta.flags;
        self.led_count = meta.led_count;
        self.max_leds = meta.max_leds;
        self.hw_effects = meta.hw_effects;
        self.hw_max_colors = meta.hw_max_colors;
        if (self.led_x) |positions| heap.allocator.free(positions);
        self.led_x = if (meta.led_x) |positions| heap.allocator.dupe(u16, positions) catch null else null;
        if (self.frame.len != meta.led_count) {
            if (self.frame.len > 0) heap.allocator.free(self.frame);
            self.frame = heap.allocator.alloc(Rgb, meta.led_count) catch &.{};
            @memset(self.frame, Rgb.black);
        }
    }
};

const DeviceRuntime = struct {
    id: []const u8,
    name: []const u8,
    max_fps: u32,
    zones: []ZoneRuntime,
    next_frame_ms: ?u64 = null,
    last_overrun_log_ms: u64 = 0,
    persist_state: ?*persist_policy.State = null,
    label: []const u8 = "",
};

pub const Worker = struct {
    shared: *Shared,
    plugin: *const loader.Plugin,
    context: *host_services.Context,
    thread: ?win32.HANDLE = null,
    mailbox_event: win32.HANDLE,
    timer: win32.HANDLE,

    lock: win32.SRWLOCK = .{},
    pending_close: ?u32 = null,
    pending_open: ?*generation.ConfigGeneration = null,
    pending_rescan: u8 = 0,
    pending_binding: ?*bindings.BindingGeneration = null,
    pending_exit: bool = false,
    reported_devices: ?*bindings.DeviceSet = null,
    has_report: bool = false,
    open_state: OpenState = .idle,
    applied_binding_serial: u64 = 0,
    sensor_ticks: u32 = 0,
    exited: bool = false,

    call_started_ms: std.atomic.Value(u64) = .init(0),
    call_name: std.atomic.Value(usize) = .init(0),
    stall_warned: std.atomic.Value(bool) = .init(false),

    instance: ?*anyopaque = null,
    devices: ?*bindings.DeviceSet = null,
    device_serial: u64 = 0,
    binding: ?*bindings.BindingGeneration = null,
    runtime: []DeviceRuntime = &.{},
    runtime_arena: std.heap.ArenaAllocator = undefined,
    next_tick_ms: ?u64 = null,
    lost: bool = false,
    success_in_pass: bool = false,
    recover_at_ms: u64 = 0,
    recover_delay_ms: u64 = 0,
    apply_frames_pending: bool = false,
    last_error_log_ms: u64 = 0,

    pub fn init(self: *Worker, shared: *Shared, plugin: *const loader.Plugin, context: *host_services.Context) !void {
        const mailbox = win32.CreateEventW(null, win32.FALSE, win32.FALSE, null) orelse return error.EventCreationFailed;
        const timer = win32.CreateWaitableTimerExW(null, null, win32.CREATE_WAITABLE_TIMER_HIGH_RESOLUTION, win32.TIMER_ALL_ACCESS) orelse
            win32.CreateWaitableTimerExW(null, null, 0, win32.TIMER_ALL_ACCESS) orelse return error.TimerCreationFailed;
        self.* = .{ .shared = shared, .plugin = plugin, .context = context, .mailbox_event = mailbox, .timer = timer };
        self.runtime_arena = std.heap.ArenaAllocator.init(heap.allocator);
    }

    pub fn start(self: *Worker) !void {
        self.thread = win32.CreateThread(null, 1024 * 1024, threadMain, self, 0, null) orelse return error.ThreadCreationFailed;
    }

    fn source(self: *const Worker) []const u8 {
        return self.plugin.name;
    }

    fn logMessage(self: *Worker, level: log.Level, comptime format: []const u8, args: anytype) void {
        self.shared.logger.log(level, self.plugin.name, format, args);
    }

    pub fn postOpen(self: *Worker, config: *generation.ConfigGeneration) void {
        win32.AcquireSRWLockExclusive(&self.lock);
        if (self.pending_open) |previous| previous.release();
        self.pending_open = config.retain();
        win32.ReleaseSRWLockExclusive(&self.lock);
        _ = win32.SetEvent(self.mailbox_event);
    }

    pub fn postClose(self: *Worker, reason: u32) void {
        win32.AcquireSRWLockExclusive(&self.lock);
        if (self.pending_open) |previous| {
            previous.release();
            self.pending_open = null;
        }
        if (self.pending_binding) |previous| {
            previous.destroy();
            self.pending_binding = null;
        }
        self.pending_close = reason;
        win32.ReleaseSRWLockExclusive(&self.lock);
        _ = win32.SetEvent(self.mailbox_event);
    }

    pub fn postRescan(self: *Worker, reason: u32) void {
        win32.AcquireSRWLockExclusive(&self.lock);
        self.pending_rescan |= if (reason == abi.rescan_resume) rescan_resume_bit else rescan_hotplug_bit;
        win32.ReleaseSRWLockExclusive(&self.lock);
        _ = win32.SetEvent(self.mailbox_event);
    }

    pub fn postBinding(self: *Worker, binding: *bindings.BindingGeneration) void {
        win32.AcquireSRWLockExclusive(&self.lock);
        if (self.pending_binding) |previous| previous.destroy();
        self.pending_binding = binding;
        win32.ReleaseSRWLockExclusive(&self.lock);
        _ = win32.SetEvent(self.mailbox_event);
    }

    pub fn postExit(self: *Worker) void {
        win32.AcquireSRWLockExclusive(&self.lock);
        self.pending_exit = true;
        win32.ReleaseSRWLockExclusive(&self.lock);
        _ = win32.SetEvent(self.mailbox_event);
    }

    const Report = struct {
        devices: ?*bindings.DeviceSet,
        open_state: OpenState,
        applied_binding_serial: u64,
        sensor_ticks: u32,
        has_devices: bool,
        exited: bool,
    };

    pub fn takeReport(self: *Worker) Report {
        win32.AcquireSRWLockExclusive(&self.lock);
        defer win32.ReleaseSRWLockExclusive(&self.lock);
        const report = Report{
            .devices = self.reported_devices,
            .has_devices = self.has_report,
            .open_state = self.open_state,
            .applied_binding_serial = self.applied_binding_serial,
            .sensor_ticks = self.sensor_ticks,
            .exited = self.exited,
        };
        self.reported_devices = null;
        self.has_report = false;
        return report;
    }

    fn publishDevices(self: *Worker, devices: ?*bindings.DeviceSet, state: OpenState) void {
        win32.AcquireSRWLockExclusive(&self.lock);
        if (self.reported_devices) |previous| previous.release();
        self.reported_devices = if (devices) |set| set.retain() else null;
        self.has_report = true;
        self.open_state = state;
        win32.ReleaseSRWLockExclusive(&self.lock);
        _ = win32.SetEvent(self.shared.supervisor_event);
    }

    fn publishProgress(self: *Worker, applied_serial: ?u64, sensor_ticks: ?u32) void {
        win32.AcquireSRWLockExclusive(&self.lock);
        if (applied_serial) |serial| self.applied_binding_serial = serial;
        if (sensor_ticks) |ticks| self.sensor_ticks = ticks;
        win32.ReleaseSRWLockExclusive(&self.lock);
        _ = win32.SetEvent(self.shared.supervisor_event);
    }

    pub fn stalledCall(self: *Worker, now_ms: u64) ?struct { name: []const u8, elapsed_ms: u64 } {
        const started = self.call_started_ms.load(.acquire);
        if (started == 0 or now_ms < started + 2000) return null;
        if (self.stall_warned.swap(true, .acq_rel)) return null;
        const name_pointer = self.call_name.load(.acquire);
        const name: []const u8 = if (name_pointer == 0) "call" else std.mem.span(@as([*:0]const u8, @ptrFromInt(name_pointer)));
        return .{ .name = name, .elapsed_ms = now_ms - started };
    }

    fn beginCall(self: *Worker, comptime name: [:0]const u8) void {
        self.call_name.store(@intFromPtr(name.ptr), .release);
        self.call_started_ms.store(@max(self.shared.clock.nowMs(), 1), .release);
    }

    fn endCall(self: *Worker) void {
        const started = self.call_started_ms.swap(0, .acq_rel);
        if (self.stall_warned.swap(false, .acq_rel)) {
            const name_pointer = self.call_name.load(.acquire);
            const name: []const u8 = if (name_pointer == 0) "call" else std.mem.span(@as([*:0]const u8, @ptrFromInt(name_pointer)));
            self.logMessage(.warn, "{s} returned after {d} ms", .{ name, self.shared.clock.nowMs() -| started });
        }
    }

    fn threadMain(parameter: ?*anyopaque) callconv(.winapi) u32 {
        const self: *Worker = @ptrCast(@alignCast(parameter.?));
        self.loop();
        return 0;
    }

    fn loop(self: *Worker) void {
        while (true) {
            const handles = [_]win32.HANDLE{ self.mailbox_event, self.timer };
            _ = win32.WaitForMultipleObjects(handles.len, &handles, win32.FALSE, win32.INFINITE);
            win32.AcquireSRWLockExclusive(&self.lock);
            const close_reason = self.pending_close;
            const open_config = self.pending_open;
            const rescan_bits = self.pending_rescan;
            const binding = self.pending_binding;
            const exit_requested = self.pending_exit;
            self.pending_close = null;
            self.pending_open = null;
            self.pending_rescan = 0;
            self.pending_binding = null;
            win32.ReleaseSRWLockExclusive(&self.lock);

            if (close_reason) |reason| self.closeInstance(reason);
            if (open_config) |config| {
                self.openInstance(config);
                config.release();
            }
            if (rescan_bits != 0) self.handleRescans(rescan_bits);
            if (binding) |new_binding| self.acceptBinding(new_binding);
            if (exit_requested) {
                if (self.instance != null) self.closeInstance(if (self.shared.mode == .run) abi.close_exit else abi.close_keep);
                win32.AcquireSRWLockExclusive(&self.lock);
                self.exited = true;
                win32.ReleaseSRWLockExclusive(&self.lock);
                _ = win32.SetEvent(self.shared.supervisor_event);
                return;
            }
            self.service();
            self.settleBackoff();
            self.armTimer();
        }
    }

    fn openInstance(self: *Worker, config: *generation.ConfigGeneration) void {
        if (self.instance != null) self.closeInstance(abi.close_keep);
        const table = &self.plugin.table;
        const plugin_config = config.settings.pluginConfig(self.plugin.name);
        var instance: ?*anyopaque = null;
        self.beginCall("open");
        const status = table.open.?(&self.context.host, @ptrCast(plugin_config), &instance);
        self.endCall();
        if (status != abi.status_ok) {
            self.logMessage(.err, "open failed ({s}); the plugin stays inactive until its configuration changes", .{statusName(status)});
            self.publishDevices(null, .failed);
            return;
        }
        self.instance = instance;
        self.lost = false;
        self.recover_delay_ms = 0;
        self.next_tick_ms = if (self.plugin.tickInterval() > 0) self.shared.clock.nowMs() else null;
        self.publishProgress(null, 0);
        self.refreshDevices(true);
    }

    fn closeInstance(self: *Worker, reason: u32) void {
        const instance = self.instance orelse return;
        if (reason == abi.close_exit and self.shared.mode == .run) self.persistBeforeExit();
        self.beginCall("close");
        self.plugin.table.close.?(instance, reason);
        self.endCall();
        self.instance = null;
        self.clearRuntime();
        if (self.devices) |devices| devices.release();
        self.devices = null;
        if (self.binding) |binding| binding.destroy();
        self.binding = null;
        self.next_tick_ms = null;
        self.lost = false;
        self.publishDevices(null, .closed);
    }

    fn clearRuntime(self: *Worker) void {
        for (self.runtime) |*device| {
            for (device.zones) |*zone| zone.deinit();
        }
        self.runtime = &.{};
        _ = self.runtime_arena.reset(.free_all);
    }

    fn fetchDevices(self: *Worker) ?*bindings.DeviceSet {
        const instance = self.instance orelse return null;
        const table = &self.plugin.table;
        self.device_serial += 1;
        const set = bindings.DeviceSet.create(self.device_serial) catch return null;
        const arena = set.arena();
        self.beginCall("device_count");
        const reported_count = table.device_count.?(instance);
        self.endCall();
        if (reported_count > validate.max_devices) self.logMessage(.warn, "reports {d} devices; only the first 64 are used", .{reported_count});
        const count = @min(reported_count, validate.max_devices);
        var devices: std.ArrayList(validate.DeviceMeta) = .empty;
        var index: u32 = 0;
        while (index < count) : (index += 1) {
            self.beginCall("device_info");
            const info = table.device_info.?(instance, index);
            self.endCall();
            const outcome = validate.copyDevice(arena, index, info, self.plugin.capabilities()) catch break;
            switch (outcome) {
                .rejected => |reason| self.logMessage(.warn, "device {d} rejected: {s}", .{ index, reason }),
                .device => |device| {
                    var duplicate = false;
                    for (devices.items) |existing| {
                        if (std.mem.eql(u8, existing.id, device.id)) duplicate = true;
                    }
                    if (duplicate) {
                        self.logMessage(.warn, "device {d} rejected: id \"{s}\" is used twice by this plugin", .{ index, device.id });
                    } else {
                        devices.append(arena, device) catch break;
                    }
                },
            }
        }
        set.devices = devices.items;
        return set;
    }

    fn refreshDevices(self: *Worker, initial: bool) void {
        const fresh = self.fetchDevices() orelse return;
        if (!initial) {
            if (self.devices) |current| {
                if (current.sameTopology(fresh) and self.binding != null) {
                    for (self.runtime, 0..) |*device, device_index| {
                        for (device.zones, 0..) |*zone, zone_index| zone.adopt(fresh.devices[device_index].zones[zone_index]);
                    }
                    fresh.release();
                    self.applyBinding(true);
                    return;
                }
            }
        }
        self.clearRuntime();
        if (self.devices) |previous| previous.release();
        if (self.binding) |binding| binding.destroy();
        self.binding = null;
        self.devices = fresh;
        self.buildRuntime(fresh);
        self.publishDevices(fresh, .opened);
    }

    fn buildRuntime(self: *Worker, set: *bindings.DeviceSet) void {
        const arena = self.runtime_arena.allocator();
        const runtime = arena.alloc(DeviceRuntime, set.devices.len) catch return;
        for (runtime, set.devices) |*device, meta| {
            const zones = arena.alloc(ZoneRuntime, meta.zones.len) catch return;
            for (zones, meta.zones) |*zone, zone_meta| {
                zone.* = .{ .name = zone_meta.name, .flags = 0, .led_count = 0, .max_leds = 0, .hw_effects = 0, .hw_max_colors = 0 };
                zone.adopt(zone_meta);
            }
            device.* = .{ .id = meta.id, .name = meta.name, .max_fps = meta.max_fps, .zones = zones };
        }
        self.runtime = runtime;
    }

    fn handleRescans(self: *Worker, bits: u8) void {
        const instance = self.instance orelse return;
        const rescan = self.plugin.table.rescan orelse {
            if (bits & rescan_resume_bit != 0) self.applyBinding(true);
            return;
        };
        if (bits & rescan_resume_bit != 0) {
            self.beginCall("rescan(RESUME)");
            const status = rescan(instance, abi.rescan_resume);
            self.endCall();
            self.logMessage(.info, "resumed from sleep; devices re-initialized ({s})", .{statusName(status)});
            if (status == abi.status_device_lost) {
                self.markLost();
            } else if (status >= 0) {
                self.lost = false;
                self.refreshDevices(false);
            }
        }
        if (bits & rescan_hotplug_bit != 0 and self.plugin.usesHid()) {
            self.beginCall("rescan(HOTPLUG)");
            const status = rescan(instance, abi.rescan_hotplug);
            self.endCall();
            if (status == abi.rescan_changed) {
                self.logMessage(.info, "device set changed after a hotplug event", .{});
                self.refreshDevices(false);
            } else if (status < 0) {
                self.logMessage(.debug, "rescan(HOTPLUG) returned {s}", .{statusName(status)});
            }
        }
    }

    fn acceptBinding(self: *Worker, binding: *bindings.BindingGeneration) void {
        const devices = self.devices orelse {
            binding.destroy();
            return;
        };
        if (binding.device_set_serial != devices.serial or binding.devices.len != self.runtime.len) {
            binding.destroy();
            return;
        }
        const previous = self.binding;
        self.binding = binding;
        self.applyBinding(false);
        if (previous) |old| old.destroy();
    }

    fn applyBinding(self: *Worker, force: bool) void {
        const binding = self.binding orelse return;
        if (self.instance == null) return;
        const now = self.shared.clock.nowMs();
        for (self.runtime, 0..) |*device, device_index| {
            const plan = binding.devices[device_index];
            device.label = plan.key;
            if (binding.persist_enabled and self.plugin.table.persist != null and self.shared.mode == .run) {
                device.persist_state = self.shared.persist_registry.get(plan.persist_key);
            } else {
                device.persist_state = null;
            }
            for (device.zones, 0..) |*zone, zone_index| {
                const resolution = plan.zones[zone_index];
                const unchanged = if (zone.applied) |applied| bindings.resolutionEql(applied, resolution) else false;
                zone.pending_apply = force or !unchanged;
                zone.pending_changed = !unchanged;
                zone.applied = resolution;
            }
        }
        for (self.runtime, 0..) |*device, device_index| {
            const plan = binding.devices[device_index];
            var has_hardware_zone = false;
            for (device.zones, 0..) |*zone, zone_index| {
                if (zone.pending_apply) {
                    zone.pending_apply = false;
                    self.applyZone(device, @intCast(device_index), @intCast(zone_index), plan.zones[zone_index], zone.pending_changed);
                    if (self.lost) return;
                }
                if (zone.engine == .hardware) has_hardware_zone = true;
            }
            if (!has_hardware_zone) {
                if (device.persist_state) |state| state.clear();
            }
            device.next_frame_ms = now;
        }
        if (self.shared.mode == .apply) self.apply_frames_pending = true;
        self.publishProgress(if (self.shared.mode == .apply) null else binding.serial, null);
    }

    fn applyZone(self: *Worker, device: *DeviceRuntime, device_index: u32, zone_index: u32, resolution: lighting_config.Resolution, changed: bool) void {
        const zone = &device.zones[zone_index];
        zone.applied = resolution;
        zone.needs_send = false;
        const spec = switch (resolution) {
            .spec => |*value| value,
            else => {
                zone.engine = .untouched;
                self.logMessage(.debug, "{s}.{s}: left unchanged", .{ device.label, zone.name });
                return;
            },
        };
        if (spec.leds) |requested| {
            if (zone.flags & abi.zone_resizable != 0 and requested != zone.led_count) self.resizeZone(device, device_index, zone_index, requested);
        }
        const selection = lighting_config.selectEngine(spec, zone.shape());
        if (selection.reverse_ignored) self.logMessage(.warn, "{s}.{s}: reverse only applies to rainbow, gradient and static with led_colors; ignored", .{ device.label, zone.name });
        switch (selection.fallback) {
            .none => {},
            .host_instead_of_hardware => self.logMessage(.warn, "{s}.{s}: the hardware cannot run {s} with these settings; using host frames", .{ device.label, zone.name, @tagName(spec.effect) }),
            .hardware_instead_of_host => self.logMessage(.warn, "{s}.{s}: the zone does not accept host frames; using the hardware effect", .{ device.label, zone.name }),
            .no_engine => self.logMessage(.warn, "{s}.{s}: neither the hardware nor host frames can show {s}; zone left unchanged", .{ device.label, zone.name, @tagName(spec.effect) }),
            .off_unsupported => self.logMessage(.warn, "{s}.{s}: the zone cannot be turned off; left unchanged", .{ device.label, zone.name }),
        }
        zone.engine = selection.choice;
        switch (selection.choice) {
            .untouched => {},
            .host => {
                zone.needs_send = true;
                if (self.shared.mode == .apply and effects.isAnimated(spec.effect)) self.logMessage(.warn, "{s}.{s}: {s} is animated by the host; apply shows a single frame (use run)", .{ device.label, zone.name, @tagName(spec.effect) });
            },
            .hardware => {
                const color_count: u32 = if (spec.effect == .off) 0 else @intCast(@min(spec.colors.len, @max(zone.hw_max_colors, 1)));
                const effect = abi.HwEffect{
                    .effect = @intFromEnum(spec.effect),
                    .speed = spec.speed,
                    .brightness = spec.brightness,
                    .color_count = color_count,
                    .colors = if (color_count > 0) spec.colors.ptr else null,
                };
                self.beginCall("set_hw_effect");
                const status = self.plugin.table.set_hw_effect.?(self.instance, device_index, zone_index, &effect);
                self.endCall();
                if (status == abi.status_ok) {
                    self.noteSuccess();
                    if (changed) {
                        if (device.persist_state) |state| state.markDirty(self.shared.clock.nowMs());
                    }
                } else {
                    zone.engine = .untouched;
                    self.logMessage(.warn, "{s}.{s}: set_hw_effect({s}) failed ({s})", .{ device.label, zone.name, @tagName(spec.effect), statusName(status) });
                    if (status == abi.status_device_lost) self.markLost();
                    return;
                }
            },
        }
        self.logMessage(.info, "{s}.{s}: {s} via {s} (speed {d}, brightness {d}, {d} LEDs)", .{ device.label, zone.name, @tagName(spec.effect), engineName(zone.engine), spec.speed, spec.brightness, zone.led_count });
    }

    fn resizeZone(self: *Worker, device: *DeviceRuntime, device_index: u32, zone_index: u32, requested: u32) void {
        const set_zone_size = self.plugin.table.set_zone_size orelse return;
        const zone = &device.zones[zone_index];
        const count = @min(requested, zone.max_leds);
        self.beginCall("set_zone_size");
        const status = set_zone_size(self.instance, device_index, zone_index, count);
        self.endCall();
        if (status != abi.status_ok) {
            self.logMessage(.warn, "{s}.{s}: set_zone_size({d}) failed ({s})", .{ device.label, zone.name, count, statusName(status) });
            if (status == abi.status_device_lost) self.markLost();
            return;
        }
        var scratch = std.heap.ArenaAllocator.init(heap.allocator);
        defer scratch.deinit();
        self.beginCall("device_info");
        const info = self.plugin.table.device_info.?(self.instance, device_index);
        self.endCall();
        const outcome = validate.copyDevice(scratch.allocator(), device_index, info, self.plugin.capabilities()) catch return;
        switch (outcome) {
            .rejected => |reason| self.logMessage(.warn, "{s}: device_info after resizing was rejected: {s}", .{ device.label, reason }),
            .device => |meta| {
                if (meta.zones.len != device.zones.len) return;
                for (device.zones, meta.zones) |*runtime_zone, zone_meta| runtime_zone.adopt(zone_meta);
                self.logMessage(.info, "{s}.{s}: resized to {d} LEDs", .{ device.label, zone.name, zone.led_count });
            },
        }
    }

    fn markLost(self: *Worker) void {
        const now = self.shared.clock.nowMs();
        self.lost = true;
        self.success_in_pass = false;
        self.recover_delay_ms = if (self.recover_delay_ms == 0) first_recover_delay_ms else @min(self.recover_delay_ms * 2, max_recover_delay_ms);
        self.recover_at_ms = now + self.recover_delay_ms;
        self.logMessage(.warn, "device lost; retrying in {d} s", .{self.recover_delay_ms / 1000});
    }

    fn recover(self: *Worker) void {
        const instance = self.instance orelse return;
        const rescan = self.plugin.table.rescan orelse {
            self.lost = false;
            self.applyBinding(true);
            return;
        };
        self.beginCall("rescan(RECOVER)");
        const status = rescan(instance, abi.rescan_recover);
        self.endCall();
        if (status < 0) {
            self.logMessage(.debug, "rescan(RECOVER) returned {s}", .{statusName(status)});
            self.markLost();
            return;
        }
        self.lost = false;
        self.logMessage(.info, "recovered", .{});
        self.refreshDevices(false);
    }

    fn noteSuccess(self: *Worker) void {
        self.success_in_pass = true;
    }

    fn settleBackoff(self: *Worker) void {
        if (self.success_in_pass and !self.lost) self.recover_delay_ms = 0;
        self.success_in_pass = false;
    }

    fn logErrorRateLimited(self: *Worker, comptime format: []const u8, args: anytype) void {
        const now = self.shared.clock.nowMs();
        if (self.last_error_log_ms != 0 and now < self.last_error_log_ms + 60_000) return;
        self.last_error_log_ms = @max(now, 1);
        self.logMessage(.warn, format, args);
    }

    fn service(self: *Worker) void {
        if (self.instance == null) return;
        const now = self.shared.clock.nowMs();
        if (self.lost) {
            if (now >= self.recover_at_ms) self.recover();
            return;
        }
        self.serviceTick(now);
        if (self.lost) return;
        self.serviceFrames(now);
        if (self.lost) return;
        self.servicePersist(now);
    }

    fn tickAllowed(self: *const Worker) bool {
        if (self.plugin.table.tick == null or self.plugin.tickInterval() == 0) return false;
        return switch (self.shared.mode) {
            .run => true,
            .apply => self.plugin.isSensorSource(),
            .list => self.plugin.isSensorSource() and self.sensor_ticks < 2,
        };
    }

    fn serviceTick(self: *Worker, now: u64) void {
        if (!self.tickAllowed()) return;
        const due = self.next_tick_ms orelse return;
        if (now < due) return;
        const interval: u64 = if (self.shared.mode == .list) list_tick_interval_ms else self.plugin.tickInterval();
        self.beginCall("tick");
        const status = self.plugin.table.tick.?(self.instance, now);
        self.endCall();
        self.next_tick_ms = if (due + interval > now) due + interval else now + interval;
        if (self.shared.mode == .list) self.publishProgress(null, self.sensor_ticks + 1);
        if (status == abi.status_ok) {
            self.noteSuccess();
        } else if (status == abi.status_device_lost) {
            self.markLost();
        } else {
            self.logErrorRateLimited("tick returned {s}", .{statusName(status)});
        }
    }

    fn serviceFrames(self: *Worker, now: u64) void {
        if (self.shared.mode == .list) return;
        const binding = self.binding orelse return;
        const set_leds = self.plugin.table.set_leds;
        for (self.runtime, 0..) |*device, device_index| {
            const due = device.next_frame_ms orelse continue;
            if (now < due) continue;
            var sent = false;
            var animated = false;
            var retry_needed = false;
            for (device.zones, 0..) |*zone, zone_index| {
                const spec = zone.hostSpec() orelse continue;
                const moving = effects.isAnimated(spec.effect) and self.shared.mode == .run;
                if (moving) animated = true;
                if (!moving and !zone.needs_send) continue;
                const send = set_leds orelse continue;
                if (zone.frame.len == 0) {
                    zone.needs_send = false;
                    continue;
                }
                effects.render(spec, zone.led_x, now, zone.frame);
                self.beginCall("set_leds");
                const status = send(self.instance, @intCast(device_index), @intCast(zone_index), zone.frame.ptr, @intCast(zone.frame.len));
                self.endCall();
                if (status == abi.status_device_lost) {
                    self.markLost();
                    return;
                }
                if (status != abi.status_ok) {
                    if (!zone.set_leds_failed) self.logMessage(.warn, "{s}.{s}: set_leds failed ({s})", .{ device.label, zone.name, statusName(status) });
                    zone.set_leds_failed = true;
                    if (status == abi.status_busy) {
                        retry_needed = true;
                    } else {
                        zone.needs_send = false;
                    }
                    continue;
                }
                zone.set_leds_failed = false;
                zone.needs_send = false;
                sent = true;
            }
            var flush_failed = retry_needed;
            if (sent) {
                if (self.plugin.table.flush) |flush| {
                    self.beginCall("flush");
                    const status = flush(self.instance, @intCast(device_index));
                    self.endCall();
                    if (status == abi.status_device_lost) {
                        self.markLost();
                        return;
                    }
                    if (status == abi.status_ok) {
                        self.noteSuccess();
                    } else {
                        flush_failed = true;
                        self.logErrorRateLimited("{s}: flush returned {s}; retrying", .{ device.label, statusName(status) });
                        for (device.zones) |*zone| {
                            if (zone.hostSpec() != null) zone.needs_send = true;
                        }
                    }
                }
            }
            if (animated) {
                const interval: u64 = bindings.frameIntervalMs(binding.frame_rate, device.max_fps);
                var next = due + interval;
                if (next <= now) {
                    if (now >= device.last_overrun_log_ms + overrun_log_interval_ms) {
                        device.last_overrun_log_ms = now;
                        self.logMessage(.debug, "{s}: frames dropped because rendering fell behind", .{device.label});
                    }
                    next = now + interval;
                }
                device.next_frame_ms = next;
            } else if (flush_failed) {
                device.next_frame_ms = now + failed_flush_retry_ms;
            } else {
                device.next_frame_ms = null;
            }
        }
        if (self.apply_frames_pending) {
            self.apply_frames_pending = false;
            self.publishProgress(binding.serial, null);
        }
    }

    fn servicePersist(self: *Worker, now: u64) void {
        if (self.shared.mode != .run) return;
        const persist = self.plugin.table.persist orelse return;
        for (self.runtime, 0..) |*device, device_index| {
            const state = device.persist_state orelse continue;
            if (state.takeUnsavedWarning(now)) {
                self.logMessage(.warn, "{s}: settings have not been saved to the device for 10 minutes ({s})", .{ device.label, @tagName(state.last_failure) });
            }
            const eligible = state.eligibleAt() orelse continue;
            if (now < eligible) continue;
            self.beginCall("persist");
            const status = persist(self.instance, @intCast(device_index));
            self.endCall();
            state.recordResult(status, now);
            switch (status) {
                abi.status_ok => {
                    self.noteSuccess();
                    self.logMessage(.info, "{s}: saved the current settings to device memory", .{device.label});
                },
                abi.status_busy => self.logMessage(.debug, "{s}: persist deferred because the device is busy", .{device.label}),
                else => self.logMessage(.warn, "{s}: persist failed ({s}); retrying in 60 s", .{ device.label, statusName(status) }),
            }
            if (status == abi.status_device_lost) {
                self.markLost();
                return;
            }
        }
    }

    fn persistBeforeExit(self: *Worker) void {
        const persist = self.plugin.table.persist orelse return;
        const now = self.shared.clock.nowMs();
        for (self.runtime, 0..) |*device, device_index| {
            const state = device.persist_state orelse continue;
            switch (persist_policy.finalDecision(state, now)) {
                .nothing => {},
                .skipped => |reason| self.logMessage(.info, "final state of {s} not saved ({s})", .{ device.label, reason }),
                .persist => {
                    self.beginCall("persist");
                    const status = persist(self.instance, @intCast(device_index));
                    self.endCall();
                    state.recordResult(status, now);
                    if (status == abi.status_ok) {
                        self.logMessage(.info, "{s}: saved the final settings to device memory", .{device.label});
                    } else {
                        self.logMessage(.info, "final state of {s} not saved ({s})", .{ device.label, statusName(status) });
                    }
                },
            }
        }
    }

    fn armTimer(self: *Worker) void {
        const now = self.shared.clock.nowMs();
        var next: u64 = now + max_idle_wait_ms;
        if (self.instance != null) {
            if (self.lost) {
                next = @min(next, self.recover_at_ms);
            } else {
                if (self.tickAllowed()) {
                    if (self.next_tick_ms) |due| next = @min(next, due);
                }
                if (self.shared.mode != .list) {
                    for (self.runtime) |*device| {
                        if (device.next_frame_ms) |due| next = @min(next, due);
                        if (self.shared.mode == .run) {
                            if (device.persist_state) |state| {
                                if (state.eligibleAt()) |eligible| next = @min(next, eligible);
                            }
                        }
                    }
                }
            }
        }
        const wait_ms = if (next > now) next - now else 0;
        const due_time: i64 = -@as(i64, @intCast(@max(wait_ms, 1) * 10_000));
        _ = win32.SetWaitableTimer(self.timer, &due_time, 0, null, null, win32.FALSE);
    }

    pub fn wait(self: *Worker, timeout_ms: u32) bool {
        const thread = self.thread orelse return true;
        return win32.WaitForSingleObject(thread, timeout_ms) == win32.WAIT_OBJECT_0;
    }
};

fn engineName(engine: lighting_config.EngineChoice) []const u8 {
    return switch (engine) {
        .untouched => "none",
        .hardware => "hardware",
        .host => "host frames",
    };
}

fn statusName(status: i32) []const u8 {
    return switch (status) {
        abi.status_ok => "OK",
        abi.rescan_changed => "CHANGED",
        abi.status_fail => "E_FAIL",
        abi.status_unsupported => "E_UNSUPPORTED",
        abi.status_argument => "E_ARGUMENT",
        abi.status_device_lost => "E_DEVICE_LOST",
        abi.status_access => "E_ACCESS",
        abi.status_busy => "E_BUSY",
        else => "unknown status",
    };
}

test "status names cover every ABI status" {
    try std.testing.expectEqualStrings("E_BUSY", statusName(abi.status_busy));
    try std.testing.expectEqualStrings("CHANGED", statusName(abi.rescan_changed));
    try std.testing.expectEqualStrings("unknown status", statusName(-99));
}
