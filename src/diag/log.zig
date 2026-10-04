const std = @import("std");
const formatting = @import("format.zig");
const sdk = @import("sdk");
const heap = @import("../heap.zig");
const console = @import("console.zig");
const event_log = @import("event_log.zig");
const safe_open = @import("../security/safe_open.zig");

const win32 = sdk.win32;

pub const Level = sdk.abi.LogLevel;

const level_labels = [_][]const u8{ "ERROR", "WARN ", "INFO ", "DEBUG", "TRACE" };
const max_message_bytes = 1800;
const pending_capacity = 32 * 1024;
const path_capacity = 1024;
const reopen_retry_ms: u64 = 5000;
const rotation_retry_ms: u64 = 60_000;
const fallback_burst = 10;
const fallback_summary_interval_ms: u64 = 60_000;

const OpenError = safe_open.Error;

extern "kernel32" fn SetEndOfFile(file: win32.HANDLE) callconv(.winapi) win32.BOOL;
extern "kernel32" fn CopyFileW(existing: [*:0]const u16, new: [*:0]const u16, fail_if_exists: win32.BOOL) callconv(.winapi) win32.BOOL;

pub const Logger = struct {
    lock: win32.SRWLOCK = .{},
    file: ?win32.HANDLE = null,
    path_buffer: [path_capacity]u16 = @splat(0),
    path_len: usize = 0,
    level: Level = .debug,
    max_bytes: u64 = 1024 * 1024,
    size: u64 = 0,
    echo_to_stderr: bool = false,
    echo_info_to_stdout: bool = false,
    pending: []u8 = &.{},
    pending_len: usize = 0,
    pending_overflowed: bool = false,
    rotation_failed: bool = false,
    rotation_retry_after_ms: u64 = 0,
    reopen_failed: bool = false,
    reopen_after_ms: u64 = 0,
    sink_failed: bool = false,
    fallback_reported: u32 = 0,
    fallback_suppressed: u64 = 0,
    fallback_summary_after_ms: u64 = 0,
    event_log_fallback: bool = false,
    dropped_lines: u64 = 0,
    cap_reported: bool = false,

    pub fn log(self: *Logger, level: Level, source: []const u8, comptime format: []const u8, args: anytype) void {
        if (@intFromEnum(level) > @intFromEnum(self.level)) return;
        var buffer: [max_message_bytes]u8 = undefined;
        self.write(level, source, formatting.print(&buffer, format, args));
    }

    pub fn write(self: *Logger, level: Level, source: []const u8, message: []const u8) void {
        self.writeWithEcho(level, source, message, true);
    }

    pub fn writeWithoutEcho(self: *Logger, level: Level, source: []const u8, message: []const u8) void {
        self.writeWithEcho(level, source, message, false);
    }

    fn writeWithEcho(self: *Logger, level: Level, source: []const u8, message: []const u8, echo: bool) void {
        if (@intFromEnum(level) > @intFromEnum(self.level)) return;
        var line_buffer: [max_message_bytes + 128]u8 = undefined;
        const line = formatLine(&line_buffer, level, source, message, localTimestamp());
        const without_timestamp = line[24..];
        if (echo and self.echo_to_stderr and @intFromEnum(level) <= @intFromEnum(Level.warn)) {
            console.write(.err, without_timestamp);
        } else if (echo and self.echo_info_to_stdout and level == .info) {
            console.write(.out, without_timestamp);
        }
        win32.AcquireSRWLockExclusive(&self.lock);
        defer win32.ReleaseSRWLockExclusive(&self.lock);
        if (self.file == null and self.path_len > 0 and win32.GetTickCount64() >= self.reopen_after_ms) self.reopen();
        if (self.file == null) {
            self.appendPending(line);
            if (self.sink_failed and self.event_log_fallback and @intFromEnum(level) <= @intFromEnum(Level.warn)) self.reportFallback(level, without_timestamp);
            return;
        }
        self.rotateIfNeeded(line.len);
        const file = self.file orelse {
            self.appendPending(line);
            return;
        };
        if (self.size + line.len > self.max_bytes * 2) {
            self.dropped_lines += 1;
            if (!self.cap_reported) {
                self.cap_reported = true;
                const notice = "rgbctrl: the log file reached twice log.max_size_kb and cannot be rotated; further lines are dropped until rotation succeeds\r\n";
                self.notify(.warning, notice);
            }
            if (self.event_log_fallback and @intFromEnum(level) <= @intFromEnum(Level.warn)) self.reportFallback(level, without_timestamp);
            return;
        }
        var written: u32 = 0;
        if (win32.WriteFile(file, line.ptr, @intCast(line.len), &written, null) != 0) self.size += written;
    }

    fn appendPending(self: *Logger, line: []const u8) void {
        if (self.pending.len == 0) {
            self.pending = heap.allocator.alloc(u8, pending_capacity) catch {
                self.pending_overflowed = true;
                return;
            };
        }
        if (self.pending_len + line.len > self.pending.len) {
            self.pending_overflowed = true;
            return;
        }
        @memcpy(self.pending[self.pending_len .. self.pending_len + line.len], line);
        self.pending_len += line.len;
    }

    fn resetFallback(self: *Logger, delivered: bool) void {
        if (self.fallback_suppressed > 0 and self.event_log_fallback) {
            var buffer: [160]u8 = undefined;
            if (delivered) {
                event_log.report(.warning, formatting.print(&buffer, "{d} further rgbctrl warnings or errors were written only to the log file, which is available again", .{self.fallback_suppressed}));
            } else {
                event_log.report(.warning, formatting.print(&buffer, "{d} further rgbctrl warnings or errors were dropped while the log file was full; log rotation works again", .{self.fallback_suppressed}));
            }
        }
        self.fallback_reported = 0;
        self.fallback_suppressed = 0;
        self.fallback_summary_after_ms = 0;
    }

    fn reportFallback(self: *Logger, level: Level, line: []const u8) void {
        const now = win32.GetTickCount64();
        if (self.fallback_reported < fallback_burst) {
            self.fallback_reported += 1;
            event_log.report(if (level == .err) .err else .warning, line);
            return;
        }
        self.fallback_suppressed += 1;
        if (now < self.fallback_summary_after_ms) return;
        self.fallback_summary_after_ms = now + fallback_summary_interval_ms;
        var buffer: [160]u8 = undefined;
        event_log.report(.warning, formatting.print(&buffer, "{d} further rgbctrl warnings or errors were not written to the log file", .{self.fallback_suppressed}));
        self.fallback_suppressed = 0;
    }

    fn notify(self: *Logger, kind: event_log.Kind, notice: []const u8) void {
        if (self.echo_to_stderr) {
            console.write(.err, notice);
        } else if (self.event_log_fallback) {
            event_log.report(kind, notice["rgbctrl: ".len..]);
        }
    }

    fn flushPending(self: *Logger, handle: win32.HANDLE) void {
        if (self.pending_len == 0) return;
        var written: u32 = 0;
        if (win32.WriteFile(handle, self.pending.ptr, @intCast(self.pending_len), &written, null) != 0) self.size += written;
        self.pending_len = 0;
    }

    fn writeNotice(self: *Logger, level: Level, comptime format: []const u8, args: anytype) void {
        const file = self.file orelse return;
        var message_buffer: [200]u8 = undefined;
        var line_buffer: [320]u8 = undefined;
        const line = formatLine(&line_buffer, level, "host", formatting.print(&message_buffer, format, args), localTimestamp());
        var written: u32 = 0;
        if (win32.WriteFile(file, line.ptr, @intCast(line.len), &written, null) != 0) self.size += written;
    }

    fn reopen(self: *Logger) void {
        const path = self.path_buffer[0..self.path_len :0];
        const handle = safe_open.openAppend(path.ptr) catch {
            self.sink_failed = true;
            if (!self.reopen_failed) {
                self.reopen_failed = true;
                const notice = "rgbctrl: the log file cannot be opened; retrying every 5 s and keeping messages in memory meanwhile\r\n";
                self.notify(.err, notice);
            }
            self.reopen_after_ms = win32.GetTickCount64() + reopen_retry_ms;
            return;
        };
        self.file = handle;
        self.size = currentSize(handle);
        self.reopen_failed = false;
        if (self.sink_failed) {
            self.sink_failed = false;
            self.resetFallback(true);
        }
        self.flushPending(handle);
    }

    fn rotateIfNeeded(self: *Logger, incoming: usize) void {
        if (self.size == 0 or self.size + incoming <= self.max_bytes) return;
        const now = win32.GetTickCount64();
        if (self.rotation_failed and now < self.rotation_retry_after_ms) return;
        const path = self.path_buffer[0..self.path_len :0];
        var rotated: [path_capacity + 2:0]u16 = undefined;
        @memcpy(rotated[0..self.path_len], self.path_buffer[0..self.path_len]);
        rotated[self.path_len] = '.';
        rotated[self.path_len + 1] = '1';
        rotated[self.path_len + 2] = 0;
        _ = win32.CloseHandle(self.file.?);
        self.file = null;
        const moved = win32.MoveFileExW(path.ptr, rotated[0 .. self.path_len + 2 :0].ptr, win32.MOVEFILE_REPLACE_EXISTING) != 0;
        const move_error = if (moved) 0 else win32.GetLastError();
        const emptied = !moved and CopyFileW(path.ptr, rotated[0 .. self.path_len + 2 :0].ptr, 0) != 0 and self.truncateInPlace();
        self.reopen();
        if (moved or emptied) {
            if (self.rotation_failed) self.writeNotice(.warn, "log rotation works again; {d} lines were dropped while it failed", .{self.dropped_lines});
            if (emptied) self.writeNotice(.warn, "log rotation could not rename the file (Win32 error {d}; another program has it open), so it was copied to the .1 file and emptied", .{move_error});
            if (self.cap_reported) self.resetFallback(false);
            self.rotation_failed = false;
            self.dropped_lines = 0;
            self.cap_reported = false;
            return;
        }
        const first_failure = !self.rotation_failed;
        self.rotation_failed = true;
        self.rotation_retry_after_ms = now + rotation_retry_ms;
        if (first_failure) self.writeNotice(.warn, "log rotation failed (Win32 error {d}); retrying every 60 s, and lines beyond twice log.max_size_kb are dropped", .{move_error});
    }

    fn truncateInPlace(self: *Logger) bool {
        const path = self.path_buffer[0..self.path_len :0];
        const handle = win32.CreateFileW(path.ptr, win32.GENERIC_WRITE | win32.FILE_READ_ATTRIBUTES | win32.SYNCHRONIZE, win32.FILE_SHARE_READ | win32.FILE_SHARE_WRITE | win32.FILE_SHARE_DELETE, null, win32.OPEN_EXISTING, win32.FILE_FLAG_OPEN_REPARSE_POINT, null);
        if (!win32.isValid(handle)) return false;
        defer _ = win32.CloseHandle(handle);
        _ = safe_open.checkPlainFile(handle) catch return false;
        if (win32.SetFilePointerEx(handle, 0, null, 0) == 0) return false;
        return SetEndOfFile(handle) != 0;
    }

    pub fn open(self: *Logger, directory: []const u16, file_name: []const u8) OpenError!void {
        var path: [path_capacity]u16 = undefined;
        const joined = joinPath(&path, directory, file_name) orelse return error.PathTooLong;
        const opened = safe_open.openAppend(joined.ptr);
        win32.AcquireSRWLockExclusive(&self.lock);
        defer win32.ReleaseSRWLockExclusive(&self.lock);
        const handle = opened catch |err| {
            if (self.file == null) {
                @memcpy(self.path_buffer[0..joined.len], joined);
                self.path_buffer[joined.len] = 0;
                self.path_len = joined.len;
                self.sink_failed = true;
                self.reopen_after_ms = win32.GetTickCount64() + reopen_retry_ms;
            }
            return err;
        };
        @memcpy(self.path_buffer[0..joined.len], joined);
        self.path_buffer[joined.len] = 0;
        self.path_len = joined.len;
        if (self.file) |previous| _ = win32.CloseHandle(previous);
        self.file = handle;
        self.sink_failed = false;
        self.resetFallback(!self.cap_reported);
        self.reopen_failed = false;
        self.rotation_failed = false;
        self.dropped_lines = 0;
        self.cap_reported = false;
        self.size = currentSize(handle);
        self.flushPending(handle);
    }

    pub fn configure(self: *Logger, level: Level, max_size_kb: u32) void {
        win32.AcquireSRWLockExclusive(&self.lock);
        defer win32.ReleaseSRWLockExclusive(&self.lock);
        self.level = level;
        self.max_bytes = @as(u64, max_size_kb) * 1024;
    }

    pub fn isOpen(self: *Logger) bool {
        win32.AcquireSRWLockExclusive(&self.lock);
        defer win32.ReleaseSRWLockExclusive(&self.lock);
        return self.file != null;
    }

    pub fn pathUtf8(self: *Logger, buffer: []u8) []const u8 {
        return sdk.text.utf16ToUtf8(buffer, self.path_buffer[0..self.path_len]);
    }

    pub fn switchFileName(self: *Logger, file_name: []const u8) OpenError!void {
        var directory: [path_capacity]u16 = undefined;
        win32.AcquireSRWLockExclusive(&self.lock);
        const path = self.path_buffer[0..self.path_len];
        const separator = std.mem.lastIndexOfScalar(u16, path, '\\') orelse {
            win32.ReleaseSRWLockExclusive(&self.lock);
            return error.Failed;
        };
        @memcpy(directory[0..separator], path[0..separator]);
        win32.ReleaseSRWLockExclusive(&self.lock);
        return self.open(directory[0..separator], file_name);
    }

    pub fn reportUndeliveredToEventLog(self: *Logger) void {
        win32.AcquireSRWLockExclusive(&self.lock);
        defer win32.ReleaseSRWLockExclusive(&self.lock);
        if (self.file != null or self.pending_len == 0) return;
        var lines = std.mem.splitSequence(u8, self.pending[0..self.pending_len], "\r\n");
        while (lines.next()) |line| {
            if (line.len < 30) continue;
            const label = line[24..29];
            if (std.mem.eql(u8, label, "ERROR")) event_log.report(.err, line[24..]) else if (std.mem.eql(u8, label, "WARN ")) event_log.report(.warning, line[24..]);
        }
    }

    pub fn close(self: *Logger) void {
        win32.AcquireSRWLockExclusive(&self.lock);
        defer win32.ReleaseSRWLockExclusive(&self.lock);
        if (self.file) |file| _ = win32.CloseHandle(file);
        self.file = null;
    }
};

