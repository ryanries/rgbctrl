const std = @import("std");
const formatting = @import("../diag/format.zig");
const sdk = @import("sdk");
const acl_policy = @import("acl_policy.zig");
const log = @import("../diag/log.zig");

const win32 = sdk.win32;
const ObjectKind = acl_policy.ObjectKind;

const Problem = union(enum) {
    open_failed: u32,
    reparse_point,
    hard_linked,
    path_mismatch,
    security_unreadable: u32,
    violation: acl_policy.Violation,
};

pub const Finding = struct {
    path: []const u8,
    kind: ObjectKind,
    problem: ?Problem,
};

const path_capacity = 1024;

fn checkObject(path: [:0]const u16, kind: ObjectKind, require_single_link: bool) ?Problem {
    const handle = win32.CreateFileW(path.ptr, win32.READ_CONTROL | win32.FILE_READ_ATTRIBUTES, win32.FILE_SHARE_READ | win32.FILE_SHARE_WRITE | win32.FILE_SHARE_DELETE, null, win32.OPEN_EXISTING, win32.FILE_FLAG_OPEN_REPARSE_POINT | win32.FILE_FLAG_BACKUP_SEMANTICS, null);
    if (!win32.isValid(handle)) return .{ .open_failed = win32.GetLastError() };
    defer _ = win32.CloseHandle(handle);
    var information: win32.BY_HANDLE_FILE_INFORMATION = undefined;
    if (win32.GetFileInformationByHandle(handle, &information) == 0) return .{ .open_failed = win32.GetLastError() };
    if (information.dwFileAttributes & win32.FILE_ATTRIBUTE_REPARSE_POINT != 0) return .reparse_point;
    if (require_single_link and information.nNumberOfLinks != 1) return .hard_linked;
    var owner: ?win32.PSID = null;
    var dacl: ?*win32.ACL = null;
    var descriptor: ?*anyopaque = null;
    const status = win32.GetSecurityInfo(handle, win32.SE_FILE_OBJECT, win32.OWNER_SECURITY_INFORMATION | win32.DACL_SECURITY_INFORMATION, &owner, null, &dacl, null, &descriptor);
    if (status != win32.ERROR_SUCCESS) return .{ .security_unreadable = status };
    defer _ = win32.LocalFree(descriptor);
    const violation = acl_policy.evaluate(owner, dacl, kind);
    if (violation != .none) return .{ .violation = violation };
    return null;
}

pub fn describeProblem(buffer: []u8, problem: Problem, kind: ObjectKind) []const u8 {
    var sid_buffer: [96]u8 = undefined;
    var rights_buffer: [128]u8 = undefined;
    return switch (problem) {
        .open_failed => |code| formatting.print(buffer, "cannot be opened (Win32 error {d})", .{code}),
        .reparse_point => "is a reparse point (symbolic link or junction)",
        .hard_linked => "has more than one hard link",
        .path_mismatch => "resolves to a different path",
        .security_unreadable => |code| formatting.print(buffer, "security information cannot be read (Win32 error {d})", .{code}),
        .violation => |violation| switch (violation) {
            .none => "ok",
            .missing_owner => "has no owner",
            .missing_dacl => "has no DACL, so everyone has full access",
            .unsupported_ace => |ace_type| formatting.print(buffer, "has an access entry of unsupported type {d}", .{ace_type}),
            .untrusted_owner => |sid| formatting.print(buffer, "is owned by {s} {s} instead of SYSTEM, Administrators or TrustedInstaller", .{ sid.format(&sid_buffer), friendlyName(sid.slice()) }),
            .grants => |grant| formatting.print(buffer, "allows {s} {s} to {s}", .{ grant.sid.format(&sid_buffer), friendlyName(grant.sid.slice()), acl_policy.describeRights(&rights_buffer, grant.rights, kind) }),
        },
    };
}

fn friendlyName(sid: []const u8) []const u8 {
    const known = [_]struct { bytes: []const u8, name: []const u8 }{
        .{ .bytes = &.{ 1, 1, 0, 0, 0, 0, 0, 1, 0, 0, 0, 0 }, .name = "(Everyone)" },
        .{ .bytes = &.{ 1, 1, 0, 0, 0, 0, 0, 5, 11, 0, 0, 0 }, .name = "(Authenticated Users)" },
        .{ .bytes = &.{ 1, 2, 0, 0, 0, 0, 0, 5, 32, 0, 0, 0, 0x21, 0x02, 0, 0 }, .name = "(Users)" },
        .{ .bytes = &.{ 1, 1, 0, 0, 0, 0, 0, 3, 0, 0, 0, 0 }, .name = "(CREATOR OWNER)" },
        .{ .bytes = &.{ 1, 1, 0, 0, 0, 0, 0, 5, 4, 0, 0, 0 }, .name = "(INTERACTIVE)" },
    };
    for (known) |entry| {
        if (std.mem.eql(u8, entry.bytes, sid)) return entry.name;
    }
    return "";
}

