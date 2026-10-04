const std = @import("std");
const formatting = @import("../diag/format.zig");
const sdk = @import("sdk");
const heap = @import("../heap.zig");
const log = @import("../diag/log.zig");
const console = @import("../diag/console.zig");
const loader = @import("../plugin_host/loader.zig");
const host_services = @import("../plugin_host/host_services.zig");
const generation = @import("../config/generation.zig");
const lighting_config = @import("../config/lighting_config.zig");
const suggest = @import("../config/suggest.zig");
const Diagnostics = @import("../config/diagnostics.zig").Diagnostics;
const bindings = @import("bindings.zig");
const worker_module = @import("worker.zig");
const sensors = @import("sensors.zig");
const clock_module = @import("clock.zig");
const persist_policy = @import("persist_policy.zig");
const safe_open = @import("../security/safe_open.zig");

const abi = sdk.abi;
const win32 = sdk.win32;

pub const Mode = worker_module.Mode;

const Environment = struct {
    mode: Mode,
    logger: *log.Logger,
    clock: *const clock_module.Clock,
    sensor_table: *sensors.SensorTable,
    host_dir: [*:0]const u16,
    sources: *const generation.Sources,
    stop_event: win32.HANDLE,
    plugins: []loader.Plugin,
    failures: []const loader.Failure,
    config: *generation.ConfigGeneration,
};

const PluginState = struct {
    enabled: bool = false,
    hash: u64 = 0,
    devices: ?*bindings.DeviceSet = null,
    aliases: []const []const u8 = &.{},
    open_state: worker_module.OpenState = .idle,
    applied_serial: u64 = 0,
    posted_serial: u64 = 0,
    sensor_ticks: u32 = 0,
    exited: bool = false,
};

const source = "host";

