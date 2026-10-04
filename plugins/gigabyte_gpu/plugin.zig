const std = @import("std");
const builtin = @import("builtin");
const sdk = @import("sdk");
const protocol = @import("protocol.zig");
const lcd = @import("lcd.zig");
const abi = sdk.abi;

comptime {
    if (!builtin.is_test) _ = @import("rt");
}

pub const panic = sdk.panic;

const max_devices = 8;
const max_name_len = 63;
const max_id_len = 15;
const max_zones = protocol.max_zone_count;
const max_leds = protocol.max_led_count;

const ZoneState = struct {
    info: abi.ZoneInfo = .{ .name = null, .led_count = 0, .max_leds = 0 },
    colors: [max_leds]abi.Rgb = @splat(abi.Rgb.black),
    dirty: bool = false,
    host_streamed: bool = false,
    mode_pending: bool = true,
    legacy_mode: u8 = 0x01,

    fn reset(self: *ZoneState, spec: protocol.ZoneSpec) void {
        self.* = .{
            .info = .{
                .flags = abi.zone_host_frames,
                .name = spec.name,
                .led_count = spec.led_count,
                .max_leds = spec.led_count,
                .hw_effects = protocol.hwEffects(.legacy),
                .hw_max_colors = 1,
            },
        };
    }
};

const Device = struct {
    handle: sdk.nvapi.GpuHandle,
    identity: protocol.PciIdentity,
    family: protocol.ProtocolFamily,
    layout: protocol.ZoneLayout,
    address: u7,
    lost: bool = false,
    id_buffer: [max_id_len + 1]u8 = @splat(0),
    name_buffer: [max_name_len + 1]u8 = @splat(0),
    zone_storage: [max_zones]ZoneState = @splat(.{}),
    zone_pointers: [max_zones]*const abi.ZoneInfo = undefined,
    info: abi.DeviceInfo = .{ .zone_count = 0, .id = null, .name = null, .zones = null, .max_fps = protocol.device_max_fps },

    fn resetZones(self: *Device, name: []const u8) void {
        const display_name = if (name.len == 0) "Gigabyte GPU" else name[0..@min(name.len, max_name_len)];
        @memset(&self.name_buffer, 0);
        @memcpy(self.name_buffer[0..display_name.len], display_name);
        for (protocol.zones(self.layout), 0..) |spec, index| {
            self.zone_storage[index].reset(spec);
            self.zone_storage[index].info.hw_effects = protocol.hwEffects(self.family);
        }
    }

    fn link(self: *Device, id: []const u8) void {
        @memset(&self.id_buffer, 0);
        @memcpy(self.id_buffer[0..id.len], id);
        const specs = protocol.zones(self.layout);
        for (0..specs.len) |index| self.zone_pointers[index] = &self.zone_storage[index].info;
        self.info = .{
            .zone_count = @intCast(specs.len),
            .id = @ptrCast(&self.id_buffer),
            .name = @ptrCast(&self.name_buffer),
            .zones = &self.zone_pointers,
            .max_fps = protocol.device_max_fps,
        };
    }

    fn anyHostStreamed(self: *const Device) bool {
        for (self.zone_storage[0..self.info.zone_count]) |zone| {
            if (zone.host_streamed) return true;
        }
        return false;
    }

    fn markResume(self: *Device) void {
        for (self.zone_storage[0..self.info.zone_count]) |*zone| {
            zone.mode_pending = true;
            zone.dirty = zone.host_streamed;
        }
    }
};

const Candidate = struct {
    handle: sdk.nvapi.GpuHandle,
    identity: protocol.PciIdentity,
};

const lcd_retry_ms: u64 = 30_000;
const lcd_reprobe_after_failures: u32 = 3;
// PrivateGER's driver retries a failed LCD transfer 8 times 250 ms apart; a probe here gives it
// 3 tries (each already reading again after short waits) to keep open() and tick() short.
const lcd_query_attempts: u32 = 3;
const lcd_query_pause_ms: u32 = 250;

const LcdSearch = enum { found, no_card, no_answer };

// What an LCD address did with the firmware query when no panel came of it.
const QueryMiss = union(enum) {
    refused: i32,
    no_reply: i32,
    no_firmware,
};

// Why the LCD could not be used; logged when it differs from the last one.
const LcdProblem = union(enum) {
    no_card,
    busy,
    // What 0x76 and then 0x61 did; null for an address that was not asked.
    silent: struct { ex: ?QueryMiss, legacy: ?QueryMiss },
    unrecognized: [lcd.reply_length]u8,
    unrecognized_ex: [lcd.reply_length]u8,
};

const LcdPanel = struct {
    enabled: bool = false,
    // Without it the panel only gets read-only queries: nothing that changes what it shows.
    readout: bool = false,
    flags: u8 = lcd.default_metrics,
    seconds: u8 = lcd.default_seconds,
    screen: lcd.Mode = .faith1,
    // Whether lcd_screen was given; the newer controller changes screens only then.
    screen_set: bool = false,
    color: abi.Rgb = lcd.default_color,
    // Whether lcd_color was given: only then does the newer controller get it for the readings
    // of its built-in screens too.
    color_set: bool = false,
    // lcd_logo_color, for the artwork of the newer controller's built-in screens.
    logo_color: ?abi.Rgb = null,
    kind: lcd.Kind = .legacy,
    // The card of the panel; kept when a later probe fails, so close() can still restore it.
    handle: ?sdk.nvapi.GpuHandle = null,
    // The I2C speed of every transfer to that card, lighting included.
    bus_speed: u32 = sdk.nvapi.i2c_speed_default,
    found: bool = false,
    original: ?lcd.PanelState = null,
    setup_pending: bool = true,
    active: bool = false,
    problem: ?LcdProblem = null,
    retry_at_ms: u64 = 0,
    failures: u32 = 0,
    last_sent: ?lcd.Encoded = null,
    last_sent_ms: u64 = 0,
    last_tick_ms: u64 = 0,
    holds: [8]lcd.SensorHold = @splat(.{}),
};

