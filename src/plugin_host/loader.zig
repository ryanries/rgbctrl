const std = @import("std");
const formatting = @import("../diag/format.zig");
const sdk = @import("sdk");
const validate = @import("validate.zig");
const install_check = @import("../security/install_check.zig");

const abi = sdk.abi;
const win32 = sdk.win32;

pub const Plugin = struct {
    file_name: []const u8,
    library: win32.HMODULE,
    table: abi.Plugin,
    name: []const u8,
    version: []const u8,

    pub fn isSensorSource(self: *const Plugin) bool {
        return self.table.flags & abi.plugin_sensor_source != 0;
    }

    pub fn isOptIn(self: *const Plugin) bool {
        return self.table.flags & abi.plugin_opt_in != 0;
    }

    pub fn usesHid(self: *const Plugin) bool {
        return self.table.transports & abi.transport_hid != 0;
    }

    pub fn tickInterval(self: *const Plugin) u32 {
        return validate.effectiveTickInterval(self.table.tick_interval_ms);
    }

    pub fn capabilities(self: *const Plugin) validate.Capabilities {
        return .{ .set_leds = self.table.set_leds != null, .set_hw_effect = self.table.set_hw_effect != null, .set_zone_size = self.table.set_zone_size != null };
    }
};

pub const Failure = struct {
    file_name: []const u8,
    reason: []const u8,
};

const Result = struct {
    plugins: []Plugin,
    failures: []Failure,
};

const path_capacity = 1024;

fn lowerUnit(unit: u16) u16 {
    return if (unit >= 'A' and unit <= 'Z') unit + 32 else unit;
}

fn lessThanIgnoreCase(context: void, first: []const u16, second: []const u16) bool {
    _ = context;
    const shared = @min(first.len, second.len);
    for (first[0..shared], second[0..shared]) |a, b| {
        const lower_a = lowerUnit(a);
        const lower_b = lowerUnit(b);
        if (lower_a != lower_b) return lower_a < lower_b;
    }
    return first.len < second.len;
}

fn listDllNames(arena: std.mem.Allocator, directory: []const u16) error{OutOfMemory}![]const []const u16 {
    var names: std.ArrayList([]const u16) = .empty;
    var pattern_buffer: [path_capacity]u16 = undefined;
    const pattern = install_check.join(&pattern_buffer, directory, win32.L("*")) orelse return &.{};
    var data: win32.WIN32_FIND_DATAW = undefined;
    const find = win32.FindFirstFileW(pattern.ptr, &data);
    if (!win32.isValid(find)) return &.{};
    defer _ = win32.FindClose(find);
    while (true) {
        const name = std.mem.sliceTo(&data.cFileName, 0);
        if (data.dwFileAttributes & win32.FILE_ATTRIBUTE_DIRECTORY == 0 and install_check.endsWithIgnoreCase(name, ".dll")) {
            try names.append(arena, try arena.dupe(u16, name));
        }
        if (win32.FindNextFileW(find, &data) == 0) break;
    }
    std.sort.insertion([]const u16, names.items, {}, lessThanIgnoreCase);
    return names.items;
}

fn describeLoadError(arena: std.mem.Allocator, code: u32) error{OutOfMemory}![]const u8 {
    const hint: []const u8 = switch (code) {
        126 => " (a dependency of the DLL is missing)",
        193 => " (not a 64-bit Windows DLL)",
        1114 => " (the DLL failed to initialize)",
        else => "",
    };
    return formatting.allocPrint(arena, "LoadLibrary failed with Win32 error {d}{s}", .{ code, hint });
}

pub fn loadDirectory(arena: std.mem.Allocator, directory: []const u16) error{OutOfMemory}!Result {
    var plugins: std.ArrayList(Plugin) = .empty;
    var failures: std.ArrayList(Failure) = .empty;
    const names = try listDllNames(arena, directory);
    for (names) |name| {
        var utf8_buffer: [512]u8 = undefined;
        const file_name = try arena.dupe(u8, sdk.text.utf16ToUtf8(&utf8_buffer, name));
        var path_buffer: [path_capacity]u16 = undefined;
        const path = install_check.join(&path_buffer, directory, name) orelse {
            try failures.append(arena, .{ .file_name = file_name, .reason = "path is too long" });
            continue;
        };
        const library = win32.LoadLibraryExW(path.ptr, null, win32.LOAD_LIBRARY_SEARCH_DLL_LOAD_DIR | win32.LOAD_LIBRARY_SEARCH_SYSTEM32) orelse {
            try failures.append(arena, .{ .file_name = file_name, .reason = try describeLoadError(arena, win32.GetLastError()) });
            continue;
        };
        const reason = try register(arena, &plugins, library, file_name);
        if (reason) |text| {
            _ = win32.FreeLibrary(library);
            try failures.append(arena, .{ .file_name = file_name, .reason = text });
        }
    }
    return .{ .plugins = plugins.items, .failures = failures.items };
}

fn register(arena: std.mem.Allocator, plugins: *std.ArrayList(Plugin), library: win32.HMODULE, file_name: []const u8) error{OutOfMemory}!?[]const u8 {
    const address = win32.GetProcAddress(library, abi.entry_name) orelse return "no rgbctrl_plugin_entry export";
    const entry: abi.EntryFn = @ptrCast(@alignCast(address));
    const table_pointer = entry(abi.abi_version) orelse return "rgbctrl_plugin_entry returned NULL (the plugin cannot serve ABI version 1)";
    const header: *const [8]u8 = @ptrCast(table_pointer);
    const struct_size = std.mem.readInt(u32, header[0..4], .little);
    if (struct_size < abi.v1_size.plugin) return validate.describePluginProblem(.short_struct);
    var table: abi.Plugin = undefined;
    @memcpy(std.mem.asBytes(&table), @as([*]const u8, @ptrCast(table_pointer))[0..@sizeOf(abi.Plugin)]);
    const problem = validate.validatePluginTable(&table);
    if (problem != .none) return validate.describePluginProblem(problem);
    const name = try arena.dupe(u8, validate.boundedString(table.name, 31).?);
    for (plugins.items) |existing| {
        if (std.mem.eql(u8, existing.name, name)) return try formatting.allocPrint(arena, "plugin name \"{s}\" is already used by {s}", .{ name, existing.file_name });
    }
    try plugins.append(arena, .{
        .file_name = file_name,
        .library = library,
        .table = table,
        .name = name,
        .version = try arena.dupe(u8, validate.boundedString(table.version, 31).?),
    });
    return null;
}

test "plugin files sort case-insensitively" {
    var names = [_][]const u16{ win32.L("Zeta.dll"), win32.L("alpha.dll"), win32.L("Beta.dll") };
    std.sort.insertion([]const u16, &names, {}, lessThanIgnoreCase);
    try std.testing.expectEqualSlices(u16, win32.L("alpha.dll"), names[0]);
    try std.testing.expectEqualSlices(u16, win32.L("Beta.dll"), names[1]);
    try std.testing.expectEqualSlices(u16, win32.L("Zeta.dll"), names[2]);
}