fn appendFinding(arena: std.mem.Allocator, findings: *std.ArrayList(Finding), path: []const u16, kind: ObjectKind, problem: ?Problem) error{OutOfMemory}!void {
    var utf8: [path_capacity * 3]u8 = undefined;
    const text = try arena.dupe(u8, sdk.text.utf16ToUtf8(&utf8, path));
    try findings.append(arena, .{ .path = text, .kind = kind, .problem = problem });
}

fn checkAndRecord(arena: std.mem.Allocator, findings: *std.ArrayList(Finding), path: [:0]const u16, kind: ObjectKind, require_single_link: bool) error{OutOfMemory}!bool {
    const problem = checkObject(path, kind, require_single_link);
    try appendFinding(arena, findings, path, kind, problem);
    return problem == null;
}

pub fn join(buffer: []u16, directory: []const u16, name: []const u16) ?[:0]const u16 {
    const is_drive = directory.len == 2 and directory[1] == ':';
    const needs_separator = directory.len > 0 and directory[directory.len - 1] != '\\' and (name.len > 0 or is_drive);
    const total = directory.len + @intFromBool(needs_separator) + name.len;
    if (total + 1 > buffer.len) return null;
    @memcpy(buffer[0..directory.len], directory);
    if (needs_separator) buffer[directory.len] = '\\';
    @memcpy(buffer[total - name.len .. total], name);
    buffer[total] = 0;
    return buffer[0..total :0];
}

pub fn exists(path: [:0]const u16) bool {
    return win32.GetFileAttributesW(path.ptr) != win32.INVALID_FILE_ATTRIBUTES;
}

const Presence = enum { absent, present, failed };

fn presenceWithoutFollowing(path: [:0]const u16) Presence {
    const handle = win32.CreateFileW(path.ptr, win32.FILE_READ_ATTRIBUTES, win32.FILE_SHARE_READ | win32.FILE_SHARE_WRITE | win32.FILE_SHARE_DELETE, null, win32.OPEN_EXISTING, win32.FILE_FLAG_OPEN_REPARSE_POINT | win32.FILE_FLAG_BACKUP_SEMANTICS, null);
    if (win32.isValid(handle)) {
        _ = win32.CloseHandle(handle);
        return .present;
    }
    return switch (win32.GetLastError()) {
        win32.ERROR_FILE_NOT_FOUND, win32.ERROR_PATH_NOT_FOUND => .absent,
        else => .failed,
    };
}

fn parentDirectory(path: []const u16) ?[]const u16 {
    var end = path.len;
    while (end > 0 and path[end - 1] == '\\') end -= 1;
    const separator = std.mem.lastIndexOfScalar(u16, path[0..end], '\\') orelse return null;
    if (separator == 2 and path[1] == ':') return path[0..3];
    if (separator == 0) return null;
    return path[0..separator];
}

pub fn endsWithIgnoreCase(name: []const u16, suffix: []const u8) bool {
    if (name.len < suffix.len) return false;
    const tail = name[name.len - suffix.len ..];
    for (tail, suffix) |unit, char| {
        const lowered: u16 = if (unit >= 'A' and unit <= 'Z') unit + 32 else unit;
        if (lowered != char) return false;
    }
    return true;
}

fn checkAncestors(arena: std.mem.Allocator, findings: *std.ArrayList(Finding), directory: []const u16) error{OutOfMemory}!bool {
    var ancestors: [64][]const u16 = undefined;
    var count: usize = 0;
    var current = parentDirectory(directory);
    while (current) |ancestor| {
        if (count == ancestors.len) return false;
        ancestors[count] = ancestor;
        count += 1;
        if (ancestor.len <= 3) break;
        current = parentDirectory(ancestor);
    }
    var index = count;
    while (index > 0) {
        index -= 1;
        var buffer: [path_capacity]u16 = undefined;
        const terminated = join(&buffer, ancestors[index], &.{}) orelse return false;
        if (!try checkAndRecord(arena, findings, terminated, .ancestor, false)) return false;
    }
    return true;
}