const Instance = struct {
    host: sdk.HostApi,
    nvapi: ?sdk.nvapi.Nvapi = null,
    devices: [max_devices]Device = undefined,
    device_count: usize = 0,
    lcd: LcdPanel = .{},

    fn discover(self: *Instance, reprobe_present: bool) i32 {
        var api = &(self.nvapi orelse return abi.status_ok);
        var handles: [sdk.nvapi.max_gpus]?sdk.nvapi.GpuHandle = undefined;
        const count = api.gpus(&handles);
        var candidates: [max_devices]Candidate = undefined;
        var candidate_count: usize = 0;
        for (handles[0..count]) |maybe_handle| {
            const handle = maybe_handle orelse continue;
            const pci = api.pciIds(handle) orelse continue;
            const identity = protocol.PciIdentity{ .device_id = pci.device(), .subvendor_id = pci.subvendor(), .subdevice_id = pci.subdevice(), .revision = pci.revision };
            if (protocol.lookup(identity, .legacy) == null and protocol.lookup(identity, .blackwell) == null) {
                logSkippedGpu(self.host, identity);
                continue;
            }
            if (candidate_count == max_devices) break;
            candidates[candidate_count] = .{ .handle = handle, .identity = identity };
            candidate_count += 1;
        }
        std.sort.insertion(Candidate, candidates[0..candidate_count], {}, candidateLessThan);
        var fresh: [max_devices]Device = undefined;
        var fresh_count: usize = 0;
        for (candidates[0..candidate_count]) |candidate| {
            if (!reprobe_present) {
                if (self.findPresent(candidate)) |index| {
                    fresh[fresh_count] = self.devices[index];
                    fresh_count += 1;
                    continue;
                }
            }
            const probed = self.probe(candidate) orelse continue;
            var name_buffer: [64]u8 = undefined;
            fresh[fresh_count] = .{ .handle = candidate.handle, .identity = candidate.identity, .family = probed.model.family, .layout = probed.model.layout, .address = probed.address };
            fresh[fresh_count].resetZones(api.fullName(candidate.handle, &name_buffer));
            fresh_count += 1;
        }
        const changed = !sameDevices(self.devices[0..self.device_count], fresh[0..fresh_count]);
        @memcpy(self.devices[0..fresh_count], fresh[0..fresh_count]);
        self.device_count = fresh_count;
        assignIds(self.devices[0..fresh_count]);
        return if (changed) abi.rescan_changed else abi.status_ok;
    }

    fn findPresent(self: *Instance, candidate: Candidate) ?usize {
        for (self.devices[0..self.device_count], 0..) |device, index| {
            if (!device.lost and device.handle == candidate.handle and sameIdentity(device.identity, candidate.identity)) return index;
        }
        return null;
    }

    const Probed = struct {
        model: protocol.DeviceModel,
        address: u7,
    };

    fn probe(self: *Instance, candidate: Candidate) ?Probed {
        if (self.tryProbe(candidate, .blackwell)) |model| return .{ .model = model, .address = protocol.blackwell_address };
        if (self.tryProbe(candidate, .legacy)) |model| return .{ .model = model, .address = protocol.legacy_address };
        return null;
    }

    fn tryProbe(self: *Instance, candidate: Candidate, family: protocol.ProtocolFamily) ?protocol.DeviceModel {
        const model = protocol.lookup(candidate.identity, family) orelse return null;
        const lcd_card = lcd.supports(candidate.identity.device_id, candidate.identity.subvendor_id, candidate.identity.subdevice_id);
        const api = self.busFor(candidate.handle, lcd_card);
        switch (family) {
            .legacy => {
                var response: [4]u8 = undefined;
                const request = protocol.buildLegacyProbe();
                if (!api.writeThenRead(candidate.handle, protocol.legacy_address, &request, &response)) return null;
                if (!protocol.parseLegacyProbe(&response)) return null;
                return model;
            },
            .blackwell => {
                const request10 = protocol.buildBlackwellProbe10();
                // CodeTorch's AorusLcd never reads from this controller on the LCD card: reads from
                // it hung the I2C engine the LCD shares on the 5090. With lcd on, a write ACK
                // stands in for the replies, and the PCI identity already fixed the model.
                if (self.lcd.enabled and lcd_card) {
                    return if (api.writeRetrying(candidate.handle, protocol.blackwell_address, &request10)) model else null;
                }
                var response: [4]u8 = undefined;
                if (!api.writeThenRead(candidate.handle, protocol.blackwell_address, &request10, &response)) return null;
                if (!protocol.parseBlackwellProbe10(&response)) return null;
                const request11 = protocol.buildBlackwellSubsystemProbe();
                if (!api.writeThenRead(candidate.handle, protocol.blackwell_address, &request11, &response)) return null;
                if (!protocol.parseBlackwellSubsystem(&response, candidate.identity.subdevice_id)) return null;
                return model;
            },
        }
    }

    fn write(self: *Instance, device: *Device, bytes: []const u8) i32 {
        const lcd_card = lcd.supports(device.identity.device_id, device.identity.subvendor_id, device.identity.subdevice_id);
        if (!self.busFor(device.handle, lcd_card).write(device.handle, device.address, bytes)) {
            self.host.logMessage(.warn, "GPU RGB I2C write failed");
            device.lost = true;
            return abi.status_device_lost;
        }
        return abi.status_ok;
    }

    fn configRange(self: *Instance, config: ?*const abi.Json, key: []const u8, default: u8, min: u8, max: u8, problem: []const u8) u8 {
        const node = self.host.member(config, key) orelse return default;
        const value = self.host.asNumber(node) orelse {
            self.host.logMessage(.warn, problem);
            return default;
        };
        const rounded = sdk.text.roundToInt(i64, value);
        if (rounded < min or rounded > max) {
            self.host.logMessage(.warn, problem);
            return default;
        }
        return @intCast(rounded);
    }

    fn readLcdConfig(self: *Instance, config: ?*const abi.Json) void {
        const enabled = self.host.member(config, "lcd") orelse return;
        self.lcd.enabled = self.host.asBool(enabled) orelse {
            self.host.logMessage(.warn, "lcd must be true or false; the GPU LCD stays off");
            return;
        };
        if (!self.lcd.enabled) return;
        if (self.host.member(config, "lcd_readout")) |node| {
            if (self.host.asBool(node)) |readout| {
                self.lcd.readout = readout;
            } else {
                self.host.logMessage(.warn, "lcd_readout must be true or false; the GPU LCD only gets read-only queries");
            }
        }
        self.lcd.seconds = self.configRange(config, "lcd_seconds", lcd.default_seconds, 1, 60, "lcd_seconds must be a number from 1 to 60; using 4");
        if (self.host.member(config, "lcd_screen")) |node| {
            // Only a valid screen counts as asked for: the newer controller cannot switch back.
            const screen = if (self.host.asNumber(node)) |value| sdk.text.roundToInt(i64, value) else 0;
            if (screen >= 1 and screen <= 3) {
                self.lcd.screen = @enumFromInt(screen - 1);
                self.lcd.screen_set = true;
            } else {
                self.host.logMessage(.warn, "lcd_screen must be 1, 2 or 3; ignored");
            }
        }
        if (self.host.member(config, "lcd_color")) |node| {
            const parsed = if (self.host.asString(node)) |color_text| sdk.color.parseHex(color_text) else null;
            if (parsed) |color| {
                self.lcd.color = color;
                self.lcd.color_set = true;
            } else {
                self.host.logMessage(.warn, "lcd_color must be a color such as \"#FFFFFF\"; ignored");
            }
        }
        if (self.host.member(config, "lcd_logo_color")) |node| {
            const parsed = if (self.host.asString(node)) |color_text| sdk.color.parseHex(color_text) else null;
            if (parsed == null) {
                self.host.logMessage(.warn, "lcd_logo_color must be a color such as \"#000000\"; ignored");
            } else if (!self.lcd.screen_set) {
                self.host.logMessage(.warn, "lcd_logo_color colors a built-in screen, so it needs lcd_screen; ignored");
            } else {
                self.lcd.logo_color = parsed;
            }
        }
        const node = self.host.member(config, "lcd_metrics") orelse return;
        if (self.host.kind(node) != abi.json_array) {
            self.host.logMessage(.warn, "lcd_metrics must be an array of names; using temp, load, fan and power");
            return;
        }
        var flags: u8 = 0;
        const length = self.host.length(node);
        var index: u32 = 0;
        while (index < length) : (index += 1) {
            const metric = if (self.host.asString(self.host.at(node, index))) |name| lcd.parseMetric(name) else null;
            if (metric) |value| {
                flags |= lcd.bit(value);
            } else {
                self.host.logMessage(.warn, "an lcd_metrics entry is not temp, clock, load, fan, vram_clock, vram or power; ignored");
            }
        }
        if (flags == 0) {
            self.host.logMessage(.warn, "lcd_metrics selects nothing; using temp, load, fan and power");
            return;
        }
        self.lcd.flags = flags;
    }

    fn findLcd(self: *Instance) LcdSearch {
        var api = &(self.nvapi orelse return .no_card);
        self.lcd.found = false;
        var handles: [sdk.nvapi.max_gpus]?sdk.nvapi.GpuHandle = undefined;
        const count = api.gpus(&handles);
        var saw_card = false;
        for (handles[0..count]) |maybe_handle| {
            const handle = maybe_handle orelse continue;
            const pci = api.pciIds(handle) orelse continue;
            if (!lcd.supports(pci.device(), pci.subvendor(), pci.subdevice())) continue;
            saw_card = true;
            // A card has one LCD controller, so once one was found on it, only that one is
            // asked again, at its own speed.
            const adopted_here = if (self.lcd.handle) |card| card == handle else false;
            const ask_ex = !adopted_here or self.lcd.kind == .ex;
            const ask_legacy = !adopted_here or self.lcd.kind == .legacy;
            var ex_miss: ?QueryMiss = null;
            if (ask_ex) {
                // Gigabyte's software asks for its newer controller first and falls back to the
                // older one.
                switch (self.findExPanel(api, handle)) {
                    .found => return .found,
                    .skip => continue,
                    .fallback => |miss| ex_miss = miss,
                }
            }
            if (!ask_legacy) {
                self.noteLcdProblem(.{ .silent = .{ .ex = ex_miss, .legacy = null } });
                continue;
            }
            api.speed = sdk.nvapi.i2c_speed_400khz;
            var frame: [lcd.frame_length]u8 = undefined;
            var reply: [lcd.reply_length]u8 = undefined;
            lcd.buildReadFirmware(&frame);
            switch (queryLcd(api, handle, lcd.address, &frame, &reply)) {
                .answered => {},
                .refused => |status| {
                    self.noteLcdProblem(.{ .silent = .{ .ex = ex_miss, .legacy = .{ .refused = status } } });
                    continue;
                },
                .no_reply => |status| {
                    self.noteLcdProblem(.{ .silent = .{ .ex = ex_miss, .legacy = .{ .no_reply = status } } });
                    continue;
                },
                .busy => {
                    self.noteLcdProblem(.busy);
                    continue;
                },
            }
            const firmware = lcd.parseFirmware(&reply) orelse {
                self.noteLcdProblem(.{ .unrecognized = reply });
                continue;
            };
            // Once rgbctrl switched screens, DE reports its own screen, not the one to restore.
            if (!self.lcd.active) {
                self.lcd.original = readPanelState(api, handle);
                if (self.lcd.original == null) self.host.logMessage(.warn, "the GPU LCD did not report its screen; the readout goes on the screen it shows now");
            }
            self.adoptLcd(handle, .legacy);
            const digits = "0123456789ABCDEF";
            const version = [_]u8{ 'F', digits[firmware >> 4], '.', digits[firmware & 0xF] };
            self.logLcdFound("the older controller, firmware ", &version, "");
            if (self.lcd.readout and self.lcd.logo_color != null) self.host.logMessage(.warn, "the older GPU LCD controller ignores lcd_logo_color");
            return .found;
        }
        if (!saw_card) {
            self.noteLcdProblem(.no_card);
            return .no_card;
        }
        return .no_answer;
    }

    const ExSearch = union(enum) { found, fallback: QueryMiss, skip };

    /// Asks for Gigabyte's newer LCD controller at 0x76, at the 100 kHz its software uses there.
    fn findExPanel(self: *Instance, api: *sdk.nvapi.Nvapi, handle: sdk.nvapi.GpuHandle) ExSearch {
        api.speed = sdk.nvapi.i2c_speed_100khz;
        var frame: [lcd.frame_length]u8 = undefined;
        var reply: [lcd.reply_length]u8 = undefined;
        lcd.buildExReadFirmware(&frame);
        const result = queryLcd(api, handle, lcd.ex_address, &frame, &reply);
        const firmware = switch (lcd.classifyExProbe(result, &reply)) {
            .panel => |version| version,
            .fallback => {
                self.host.logMessage(.debug, "no newer GPU LCD controller answered the firmware query at 0x76");
                return .{ .fallback = switch (result) {
                    .refused => |status| .{ .refused = status },
                    .no_reply => |status| .{ .no_reply = status },
                    else => .no_firmware,
                } };
            },
            .unclear => {
                if (result == .busy) {
                    self.noteLcdProblem(.busy);
                } else {
                    self.noteLcdProblem(.{ .unrecognized_ex = reply });
                }
                return .skip;
            },
        };
        // This panel cannot report its screen, so there is no screen to restore.
        self.lcd.original = null;
        self.adoptLcd(handle, .ex);
        var major: [20]u8 = undefined;
        var minor: [20]u8 = undefined;
        var version: [41]u8 = undefined;
        var length = appendText(&version, 0, decimal(&major, firmware.major));
        length = appendText(&version, length, ".");
        length = appendText(&version, length, decimal(&minor, firmware.minor));
        const where = if (self.lcd.screen_set) " on the built-in screen set by lcd_screen" else " over the screen it shows now";
        self.logLcdFound("Gigabyte's newer controller, firmware ", version[0..length], where);
        if (self.lcd.readout and self.lcd.seconds > lcd.ex_max_seconds) self.host.logMessage(.warn, "this GPU LCD shows each reading for at most 10 s; lcd_seconds above 10 counts as 10");
        return .found;
    }

    fn adoptLcd(self: *Instance, handle: sdk.nvapi.GpuHandle, kind: lcd.Kind) void {
        self.lcd.kind = kind;
        self.lcd.handle = handle;
        self.lcd.bus_speed = switch (kind) {
            .legacy => sdk.nvapi.i2c_speed_400khz,
            .ex => sdk.nvapi.i2c_speed_100khz,
        };
        self.lcd.found = true;
        self.lcd.setup_pending = true;
        self.lcd.last_sent = null;
        self.lcd.problem = null;
    }

    /// NVAPI set to the speed for `handle`. Once a panel was found on a card, every transfer to
    /// that card, lighting included, runs at the speed Gigabyte's software uses for that panel:
    /// RGB writes at another speed on the same bus were reported to wedge it. With `lcd` on, an
    /// LCD card whose panel has not answered yet gets 100 kHz, never an unspecified speed; other
    /// cards keep the driver's.
    fn busFor(self: *Instance, handle: sdk.nvapi.GpuHandle, lcd_card: bool) *sdk.nvapi.Nvapi {
        const api = &self.nvapi.?;
        const panel_card = if (self.lcd.handle) |card| card == handle else false;
        api.speed = if (panel_card)
            self.lcd.bus_speed
        else if (self.lcd.enabled and lcd_card)
            sdk.nvapi.i2c_speed_100khz
        else
            sdk.nvapi.i2c_speed_default;
        return api;
    }

    fn overlaySeconds(self: *const Instance) u8 {
        return if (self.lcd.kind == .ex) @min(self.lcd.seconds, lcd.ex_max_seconds) else self.lcd.seconds;
    }

    fn lcdAddress(self: *const Instance) u7 {
        return if (self.lcd.kind == .ex) lcd.ex_address else lcd.address;
    }

    fn logLcdFound(self: *Instance, controller: []const u8, version: []const u8, where: []const u8) void {
        var names: [64]u8 = undefined;
        var number: [20]u8 = undefined;
        if (self.lcd.readout) {
            logParts(self.host, .info, &.{ "GPU LCD found: ", controller, version, "; in run it shows ", lcd.describe(&names, self.lcd.flags), " for ", decimal(&number, self.overlaySeconds()), " s each", where });
        } else {
            logParts(self.host, .info, &.{ "GPU LCD found: ", controller, version, "; lcd_readout is off, so rgbctrl sends the panel nothing but read-only queries" });
        }
    }

    /// Reports a problem once, and again only when the panel starts failing differently.
    fn noteLcdProblem(self: *Instance, problem: LcdProblem) void {
        if (self.lcd.problem) |last| {
            if (std.meta.eql(last, problem)) return;
        }
        self.lcd.problem = problem;
        var bytes: [lcd.reply_length * 3]u8 = undefined;
        var ex_text: [48]u8 = undefined;
        var legacy_text: [48]u8 = undefined;
        // Only the readout probes again later; without it the probe at start is the only one.
        const next = if (self.lcd.readout) "; retrying every 30 s" else "; not asked again until rgbctrl restarts";
        switch (problem) {
            .no_card => self.host.logMessage(.warn, "lcd is on, but no GPU with a supported LCD (RTX 5080 AORUS MASTER ICE) was found"),
            .busy => logParts(self.host, .warn, &.{ "the rgbctrl I2C lock stayed taken, so the GPU LCD was not queried", next }),
            .silent => |silent| {
                // Only an address that was asked appears; one alone is a panel found earlier.
                if (silent.ex != null and silent.legacy != null) {
                    logParts(self.host, .warn, &.{ "no GPU LCD answered the firmware query: 0x76 (", describeMiss(&ex_text, silent.ex.?), "), 0x61 (", describeMiss(&legacy_text, silent.legacy.?), ")", next });
                } else if (silent.ex) |miss| {
                    logParts(self.host, .warn, &.{ "the GPU LCD at 0x76 no longer answers the firmware query (", describeMiss(&ex_text, miss), ")", next });
                } else if (silent.legacy) |miss| {
                    logParts(self.host, .warn, &.{ "the GPU LCD at 0x61 no longer answers the firmware query (", describeMiss(&legacy_text, miss), ")", next });
                }
            },
            .unrecognized => |reply| logParts(self.host, .warn, &.{ "the GPU LCD firmware reply ", sdk.text.hexBytes(&bytes, &reply), " from 0x61 is not recognized, so the LCD stays untouched", next }),
            .unrecognized_ex => |reply| logParts(self.host, .warn, &.{ "the GPU LCD firmware reply ", sdk.text.hexBytes(&bytes, &reply), " from 0x76 is not recognized, so the LCD stays untouched", next }),
        }
    }

    fn writeLcd(self: *Instance, handle: sdk.nvapi.GpuHandle, frame: *const [lcd.frame_length]u8) bool {
        const api = self.busFor(handle, true);
        traceLcdWrite(self.host, frame);
        if (api.writeRetrying(handle, self.lcdAddress(), frame)) return true;
        if (self.lcd.failures == 0) {
            var number: [20]u8 = undefined;
            logParts(self.host, .warn, &.{ "GPU LCD write failed (NVAPI status ", decimal(&number, api.last_status), "); retrying in 30 s" });
        }
        return false;
    }

    fn setupLcd(self: *Instance, handle: sdk.nvapi.GpuHandle) bool {
        // Set before the first command, so close() also undoes a setup that failed halfway.
        self.lcd.active = true;
        const done = switch (self.lcd.kind) {
            .legacy => self.setupLegacyLcd(handle),
            .ex => self.setupExLcd(handle),
        };
        if (done) self.host.logMessage(.debug, "GPU LCD overlay switched on");
        return done;
    }

    fn setupLegacyLcd(self: *Instance, handle: sdk.nvapi.GpuHandle) bool {
        var frame: [lcd.frame_length]u8 = undefined;
        lcd.buildOpen(&frame, true);
        if (!self.writeLcd(handle, &frame)) return false;
        lcd.buildOverlay(&frame, 0, 0);
        if (!self.writeLcd(handle, &frame)) return false;
        // A screen that could not be read could not be restored either, so it stays.
        if (self.lcd.original != null) {
            lcd.buildSetMode(&frame, self.lcd.screen);
            if (!self.writeLcd(handle, &frame)) return false;
            sdk.win32.Sleep(300);
        }
        lcd.buildOverlay(&frame, self.lcd.flags, self.lcd.seconds);
        return self.writeLcd(handle, &frame);
    }

    /// What Gigabyte's software sends when its LCD page loads, less what cannot be undone unless
    /// it was asked for (see lcd.exSetupSteps), plus the colors of its lighting page. It saves
    /// none of it until Apply, and rgbctrl never saves.
    fn setupExLcd(self: *Instance, handle: sdk.nvapi.GpuHandle) bool {
        var frame: [lcd.frame_length]u8 = undefined;
        var areas: [lcd.ex_area_count]lcd.ExAreaColor = undefined;
        const text_color: ?abi.Rgb = if (self.lcd.color_set) self.lcd.color else null;
        // Colors only for a built-in screen that rgbctrl set, so their areas are known to exist.
        const area_colors = if (self.lcd.screen_set) lcd.exAreaColors(&areas, self.lcd.screen, text_color, self.lcd.logo_color) else areas[0..0];
        for (lcd.exSetupSteps(self.lcd.screen_set, area_colors.len > 0)) |step| {
            switch (step) {
                .open => lcd.buildExOpen(&frame, true),
                .set_mode => lcd.buildExSetMode(&frame, self.lcd.screen),
                .overlay_switch => lcd.buildExOverlaySwitch(&frame, true),
                .overlay => lcd.buildExOverlay(&frame, self.lcd.flags, self.overlaySeconds(), self.lcd.color),
                .area_colors => {
                    for (area_colors) |area_color| {
                        lcd.buildExAreaColor(&frame, area_color.area, area_color.color);
                        if (!self.writeLcd(handle, &frame)) return false;
                        sdk.win32.Sleep(lcd.ex_area_pause_ms);
                    }
                    continue;
                },
            }
            if (!self.writeLcd(handle, &frame)) return false;
        }
        return true;
    }

    fn lcdFailed(self: *Instance, now_ms: u64) void {
        self.lcd.failures += 1;
        self.lcd.setup_pending = true;
        self.lcd.retry_at_ms = now_ms + lcd_retry_ms;
    }

    fn tickLcd(self: *Instance, now_ms: u64) void {
        if (!self.lcd.enabled or self.nvapi == null or self.host.mode() != abi.mode_run) return;
        // Without lcd_readout the probe in open() is all the panel gets: no setup, no values
        // and no periodic re-probes.
        if (!self.lcd.readout) return;
        // After sleep every reading is as old as the sleep, which restarts the grace instead of
        // reporting the sensors missing.
        if (now_ms -| self.lcd.last_tick_ms > lcd.hold_ms) {
            for (&self.lcd.holds) |*hold| hold.restart(now_ms);
        }
        self.lcd.last_tick_ms = now_ms;
        if (now_ms < self.lcd.retry_at_ms) return;
        var readings: [8]f64 = @splat(0);
        var waiting = true;
        for (lcd.metric_sensors, 0..) |name, index| {
            if ((self.lcd.flags >> @intCast(index)) & 1 == 0) continue;
            const reading: ?lcd.SensorHold.Reading = if (self.host.getSensor(name)) |sensor| .{ .value = sensor.value, .age_ms = sensor.age_ms } else null;
            const resolution = self.lcd.holds[index].resolve(reading, now_ms);
            if (resolution.became_unavailable) logParts(self.host, .warn, &.{ "sensor ", name, " unavailable; the GPU LCD shows 0 for it" });
            if (!resolution.pending) waiting = false;
            readings[index] = resolution.value;
        }
        // The panel is left alone until nvidia_gpu delivers or the sensors' grace time is over.
        if (waiting) return;
        if (!self.lcd.found or self.lcd.failures >= lcd_reprobe_after_failures) {
            self.lcd.failures = 0;
            const search = self.findLcd();
            // A card that vanishes while the readout is up may come back after a driver reset.
            if (search == .no_card and !self.lcd.active) {
                self.lcd.enabled = false;
                return;
            }
            if (search != .found) {
                self.lcd.retry_at_ms = now_ms + lcd_retry_ms;
                return;
            }
        }
        const handle = self.lcd.handle orelse return;
        if (self.lcd.setup_pending) {
            if (!self.setupLcd(handle)) return self.lcdFailed(now_ms);
            self.lcd.setup_pending = false;
            self.lcd.last_sent = null;
        }
        const encoded = lcd.encode(self.lcd.flags, readings);
        var frame: [lcd.frame_length]u8 = undefined;
        switch (self.lcd.kind) {
            .legacy => {
                if (self.lcd.last_sent) |previous| {
                    if (!lcd.worthSending(self.lcd.flags, previous, encoded) and now_ms -| self.lcd.last_sent_ms < lcd.refresh_after_ms) return;
                }
                lcd.buildValues(&frame, encoded);
            },
            // Gigabyte's service sends this panel its values every second. How long the panel
            // keeps values without an update is not known, so rgbctrl does the same.
            .ex => lcd.buildExValues(&frame, encoded),
        }
        if (!self.writeLcd(handle, &frame)) return self.lcdFailed(now_ms);
        self.lcd.last_sent = encoded;
        self.lcd.last_sent_ms = now_ms;
        self.lcd.failures = 0;
    }

    fn restoreLcd(self: *Instance) void {
        if (!self.lcd.active or self.nvapi == null) return;
        const handle = self.lcd.handle orelse return;
        const api = self.busFor(handle, true);
        var frame: [lcd.frame_length]u8 = undefined;
        if (self.lcd.kind == .ex) {
            // The screen and the colors stay: this panel cannot report the ones it had before.
            lcd.buildExOverlaySwitch(&frame, false);
            traceLcdWrite(self.host, &frame);
            _ = api.writeRetrying(handle, lcd.ex_address, &frame);
            return;
        }
        lcd.buildOverlay(&frame, 0, 0);
        traceLcdWrite(self.host, &frame);
        _ = api.writeRetrying(handle, lcd.address, &frame);
        const original = self.lcd.original orelse return;
        if (original.mode != self.lcd.screen) {
            lcd.buildSetMode(&frame, original.mode);
            traceLcdWrite(self.host, &frame);
            _ = api.writeRetrying(handle, lcd.address, &frame);
        }
        if (original.on) return;
        sdk.win32.Sleep(300);
        lcd.buildOpen(&frame, false);
        traceLcdWrite(self.host, &frame);
        _ = api.writeRetrying(handle, lcd.address, &frame);
    }
};