pub var global: Logger = .{};

fn currentSize(handle: win32.HANDLE) u64 {
    var size: i64 = 0;
    if (win32.GetFileSizeEx(handle, &size) == 0 or size < 0) return 0;
    return @intCast(size);
}

fn joinPath(buffer: []u16, directory: []const u16, file_name: []const u8) ?[:0]const u16 {
    const needs_separator = directory.len > 0 and directory[directory.len - 1] != '\\';
    const separator_len: usize = if (needs_separator) 1 else 0;
    const total = directory.len + separator_len + file_name.len;
    if (total + 1 > buffer.len) return null;
    @memcpy(buffer[0..directory.len], directory);
    if (needs_separator) buffer[directory.len] = '\\';
    for (file_name, 0..) |char, index| buffer[directory.len + separator_len + index] = char;
    buffer[total] = 0;
    return buffer[0..total :0];
}

const Timestamp = struct {
    year: u16,
    month: u16,
    day: u16,
    hour: u16,
    minute: u16,
    second: u16,
    millisecond: u16,
};

fn localTimestamp() Timestamp {
    var time: win32.SYSTEMTIME = undefined;
    win32.GetLocalTime(&time);
    return .{ .year = time.wYear, .month = time.wMonth, .day = time.wDay, .hour = time.wHour, .minute = time.wMinute, .second = time.wSecond, .millisecond = time.wMilliseconds };
}

