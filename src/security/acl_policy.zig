const std = @import("std");
const formatting = @import("../diag/format.zig");
const sdk = @import("sdk");

const win32 = sdk.win32;

pub const ObjectKind = enum { file, directory, ancestor };

const max_sid_bytes = 68;

pub const Sid = struct {
    bytes: [max_sid_bytes]u8 = undefined,
    len: usize = 0,

    pub fn slice(self: *const Sid) []const u8 {
        return self.bytes[0..self.len];
    }

    pub fn format(self: *const Sid, buffer: []u8) []const u8 {
        const raw = self.slice();
        if (raw.len < 8) return "S-?";
        var authority: u64 = 0;
        for (raw[2..8]) |byte| authority = (authority << 8) | byte;
        var length = (formatting.bufPrint(buffer, "S-{d}-{d}", .{ raw[0], authority }) catch return "S-?").len;
        const count = raw[1];
        for (0..count) |index| {
            const offset = 8 + index * 4;
            if (offset + 4 > raw.len) break;
            const value = std.mem.readInt(u32, raw[offset..][0..4], .little);
            const part = formatting.bufPrint(buffer[length..], "-{d}", .{value}) catch break;
            length += part.len;
        }
        return buffer[0..length];
    }
};

pub const Violation = union(enum) {
    none,
    untrusted_owner: Sid,
    missing_owner,
    missing_dacl,
    unsupported_ace: u8,
    grants: struct { sid: Sid, rights: u32 },
};

const system_sid = [_]u8{ 1, 1, 0, 0, 0, 0, 0, 5, 18, 0, 0, 0 };
const administrators_sid = [_]u8{ 1, 2, 0, 0, 0, 0, 0, 5, 32, 0, 0, 0, 0x20, 0x02, 0, 0 };
const owner_rights_sid = [_]u8{ 1, 1, 0, 0, 0, 0, 0, 3, 4, 0, 0, 0 };
const trusted_installer_sid = blk: {
    var bytes = [_]u8{ 1, 6, 0, 0, 0, 0, 0, 5, 80, 0, 0, 0 } ++ [_]u8{0} ** 20;
    const parts = [_]u32{ 956008885, 3418522649, 1831038044, 1853292631, 2271478464 };
    for (parts, 0..) |part, index| std.mem.writeInt(u32, bytes[12 + index * 4 ..][0..4], part, .little);
    break :blk bytes;
};

const access_allowed_ace_type: u8 = 0;
const access_denied_ace_type: u8 = 1;
const access_allowed_callback_ace_type: u8 = 9;
const access_denied_object_ace_type: u8 = 6;
const access_denied_callback_ace_type: u8 = 10;
const access_denied_callback_object_ace_type: u8 = 12;
const maximum_allowed: u32 = 0x02000000;

fn forbiddenRights(kind: ObjectKind) u32 {
    return switch (kind) {
        .file => win32.FILE_WRITE_DATA | win32.FILE_APPEND_DATA | win32.DELETE | win32.WRITE_DAC | win32.WRITE_OWNER,
        .directory => win32.FILE_ADD_FILE | win32.FILE_ADD_SUBDIRECTORY | win32.FILE_DELETE_CHILD | win32.DELETE | win32.WRITE_DAC | win32.WRITE_OWNER,
        .ancestor => win32.DELETE | win32.FILE_DELETE_CHILD | win32.WRITE_DAC | win32.WRITE_OWNER,
    };
}

fn mapGenericRights(mask: u32) u32 {
    var mapped = mask & ~(win32.GENERIC_READ | win32.GENERIC_WRITE | win32.GENERIC_EXECUTE | win32.GENERIC_ALL | maximum_allowed);
    if (mask & win32.GENERIC_READ != 0) mapped |= win32.FILE_GENERIC_READ;
    if (mask & win32.GENERIC_WRITE != 0) mapped |= win32.FILE_GENERIC_WRITE;
    if (mask & win32.GENERIC_EXECUTE != 0) mapped |= win32.FILE_GENERIC_EXECUTE;
    if (mask & (win32.GENERIC_ALL | maximum_allowed) != 0) mapped |= win32.FILE_ALL_ACCESS;
    return mapped;
}