fn queryLcd(api: *sdk.nvapi.Nvapi, handle: sdk.nvapi.GpuHandle, address: u7, frame: *const [lcd.frame_length]u8, reply: *[lcd.reply_length]u8) sdk.nvapi.Exchange {
    var result = api.exchange(handle, address, frame, reply);
    var tries: u32 = 1;
    while (result != .answered and tries < lcd_query_attempts) : (tries += 1) {
        sdk.win32.Sleep(lcd_query_pause_ms);
        result = api.exchange(handle, address, frame, reply);
    }
    return result;
}

fn readPanelState(api: *sdk.nvapi.Nvapi, handle: sdk.nvapi.GpuHandle) ?lcd.PanelState {
    var frame: [lcd.frame_length]u8 = undefined;
    var reply: [lcd.reply_length]u8 = undefined;
    lcd.buildReadMode(&frame);
    for (0..lcd_query_attempts) |_| {
        if (queryLcd(api, handle, lcd.address, &frame, &reply) != .answered) return null;
        if (lcd.parseState(&reply)) |state| return state;
    }
    return null;
}

fn assignIds(devices: []Device) void {
    for (devices, 0..) |*device, index| {
        var id_buffer: [max_id_len + 1]u8 = undefined;
        var ordinal: usize = 0;
        while (true) : (ordinal += 1) {
            const candidate_id = protocol.deviceId(&id_buffer, index, device.identity.subdevice_id, ordinal);
            if (!idTaken(devices[0..index], candidate_id)) {
                device.link(candidate_id);
                break;
            }
        }
    }
}