fn formatLine(buffer: []u8, level: Level, source: []const u8, message: []const u8, time: Timestamp) []const u8 {
    const prefix = formatting.bufPrint(buffer, "{d:0>4}-{d:0>2}-{d:0>2} {d:0>2}:{d:0>2}:{d:0>2}.{d:0>3} {s} [{s}] ", .{
        time.year, time.month, time.day, time.hour, time.minute, time.second, time.millisecond, level_labels[@intFromEnum(level)], source[0..@min(source.len, 40)],
    }) catch unreachable;
    var length = prefix.len;
    const room = buffer.len - length - 2;
    const kept = message[0..@min(message.len, room)];
    for (kept) |byte| {
        buffer[length] = if (byte < 0x20 or byte == 0x7F) ' ' else byte;
        length += 1;
    }
    buffer[length] = '\r';
    buffer[length + 1] = '\n';
    return buffer[0 .. length + 2];
}

test "formatLine writes the documented layout and neutralizes control characters" {
    var buffer: [256]u8 = undefined;
    const line = formatLine(&buffer, .warn, "keychron", "first\nsecond\x1b[31m", .{ .year = 2025, .month = 9, .day = 7, .hour = 8, .minute = 5, .second = 3, .millisecond = 42 });
    try std.testing.expectEqualStrings("2025-09-07 08:05:03.042 WARN  [keychron] first second [31m\r\n", line);
}