fn checkDirectoryWithFiles(arena: std.mem.Allocator, findings: *std.ArrayList(Finding), directory: [:0]const u16, suffix: []const u8) error{OutOfMemory}!bool {
    switch (presenceWithoutFollowing(directory)) {
        .absent => return true,
        .present, .failed => {},
    }
    if (!try checkAndRecord(arena, findings, directory, .directory, false)) return false;
    var ok = true;
    var pattern_buffer: [path_capacity]u16 = undefined;
    const pattern = join(&pattern_buffer, directory, win32.L("*")) orelse return false;
    var data: win32.WIN32_FIND_DATAW = undefined;
    const find = win32.FindFirstFileW(pattern.ptr, &data);
    if (!win32.isValid(find)) return ok;
    defer _ = win32.FindClose(find);
    while (true) {
        const name = std.mem.sliceTo(&data.cFileName, 0);
        if (data.dwFileAttributes & win32.FILE_ATTRIBUTE_DIRECTORY == 0 and endsWithIgnoreCase(name, suffix)) {
            var file_buffer: [path_capacity]u16 = undefined;
            if (join(&file_buffer, directory, name)) |file_path| {
                if (!try checkAndRecord(arena, findings, file_path, .file, false)) ok = false;
            }
        }
        if (win32.FindNextFileW(find, &data) == 0) break;
    }
    return ok;
}

pub fn checkInstall(arena: std.mem.Allocator, install_directory: []const u16, findings: *std.ArrayList(Finding)) error{OutOfMemory}!bool {
    if (!try checkAncestors(arena, findings, install_directory)) return false;
    var directory_buffer: [path_capacity]u16 = undefined;
    const directory = join(&directory_buffer, install_directory, &.{}) orelse return false;
    if (!try checkAndRecord(arena, findings, directory, .directory, false)) return false;
    var ok = true;
    var buffer: [path_capacity]u16 = undefined;
    const exe = join(&buffer, install_directory, win32.L("rgbctrl.exe")) orelse return false;
    if (!try checkAndRecord(arena, findings, exe, .file, false)) ok = false;
    var plugins_buffer: [path_capacity]u16 = undefined;
    const plugins = join(&plugins_buffer, install_directory, win32.L("plugins")) orelse return false;
    if (!try checkDirectoryWithFiles(arena, findings, plugins, ".dll")) ok = false;
    var pawnio_buffer: [path_capacity]u16 = undefined;
    const pawnio = join(&pawnio_buffer, install_directory, win32.L("pawnio")) orelse return false;
    if (!try checkDirectoryWithFiles(arena, findings, pawnio, ".bin")) ok = false;
    return ok;
}

pub const BaseVerdict = union(enum) {
    absent,
    trusted,
    untrusted: []const u8,
};

pub fn checkBase(arena: std.mem.Allocator, base_directory: []const u16, findings: *std.ArrayList(Finding)) error{OutOfMemory}!BaseVerdict {
    var directory_buffer: [path_capacity]u16 = undefined;
    const directory = join(&directory_buffer, base_directory, &.{}) orelse return .{ .untrusted = "path too long" };
    var file_buffer: [path_capacity]u16 = undefined;
    const file = join(&file_buffer, base_directory, win32.L("rgbctrl.json")) orelse return .{ .untrusted = "path too long" };
    const first_finding = findings.items.len;
    var ok = try checkAncestors(arena, findings, base_directory);
    if (ok) {
        switch (presenceWithoutFollowing(directory)) {
            .absent => return .absent,
            .present, .failed => {},
        }
        ok = try checkAndRecord(arena, findings, directory, .directory, false);
    }
    if (ok) {
        switch (presenceWithoutFollowing(file)) {
            .absent => return .absent,
            .present, .failed => {},
        }
        const file_problem = checkObject(file, .file, true) orelse finalPathProblem(file);
        try appendFinding(arena, findings, file, .file, file_problem);
        if (file_problem == null) return .trusted;
    }
    for (findings.items[first_finding..]) |finding| {
        const problem = finding.problem orelse continue;
        var reason_buffer: [512]u8 = undefined;
        const reason = describeProblem(&reason_buffer, problem, finding.kind);
        return .{ .untrusted = try formatting.allocPrint(arena, "{s} {s}", .{ finding.path, reason }) };
    }
    return .{ .untrusted = "unknown reason" };
}