fn idTaken(earlier: []const Device, id: []const u8) bool {
    for (earlier) |*device| {
        if (std.mem.eql(u8, std.mem.sliceTo(&device.id_buffer, 0), id)) return true;
    }
    return false;
}

fn candidateLessThan(_: void, left: Candidate, right: Candidate) bool {
    return protocol.compareIdentity({}, left.identity, right.identity);
}

fn sameDevices(left: []const Device, right: []const Device) bool {
    if (left.len != right.len) return false;
    for (left, right) |left_device, right_device| {
        if (!sameIdentity(left_device.identity, right_device.identity)) return false;
        if (left_device.family != right_device.family) return false;
    }
    return true;
}

fn sameIdentity(left: protocol.PciIdentity, right: protocol.PciIdentity) bool {
    return left.device_id == right.device_id and left.subvendor_id == right.subvendor_id and left.subdevice_id == right.subdevice_id and left.revision == right.revision;
}

fn logSkippedGpu(host: sdk.HostApi, identity: protocol.PciIdentity) void {
    var buffer: [64]u8 = undefined;
    var index = appendText(&buffer, 0, "skipping GPU PCI ");
    index = appendHex16(&buffer, index, identity.device_id);
    index = appendText(&buffer, index, ":");
    index = appendHex16(&buffer, index, identity.subvendor_id);
    index = appendText(&buffer, index, ":");
    index = appendHex16(&buffer, index, identity.subdevice_id);
    host.logMessage(.debug, buffer[0..index]);
}