pub const Supervisor = struct {
    env: Environment,
    services: host_services.Shared,
    worker_shared: worker_module.Shared,
    persist_registry: persist_policy.Registry,
    supervisor_event: win32.HANDLE,
    contexts: []host_services.Context,
    workers: []worker_module.Worker,
    states: []PluginState,
    config: *generation.ConfigGeneration,
    epoch_arena: std.heap.ArenaAllocator,
    alias_arena: std.heap.ArenaAllocator,
    diagnostics: Diagnostics = undefined,
    logged_diagnostics: usize = 0,
    binding_serial: u64 = 0,
    config_serial: u64 = 1,
    topology_changed: bool = false,
    stamps: [2]generation.Stamp = .{ .{}, .{} },
    reload_pending: bool = false,
    change_seen_ms: u64 = 0,
    hid_hash: ?u64 = null,
    resume_detector: clock_module.ResumeDetector = undefined,

    pub fn create(env: Environment) !*Supervisor {
        const self = try heap.allocator.create(Supervisor);
        const event = win32.CreateEventW(null, win32.FALSE, win32.FALSE, null) orelse return error.EventCreationFailed;
        const count = env.plugins.len;
        self.* = .{
            .env = env,
            .services = .{ .logger = env.logger, .sensor_table = env.sensor_table, .clock = env.clock },
            .worker_shared = undefined,
            .persist_registry = .{ .allocator = heap.allocator },
            .supervisor_event = event,
            .contexts = try heap.allocator.alloc(host_services.Context, count),
            .workers = try heap.allocator.alloc(worker_module.Worker, count),
            .states = try heap.allocator.alloc(PluginState, count),
            .config = env.config.retain(),
            .epoch_arena = std.heap.ArenaAllocator.init(heap.allocator),
            .alias_arena = std.heap.ArenaAllocator.init(heap.allocator),
        };
        self.worker_shared = .{ .mode = env.mode, .clock = env.clock, .logger = env.logger, .persist_registry = &self.persist_registry, .supervisor_event = event };
        self.diagnostics = Diagnostics.init(self.epoch_arena.allocator());
        self.resume_detector = clock_module.ResumeDetector.init();
        self.stamps = .{ generation.stampFor(env.sources.base_file, env.sources.elevated), generation.stampFor(env.sources.user_file, env.sources.elevated) };
        for (env.plugins, 0..) |*plugin, index| {
            self.states[index] = .{};
            self.contexts[index].init(&self.services, @intCast(index + 1), plugin.name, env.host_dir, env.mode.abiMode());
            try self.workers[index].init(&self.worker_shared, plugin, &self.contexts[index]);
            try self.workers[index].start();
        }
        return self;
    }

    fn logger(self: *Supervisor) *log.Logger {
        return self.env.logger;
    }

    pub fn startPlugins(self: *Supervisor) void {
        const settings = &self.config.settings;
        var any_persist = false;
        for (self.env.plugins, 0..) |*plugin, index| {
            const enabled = settings.pluginEnabled(plugin.name, plugin.isOptIn());
            if (plugin.isOptIn() and !enabled) {
                self.logger().log(.info, source, "{s} is opt-in and stays disabled; enable it with \"plugins\": {{\"{s}\": {{\"enabled\": true}}}} (in %ProgramData%\\rgbctrl\\rgbctrl.json when rgbctrl runs elevated)", .{ plugin.name, plugin.name });
                if (settings.enableRequestedByUntrustedLayer(plugin.name)) {
                    self.logger().log(.warn, source, "plugins.{s}.enabled = true in an untrusted config is ignored while rgbctrl runs elevated", .{plugin.name});
                }
            }
            if (settings.pluginPersist(plugin.name)) {
                any_persist = true;
                if (plugin.table.persist == null) self.logger().log(.warn, source, "plugins.{s}.persist is true but {s} cannot save settings to its devices", .{ plugin.name, plugin.name });
            }
            self.states[index].enabled = enabled;
            self.states[index].hash = settings.pluginHash(plugin.name);
            if (enabled) {
                self.workers[index].postOpen(self.config);
            } else if (!plugin.isOptIn()) {
                self.logger().log(.info, source, "{s} is disabled by the configuration", .{plugin.name});
            }
        }
        if (any_persist and self.env.mode == .apply) self.logger().log(.warn, source, "apply never writes device memory; use run for at least 60 s to persist settings", .{});
        self.warnUnknownPluginNames();
    }

    fn warnUnknownPluginNames(self: *Supervisor) void {
        var names: [64][]const u8 = undefined;
        var count: usize = 0;
        for (self.env.plugins) |plugin| {
            if (count < names.len) {
                names[count] = plugin.name;
                count += 1;
            }
        }
        var reported: usize = 0;
        for (self.config.settings.configuredPluginNames()) |member| {
            if (reported == 20) break;
            var known = false;
            for (names[0..count]) |name| {
                if (std.mem.eql(u8, name, member.key)) known = true;
            }
            if (known) continue;
            reported += 1;
            if (suggest.closest(member.key, names[0..count])) |suggestion| {
                self.logger().log(.warn, "config", "line {d}:{d}: plugins.{s} matches no loaded plugin; did you mean \"{s}\"?", .{ member.value.line, member.value.column, member.key, suggestion });
            } else {
                self.logger().log(.warn, "config", "line {d}:{d}: plugins.{s} matches no loaded plugin", .{ member.value.line, member.value.column, member.key });
            }
        }
    }

    pub fn logConfigDiagnostics(logger_instance: *log.Logger, config: *generation.ConfigGeneration) void {
        var buffer: [512]u8 = undefined;
        logger_instance.log(.info, "config", "base config {s}: {s}", .{ config.base.path, generation.describeStatus(&buffer, config.base.status) });
        logger_instance.log(.info, "config", "user config {s}: {s}", .{ config.user.path, generation.describeStatus(&buffer, config.user.status) });
        for (config.diagnostics.entries.items) |entry| {
            logger_instance.write(if (entry.severity == .failure) .err else .warn, "config", entry.message);
        }
    }

    fn logNewDiagnostics(self: *Supervisor) void {
        const entries = self.diagnostics.entries.items;
        for (entries[self.logged_diagnostics..]) |entry| {
            self.logger().write(if (entry.severity == .failure) .err else .warn, "config", entry.message);
        }
        self.logged_diagnostics = entries.len;
    }

    fn collectReports(self: *Supervisor) void {
        var changed: [64]bool = @splat(false);
        var any_changed = false;
        for (self.workers, 0..) |*worker, index| {
            const report = worker.takeReport();
            const state = &self.states[index];
            state.open_state = report.open_state;
            state.applied_serial = report.applied_binding_serial;
            state.sensor_ticks = report.sensor_ticks;
            state.exited = report.exited;
            if (!report.has_devices) continue;
            if (state.devices) |previous| previous.release();
            state.devices = report.devices;
            if (index < changed.len) changed[index] = true;
            any_changed = true;
        }
        if (!any_changed) return;
        self.recomputeAliases();
        for (self.states, 0..) |*state, index| {
            if (index < changed.len and changed[index]) self.logInventory(index, state);
        }
        for (self.states, 0..) |_, index| self.rebind(index);
        self.topology_changed = true;
        self.validateLightingWhenReady();
    }

    fn allOpensReported(self: *Supervisor) bool {
        for (self.states) |state| {
            if (state.enabled and (state.open_state == .idle or state.open_state == .closed)) return false;
        }
        return true;
    }

    fn validateLightingWhenReady(self: *Supervisor) void {
        if (!self.topology_changed or !self.allOpensReported()) return;
        self.topology_changed = false;
        var scratch = std.heap.ArenaAllocator.init(heap.allocator);
        defer scratch.deinit();
        const arena = scratch.allocator();
        var shapes: std.ArrayList(lighting_config.DeviceShape) = .empty;
        for (self.states) |*state| {
            const set = state.devices orelse continue;
            for (set.devices, 0..) |device, device_index| {
                const zone_names = arena.alloc([]const u8, device.zones.len) catch return;
                for (device.zones, 0..) |zone, zone_index| zone_names[zone_index] = zone.name;
                shapes.append(arena, .{ .key = aliasOf(state, device_index, device.id), .zone_names = zone_names }) catch return;
            }
        }
        lighting_config.validateTree(arena, self.config.settings.lighting, shapes.items, &self.diagnostics) catch {};
        self.logNewDiagnostics();
    }

    fn recomputeAliases(self: *Supervisor) void {
        for (self.states) |*state| state.aliases = &.{};
        _ = self.alias_arena.reset(.retain_capacity);
        const arena = self.alias_arena.allocator();
        var ids: std.ArrayList([]const u8) = .empty;
        for (self.states, 0..) |*state, index| {
            const set = state.devices orelse continue;
            const aliases = arena.alloc([]const u8, set.devices.len) catch return;
            for (set.devices, 0..) |device, device_index| {
                const alias = bindings.aliasFor(arena, self.env.plugins[index].name, device.id, ids.items) catch return;
                aliases[device_index] = alias.key;
                ids.append(arena, device.id) catch return;
            }
            state.aliases = aliases;
        }
    }

    fn logInventory(self: *Supervisor, index: usize, state: *PluginState) void {
        const plugin = &self.env.plugins[index];
        const set = state.devices orelse {
            self.logger().log(.debug, plugin.name, "no devices", .{});
            return;
        };
        if (set.devices.len == 0 and !plugin.isSensorSource()) self.logger().log(.info, plugin.name, "no supported devices found", .{});
        for (set.devices, 0..) |device, device_index| {
            const key = aliasOf(state, device_index, device.id);
            if (!std.mem.eql(u8, key, device.id)) {
                self.logger().log(.warn, plugin.name, "device id \"{s}\" is already used by an earlier plugin; configure it as \"{s}\"", .{ device.id, key });
            }
            self.logger().log(.info, plugin.name, "device {s}: {s} ({d} zones)", .{ key, device.name, device.zones.len });
            if (device.max_fps > 0) self.logger().log(.debug, plugin.name, "device {s} accepts at most {d} frames per second", .{ key, device.max_fps });
            for (device.zones) |zone| {
                var flags_buffer: [96]u8 = undefined;
                var effects_buffer: [128]u8 = undefined;
                self.logger().log(.info, plugin.name, "  zone {s}: {d}/{d} LEDs; {s}; hardware effects: {s}", .{ zone.name, zone.led_count, zone.max_leds, describeFlags(&flags_buffer, zone.flags), describeEffects(&effects_buffer, zone.hw_effects, zone.hw_max_colors) });
            }
        }
    }

    fn rebind(self: *Supervisor, index: usize) void {
        const state = &self.states[index];
        if (!state.enabled or state.open_state != .opened) return;
        const set = state.devices orelse return;
        const plugin = &self.env.plugins[index];
        const settings = &self.config.settings;
        self.binding_serial += 1;
        const binding = bindings.BindingGeneration.create(self.binding_serial, set.serial, settings.frame_rate, settings.pluginPersist(plugin.name)) catch return;
        const arena = binding.arena();
        const plans = arena.alloc(bindings.DevicePlan, set.devices.len) catch {
            binding.destroy();
            return;
        };
        for (set.devices, 0..) |device, device_index| {
            const key = arena.dupe(u8, aliasOf(state, device_index, device.id)) catch "";
            const zones = arena.alloc(lighting_config.Resolution, device.zones.len) catch {
                binding.destroy();
                return;
            };
            for (device.zones, 0..) |zone, zone_index| {
                const shape = lighting_config.ZoneShape{ .flags = zone.flags, .led_count = zone.led_count, .max_leds = zone.max_leds, .hw_effects = zone.hw_effects, .hw_max_colors = zone.hw_max_colors };
                zones[zone_index] = lighting_config.resolve(arena, settings.lighting, key, zone.name, shape, &self.diagnostics) catch .invalid;
            }
            plans[device_index] = .{
                .key = key,
                .persist_key = formatting.allocPrint(arena, "{s}.{s}", .{ plugin.name, device.id }) catch "",
                .zones = zones,
            };
        }
        binding.devices = plans;
        self.logNewDiagnostics();
        if (self.env.mode == .list) {
            binding.destroy();
            return;
        }
        state.posted_serial = binding.serial;
        self.workers[index].postBinding(binding);
    }

    fn checkStalls(self: *Supervisor, now: u64) void {
        for (self.workers, 0..) |*worker, index| {
            if (worker.stalledCall(now)) |stall| {
                self.logger().log(.warn, self.env.plugins[index].name, "{s} has not returned after {d} ms", .{ stall.name, stall.elapsed_ms });
            }
        }
    }

    fn waitForEvents(self: *Supervisor, timeout_ms: u32) bool {
        const handles = [_]win32.HANDLE{ self.env.stop_event, self.supervisor_event };
        const result = win32.WaitForMultipleObjects(handles.len, &handles, win32.FALSE, timeout_ms);
        return result == win32.WAIT_OBJECT_0;
    }

    fn waitUntil(self: *Supervisor, timeout_ms: u64, comptime predicate: fn (*Supervisor) bool) bool {
        const deadline = self.env.clock.nowMs() + timeout_ms;
        while (true) {
            self.collectReports();
            if (predicate(self)) return true;
            const now = self.env.clock.nowMs();
            self.checkStalls(now);
            if (now >= deadline) return false;
            if (self.waitForEvents(@intCast(@min(deadline - now, 100)))) return false;
        }
    }

    fn allApplied(self: *Supervisor) bool {
        for (self.states) |state| {
            if (!state.enabled or state.open_state != .opened or state.devices == null) continue;
            if (state.posted_serial == 0 or state.applied_serial < state.posted_serial) return false;
        }
        return true;
    }

    fn allSensorsTicked(self: *Supervisor) bool {
        for (self.states, 0..) |state, index| {
            if (!state.enabled or state.open_state != .opened) continue;
            const plugin = &self.env.plugins[index];
            if (plugin.isSensorSource() and plugin.table.tick != null and plugin.tickInterval() > 0 and state.sensor_ticks < 2) return false;
        }
        return true;
    }

    fn reportUnfinished(self: *Supervisor, what: []const u8) void {
        for (self.states, 0..) |state, index| {
            if (state.enabled and (state.open_state == .idle or (state.open_state == .opened and state.devices != null and state.applied_serial < state.posted_serial))) {
                self.logger().log(.warn, self.env.plugins[index].name, "did not finish {s} in time", .{what});
            }
        }
    }

    pub fn runApply(self: *Supervisor) u8 {
        if (!self.waitUntil(10_000, allOpensReported)) self.reportUnfinished("opening");
        if (!self.waitUntil(10_000, allApplied)) self.reportUnfinished("applying");
        if (self.config.layer_failed or self.config.diagnostics.failure_seen or self.diagnostics.failure_seen) return 1;
        return 0;
    }

    pub fn runList(self: *Supervisor) u8 {
        if (!self.waitUntil(10_000, allOpensReported)) self.reportUnfinished("opening");
        _ = self.waitUntil(2_500, allSensorsTicked);
        self.printList();
        if (self.config.layer_failed or self.config.diagnostics.failure_seen or self.diagnostics.failure_seen) return 1;
        return 0;
    }

    pub fn runResident(self: *Supervisor) void {
        var next_config_poll: u64 = 0;
        var next_hotplug_poll: u64 = 0;
        var next_resume_poll: u64 = 0;
        var next_sensor_log: u64 = 60_000;
        while (true) {
            if (self.waitForEvents(250)) {
                self.logger().log(.info, source, "stop requested", .{});
                return;
            }
            const now = self.env.clock.nowMs();
            self.collectReports();
            self.checkStalls(now);
            if (now >= next_config_poll) {
                self.pollConfig(now);
                next_config_poll = now + if (self.reload_pending) @as(u64, 300) else 1000;
            }
            if (now >= next_hotplug_poll) {
                self.pollHotplug();
                next_hotplug_poll = now + 2000;
            }
            if (now >= next_resume_poll) {
                self.pollResume();
                next_resume_poll = now + 1000;
            }
            if (now >= next_sensor_log) {
                self.logSensors();
                next_sensor_log = now + 60_000;
            }
        }
    }

    fn pollConfig(self: *Supervisor, now: u64) void {
        const stamps = [2]generation.Stamp{ generation.stampFor(self.env.sources.base_file, self.env.sources.elevated), generation.stampFor(self.env.sources.user_file, self.env.sources.elevated) };
        if (!stamps[0].eql(self.stamps[0]) or !stamps[1].eql(self.stamps[1])) {
            self.stamps = stamps;
            self.change_seen_ms = now;
            self.reload_pending = true;
            return;
        }
        if (self.reload_pending and now >= self.change_seen_ms + 300) {
            self.reload_pending = false;
            self.reload();
        }
    }

    fn reload(self: *Supervisor) void {
        self.config_serial += 1;
        const fresh = generation.load(self.config_serial, self.env.sources) catch {
            self.logger().log(.err, "config", "out of memory while reloading the configuration", .{});
            return;
        };
        if (fresh.layer_failed) {
            logConfigDiagnostics(self.logger(), fresh);
            self.logger().log(.err, "config", "configuration not reloaded because a file could not be used; keeping the previous configuration", .{});
            fresh.release();
            return;
        }
        self.logger().log(.info, "config", "configuration changed; reloading", .{});
        logConfigDiagnostics(self.logger(), fresh);
        const settings = &fresh.settings;
        const previous = &self.config.settings;
        if (settings.log_level != previous.log_level or settings.log_max_size_kb != previous.log_max_size_kb) {
            self.logger().configure(settings.log_level, settings.log_max_size_kb);
        }
        if (!std.mem.eql(u8, settings.log_file, previous.log_file)) self.switchLogFile(settings.log_file);
        for (self.env.plugins, 0..) |*plugin, index| {
            const state = &self.states[index];
            const enabled = settings.pluginEnabled(plugin.name, plugin.isOptIn());
            const hash = settings.pluginHash(plugin.name);
            if (state.enabled and !enabled) {
                self.logger().log(.info, plugin.name, "disabled by the configuration; closing", .{});
                self.workers[index].postClose(abi.close_keep);
            } else if (!state.enabled and enabled) {
                self.logger().log(.info, plugin.name, "enabled by the configuration; opening", .{});
                self.workers[index].postOpen(fresh);
            } else if (enabled and hash != state.hash) {
                self.logger().log(.info, plugin.name, "plugin settings changed; reopening", .{});
                self.workers[index].postClose(abi.close_keep);
                self.workers[index].postOpen(fresh);
            }
            state.enabled = enabled;
            state.hash = hash;
        }
        self.config.release();
        self.config = fresh;
        _ = self.epoch_arena.reset(.retain_capacity);
        self.diagnostics = Diagnostics.init(self.epoch_arena.allocator());
        self.logged_diagnostics = 0;
        self.warnUnknownPluginNames();
        for (self.states, 0..) |_, index| self.rebind(index);
        self.topology_changed = true;
        self.validateLightingWhenReady();
    }

    fn switchLogFile(self: *Supervisor, file_name: []const u8) void {
        self.logger().log(.info, source, "switching the log to {s}", .{file_name});
        self.logger().switchFileName(file_name) catch |err| {
            self.logger().log(.err, source, "cannot open log file {s}: {s}; keeping the current log", .{ file_name, safe_open.describe(err) });
        };
    }

    fn pollHotplug(self: *Supervisor) void {
        var list = sdk.hid.InterfaceList.init(heap.allocator) catch return;
        defer list.deinit();
        const hash = sdk.hid.contentHash(list.contents());
        const previous = self.hid_hash;
        self.hid_hash = hash;
        if (previous == null or previous.? == hash) return;
        self.logger().log(.debug, source, "HID device list changed", .{});
        for (self.env.plugins, 0..) |*plugin, index| {
            if (plugin.usesHid() and self.states[index].open_state == .opened) self.workers[index].postRescan(abi.rescan_hotplug);
        }
    }

    fn pollResume(self: *Supervisor) void {
        if (!self.resume_detector.check()) return;
        self.logger().log(.info, source, "system resumed from sleep; re-initializing devices", .{});
        for (self.states, 0..) |state, index| {
            if (state.open_state == .opened) self.workers[index].postRescan(abi.rescan_resume);
        }
    }

    fn logSensors(self: *Supervisor) void {
        var entries: [sensors.max_sensors]sensors.Entry = undefined;
        const count = self.env.sensor_table.snapshot(&entries);
        if (count == 0) return;
        var line: [2048]u8 = undefined;
        var length: usize = 0;
        const now = self.env.clock.nowMs();
        for (entries[0..count]) |entry| {
            var value_buffer: [32]u8 = undefined;
            const age_note: []const u8 = if (now -| entry.timestamp_ms > sensors.stale_after_ms) " (stale)" else "";
            const part = formatting.bufPrint(line[length..], "{s}{s}={s}{s}", .{ if (length == 0) "" else " ", entry.name(), formatting.fixed(&value_buffer, entry.value, 1), age_note }) catch break;
            length += part.len;
        }
        self.logger().log(.debug, "sensors", "{s}", .{line[0..length]});
    }

    pub fn shutdown(self: *Supervisor) bool {
        for (self.workers) |*worker| worker.postExit();
        const deadline = self.env.clock.nowMs() + 3000;
        var clean = true;
        for (self.workers, 0..) |*worker, index| {
            const now = self.env.clock.nowMs();
            const remaining: u32 = @intCast(if (deadline > now) deadline - now else 0);
            if (!worker.wait(remaining)) {
                clean = false;
                self.logger().log(.warn, self.env.plugins[index].name, "did not finish within 3 s of the stop request; abandoning it", .{});
            }
        }
        return clean;
    }

    fn printList(self: *Supervisor) void {
        var buffer: [512]u8 = undefined;
        console.print(.out, "Configuration:\n", .{});
        console.print(.out, "  base  {s}: {s}\n", .{ self.config.base.path, generation.describeStatus(&buffer, self.config.base.status) });
        console.print(.out, "  user  {s}: {s}\n", .{ self.config.user.path, generation.describeStatus(&buffer, self.config.user.status) });
        for ([_]*const Diagnostics{ &self.config.diagnostics, &self.diagnostics }) |diagnostics| {
            for (diagnostics.entries.items) |entry| {
                console.print(.out, "  {s}: {s}\n", .{ if (entry.severity == .failure) "error" else "warning", entry.message });
            }
        }
        console.print(.out, "\nPlugins:\n", .{});
        for (self.env.plugins, 0..) |*plugin, index| {
            const state = self.states[index];
            var flags_buffer: [96]u8 = undefined;
            var status_buffer: [128]u8 = undefined;
            const status: []const u8 = if (!state.enabled)
                (if (plugin.isOptIn()) formatting.print(&status_buffer, "disabled (opt-in; set plugins.{s}.enabled to true)", .{plugin.name}) else "disabled")
            else switch (state.open_state) {
                .opened => "active",
                .failed => "open failed (see the log)",
                else => "did not respond",
            };
            console.print(.out, "  {s} {s} [{s}] from {s}: {s}\n", .{ plugin.name, plugin.version, describePluginFlags(&flags_buffer, plugin), plugin.file_name, status });
        }
        for (self.env.failures) |failure| console.print(.out, "  {s}: not loaded ({s})\n", .{ failure.file_name, failure.reason });
        console.print(.out, "\nDevices:\n", .{});
        var device_total: usize = 0;
        for (self.states, 0..) |state, index| {
            const set = state.devices orelse continue;
            for (set.devices, 0..) |device, device_index| {
                device_total += 1;
                console.print(.out, "  {s}: {s} ({s})\n", .{ aliasOf(&state, device_index, device.id), device.name, self.env.plugins[index].name });
                for (device.zones) |zone| {
                    var flags_buffer: [96]u8 = undefined;
                    var effects_buffer: [128]u8 = undefined;
                    console.print(.out, "    {s}: {d}/{d} LEDs; {s}; hardware effects: {s}\n", .{ zone.name, zone.led_count, zone.max_leds, describeFlags(&flags_buffer, zone.flags), describeEffects(&effects_buffer, zone.hw_effects, zone.hw_max_colors) });
                    if (zone.flags & abi.zone_resizable != 0 and zone.led_count == 0) console.print(.out, "      note: set \"leds\" in lighting.{s}.{s} to the number of LEDs connected\n", .{ aliasOf(&state, device_index, device.id), zone.name });
                    if (zone.flags & abi.zone_host_frames == 0 and zone.hw_effects == 0) console.print(.out, "      note: this zone offers no controllable lighting\n", .{});
                }
            }
        }
        if (device_total == 0) console.print(.out, "  none found\n", .{});
        console.print(.out, "\nSensors:\n", .{});
        self.printSensors();
    }

    fn printSensors(self: *Supervisor) void {
        var entries: [sensors.max_sensors]sensors.Entry = undefined;
        const count = self.env.sensor_table.snapshot(&entries);
        const now = self.env.clock.nowMs();
        for (entries[0..count]) |entry| {
            var value_buffer: [32]u8 = undefined;
            const stale: []const u8 = if (now -| entry.timestamp_ms > sensors.stale_after_ms) " (stale)" else "";
            console.print(.out, "  {s}: {s}{s}\n", .{ entry.name(), formatting.fixed(&value_buffer, entry.value, 1), stale });
        }
        for (sensors.standard_sources) |standard| {
            var present = false;
            for (entries[0..count]) |entry| {
                if (std.mem.eql(u8, entry.name(), standard.name)) present = true;
            }
            if (present) continue;
            var reason_buffer: [320]u8 = undefined;
            console.print(.out, "  {s}: {s}\n", .{ standard.name, self.sensorAbsenceReason(&reason_buffer, standard.source) });
        }
    }

    fn sensorAbsenceReason(self: *Supervisor, buffer: []u8, plugin_name: []const u8) []const u8 {
        for (self.env.plugins, 0..) |*plugin, index| {
            if (!std.mem.eql(u8, plugin.name, plugin_name)) continue;
            const state = self.states[index];
            if (!state.enabled) return formatting.print(buffer, "unavailable ({s} is disabled)", .{plugin_name});
            if (state.open_state != .opened) return formatting.print(buffer, "unavailable ({s} did not open)", .{plugin_name});
            var problem_buffer: [240]u8 = undefined;
            const problem = self.contexts[index].lastProblem(&problem_buffer);
            if (problem.len > 0) return formatting.print(buffer, "unavailable ({s}: {s})", .{ plugin_name, problem });
            return "pending";
        }
        return formatting.print(buffer, "unavailable (plugin {s} is not installed)", .{plugin_name});
    }
};

