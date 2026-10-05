const std = @import("std");
const formatting = @import("../diag/format.zig");
const sdk = @import("sdk");
const heap = @import("../heap.zig");
const json = @import("json.zig");
const layers = @import("layers.zig");
const settings_module = @import("settings.zig");
const Diagnostics = @import("diagnostics.zig").Diagnostics;
const safe_open = @import("../security/safe_open.zig");
const install_check = @import("../security/install_check.zig");

const win32 = sdk.win32;

const Settings = settings_module.Settings;

const LayerStatus = union(enum) {
    absent,
    used,
    used_untrusted: []const u8,
    parse_error: []const u8,
    unreadable: []const u8,
};

const LayerReport = struct {
    path: []const u8,
    status: LayerStatus = .absent,
    /// The file's stamp, taken just before it was read: a change after that moment differs from
    /// it, so polling the stamp never misses a change to the configuration that was loaded.
    stamp: Stamp = .{},

    pub fn failed(self: *const LayerReport) bool {
        return switch (self.status) {
            .parse_error, .unreadable => true,
            else => false,
        };
    }
};

pub const Sources = struct {
    base_directory: [:0]const u16,
    base_file: [:0]const u16,
    user_file: [:0]const u16,
    elevated: bool,
};

pub const ConfigGeneration = struct {
    arena_state: std.heap.ArenaAllocator,
    references: std.atomic.Value(u32),
    serial: u64,
    settings: Settings = .{},
    base: LayerReport = .{ .path = "" },
    user: LayerReport = .{ .path = "" },
    diagnostics: Diagnostics = undefined,
    layer_failed: bool = false,

    pub fn arena(self: *ConfigGeneration) std.mem.Allocator {
        return self.arena_state.allocator();
    }

    pub fn retain(self: *ConfigGeneration) *ConfigGeneration {
        _ = self.references.fetchAdd(1, .monotonic);
        return self;
    }

    pub fn release(self: *ConfigGeneration) void {
        if (self.references.fetchSub(1, .acq_rel) != 1) return;
        self.arena_state.deinit();
        heap.allocator.destroy(self);
    }
};

fn createEmpty(serial: u64) error{OutOfMemory}!*ConfigGeneration {
    const generation = try heap.allocator.create(ConfigGeneration);
    generation.* = .{ .arena_state = std.heap.ArenaAllocator.init(heap.allocator), .references = .init(1), .serial = serial };
    generation.diagnostics = Diagnostics.init(generation.arena());
    return generation;
}

const LoadedLayer = struct {
    root: ?*const json.Node = null,
    trusted: bool = false,
};

fn utf8Path(arena: std.mem.Allocator, path: []const u16) error{OutOfMemory}![]const u8 {
    var buffer: [2048]u8 = undefined;
    return arena.dupe(u8, sdk.text.utf16ToUtf8(&buffer, path));
}

fn readLayer(generation: *ConfigGeneration, report: *LayerReport, path: [:0]const u16, untrusted_rules: bool) error{OutOfMemory}!?[]const u8 {
    const arena = generation.arena();
    if (!untrusted_rules and !install_check.exists(path)) {
        report.status = .absent;
        return null;
    }
    const opened = (if (untrusted_rules) safe_open.openUntrusted(path.ptr) else safe_open.openPlain(path.ptr)) catch |err| {
        if (err == error.NotFound) {
            report.status = .absent;
            return null;
        }
        report.status = .{ .unreadable = safe_open.describe(err) };
        generation.layer_failed = true;
        return null;
    };
    defer opened.close();
    const content = safe_open.readAll(arena, opened.handle, json.max_source_bytes) catch |err| {
        report.status = .{ .unreadable = safe_open.describe(err) };
        generation.layer_failed = true;
        return null;
    };
    return content;
}