pub fn sidFromPointer(pointer: *const anyopaque) Sid {
    const raw: [*]const u8 = @ptrCast(pointer);
    const count = @min(raw[1], 15);
    const length = 8 + @as(usize, count) * 4;
    var sid = Sid{ .len = length };
    @memcpy(sid.bytes[0..length], raw[0..length]);
    return sid;
}

fn isTrustedPrincipal(sid: []const u8) bool {
    return std.mem.eql(u8, sid, &system_sid) or std.mem.eql(u8, sid, &administrators_sid) or std.mem.eql(u8, sid, &trusted_installer_sid);
}

pub fn evaluate(owner: ?*const anyopaque, dacl: ?*win32.ACL, kind: ObjectKind) Violation {
    const owner_pointer = owner orelse return .missing_owner;
    const owner_sid = sidFromPointer(owner_pointer);
    if (!isTrustedPrincipal(owner_sid.slice())) return .{ .untrusted_owner = owner_sid };
    const list = dacl orelse return .missing_dacl;
    var information = win32.ACL_SIZE_INFORMATION{};
    if (win32.GetAclInformation(list, &information, @sizeOf(win32.ACL_SIZE_INFORMATION), win32.ACL_SIZE_INFORMATION_CLASS) == 0) return .missing_dacl;
    const forbidden = forbiddenRights(kind);
    var index: u32 = 0;
    while (index < information.AceCount) : (index += 1) {
        var ace_pointer: ?*anyopaque = null;
        if (win32.GetAce(list, index, &ace_pointer) == 0) return .missing_dacl;
        const header: *const win32.ACE_HEADER = @ptrCast(@alignCast(ace_pointer.?));
        if (header.AceFlags & win32.INHERIT_ONLY_ACE != 0) continue;
        switch (header.AceType) {
            access_denied_ace_type, access_denied_object_ace_type, access_denied_callback_ace_type, access_denied_callback_object_ace_type => continue,
            access_allowed_ace_type, access_allowed_callback_ace_type => {},
            else => return .{ .unsupported_ace = header.AceType },
        }
        const ace: *const win32.ACCESS_ALLOWED_ACE = @ptrCast(@alignCast(ace_pointer.?));
        const sid = sidFromPointer(&ace.SidStart);
        if (isTrustedPrincipal(sid.slice()) or std.mem.eql(u8, sid.slice(), &owner_rights_sid)) continue;
        const granted = mapGenericRights(ace.Mask) & forbidden;
        if (granted != 0) return .{ .grants = .{ .sid = sid, .rights = granted } };
    }
    return .none;
}

pub fn describeRights(buffer: []u8, rights: u32, kind: ObjectKind) []const u8 {
    const names = [_]struct { bit: u32, file: []const u8, directory: []const u8 }{
        .{ .bit = win32.FILE_WRITE_DATA, .file = "write data", .directory = "add file" },
        .{ .bit = win32.FILE_APPEND_DATA, .file = "append data", .directory = "add subdirectory" },
        .{ .bit = win32.FILE_DELETE_CHILD, .file = "delete child", .directory = "delete child" },
        .{ .bit = win32.DELETE, .file = "delete", .directory = "delete" },
        .{ .bit = win32.WRITE_DAC, .file = "change permissions", .directory = "change permissions" },
        .{ .bit = win32.WRITE_OWNER, .file = "take ownership", .directory = "take ownership" },
    };
    var length: usize = 0;
    for (names) |entry| {
        if (rights & entry.bit == 0) continue;
        const name = if (kind == .file) entry.file else entry.directory;
        const separator: []const u8 = if (length == 0) "" else ", ";
        const part = formatting.bufPrint(buffer[length..], "{s}{s}", .{ separator, name }) catch break;
        length += part.len;
    }
    return buffer[0..length];
}

const testing = std.testing;

const ParsedDescriptor = struct {
    descriptor: *anyopaque,
    owner: ?*anyopaque,
    dacl: ?*win32.ACL,

    fn deinit(self: ParsedDescriptor) void {
        _ = win32.LocalFree(self.descriptor);
    }
};

