const std = @import("std");
const sdk = @import("sdk");
const ui = @import("win32_ui.zig");
const files = @import("files.zig");
const jsonc_edit = @import("jsonc_edit.zig");
const json = @import("../config/json.zig");
const platform = @import("../platform.zig");
const heap = @import("../heap.zig");
const safe_open = @import("../security/safe_open.zig");
const install_check = @import("../security/install_check.zig");

const win32 = sdk.win32;
const L = win32.L;

extern "kernel32" fn GetLongPathNameW(short_path: [*:0]const u16, long_path: [*]u16, capacity: u32) callconv(.winapi) u32;

// Turning on an opt-in plugin, such as corsair_ddr5, needs plugins.<name>.enabled = true in the
// admin-only base file while rgbctrl runs elevated. rgbctrl-gui runs a copy of itself as
// administrator for that edit alone; Windows asks the user for approval first. When rgbctrl-gui
// already runs as administrator it makes the edit itself.

pub const helper_flag = "--enable-plugins-in-base";
const max_names = 64;
const max_name_length = 31;
const wait_ms: u32 = 60_000;

pub const exit_ok: u32 = 0;
pub const exit_usage: u32 = 1;
pub const exit_no_base_folder: u32 = 2;
pub const exit_untrusted: u32 = 3;
pub const exit_syntax: u32 = 4;
pub const exit_write_failed: u32 = 5;
pub const exit_untrusted_after: u32 = 6;
pub const exit_not_elevated: u32 = 7;
pub const exit_busy: u32 = 8;
pub const exit_no_lock: u32 = 9;
// Reported by the launching side only.
const launch_failed: u32 = 100;
const timed_out: u32 = 101;
const not_installed: u32 = 102;
const lock_wait_ms: u32 = 15_000;

/// The names plugins use (see validate.zig): a-z, 0-9 and _, at most 31 bytes.
pub fn isValidName(name: []const u8) bool {
    if (name.len == 0 or name.len > max_name_length) return false;
    for (name) |char| {
        if (!(std.ascii.isLower(char) or std.ascii.isDigit(char) or char == '_')) return false;
    }
    return true;
}

pub const Outcome = union(enum) {
    saved,
    declined,
    failed: u32,
};

/// Turns the plugins on in the base file: in this process when it already runs as
/// administrator, else in a copy of this program that Windows starts as administrator once the
/// user approves. That copy must be one that only administrators can change, such as the
/// installed rgbctrl-gui.exe; another program could take the place of any other copy between
/// this check and the start.
pub fn enablePluginsInBase(owner: ?ui.HWND, names: []const []const u8, elevated: bool) Outcome {
    if (names.len == 0 or names.len > max_names) return .{ .failed = exit_usage };
    if (elevated) {
        const code = runHelper(names);
        return if (code == exit_ok) .saved else .{ .failed = code };
    }
    var exe = platform.PathBuffer{};
    if (!platform.executablePath(&exe)) return .{ .failed = launch_failed };
    // The long form, as the check compares it with the path the file system reports.
    var long_path: [1024]u16 = undefined;
    const long_length = GetLongPathNameW(exe.terminated().ptr, &long_path, long_path.len);
    if (long_length > 0 and long_length < long_path.len) _ = exe.set(long_path[0..long_length]);
    var scratch = std.heap.ArenaAllocator.init(heap.allocator);
    defer scratch.deinit();
    if (!(install_check.adminOnlyFile(scratch.allocator(), exe.slice()) catch false)) return .{ .failed = not_installed };
    var parameters: std.ArrayList(u8) = .empty;
    defer parameters.deinit(heap.allocator);
    parameters.appendSlice(heap.allocator, helper_flag) catch return .{ .failed = launch_failed };
    for (names) |name| {
        if (!isValidName(name)) return .{ .failed = exit_usage };
        parameters.append(heap.allocator, ' ') catch return .{ .failed = launch_failed };
        parameters.appendSlice(heap.allocator, name) catch return .{ .failed = launch_failed };
    }
    var wide_parameters: [max_names * (max_name_length + 1) + helper_flag.len + 1]u16 = undefined;
    const parameters_wide = sdk.text.utf8ToUtf16(&wide_parameters, parameters.items) orelse return .{ .failed = launch_failed };
    var info = ui.SHELLEXECUTEINFOW{
        .fMask = ui.SEE_MASK_NOCLOSEPROCESS | ui.SEE_MASK_NOASYNC,
        .hwnd = owner,
        .lpVerb = L("runas"),
        .lpFile = exe.terminated().ptr,
        .lpParameters = parameters_wide.ptr,
        .nShow = ui.SW_HIDE,
    };
    if (ui.ShellExecuteExW(&info) == 0) {
        return if (win32.GetLastError() == ui.ERROR_CANCELLED) .declined else .{ .failed = launch_failed };
    }
    const process = info.hProcess orelse return .{ .failed = launch_failed };
    defer _ = win32.CloseHandle(process);
    if (!waitWhileDrawing(process, wait_ms)) return .{ .failed = timed_out };
    var code: u32 = 0;
    if (ui.GetExitCodeProcess(process, &code) == 0) return .{ .failed = launch_failed };
    return if (code == exit_ok) .saved else .{ .failed = code };
}