test "formatLine truncates long messages to the buffer" {
    var buffer: [80]u8 = undefined;
    const long: [200]u8 = @splat('x');
    const line = formatLine(&buffer, .info, "host", &long, .{ .year = 2025, .month = 1, .day = 1, .hour = 0, .minute = 0, .second = 0, .millisecond = 0 });
    try std.testing.expectEqual(@as(usize, 80), line.len);
    try std.testing.expect(std.mem.endsWith(u8, line, "x\r\n"));
}

test "joinPath inserts one separator between the directory and the file name" {
    var buffer: [64]u16 = undefined;
    try std.testing.expectEqualSlices(u16, win32.L("C:\\a\\x.log"), joinPath(&buffer, win32.L("C:\\a"), "x.log").?);
    try std.testing.expectEqualSlices(u16, win32.L("C:\\a\\x.log"), joinPath(&buffer, win32.L("C:\\a\\"), "x.log").?);
}

fn temporaryDirectory(buffer: []u16) ![]const u16 {
    const length = win32.GetEnvironmentVariableW(win32.L("TEMP"), buffer.ptr, @intCast(buffer.len));
    if (length == 0 or length >= buffer.len) return error.SkipZigTest;
    return buffer[0..length];
}

fn readWhole(path: [:0]const u16) ![]u8 {
    const opened = try safe_open.openPlain(path.ptr);
    defer opened.close();
    return safe_open.readAll(std.testing.allocator, opened.handle, 1 << 20);
}