fn aliasOf(state: *const PluginState, device_index: usize, device_id: []const u8) []const u8 {
    if (device_index < state.aliases.len) return state.aliases[device_index];
    return device_id;
}

fn describeFlags(buffer: []u8, flags: u32) []const u8 {
    var length: usize = 0;
    const names = [_]struct { bit: u32, name: []const u8 }{
        .{ .bit = abi.zone_resizable, .name = "resizable" },
        .{ .bit = abi.zone_host_frames, .name = "host frames" },
        .{ .bit = abi.zone_global_brightness_only, .name = "global brightness only" },
    };
    for (names) |entry| {
        if (flags & entry.bit == 0) continue;
        const part = formatting.bufPrint(buffer[length..], "{s}{s}", .{ if (length == 0) "" else ", ", entry.name }) catch break;
        length += part.len;
    }
    if (length == 0) return "fixed size, no host frames";
    return buffer[0..length];
}

fn describeEffects(buffer: []u8, effects_mask: u32, max_colors: u32) []const u8 {
    const names = [_][]const u8{ "off", "static", "breathing", "flash", "cycle", "rainbow", "gradient" };
    var length: usize = 0;
    for (names, 0..) |name, index| {
        if (effects_mask & (@as(u32, 1) << @intCast(index)) == 0) continue;
        const part = formatting.bufPrint(buffer[length..], "{s}{s}", .{ if (length == 0) "" else ", ", name }) catch break;
        length += part.len;
    }
    if (length == 0) return "none";
    const suffix = formatting.bufPrint(buffer[length..], " (up to {d} color{s})", .{ max_colors, if (max_colors == 1) "" else "s" }) catch return buffer[0..length];
    return buffer[0 .. length + suffix.len];
}

