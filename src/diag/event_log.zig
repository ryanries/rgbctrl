const sdk = @import("sdk");

const win32 = sdk.win32;

pub const Kind = enum { err, warning };

pub fn report(kind: Kind, message: []const u8) void {
    const source = win32.RegisterEventSourceW(null, win32.L("rgbctrl")) orelse return;
    defer _ = win32.DeregisterEventSource(source);
    var wide: [2048]u16 = undefined;
    const text = sdk.text.utf8ToUtf16(&wide, message[0..@min(message.len, 1000)]) orelse return;
    const strings = [_][*:0]const u16{text.ptr};
    const event_type = if (kind == .err) win32.EVENTLOG_ERROR_TYPE else win32.EVENTLOG_WARNING_TYPE;
    _ = win32.ReportEventW(source, event_type, 0, 1, null, 1, 0, &strings, null);
}