test "the log rotates to name.1 at the size limit and keeps writing to a fresh file" {
    var directory_buffer: [512]u16 = undefined;
    const directory = try temporaryDirectory(&directory_buffer);
    var path_buffer: [600]u16 = undefined;
    const path = joinPath(&path_buffer, directory, "rgbctrl_rotation_test.log").?;
    var rotated_buffer: [600]u16 = undefined;
    const rotated = joinPath(&rotated_buffer, directory, "rgbctrl_rotation_test.log.1").?;
    _ = win32.DeleteFileW(path.ptr);
    _ = win32.DeleteFileW(rotated.ptr);
    defer _ = win32.DeleteFileW(path.ptr);
    defer _ = win32.DeleteFileW(rotated.ptr);
    var logger = Logger{};
    try logger.open(directory, "rgbctrl_rotation_test.log");
    logger.max_bytes = 200;
    logger.write(.info, "test", "first line that fills most of the budget " ++ @as([100]u8, @splat('x')));
    logger.write(.info, "test", "second line after rotation");
    logger.write(.debug, "test", "third line");
    logger.close();
    const current = try readWhole(path);
    defer std.testing.allocator.free(current);
    const previous = try readWhole(rotated);
    defer std.testing.allocator.free(previous);
    try std.testing.expect(std.mem.indexOf(u8, previous, "first line") != null);
    try std.testing.expect(std.mem.indexOf(u8, current, "second line after rotation") != null);
    try std.testing.expect(std.mem.indexOf(u8, current, "third line") != null);
    try std.testing.expect(std.mem.indexOf(u8, current, "first line") == null);
}