fn parseLayer(generation: *ConfigGeneration, report: *LayerReport, content: []const u8) error{OutOfMemory}!?*const json.Node {
    const arena = generation.arena();
    var warnings: std.ArrayList(json.Issue) = .empty;
    const outcome = try json.parse(arena, content, &warnings);
    for (warnings.items) |warning| generation.diagnostics.warn("{s} line {d}:{d}: {s}", .{ report.path, warning.line, warning.column, warning.message });
    switch (outcome) {
        .document => |document| return document,
        .failure => |issue| {
            report.status = .{ .parse_error = try formatting.allocPrint(arena, "line {d}:{d}: {s}", .{ issue.line, issue.column, issue.message }) };
            generation.layer_failed = true;
            return null;
        },
    }
}

pub fn load(serial: u64, sources: *const Sources) error{OutOfMemory}!*ConfigGeneration {
    const generation = try createEmpty(serial);
    errdefer generation.release();
    const arena = generation.arena();
    generation.base.path = try utf8Path(arena, sources.base_file);
    generation.user.path = try utf8Path(arena, sources.user_file);

    var base = LoadedLayer{};
    var base_untrusted_reason: ?[]const u8 = null;
    var base_readable = true;
    if (sources.elevated) {
        var findings: std.ArrayList(install_check.Finding) = .empty;
        switch (try install_check.checkBase(arena, sources.base_directory, &findings)) {
            .absent => base_readable = false,
            .trusted => base.trusted = true,
            .untrusted => |reason| base_untrusted_reason = reason,
        }
    } else {
        base.trusted = true;
    }
    generation.base.stamp = stampFor(sources.base_file, sources.elevated);
    if (base_readable) {
        if (try readLayer(generation, &generation.base, sources.base_file, sources.elevated and !base.trusted)) |content| {
            base.root = try parseLayer(generation, &generation.base, content);
            if (base.root != null) generation.base.status = if (base_untrusted_reason) |reason| .{ .used_untrusted = reason } else .used;
        }
    }

    var user = LoadedLayer{ .trusted = !sources.elevated };
    generation.user.stamp = stampFor(sources.user_file, sources.elevated);
    if (try readLayer(generation, &generation.user, sources.user_file, sources.elevated)) |content| {
        user.root = try parseLayer(generation, &generation.user, content);
        if (user.root != null) generation.user.status = if (sources.elevated) .{ .used_untrusted = "untrusted while elevated; privileged keys can only be tightened" } else .used;
    }

    const merged = try layers.mergeLayers(
        arena,
        .{ .label = "base", .root = base.root, .trusted = base.trusted },
        .{ .label = "user", .root = user.root, .trusted = user.trusted },
        sources.elevated,
        &generation.diagnostics,
    );
    generation.settings = settings_module.extract(merged.root, merged.untrusted_enable_requests, &generation.diagnostics);
    return generation;
}

pub const Stamp = struct {
    exists: bool = false,
    write_time: u64 = 0,
    size: u64 = 0,

    pub fn eql(self: Stamp, other: Stamp) bool {
        return self.exists == other.exists and self.write_time == other.write_time and self.size == other.size;
    }
};

fn stampOf(path: [:0]const u16) Stamp {
    var data: win32.WIN32_FILE_ATTRIBUTE_DATA = undefined;
    if (win32.GetFileAttributesExW(path.ptr, win32.GET_FILE_EX_INFO_STANDARD, &data) == 0) return .{};
    return .{ .exists = true, .write_time = data.ftLastWriteTime.toU64(), .size = (@as(u64, data.nFileSizeHigh) << 32) | data.nFileSizeLow };
}

pub fn stampFor(path: [:0]const u16, elevated: bool) Stamp {
    if (!elevated) return stampOf(path);
    const safe = safe_open.stampUntrusted(path.ptr);
    return .{ .exists = safe.exists, .write_time = safe.write_time, .size = safe.size };
}

pub fn describeStatus(buffer: []u8, status: LayerStatus) []const u8 {
    return switch (status) {
        .absent => "not found",
        .used => "used",
        .used_untrusted => |reason| formatting.print(buffer, "used without privileged keys ({s})", .{reason}),
        .parse_error => |message| formatting.print(buffer, "ignored: {s}", .{message}),
        .unreadable => |message| formatting.print(buffer, "ignored: {s}", .{message}),
    };
}

