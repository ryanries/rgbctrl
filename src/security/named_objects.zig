const sdk = @import("sdk");
const acl_policy = @import("acl_policy.zig");

const win32 = sdk.win32;

const singleton_name = win32.L("Global\\rgbctrl.instance");
const local_stop_name = win32.L("Local\\rgbctrl.stop");
const namespace_prefix = win32.L("rgbctrl");
const private_stop_name = win32.L("rgbctrl\\stop");
const singleton_sddl = win32.L("D:(A;;GA;;;SY)(A;;GA;;;BA)(A;;GA;;;OW)(A;;0x00120000;;;WD)");
const private_sddl = win32.L("D:P(A;;GA;;;SY)(A;;GA;;;BA)");

const Singleton = union(enum) {
    acquired: win32.HANDLE,
    held: Holder,
    failed: u32,
};

const Holder = union(enum) {
    owner: acl_policy.Sid,
    unknown_owner,
    other_type,
};

const Descriptor = struct {
    attributes: win32.SECURITY_ATTRIBUTES,
    descriptor: *anyopaque,

    fn init(sddl: [*:0]const u16) ?Descriptor {
        var descriptor: ?*anyopaque = null;
        if (win32.ConvertStringSecurityDescriptorToSecurityDescriptorW(sddl, win32.SDDL_REVISION_1, &descriptor, null) == 0) return null;
        return .{ .attributes = .{ .lpSecurityDescriptor = descriptor }, .descriptor = descriptor.? };
    }

    fn deinit(self: *Descriptor) void {
        _ = win32.LocalFree(self.descriptor);
    }
};

pub fn acquireSingleton() Singleton {
    var descriptor = Descriptor.init(singleton_sddl) orelse return .{ .failed = win32.GetLastError() };
    defer descriptor.deinit();
    const handle = win32.CreateMutexW(&descriptor.attributes, win32.TRUE, singleton_name);
    const error_code = win32.GetLastError();
    if (handle) |mutex| {
        if (error_code != win32.ERROR_ALREADY_EXISTS) return .{ .acquired = mutex };
        defer _ = win32.CloseHandle(mutex);
        return .{ .held = ownerOf(mutex) };
    }
    return switch (error_code) {
        win32.ERROR_ACCESS_DENIED => blk: {
            const existing = win32.OpenMutexW(win32.READ_CONTROL | win32.SYNCHRONIZE, win32.FALSE, singleton_name) orelse break :blk .{ .held = .unknown_owner };
            defer _ = win32.CloseHandle(existing);
            break :blk .{ .held = ownerOf(existing) };
        },
        win32.ERROR_INVALID_HANDLE => .{ .held = .other_type },
        else => .{ .failed = error_code },
    };
}

fn ownerOf(handle: win32.HANDLE) Holder {
    var owner: ?win32.PSID = null;
    var descriptor: ?*anyopaque = null;
    if (win32.GetSecurityInfo(handle, win32.SE_KERNEL_OBJECT, win32.OWNER_SECURITY_INFORMATION, &owner, null, null, null, &descriptor) != win32.ERROR_SUCCESS) return .unknown_owner;
    defer _ = win32.LocalFree(descriptor);
    const sid = owner orelse return .unknown_owner;
    return .{ .owner = acl_policy.sidFromPointer(sid) };
}

const StopEvent = struct {
    event: win32.HANDLE,
    namespace: ?win32.HANDLE = null,
    boundary: ?win32.HANDLE = null,
    private: bool,
    reachable: bool = true,
};

fn administratorsBoundary() ?win32.HANDLE {
    var boundary = win32.CreateBoundaryDescriptorW(namespace_prefix, 0) orelse return null;
    var sid_buffer: [win32.SECURITY_MAX_SID_SIZE]u8 align(4) = undefined;
    var sid_size: u32 = sid_buffer.len;
    if (win32.CreateWellKnownSid(win32.WIN_BUILTIN_ADMINISTRATORS_SID, null, @ptrCast(&sid_buffer), &sid_size) == 0 or
        win32.AddSIDToBoundaryDescriptor(&boundary, @ptrCast(&sid_buffer)) == 0)
    {
        win32.DeleteBoundaryDescriptor(boundary);
        return null;
    }
    return boundary;
}

pub fn createStopEvent(elevated: bool) ?StopEvent {
    if (elevated) {
        if (createPrivateStopEvent()) |event| return event;
        const unnamed = win32.CreateEventW(null, win32.TRUE, win32.FALSE, null) orelse return null;
        return .{ .event = unnamed, .private = false, .reachable = false };
    }
    const event = win32.CreateEventW(null, win32.TRUE, win32.FALSE, local_stop_name) orelse return null;
    return .{ .event = event, .private = false };
}

fn createPrivateStopEvent() ?StopEvent {
    const boundary = administratorsBoundary() orelse return null;
    var descriptor = Descriptor.init(private_sddl) orelse {
        win32.DeleteBoundaryDescriptor(boundary);
        return null;
    };
    defer descriptor.deinit();
    const namespace = win32.CreatePrivateNamespaceW(&descriptor.attributes, boundary, namespace_prefix) orelse
        win32.OpenPrivateNamespaceW(boundary, namespace_prefix) orelse {
        win32.DeleteBoundaryDescriptor(boundary);
        return null;
    };
    const event = win32.CreateEventW(&descriptor.attributes, win32.TRUE, win32.FALSE, private_stop_name) orelse {
        _ = win32.ClosePrivateNamespace(namespace, 0);
        win32.DeleteBoundaryDescriptor(boundary);
        return null;
    };
    return .{ .event = event, .namespace = namespace, .boundary = boundary, .private = true };
}

const StopSignal = enum { private_signaled, local_signaled, not_found };

pub fn signalRunningInstance() StopSignal {
    if (administratorsBoundary()) |boundary| {
        defer win32.DeleteBoundaryDescriptor(boundary);
        if (win32.OpenPrivateNamespaceW(boundary, namespace_prefix)) |namespace| {
            defer _ = win32.ClosePrivateNamespace(namespace, 0);
            if (win32.OpenEventW(win32.EVENT_MODIFY_STATE, win32.FALSE, private_stop_name)) |event| {
                defer _ = win32.CloseHandle(event);
                if (win32.SetEvent(event) != 0) return .private_signaled;
            }
        }
    }
    if (win32.OpenEventW(win32.EVENT_MODIFY_STATE, win32.FALSE, local_stop_name)) |event| {
        defer _ = win32.CloseHandle(event);
        if (win32.SetEvent(event) != 0) return .local_signaled;
    }
    return .not_found;
}

test "the singleton SDDL and the private namespace SDDL parse" {
    var singleton = Descriptor.init(singleton_sddl).?;
    singleton.deinit();
    var private = Descriptor.init(private_sddl).?;
    private.deinit();
}