test "a failed rotation is reported once and the log is bounded at twice the size limit" {
    var directory_buffer: [512]u16 = undefined;
    const directory = try temporaryDirectory(&directory_buffer);
    var path_buffer: [600]u16 = undefined;
    const path = joinPath(&path_buffer, directory, "rgbctrl_locked_rotation.log").?;
    var rotated_buffer: [600]u16 = undefined;
    const rotated = joinPath(&rotated_buffer, directory, "rgbctrl_locked_rotation.log.1").?;
    _ = win32.DeleteFileW(path.ptr);
    _ = win32.DeleteFileW(rotated.ptr);
    defer _ = win32.DeleteFileW(path.ptr);
    defer _ = win32.DeleteFileW(rotated.ptr);
    const blocker = win32.CreateFileW(rotated.ptr, win32.GENERIC_READ | win32.GENERIC_WRITE, 0, null, win32.CREATE_ALWAYS, win32.FILE_ATTRIBUTE_NORMAL, null);
    try std.testing.expect(win32.isValid(blocker));
    defer _ = win32.CloseHandle(blocker);
    var logger = Logger{};
    try logger.open(directory, "rgbctrl_locked_rotation.log");
    logger.max_bytes = 300;
    logger.write(.info, "test", "line one " ++ @as([120]u8, @splat('y')));
    logger.write(.info, "test", "line two");
    logger.write(.info, "test", "line three " ++ @as([100]u8, @splat('z')));
    logger.write(.info, "test", "line four");
    logger.write(.info, "test", "line five " ++ @as([80]u8, @splat('w')));
    logger.close();
    const content = try readWhole(path);
    defer std.testing.allocator.free(content);
    try std.testing.expect(logger.rotation_failed);
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, content, "log rotation failed"));
    try std.testing.expect(std.mem.indexOf(u8, content, "line three") != null);
    try std.testing.expect(std.mem.indexOf(u8, content, "line four") != null);
    try std.testing.expect(std.mem.indexOf(u8, content, "line five") == null);
    try std.testing.expectEqual(@as(u64, 1), logger.dropped_lines);
    try std.testing.expect(content.len <= 600);
}

test "a rotation whose rename is blocked by a reader copies the log to name.1 before emptying it" {
    var directory_buffer: [512]u16 = undefined;
    const directory = try temporaryDirectory(&directory_buffer);
    var path_buffer: [600]u16 = undefined;
    const path = joinPath(&path_buffer, directory, "rgbctrl_emptied_rotation.log").?;
    var rotated_buffer: [600]u16 = undefined;
    const rotated = joinPath(&rotated_buffer, directory, "rgbctrl_emptied_rotation.log.1").?;
    _ = win32.DeleteFileW(path.ptr);
    _ = win32.DeleteFileW(rotated.ptr);
    defer _ = win32.DeleteFileW(path.ptr);
    defer _ = win32.DeleteFileW(rotated.ptr);
    var logger = Logger{};
    try logger.open(directory, "rgbctrl_emptied_rotation.log");
    const reader = win32.CreateFileW(path.ptr, win32.GENERIC_READ, win32.FILE_SHARE_READ | win32.FILE_SHARE_WRITE, null, win32.OPEN_EXISTING, win32.FILE_ATTRIBUTE_NORMAL, null);
    try std.testing.expect(win32.isValid(reader));
    defer _ = win32.CloseHandle(reader);
    logger.max_bytes = 300;
    logger.write(.info, "test", "line one " ++ @as([120]u8, @splat('y')));
    logger.write(.info, "test", "line two");
    logger.write(.info, "test", "line three " ++ @as([100]u8, @splat('z')));
    logger.max_bytes = 1000;
    logger.write(.info, "test", "line four");
    logger.close();
    const content = try readWhole(path);
    defer std.testing.allocator.free(content);
    try std.testing.expect(!logger.rotation_failed);
    try std.testing.expectEqual(@as(u64, 0), logger.dropped_lines);
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, content, "copied to the .1 file and emptied"));
    try std.testing.expect(std.mem.indexOf(u8, content, "line one") == null);
    try std.testing.expect(std.mem.indexOf(u8, content, "line two") == null);
    try std.testing.expect(std.mem.indexOf(u8, content, "line three") != null);
    try std.testing.expect(std.mem.indexOf(u8, content, "line four") != null);
    const previous = try readWhole(rotated);
    defer std.testing.allocator.free(previous);
    try std.testing.expect(std.mem.indexOf(u8, previous, "line one") != null);
    try std.testing.expect(std.mem.indexOf(u8, previous, "line two") != null);
}