fn parseSddl(comptime text: []const u8) !ParsedDescriptor {
    var descriptor: ?*anyopaque = null;
    if (win32.ConvertStringSecurityDescriptorToSecurityDescriptorW(win32.L(text), win32.SDDL_REVISION_1, &descriptor, null) == 0) return error.InvalidSddl;
    var owner: ?win32.PSID = null;
    var defaulted: win32.BOOL = 0;
    _ = win32.GetSecurityDescriptorOwner(descriptor.?, &owner, &defaulted);
    var present: win32.BOOL = 0;
    var dacl: ?*win32.ACL = null;
    _ = win32.GetSecurityDescriptorDacl(descriptor.?, &present, &dacl, &defaulted);
    return .{ .descriptor = descriptor.?, .owner = owner, .dacl = if (present != 0) dacl else null };
}

fn evaluateSddl(comptime text: []const u8, kind: ObjectKind) !Violation {
    const parsed = try parseSddl(text);
    defer parsed.deinit();
    return evaluate(parsed.owner, parsed.dacl, kind);
}

test "an administrators-only DACL with read access for users passes every rule" {
    const sddl = "O:BAD:(A;;FA;;;SY)(A;;FA;;;BA)(A;;0x1200a9;;;BU)";
    try testing.expect(try evaluateSddl(sddl, .file) == .none);
    try testing.expect(try evaluateSddl(sddl, .directory) == .none);
    try testing.expect(try evaluateSddl(sddl, .ancestor) == .none);
}

test "an untrusted owner fails even with a strict DACL" {
    const violation = try evaluateSddl("O:BUD:(A;;FA;;;SY)", .file);
    try testing.expect(violation == .untrusted_owner);
    var buffer: [64]u8 = undefined;
    try testing.expectEqualStrings("S-1-5-32-545", violation.untrusted_owner.format(&buffer));
}

test "TrustedInstaller and SYSTEM are trusted owners" {
    try testing.expect(try evaluateSddl("O:S-1-5-80-956008885-3418522649-1831038044-1853292631-2271478464D:(A;;FA;;;SY)", .file) == .none);
    try testing.expect(try evaluateSddl("O:SYD:(A;;FA;;;BA)", .directory) == .none);
}

test "a missing DACL fails" {
    try testing.expect(try evaluateSddl("O:BAD:NO_ACCESS_CONTROL", .file) == .missing_dacl);
}

test "write access for users fails on files and add-file fails on directories but not on ancestors" {
    const file_violation = try evaluateSddl("O:BAD:(A;;FA;;;BA)(A;;0x2;;;BU)", .file);
    try testing.expect(file_violation == .grants);
    try testing.expectEqual(win32.FILE_WRITE_DATA, file_violation.grants.rights);
    try testing.expect(try evaluateSddl("O:BAD:(A;;FA;;;BA)(A;;0x6;;;BU)", .directory) == .grants);
    try testing.expect(try evaluateSddl("O:BAD:(A;;FA;;;BA)(A;;0x6;;;BU)", .ancestor) == .none);
    try testing.expect(try evaluateSddl("O:BAD:(A;;FA;;;BA)(A;;0x40;;;AU)", .ancestor) == .grants);
}

test "generic rights are mapped before checking" {
    const violation = try evaluateSddl("O:BAD:(A;;GW;;;WD)", .file);
    try testing.expect(violation == .grants);
    try testing.expect(violation.grants.rights & win32.FILE_WRITE_DATA != 0);
    try testing.expect(try evaluateSddl("O:BAD:(A;;GRGX;;;WD)", .file) == .none);
}

test "inherit-only and deny entries are skipped and OWNER RIGHTS is trusted" {
    try testing.expect(try evaluateSddl("O:BAD:(A;OICIIO;FA;;;BU)(D;;FA;;;WD)(A;;FA;;;OW)", .directory) == .none);
    try testing.expect(try evaluateSddl("O:BAD:(A;OICI;FA;;;CO)", .file) == .grants);
}

test "describeRights names the dangerous rights for the object kind" {
    var buffer: [128]u8 = undefined;
    try testing.expectEqualStrings("add file, delete", describeRights(&buffer, win32.FILE_ADD_FILE | win32.DELETE, .directory));
    try testing.expectEqualStrings("write data, change permissions", describeRights(&buffer, win32.FILE_WRITE_DATA | win32.WRITE_DAC, .file));
}