/// Waits for the process while the caller's windows keep repainting, so they do not look hung
/// while Windows asks for approval. The caller disables its window for the time.
fn waitWhileDrawing(process: win32.HANDLE, timeout_ms: u32) bool {
    const deadline = win32.GetTickCount64() + timeout_ms;
    const handles = [_]win32.HANDLE{process};
    while (true) {
        const now = win32.GetTickCount64();
        if (now >= deadline) return false;
        const result = ui.MsgWaitForMultipleObjects(handles.len, &handles, win32.FALSE, @intCast(deadline - now), ui.QS_ALLINPUT);
        if (result == win32.WAIT_OBJECT_0) return true;
        if (result != win32.WAIT_OBJECT_0 + 1) return false;
        var message = ui.MSG{};
        while (ui.PeekMessageW(&message, null, 0, 0, ui.PM_REMOVE) != 0) {
            if (message.message == ui.WM_QUIT) {
                // Leave the quit for the main loop.
                ui.PostQuitMessage(@intCast(message.wParam));
                return false;
            }
            _ = ui.TranslateMessage(&message);
            _ = ui.DispatchMessageW(&message);
        }
    }
}

pub fn describe(code: u32) []const u8 {
    return switch (code) {
        exit_usage => "the administrator helper was given an invalid plugin name",
        exit_no_base_folder => "the folder %ProgramData%\\rgbctrl does not exist; install rgbctrl with scripts\\install.ps1 first",
        exit_untrusted => "%ProgramData%\\rgbctrl or its rgbctrl.json can be changed by other accounts, so rgbctrl would not trust it; run \"rgbctrl check-install\" for details",
        exit_syntax => "%ProgramData%\\rgbctrl\\rgbctrl.json has an error; fix it in a text editor run as administrator",
        exit_write_failed => "%ProgramData%\\rgbctrl\\rgbctrl.json could not be written",
        exit_untrusted_after => "%ProgramData%\\rgbctrl\\rgbctrl.json would not be admin-only with the access rules of its folder, so it was left as it was; run \"rgbctrl check-install\"",
        exit_not_elevated => "the administrator helper did not run as administrator",
        exit_busy => "another change to %ProgramData%\\rgbctrl\\rgbctrl.json was still in progress; try again",
        exit_no_lock => "the administrator helper could not make sure that no other change to %ProgramData%\\rgbctrl\\rgbctrl.json was in progress; try again, or restart Windows if this keeps happening",
        timed_out => "the administrator helper did not finish within a minute",
        not_installed => "this copy of rgbctrl Settings is in a folder that other accounts can change, so it does not ask for administrator rights; use the installed one (Start menu > rgbctrl Settings)",
        else => "the administrator helper could not be started",
    };
}

/// The helper itself, in the elevated copy of rgbctrl-gui, or in rgbctrl-gui itself when it runs
/// as administrator.
pub fn runHelper(names: []const []const u8) u32 {
    if (names.len == 0 or names.len > max_names) return exit_usage;
    for (names) |name| {
        if (!isValidName(name)) return exit_usage;
    }
    if (!platform.currentPrivilege().elevated) return exit_not_elevated;
    // Helpers started from two sessions take turns, so neither loses the change of the other.
    // Without the lock nothing is changed: another program could hold the name to let two
    // helpers write at once.
    const lock = win32.CreateMutexW(null, win32.FALSE, L("Global\\rgbctrl.base-edit")) orelse return exit_no_lock;
    defer _ = win32.CloseHandle(lock);
    const wait_result = win32.WaitForSingleObject(lock, lock_wait_ms);
    if (wait_result != win32.WAIT_OBJECT_0 and wait_result != win32.WAIT_ABANDONED) return exit_busy;
    defer _ = win32.ReleaseMutex(lock);
    var arena_state = std.heap.ArenaAllocator.init(heap.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var folder = platform.PathBuffer{};
    var path = platform.PathBuffer{};
    if (!files.baseFolder(&folder) or !files.baseConfig(&path)) return exit_no_base_folder;
    const attributes = win32.GetFileAttributesW(folder.terminated().ptr);
    if (attributes == win32.INVALID_FILE_ATTRIBUTES or attributes & win32.FILE_ATTRIBUTE_DIRECTORY == 0) return exit_no_base_folder;
    var findings: std.ArrayList(install_check.Finding) = .empty;
    // A trusted folder without rgbctrl.json reads as absent; the new file inherits its access.
    var text: []const u8 = "{\r\n  \"plugins\": {\r\n  }\r\n}\r\n";
    switch (install_check.checkBase(arena, folder.slice(), &findings) catch return exit_write_failed) {
        .untrusted => return exit_untrusted,
        .absent => {},
        .trusted => {
            const opened = safe_open.openUntrusted(path.terminated().ptr) catch return exit_untrusted;
            defer opened.close();
            text = safe_open.readAll(arena, opened.handle, json.max_source_bytes) catch return exit_write_failed;
        },
    }
    var editor = jsonc_edit.Editor.init(arena, text) catch return exit_syntax;
    for (names) |name| editor.set(&.{ "plugins", name, "enabled" }, "true") catch return exit_syntax;
    // The new file is checked before it replaces the old one, so a failure leaves the old file.
    safe_open.replaceContents(path.terminated(), editor.text(), .{ .admin_only = true, .no_reparse = true }) catch |err| {
        return if (err == error.NotAdminOnly) exit_untrusted_after else exit_write_failed;
    };
    findings.clearRetainingCapacity();
    const after = install_check.checkBase(arena, folder.slice(), &findings) catch return exit_untrusted_after;
    return if (after == .trusted) exit_ok else exit_untrusted_after;
}

test "only plugin names pass to the administrator helper" {
    try std.testing.expect(isValidName("corsair_ddr5"));
    try std.testing.expect(!isValidName(""));
    try std.testing.expect(!isValidName("Corsair"));
    try std.testing.expect(!isValidName("a b"));
    try std.testing.expect(!isValidName("x\"y"));
    try std.testing.expect(!isValidName(&@as([32]u8, @splat('a'))));
}