fn appendText(buffer: []u8, start: usize, text: []const u8) usize {
    @memcpy(buffer[start .. start + text.len], text);
    return start + text.len;
}

fn describeMiss(buffer: *[48]u8, miss: QueryMiss) []const u8 {
    var number: [20]u8 = undefined;
    var length: usize = 0;
    switch (miss) {
        .refused => |status| {
            length = appendText(buffer, length, "refused, NVAPI status ");
            length = appendText(buffer, length, decimal(&number, status));
        },
        .no_reply => |status| {
            length = appendText(buffer, length, "no reply, NVAPI status ");
            length = appendText(buffer, length, decimal(&number, status));
        },
        .no_firmware => length = appendText(buffer, length, "no firmware reported"),
    }
    return buffer[0..length];
}

fn logParts(host: sdk.HostApi, level: abi.LogLevel, parts: []const []const u8) void {
    var buffer: [256]u8 = undefined;
    var length: usize = 0;
    for (parts) |part| {
        const count = @min(part.len, buffer.len - length);
        length = appendText(&buffer, length, part[0..count]);
    }
    host.logMessage(level, buffer[0..length]);
}

/// Every command frame for the LCD, without its zero padding, for a trace-level log. All of
/// them fit in the first 32 bytes.
fn traceLcdWrite(host: sdk.HostApi, frame: *const [lcd.frame_length]u8) void {
    var hex: [96]u8 = undefined;
    const command = std.mem.trimEnd(u8, frame[0..32], &.{0});
    logParts(host, .trace, &.{ "LCD write ", sdk.text.hexBytes(&hex, command) });
}