fn finalPathProblem(path: [:0]const u16) ?Problem {
    const handle = win32.CreateFileW(path.ptr, win32.FILE_READ_ATTRIBUTES, win32.FILE_SHARE_READ | win32.FILE_SHARE_WRITE | win32.FILE_SHARE_DELETE, null, win32.OPEN_EXISTING, win32.FILE_FLAG_OPEN_REPARSE_POINT, null);
    if (!win32.isValid(handle)) return .{ .open_failed = win32.GetLastError() };
    defer _ = win32.CloseHandle(handle);
    var buffer: [path_capacity]u16 = undefined;
    // Normalized name, not opened: CreateFileW follows intermediate reparse points, and normalization exposes that.
    const length = win32.GetFinalPathNameByHandleW(handle, &buffer, buffer.len, win32.FILE_NAME_NORMALIZED | win32.VOLUME_NAME_DOS);
    if (length == 0 or length >= buffer.len) return .path_mismatch;
    var final_path: []const u16 = buffer[0..length];
    const prefix = win32.L("\\\\?\\");
    if (std.mem.startsWith(u16, final_path, prefix)) final_path = final_path[prefix.len..];
    var expected: []const u16 = path;
    if (std.mem.startsWith(u16, expected, prefix)) expected = expected[prefix.len..];
    if (final_path.len != expected.len) return .path_mismatch;
    for (final_path, expected) |a, b| {
        const upper_a: u16 = if (a >= 'a' and a <= 'z') a - 32 else a;
        const upper_b: u16 = if (b >= 'a' and b <= 'z') b - 32 else b;
        if (upper_a != upper_b) return .path_mismatch;
    }
    return null;
}

pub fn logFindings(logger: *log.Logger, findings: []const Finding, only_failures: bool) void {
    for (findings) |finding| {
        if (finding.problem) |problem| {
            var buffer: [512]u8 = undefined;
            logger.log(.err, "security", "{s} {s}", .{ finding.path, describeProblem(&buffer, problem, finding.kind) });
        } else if (!only_failures) {
            logger.log(.debug, "security", "{s} ok", .{finding.path});
        }
    }
}

const testing = std.testing;

test "parentDirectory walks up to the drive root" {
    const path = win32.L("C:\\Program Files\\rgbctrl");
    const parent = parentDirectory(path).?;
    try testing.expectEqualSlices(u16, win32.L("C:\\Program Files"), parent);
    try testing.expectEqualSlices(u16, win32.L("C:\\"), parentDirectory(parent).?);
    try testing.expect(parentDirectory(win32.L("C:\\")) == null);
}

test "endsWithIgnoreCase matches file extensions without case" {
    try testing.expect(endsWithIgnoreCase(win32.L("Keychron.DLL"), ".dll"));
    try testing.expect(!endsWithIgnoreCase(win32.L("keychron.dllx"), ".dll"));
}

test "the Windows system directory passes the install rules as an ancestor-style check" {
    var findings: std.ArrayList(Finding) = .empty;
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const system_root = win32.L("C:\\Windows\\System32");
    const problem = checkObject(system_root, .ancestor, false);
    if (problem) |found| {
        var buffer: [256]u8 = undefined;
        std.debug.print("unexpected: {s}\n", .{describeProblem(&buffer, found, .ancestor)});
        return error.TestUnexpectedResult;
    }
    _ = try checkAncestors(arena_state.allocator(), &findings, system_root);
    try testing.expect(findings.items.len >= 1);
}

test "a user-owned temporary directory fails the directory rules" {
    var directory: [512]u16 = undefined;
    const length = win32.GetEnvironmentVariableW(win32.L("TEMP"), &directory, directory.len);
    if (length == 0 or length >= directory.len) return error.SkipZigTest;
    directory[length] = 0;
    const problem = checkObject(directory[0..length :0], .directory, false);
    try testing.expect(problem != null);
}

test "a missing base folder is absent only when every ancestor passes" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var protected_findings: std.ArrayList(Finding) = .empty;
    const protected_verdict = try checkBase(arena, win32.L("C:\\Windows\\System32\\rgbctrl-missing-base-folder"), &protected_findings);
    try testing.expect(protected_verdict == .absent);
    var temporary: [512]u16 = undefined;
    const length = win32.GetEnvironmentVariableW(win32.L("TEMP"), &temporary, temporary.len);
    if (length == 0 or length + 40 >= temporary.len) return error.SkipZigTest;
    const suffix = win32.L("\\rgbctrl-missing-base-folder");
    @memcpy(temporary[length .. length + suffix.len], suffix);
    var unsafe_findings: std.ArrayList(Finding) = .empty;
    const unsafe_verdict = try checkBase(arena, temporary[0 .. length + suffix.len], &unsafe_findings);
    try testing.expect(unsafe_verdict == .untrusted);
}