const testing = std.testing;

fn writeTemporary(buffer: []u16, name: []const u8, content: []const u8) ![:0]const u16 {
    var directory: [512]u16 = undefined;
    const length = win32.GetEnvironmentVariableW(win32.L("TEMP"), &directory, directory.len);
    if (length == 0 or length >= directory.len) return error.SkipZigTest;
    var directory_utf8: [1024]u8 = undefined;
    var joined_buffer: [1200]u8 = undefined;
    const joined = try formatting.bufPrint(&joined_buffer, "{s}\\{s}", .{ sdk.text.utf16ToUtf8(&directory_utf8, directory[0..length]), name });
    const path = sdk.text.utf8ToUtf16(buffer, joined) orelse return error.SkipZigTest;
    _ = win32.DeleteFileW(path.ptr);
    const handle = try safe_open.openAppend(path.ptr);
    defer _ = win32.CloseHandle(handle);
    var written: u32 = 0;
    _ = win32.WriteFile(handle, content.ptr, @intCast(content.len), &written, null);
    return path;
}

test "load merges a base and a user file and reports each layer" {
    var base_buffer: [600]u16 = undefined;
    var user_buffer: [600]u16 = undefined;
    const base_path = try writeTemporary(&base_buffer, "rgbctrl_generation_base.json", "{\"frame_rate\": 20, \"log\": {\"level\": \"info\"}}");
    defer _ = win32.DeleteFileW(base_path.ptr);
    const user_path = try writeTemporary(&user_buffer, "rgbctrl_generation_user.json", "// user\n{\"frame_rate\": 40,}");
    defer _ = win32.DeleteFileW(user_path.ptr);
    const sources = Sources{ .base_directory = win32.L("C:\\nonexistent-rgbctrl"), .base_file = base_path, .user_file = user_path, .elevated = false };
    const generation = try load(7, &sources);
    defer generation.release();
    try testing.expectEqual(@as(u32, 40), generation.settings.frame_rate);
    try testing.expectEqual(settings_module.LogLevel.info, generation.settings.log_level);
    try testing.expect(generation.base.status == .used);
    try testing.expect(generation.user.status == .used);
    try testing.expect(!generation.layer_failed);
}

test "a broken layer is ignored with its line and column while the other layer still applies" {
    var base_buffer: [600]u16 = undefined;
    var user_buffer: [600]u16 = undefined;
    const base_path = try writeTemporary(&base_buffer, "rgbctrl_generation_base2.json", "{\"frame_rate\": 20}");
    defer _ = win32.DeleteFileW(base_path.ptr);
    const user_path = try writeTemporary(&user_buffer, "rgbctrl_generation_user2.json", "{\"frame_rate\": }");
    defer _ = win32.DeleteFileW(user_path.ptr);
    const sources = Sources{ .base_directory = win32.L("C:\\nonexistent-rgbctrl"), .base_file = base_path, .user_file = user_path, .elevated = false };
    const generation = try load(8, &sources);
    defer generation.release();
    try testing.expectEqual(@as(u32, 20), generation.settings.frame_rate);
    try testing.expect(generation.layer_failed);
    try testing.expectEqualStrings("line 1:16: expected a value", generation.user.status.parse_error);
}

test "missing files yield the defaults" {
    const sources = Sources{ .base_directory = win32.L("C:\\nonexistent-rgbctrl"), .base_file = win32.L("C:\\nonexistent-rgbctrl\\rgbctrl.json"), .user_file = win32.L("C:\\nonexistent-rgbctrl\\user.json"), .elevated = false };
    const generation = try load(9, &sources);
    defer generation.release();
    try testing.expectEqual(@as(u32, 30), generation.settings.frame_rate);
    try testing.expect(generation.base.status == .absent);
    try testing.expect(generation.user.status == .absent);
}