fn decimal(buffer: *[20]u8, value: i64) []const u8 {
    var remaining: u64 = @abs(value);
    var start: usize = buffer.len;
    while (true) {
        start -= 1;
        buffer[start] = '0' + @as(u8, @intCast(remaining % 10));
        remaining /= 10;
        if (remaining == 0) break;
    }
    if (value < 0) {
        start -= 1;
        buffer[start] = '-';
    }
    return buffer[start..];
}

fn appendHex16(buffer: []u8, start: usize, value: u16) usize {
    const digits = "0123456789ABCDEF";
    buffer[start] = digits[(value >> 12) & 0xF];
    buffer[start + 1] = digits[(value >> 8) & 0xF];
    buffer[start + 2] = digits[(value >> 4) & 0xF];
    buffer[start + 3] = digits[value & 0xF];
    return start + 4;
}

var panic_host: ?*const abi.Host = null;

fn reportPanic(message: []const u8) void {
    const host = panic_host orelse return;
    host.log(host.ctx, @intFromEnum(abi.LogLevel.err), message.ptr, message.len);
}

fn instanceFrom(pointer: ?*anyopaque) *Instance {
    return @ptrCast(@alignCast(pointer.?));
}

fn open(host: *const abi.Host, config: ?*const abi.Json, instance_out: *?*anyopaque) callconv(.c) i32 {
    panic_host = host;
    sdk.panic.hook = reportPanic;
    const self = std.heap.page_allocator.create(Instance) catch return abi.status_fail;
    self.* = .{ .host = .{ .host = host } };
    self.readLcdConfig(config);
    self.nvapi = sdk.nvapi.Nvapi.load() catch |err| {
        switch (err) {
            error.NotInstalled => self.host.logMessage(.debug, "NVAPI unavailable (no NVIDIA driver); gigabyte_gpu has nothing to do"),
            error.BusLockUnavailable => self.host.logMessage(.warn, "the NVAPI I2C lock Local\\rgbctrl.nvapi.i2c cannot be created; GPU lighting stays off"),
            error.MissingFunction, error.InitializeFailed => self.host.logMessage(.warn, "NVAPI could not be initialized; GPU lighting stays off"),
        }
        instance_out.* = self;
        return abi.status_ok;
    };
    // With lcd on, the LCD is asked first, before any traffic to the lighting controller, as
    // CodeTorch's AorusLcd does; the card whose panel answers then runs all of its I2C at that
    // panel's speed (see busFor).
    if (self.lcd.enabled and self.findLcd() == .no_card) self.lcd.enabled = false;
    _ = self.discover(true);
    instance_out.* = self;
    return abi.status_ok;
}