pub fn describePluginFlags(buffer: []u8, plugin: *const loader.Plugin) []const u8 {
    var length: usize = 0;
    const transports = [_]struct { bit: u32, name: []const u8 }{
        .{ .bit = abi.transport_hid, .name = "HID" },
        .{ .bit = abi.transport_smbus, .name = "SMBus" },
        .{ .bit = abi.transport_i2c, .name = "I2C" },
        .{ .bit = abi.transport_os, .name = "OS" },
    };
    for (transports) |entry| {
        if (plugin.table.transports & entry.bit == 0) continue;
        const part = formatting.bufPrint(buffer[length..], "{s}{s}", .{ if (length == 0) "" else ", ", entry.name }) catch break;
        length += part.len;
    }
    if (plugin.isOptIn()) {
        const part = formatting.bufPrint(buffer[length..], "{s}opt-in", .{if (length == 0) "" else ", "}) catch return buffer[0..length];
        length += part.len;
    }
    if (plugin.isSensorSource()) {
        const part = formatting.bufPrint(buffer[length..], "{s}sensors", .{if (length == 0) "" else ", "}) catch return buffer[0..length];
        length += part.len;
    }
    if (length == 0) return "no transport flags";
    return buffer[0..length];
}

test "describeFlags and describeEffects name capabilities for the inventory" {
    var buffer: [128]u8 = undefined;
    try std.testing.expectEqualStrings("resizable, host frames", describeFlags(&buffer, abi.zone_resizable | abi.zone_host_frames));
    try std.testing.expectEqualStrings("fixed size, no host frames", describeFlags(&buffer, 0));
    try std.testing.expectEqualStrings("off, static, breathing (up to 1 color)", describeEffects(&buffer, 0b111, 1));
    try std.testing.expectEqualStrings("none", describeEffects(&buffer, 0, 0));
}