test "an open failure keeps the path and messages for a later retry" {
    var logger = Logger{};
    try std.testing.expectError(error.NotFound, logger.open(win32.L("C:\\nonexistent-rgbctrl-folder"), "rgbctrl.log"));
    try std.testing.expect(logger.sink_failed);
    try std.testing.expect(logger.path_len > 0);
    logger.write(.warn, "test", "kept for later");
    try std.testing.expect(std.mem.indexOf(u8, logger.pending[0..logger.pending_len], "kept for later") != null);
    heap.allocator.free(logger.pending);
}
test "messages below the configured level are dropped" {
    var logger = Logger{};
    logger.configure(.warn, 64);
    logger.write(.info, "test", "hidden");
    logger.write(.warn, "test", "shown");
    try std.testing.expect(std.mem.indexOf(u8, logger.pending[0..logger.pending_len], "hidden") == null);
    try std.testing.expect(std.mem.indexOf(u8, logger.pending[0..logger.pending_len], "shown") != null);
    heap.allocator.free(logger.pending);
}

test "switching to a log file that cannot be opened keeps writing to the current log" {
    var directory_buffer: [512]u16 = undefined;
    const directory = try temporaryDirectory(&directory_buffer);
    var current_buffer: [600]u16 = undefined;
    const current = joinPath(&current_buffer, directory, "rgbctrl_switch_current.log").?;
    var blocked_buffer: [600]u16 = undefined;
    const blocked = joinPath(&blocked_buffer, directory, "rgbctrl_switch_blocked.log").?;
    _ = win32.DeleteFileW(current.ptr);
    _ = win32.DeleteFileW(blocked.ptr);
    defer _ = win32.DeleteFileW(current.ptr);
    defer _ = win32.DeleteFileW(blocked.ptr);
    const blocker = win32.CreateFileW(blocked.ptr, win32.GENERIC_READ | win32.GENERIC_WRITE, 0, null, win32.CREATE_ALWAYS, win32.FILE_ATTRIBUTE_NORMAL, null);
    try std.testing.expect(win32.isValid(blocker));
    defer _ = win32.CloseHandle(blocker);
    var logger = Logger{};
    try logger.open(directory, "rgbctrl_switch_current.log");
    logger.write(.info, "test", "before the switch");
    try std.testing.expectError(error.SharingViolation, logger.switchFileName("rgbctrl_switch_blocked.log"));
    logger.write(.info, "test", "after the failed switch");
    try std.testing.expect(logger.isOpen());
    logger.close();
    const content = try readWhole(current);
    defer std.testing.allocator.free(content);
    try std.testing.expect(std.mem.indexOf(u8, content, "before the switch") != null);
    try std.testing.expect(std.mem.indexOf(u8, content, "after the failed switch") != null);
}

test "a recovered log sink starts the next failure episode with fresh Event Log limits" {
    var directory_buffer: [512]u16 = undefined;
    const directory = try temporaryDirectory(&directory_buffer);
    var path_buffer: [600]u16 = undefined;
    const path = joinPath(&path_buffer, directory, "rgbctrl_fallback_reset.log").?;
    _ = win32.DeleteFileW(path.ptr);
    defer _ = win32.DeleteFileW(path.ptr);
    var logger = Logger{};
    logger.fallback_reported = fallback_burst;
    logger.fallback_suppressed = 42;
    logger.fallback_summary_after_ms = std.math.maxInt(u64);
    try logger.open(directory, "rgbctrl_fallback_reset.log");
    try std.testing.expectEqual(@as(u32, 0), logger.fallback_reported);
    try std.testing.expectEqual(@as(u64, 0), logger.fallback_suppressed);
    try std.testing.expectEqual(@as(u64, 0), logger.fallback_summary_after_ms);
    logger.close();
}