fn close(pointer: ?*anyopaque, reason: u32) callconv(.c) void {
    _ = reason;
    const self = instanceFrom(pointer);
    // A reopen may come with lcd off or the plugin disabled, and nothing would feed the
    // readout after this, so it never stays up frozen.
    self.restoreLcd();
    if (self.nvapi) |*api| api.deinit();
    std.heap.page_allocator.destroy(self);
}

fn deviceCount(pointer: ?*anyopaque) callconv(.c) u32 {
    return @intCast(instanceFrom(pointer).device_count);
}

fn deviceInfo(pointer: ?*anyopaque, device_index: u32) callconv(.c) ?*const abi.DeviceInfo {
    const self = instanceFrom(pointer);
    if (device_index >= self.device_count) return null;
    return &self.devices[device_index].info;
}

fn setHwEffect(pointer: ?*anyopaque, device_index: u32, zone_index: u32, effect: *const abi.HwEffect) callconv(.c) i32 {
    const self = instanceFrom(pointer);
    if (device_index >= self.device_count) return abi.status_argument;
    var device = &self.devices[device_index];
    if (zone_index >= device.info.zone_count) return abi.status_argument;
    const effect_kind = effect.effectKind() orelse return abi.status_argument;
    var zone = &device.zone_storage[zone_index];
    switch (device.family) {
        .legacy => {
            const packet = protocol.buildLegacyModePacket(protocol.zones(device.layout)[zone_index].legacy_index, effect_kind, effect.speed, effect.brightness) orelse return abi.status_unsupported;
            const status = self.write(device, &packet);
            if (status != abi.status_ok) return status;
            zone.legacy_mode = protocol.legacyMode(effect_kind) orelse 0x01;
            if (effect_kind == .off or effect_kind == .static or effect_kind == .breathing or effect_kind == .flash) {
                var color_buffer = [1]abi.Rgb{if (effect_kind == .off) abi.Rgb.black else effect.color(0)};
                const color_packet = protocol.buildLegacyColorPacket(protocol.zones(device.layout)[zone_index], &color_buffer, zone.legacy_mode);
                const color_status = self.write(device, &color_packet);
                if (color_status != abi.status_ok) return color_status;
            }
        },
        .blackwell => {
            const packet = protocol.buildBlackwellHardwarePacket(protocol.zones(device.layout)[zone_index].blackwell_index, effect_kind, effect.speed, effect.brightness, effect.color(0), @intCast(zone.info.led_count)) orelse return abi.status_unsupported;
            const status = self.write(device, &packet);
            if (status != abi.status_ok) return status;
        },
    }
    zone.host_streamed = false;
    zone.mode_pending = false;
    zone.dirty = false;
    return abi.status_ok;
}

fn setLeds(pointer: ?*anyopaque, device_index: u32, zone_index: u32, colors: [*]const abi.Rgb, count: u32) callconv(.c) i32 {
    const self = instanceFrom(pointer);
    if (device_index >= self.device_count) return abi.status_argument;
    var device = &self.devices[device_index];
    if (zone_index >= device.info.zone_count) return abi.status_argument;
    var zone = &device.zone_storage[zone_index];
    const copied_count: usize = @min(count, zone.info.led_count);
    var changed = false;
    for (0..copied_count) |index| {
        changed = changed or !abi.Rgb.eql(zone.colors[index], colors[index]);
        zone.colors[index] = colors[index];
    }
    for (copied_count..zone.info.led_count) |index| {
        changed = changed or !abi.Rgb.eql(zone.colors[index], abi.Rgb.black);
        zone.colors[index] = abi.Rgb.black;
    }
    zone.host_streamed = true;
    zone.dirty = zone.dirty or changed or zone.mode_pending;
    return abi.status_ok;
}

fn flush(pointer: ?*anyopaque, device_index: u32) callconv(.c) i32 {
    const self = instanceFrom(pointer);
    if (device_index >= self.device_count) return abi.status_argument;
    var device = &self.devices[device_index];
    const specs = protocol.zones(device.layout);
    for (device.zone_storage[0..device.info.zone_count], 0..) |*zone, zone_index| {
        if (!zone.host_streamed or !zone.dirty) continue;
        switch (device.family) {
            .legacy => {
                if (zone.mode_pending) {
                    const mode_packet = protocol.buildLegacyModePacket(specs[zone_index].legacy_index, .static, 50, 100).?;
                    const mode_status = self.write(device, &mode_packet);
                    if (mode_status != abi.status_ok) return mode_status;
                    zone.legacy_mode = 0x01;
                    zone.mode_pending = false;
                }
                const packet = protocol.buildLegacyColorPacket(specs[zone_index], zone.colors[0..zone.info.led_count], zone.legacy_mode);
                const status = self.write(device, &packet);
                if (status != abi.status_ok) return status;
            },
            .blackwell => {
                const packet = protocol.buildBlackwellHostPacket(specs[zone_index].blackwell_index, zone.colors[0..zone.info.led_count], @intCast(zone.info.led_count));
                const status = self.write(device, &packet);
                if (status != abi.status_ok) return status;
                zone.mode_pending = false;
            },
        }
        zone.dirty = false;
    }
    return abi.status_ok;
}

fn tick(pointer: ?*anyopaque, now_ms: u64) callconv(.c) i32 {
    instanceFrom(pointer).tickLcd(now_ms);
    return abi.status_ok;
}

fn rescan(pointer: ?*anyopaque, reason: u32) callconv(.c) i32 {
    const self = instanceFrom(pointer);
    switch (reason) {
        abi.rescan_resume => {
            for (self.devices[0..self.device_count]) |*device| device.markResume();
            self.lcd.setup_pending = true;
            self.lcd.retry_at_ms = 0;
            return abi.status_ok;
        },
        abi.rescan_recover => return self.discover(false),
        else => return abi.status_ok,
    }
}

fn persist(pointer: ?*anyopaque, device_index: u32) callconv(.c) i32 {
    const self = instanceFrom(pointer);
    if (device_index >= self.device_count) return abi.status_argument;
    var device = &self.devices[device_index];
    if (device.anyHostStreamed()) return abi.status_busy;
    switch (device.family) {
        .legacy => {
            const packet = protocol.buildLegacyPersistPacket();
            return self.write(device, &packet);
        },
        .blackwell => {
            const packet = protocol.buildBlackwellPersistPacket();
            return self.write(device, &packet);
        },
    }
}

const plugin = abi.Plugin{
    .name = "gigabyte_gpu",
    .version = "0.1.0",
    .tick_interval_ms = 1000,
    .transports = abi.transport_i2c,
    .open = open,
    .close = close,
    .device_count = deviceCount,
    .device_info = deviceInfo,
    .set_hw_effect = setHwEffect,
    .set_leds = setLeds,
    .flush = flush,
    .tick = tick,
    .rescan = rescan,
    .persist = persist,
};

export fn rgbctrl_plugin_entry(host_abi_version: u32) callconv(.c) ?*const abi.Plugin {
    if (host_abi_version < 1) return null;
    return &plugin;
}

test {
    _ = protocol;
    _ = lcd;
}

test "decimal writes integers without leading zeros and with a minus sign" {
    var buffer: [20]u8 = undefined;
    try std.testing.expectEqualStrings("0", decimal(&buffer, 0));
    try std.testing.expectEqualStrings("4", decimal(&buffer, 4));
    try std.testing.expectEqualStrings("255", decimal(&buffer, 255));
    try std.testing.expectEqualStrings("-1", decimal(&buffer, -1));
    try std.testing.expectEqualStrings("-2147483648", decimal(&buffer, std.math.minInt(i32)));
    try std.testing.expectEqualStrings("-9223372036854775808", decimal(&buffer, std.math.minInt(i64)));
}

test "device info pointers refer to the device's own storage after the device moves" {
    var devices: [2]Device = undefined;
    devices[0] = .{ .handle = @ptrFromInt(0x1000), .identity = .{ .device_id = 0x2C02, .subvendor_id = 0x1458, .subdevice_id = 0x418C, .revision = 0 }, .family = .blackwell, .layout = .blackwell_master_5080, .address = protocol.blackwell_address };
    devices[0].resetZones("AORUS RTX 5080");
    devices[0].link("gpu");
    devices[1] = devices[0];
    devices[1].link("gpu_418c");
    try std.testing.expectEqual(@intFromPtr(&devices[1].id_buffer), @intFromPtr(devices[1].info.id.?));
    try std.testing.expectEqual(@intFromPtr(&devices[1].name_buffer), @intFromPtr(devices[1].info.name.?));
    try std.testing.expectEqual(@intFromPtr(&devices[1].zone_pointers), @intFromPtr(devices[1].info.zones.?));
    for (0..devices[1].info.zone_count) |index| {
        try std.testing.expectEqual(@intFromPtr(&devices[1].zone_storage[index].info), @intFromPtr(devices[1].info.zones.?[index]));
    }
    try std.testing.expectEqualStrings("gpu_418c", std.mem.span(devices[1].info.id.?));
    try std.testing.expectEqualStrings("AORUS RTX 5080", std.mem.span(devices[1].info.name.?));
    try std.testing.expectEqual(@as(u32, 6), devices[1].info.zone_count);
}

test "device ids stay unique when different cards share a subsystem id" {
    var devices: [3]Device = undefined;
    const identities = [_]protocol.PciIdentity{
        .{ .device_id = 0x2B85, .subvendor_id = 0x1458, .subdevice_id = 0x416E, .revision = 0 },
        .{ .device_id = 0x2B85, .subvendor_id = 0x1458, .subdevice_id = 0x4176, .revision = 0 },
        .{ .device_id = 0x2C02, .subvendor_id = 0x1458, .subdevice_id = 0x4176, .revision = 0 },
    };
    for (&devices, identities) |*device, identity| {
        device.* = .{ .handle = @ptrFromInt(0x1000), .identity = identity, .family = .legacy, .layout = .legacy, .address = protocol.legacy_address };
        device.resetZones("");
    }
    assignIds(&devices);
    try std.testing.expectEqualStrings("gpu", std.mem.span(devices[0].info.id.?));
    try std.testing.expectEqualStrings("gpu_4176", std.mem.span(devices[1].info.id.?));
    try std.testing.expectEqualStrings("gpu_4176_2", std.mem.span(devices[2].info.id.?));
}
