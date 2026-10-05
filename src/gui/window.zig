const std = @import("std");
const sdk = @import("sdk");
const ui = @import("win32_ui.zig");
const model_module = @import("model.zig");
const files = @import("files.zig");
const elevate = @import("elevate.zig");
const jsonc_edit = @import("jsonc_edit.zig");
const platform = @import("../platform.zig");
const heap = @import("../heap.zig");
const inventory = @import("../runtime/inventory.zig");
const safe_open = @import("../security/safe_open.zig");

const win32 = sdk.win32;
const L = win32.L;
const Rgb = sdk.abi.Rgb;
const Model = model_module.Model;
const Choice = model_module.Choice;
const Settings = model_module.Settings;

const class_name = L("rgbctrl.settings");
const window_title = L("rgbctrl Settings");
const poll_timer: usize = 1;
const poll_interval_ms: u32 = 1000;
const apply_patience_ms: u64 = 15_000;
const plugins_page_param: isize = -1;
const max_controls = 48;

const id_tree: usize = 100;
const id_effect: usize = 101;
const id_add_color: usize = 102;
const id_remove_color: usize = 103;
const id_speed: usize = 104;
const id_brightness: usize = 105;
const id_leds: usize = 106;
const id_leds_spin: usize = 107;
const id_plugins: usize = 108;
const id_revert: usize = 109;
const id_save: usize = 110;
const id_swatch_first: usize = 200;

const plugins_note_text = blk: {
    @setEvalBranchQuota(20_000);
    break :blk L("Check a plugin to turn it on, clear it to turn it off; the change takes effect when you save. " ++
        "Turning on an opt-in plugin, such as the DDR5 memory lighting, asks for administrator approval.");
};

const palette = [16]ui.COLORREF{
    ui.rgb(0x00, 0x00, 0xFF), ui.rgb(0x00, 0xA0, 0xFF), ui.rgb(0x00, 0xFF, 0xFF), ui.rgb(0x00, 0xFF, 0x80),
    ui.rgb(0x00, 0xFF, 0x00), ui.rgb(0x80, 0xFF, 0x00), ui.rgb(0xFF, 0xFF, 0x00), ui.rgb(0xFF, 0x80, 0x00),
    ui.rgb(0xFF, 0x00, 0x00), ui.rgb(0xFF, 0x00, 0x40), ui.rgb(0xFF, 0x00, 0xFF), ui.rgb(0x80, 0x00, 0xFF),
    ui.rgb(0xFF, 0xFF, 0xFF), ui.rgb(0xFF, 0xC0, 0x80), ui.rgb(0x80, 0x80, 0x80), ui.rgb(0x00, 0x00, 0x00),
};

const Page = enum { lighting, plugins };

const Pending = struct {
    user_stamp: [48]u8 = undefined,
    user_stamp_len: usize = 0,
    base_stamp: [48]u8 = undefined,
    base_stamp_len: usize = 0,
    since_ms: u64,
};

// What was selected, kept across a reload whose arena owns the node strings.
const SelectionKey = struct {
    page: Page = .lighting,
    level: model_module.Level = .all,
    device: [64]u8 = undefined,
    device_len: usize = 0,
    zone: [64]u8 = undefined,
    zone_len: usize = 0,
};

const App = struct {
    instance: ui.HINSTANCE,
    window: ui.HWND = undefined,
    created: bool = false,
    dpi: u32 = 96,
    font: ?ui.HFONT = null,
    title_font: ?ui.HFONT = null,
    controls: [max_controls]ui.HWND = undefined,
    control_count: usize = 0,
    tree: ui.HWND = undefined,
    title: ui.HWND = undefined,
    detail: ui.HWND = undefined,
    effect_label: ui.HWND = undefined,
    effect: ui.HWND = undefined,
    colors_label: ui.HWND = undefined,
    swatches: [model_module.max_colors]ui.HWND = undefined,
    add_color: ui.HWND = undefined,
    remove_color: ui.HWND = undefined,
    speed_label: ui.HWND = undefined,
    speed: ui.HWND = undefined,
    speed_value: ui.HWND = undefined,
    brightness_label: ui.HWND = undefined,
    brightness: ui.HWND = undefined,
    brightness_value: ui.HWND = undefined,
    leds_label: ui.HWND = undefined,
    leds: ui.HWND = undefined,
    leds_spin: ui.HWND = undefined,
    leds_range: ui.HWND = undefined,
    note: ui.HWND = undefined,
    plugins: ui.HWND = undefined,
    plugins_note: ui.HWND = undefined,
    info: ui.HWND = undefined,
    status: ui.HWND = undefined,
    revert: ui.HWND = undefined,
    save: ui.HWND = undefined,
    arena: std.heap.ArenaAllocator,
    status_arena: std.heap.ArenaAllocator,
    model: Model = .{},
    latest: ?inventory.Inventory = null,
    tree_items: []?ui.HTREEITEM = &.{},
    page: Page = .lighting,
    selected: usize = 0,
    user_path: platform.PathBuffer = .{},
    base_path: platform.PathBuffer = .{},
    inventory_path: platform.PathBuffer = .{},
    inventory_time: ?u64 = null,
    user_times: ?files.Times = null,
    base_times: ?files.Times = null,
    user_unreadable: bool = false,
    changed_on_disk: bool = false,
    running: bool = false,
    custom_colors: [16]ui.COLORREF = palette,
    filling: bool = false,
    pending: ?Pending = null,
    notice: [600]u8 = undefined,
    notice_len: usize = 0,
    /// Running as administrator: see files.findInventory and files.writeText.
    elevated: bool = false,
    inventory_skipped: bool = false,
    /// A modal loop runs (see enterModal), or the window waits for the administrator helper with
    /// itself disabled; polling waits meanwhile.
    busy: bool = false,
    /// Hashes of the texts last shown, so unchanged text is not set again (see setTextIfChanged).
    status_hash: u64 = 0,
    info_hash: u64 = 0,
    /// What the panel shows for the selected node (see displayed); the swatches draw from it.
    shown: Settings = .{},
};

var app: App = undefined;

pub fn run() u8 {
    const instance = ui.GetModuleHandleW(null) orelse return 1;
    // One window per session: starting rgbctrl Settings again brings the open one forward.
    const instance_lock = win32.CreateMutexW(null, win32.FALSE, L("Local\\rgbctrl.settings"));
    const lock_error = win32.GetLastError();
    defer if (instance_lock) |handle| {
        _ = win32.CloseHandle(handle);
    };
    // A copy run as administrator holds the name in a way that a copy run without it cannot
    // open; any other failure leaves no way to tell, so this copy does not open a second window.
    if (instance_lock == null and lock_error != win32.ERROR_ACCESS_DENIED) {
        reportStartFailure(lock_error);
        return 1;
    }
    if (instance_lock == null or lock_error == win32.ERROR_ALREADY_EXISTS) {
        if (ui.FindWindowW(class_name, null)) |existing| {
            if (ui.IsIconic(existing) != 0) _ = ui.ShowWindow(existing, ui.SW_RESTORE);
            _ = ui.SetForegroundWindow(existing);
            return 0;
        }
        // The other copy may still be creating its window; this copy never opens a second one.
        var waited_ms: u32 = 0;
        while (waited_ms < 5000) : (waited_ms += 100) {
            win32.Sleep(100);
            if (ui.FindWindowW(class_name, null)) |existing| {
                _ = ui.SetForegroundWindow(existing);
                break;
            }
        }
        return 0;
    }
    app = .{ .instance = instance, .arena = std.heap.ArenaAllocator.init(heap.allocator), .status_arena = std.heap.ArenaAllocator.init(heap.allocator), .elevated = platform.currentPrivilege().elevated };
    _ = ui.InitCommonControlsEx(&.{ .dwICC = ui.ICC_LISTVIEW_CLASSES | ui.ICC_TREEVIEW_CLASSES | ui.ICC_BAR_CLASSES | ui.ICC_UPDOWN_CLASS | ui.ICC_STANDARD_CLASSES });
    const class = ui.WNDCLASSEXW{
        .style = 0x0001 | 0x0002,
        .lpfnWndProc = windowProc,
        .hInstance = instance,
        .hCursor = ui.LoadCursorW(null, ui.IDC_ARROW),
        .hbrBackground = ui.GetSysColorBrush(ui.COLOR_BTNFACE),
        .lpszClassName = class_name,
    };
    if (ui.RegisterClassExW(&class) == 0) return 1;
    const dpi = ui.GetDpiForSystem();
    const window = ui.CreateWindowExW(ui.WS_EX_CONTROLPARENT, class_name, window_title, ui.WS_OVERLAPPEDWINDOW | ui.WS_CLIPCHILDREN, ui.CW_USEDEFAULT, ui.CW_USEDEFAULT, scaleFor(dpi, 980), scaleFor(dpi, 700), null, null, instance, null) orelse return 1;
    _ = ui.ShowWindow(window, ui.SW_SHOWNORMAL);
    _ = ui.UpdateWindow(window);
    var message = ui.MSG{};
    while (ui.GetMessageW(&message, null, 0, 0) > 0) {
        if (ui.IsDialogMessageW(window, &message) != 0) continue;
        _ = ui.TranslateMessage(&message);
        _ = ui.DispatchMessageW(&message);
    }
    return 0;
}

/// Before the window exists, so without messageBox, which needs app.
fn reportStartFailure(code: u32) void {
    var text: [400]u8 = undefined;
    const message = print(&text, "rgbctrl Settings could not check whether it is open already, so it did not start (Windows error {d}). Signing out of Windows and back in usually clears this.", .{code});
    var wide: [text.len + 1]u16 = undefined;
    _ = ui.MessageBoxW(null, toWide(&wide, message).ptr, window_title, ui.MB_OK | ui.MB_ICONERROR);
}

fn windowProc(hwnd: ui.HWND, message: u32, wparam: ui.WPARAM, lparam: ui.LPARAM) callconv(.winapi) ui.LRESULT {
    switch (message) {
        ui.WM_CREATE => {
            app.window = hwnd;
            app.dpi = ui.GetDpiForWindow(hwnd);
            createFonts();
            createControls() catch return -1;
            app.created = true;
            applyFonts();
            reload();
            _ = ui.SetTimer(hwnd, poll_timer, poll_interval_ms, null);
            return 0;
        },
        ui.WM_SIZE => {
            if (app.created) layout();
            return 0;
        },
        ui.WM_GETMINMAXINFO => {
            const info: *ui.MINMAXINFO = @ptrFromInt(@as(usize, @bitCast(lparam)));
            const dpi = if (app.created) app.dpi else ui.GetDpiForSystem();
            info.ptMinTrackSize = .{ .x = scaleFor(dpi, 820), .y = scaleFor(dpi, 600) };
            return 0;
        },
        ui.WM_DPICHANGED => {
            app.dpi = ui.highWord(wparam);
            const suggested: *const ui.RECT = @ptrFromInt(@as(usize, @bitCast(lparam)));
            createFonts();
            applyFonts();
            _ = ui.SetWindowPos(hwnd, null, suggested.left, suggested.top, suggested.right - suggested.left, suggested.bottom - suggested.top, ui.SWP_NOZORDER | ui.SWP_NOACTIVATE);
            layout();
            return 0;
        },
        ui.WM_COMMAND => {
            onCommand(ui.lowWord(wparam), ui.highWord(wparam));
            return 0;
        },
        ui.WM_NOTIFY => {
            onNotify(@ptrFromInt(@as(usize, @bitCast(lparam))));
            return 0;
        },
        ui.WM_HSCROLL => {
            if (lparam != 0) onSlider(@ptrFromInt(@as(usize, @bitCast(lparam))));
            return 0;
        },
        ui.WM_DRAWITEM => {
            drawSwatch(@ptrFromInt(@as(usize, @bitCast(lparam))));
            return 1;
        },
        ui.WM_TIMER => {
            if (wparam == poll_timer) poll();
            return 0;
        },
        ui.WM_CLOSE => {
            if (confirmClose()) _ = ui.DestroyWindow(hwnd);
            return 0;
        },
        ui.WM_DESTROY => {
            ui.PostQuitMessage(0);
            return 0;
        },
        else => return ui.DefWindowProcW(hwnd, message, wparam, lparam),
    }
}

fn scaleFor(dpi: u32, value: i32) i32 {
    return @intCast(@divTrunc(@as(i64, value) * dpi + 48, 96));
}

fn scale(value: i32) i32 {
    return scaleFor(app.dpi, value);
}

// UTF-8 to UTF-16, cut at a character boundary when the buffer is too small.
fn toWide(buffer: []u16, text: []const u8) [:0]const u16 {
    const shown = sdk.text.utf8Prefix(text, buffer.len - 1);
    const converted = std.unicode.utf8ToUtf16Le(buffer[0 .. buffer.len - 1], shown) catch 0;
    buffer[converted] = 0;
    return buffer[0..converted :0];
}

fn setText(control: ui.HWND, text: []const u8) void {
    var buffer: [2048]u16 = undefined;
    if (text.len < buffer.len) {
        _ = ui.SetWindowTextW(control, toWide(&buffer, text).ptr);
        return;
    }
    // A UTF-8 text never needs more UTF-16 units than it has bytes.
    const wide = heap.allocator.alloc(u16, text.len + 1) catch {
        _ = ui.SetWindowTextW(control, toWide(&buffer, text).ptr);
        return;
    };
    defer heap.allocator.free(wide);
    _ = ui.SetWindowTextW(control, toWide(wide, text).ptr);
}

/// Sets the text only when it differs from the last one, since setting the text of an edit box
/// scrolls it back to the top and drops the selection.
fn setTextIfChanged(control: ui.HWND, text: []const u8, last_hash: *u64) void {
    const hash = std.hash.Wyhash.hash(1, text);
    if (hash == last_hash.*) return;
    last_hash.* = hash;
    setText(control, text);
}

fn print(buffer: []u8, comptime format: []const u8, args: anytype) []const u8 {
    return std.fmt.bufPrint(buffer, format, args) catch buffer[0..0];
}

// Polling waits while a modal loop runs (a message box, the color picker, a save): a reload
// would free the model that the code around the loop still uses.
fn enterModal() bool {
    const was_busy = app.busy;
    app.busy = true;
    return was_busy;
}

fn leaveModal(was_busy: bool) void {
    app.busy = was_busy;
}

fn messageBox(text: []const u8, kind: u32) i32 {
    const was_busy = enterModal();
    defer leaveModal(was_busy);
    var buffer: [2048]u16 = undefined;
    return ui.MessageBoxW(app.window, toWide(&buffer, text).ptr, window_title, kind);
}

fn send(control: ui.HWND, message: u32, wparam: ui.WPARAM, lparam: ui.LPARAM) ui.LRESULT {
    return ui.SendMessageW(control, message, wparam, lparam);
}

fn pointerParam(pointer: anytype) ui.LPARAM {
    return @bitCast(@intFromPtr(pointer));
}

fn makeControl(class: [*:0]const u16, text: ?[*:0]const u16, style: u32, ex_style: u32, id: usize) error{ControlFailed}!ui.HWND {
    const control = ui.CreateWindowExW(ex_style, class, text, ui.WS_CHILD | ui.WS_VISIBLE | style, 0, 0, 0, 0, app.window, ui.idParam(id), app.instance, null) orelse return error.ControlFailed;
    if (app.control_count < max_controls) {
        app.controls[app.control_count] = control;
        app.control_count += 1;
    }
    return control;
}

fn label(text: [*:0]const u16) error{ControlFailed}!ui.HWND {
    return makeControl(L("STATIC"), text, ui.SS_LEFT, 0, 0);
}

fn createControls() error{ControlFailed}!void {
    app.tree = try makeControl(L("SysTreeView32"), null, ui.WS_TABSTOP | ui.TVS_HASBUTTONS | ui.TVS_HASLINES | ui.TVS_LINESATROOT | ui.TVS_SHOWSELALWAYS | ui.TVS_DISABLEDRAGDROP, ui.WS_EX_CLIENTEDGE, id_tree);
    _ = send(app.tree, ui.TVM_SETEXTENDEDSTYLE, ui.TVS_EX_DOUBLEBUFFER, ui.TVS_EX_DOUBLEBUFFER);
    app.title = try makeControl(L("STATIC"), null, ui.SS_LEFT | ui.SS_NOPREFIX | ui.SS_ENDELLIPSIS, 0, 0);
    app.detail = try makeControl(L("STATIC"), null, ui.SS_LEFT | ui.SS_NOPREFIX, 0, 0);
    app.effect_label = try label(L("&Effect:"));
    app.effect = try makeControl(L("COMBOBOX"), null, ui.WS_TABSTOP | ui.WS_VSCROLL | ui.CBS_DROPDOWNLIST, 0, id_effect);
    app.colors_label = try label(L("Colors:"));
    for (&app.swatches, 0..) |*swatch, index| {
        swatch.* = try makeControl(L("BUTTON"), null, ui.WS_TABSTOP | ui.BS_OWNERDRAW, 0, id_swatch_first + index);
    }
    app.add_color = try makeControl(L("BUTTON"), L("&Add color"), ui.WS_TABSTOP | ui.BS_PUSHBUTTON, 0, id_add_color);
    app.remove_color = try makeControl(L("BUTTON"), L("Re&move color"), ui.WS_TABSTOP | ui.BS_PUSHBUTTON, 0, id_remove_color);
    app.speed_label = try label(L("S&peed:"));
    app.speed = try makeControl(L("msctls_trackbar32"), null, ui.WS_TABSTOP | ui.TBS_NOTICKS, 0, id_speed);
    app.speed_value = try makeControl(L("STATIC"), null, ui.SS_LEFT | ui.SS_NOPREFIX, 0, 0);
    app.brightness_label = try label(L("&Brightness:"));
    app.brightness = try makeControl(L("msctls_trackbar32"), null, ui.WS_TABSTOP | ui.TBS_NOTICKS, 0, id_brightness);
    app.brightness_value = try makeControl(L("STATIC"), null, ui.SS_LEFT | ui.SS_NOPREFIX, 0, 0);
    for ([_]ui.HWND{ app.speed, app.brightness }) |slider| {
        _ = send(slider, ui.TBM_SETRANGE, 1, ui.makeLong(0, 100));
        _ = send(slider, ui.TBM_SETPAGESIZE, 0, 10);
        _ = send(slider, ui.TBM_SETLINESIZE, 0, 1);
    }
    app.leds_label = try label(L("&LEDs:"));
    app.leds = try makeControl(L("EDIT"), null, ui.WS_TABSTOP | ui.ES_NUMBER | ui.ES_AUTOHSCROLL, ui.WS_EX_CLIENTEDGE, id_leds);
    _ = send(app.leds, ui.EM_SETLIMITTEXT, 5, 0);
    app.leds_spin = try makeControl(L("msctls_updown32"), null, ui.UDS_SETBUDDYINT | ui.UDS_ALIGNRIGHT | ui.UDS_ARROWKEYS | ui.UDS_NOTHOUSANDS, 0, id_leds_spin);
    _ = send(app.leds_spin, ui.UDM_SETBUDDY, @intFromPtr(app.leds), 0);
    app.leds_range = try makeControl(L("STATIC"), null, ui.SS_LEFT | ui.SS_NOPREFIX, 0, 0);
    app.note = try makeControl(L("STATIC"), null, ui.SS_LEFT | ui.SS_NOPREFIX, 0, 0);
    app.plugins = try makeControl(L("SysListView32"), null, ui.WS_TABSTOP | ui.LVS_REPORT | ui.LVS_SINGLESEL | ui.LVS_SHOWSELALWAYS | ui.LVS_NOSORTHEADER, ui.WS_EX_CLIENTEDGE, id_plugins);
    const list_styles = ui.LVS_EX_CHECKBOXES | ui.LVS_EX_FULLROWSELECT | ui.LVS_EX_DOUBLEBUFFER;
    _ = send(app.plugins, ui.LVM_SETEXTENDEDLISTVIEWSTYLE, list_styles, list_styles);
    for ([_][*:0]const u16{ L("Plugin"), L("Status"), L("What it does") }, 0..) |heading, index| {
        var column = ui.LVCOLUMNW{ .mask = ui.LVCF_TEXT | ui.LVCF_WIDTH | ui.LVCF_SUBITEM, .cx = 100, .pszText = heading, .iSubItem = @intCast(index) };
        _ = send(app.plugins, ui.LVM_INSERTCOLUMNW, index, pointerParam(&column));
    }
    app.plugins_note = try makeControl(L("STATIC"), plugins_note_text, ui.SS_LEFT | ui.SS_NOPREFIX, 0, 0);
    app.info = try makeControl(L("EDIT"), null, ui.WS_TABSTOP | ui.WS_VSCROLL | ui.ES_MULTILINE | ui.ES_READONLY, ui.WS_EX_CLIENTEDGE, 0);
    app.status = try makeControl(L("STATIC"), null, ui.SS_LEFT | ui.SS_NOPREFIX | ui.SS_ENDELLIPSIS, 0, 0);
    app.revert = try makeControl(L("BUTTON"), L("Re&vert"), ui.WS_TABSTOP | ui.BS_PUSHBUTTON, 0, id_revert);
    app.save = try makeControl(L("BUTTON"), L("&Save"), ui.WS_TABSTOP | ui.BS_PUSHBUTTON, 0, id_save);
}

fn createFonts() void {
    if (app.font) |font| _ = ui.DeleteObject(font);
    if (app.title_font) |font| _ = ui.DeleteObject(font);
    var metrics = ui.NONCLIENTMETRICSW{};
    var message_font = ui.LOGFONTW{ .lfHeight = -scale(12) };
    if (ui.SystemParametersInfoForDpi(ui.SPI_GETNONCLIENTMETRICS, @sizeOf(ui.NONCLIENTMETRICSW), &metrics, 0, app.dpi) != 0) {
        message_font = metrics.lfMessageFont;
    } else {
        const face = L("Segoe UI");
        @memcpy(message_font.lfFaceName[0..face.len], face);
    }
    app.font = ui.CreateFontIndirectW(&message_font);
    var title_font = message_font;
    title_font.lfWeight = ui.FW_BOLD;
    title_font.lfHeight = @divTrunc(message_font.lfHeight * 4, 3);
    app.title_font = ui.CreateFontIndirectW(&title_font);
}

fn applyFonts() void {
    if (!app.created) return;
    for (app.controls[0..app.control_count]) |control| {
        _ = send(control, ui.WM_SETFONT, @intFromPtr(app.font), 1);
    }
    _ = send(app.title, ui.WM_SETFONT, @intFromPtr(app.title_font), 1);
}

fn place(control: ui.HWND, x: i32, y: i32, width: i32, height: i32) void {
    _ = ui.MoveWindow(control, x, y, @max(width, 0), @max(height, 0), 1);
}

/// The height text needs in the window's font when it wraps at width.
fn wrappedTextHeight(text: [*:0]const u16, width: i32) i32 {
    const hdc = ui.GetDC(app.window) orelse return scale(64);
    defer _ = ui.ReleaseDC(app.window, hdc);
    const previous = if (app.font) |font| ui.SelectObject(hdc, font) else null;
    defer if (previous) |object| {
        _ = ui.SelectObject(hdc, object);
    };
    var rect = ui.RECT{ .right = @max(width, 1) };
    _ = ui.DrawTextW(hdc, text, -1, &rect, ui.DT_CALCRECT | ui.DT_WORDBREAK | ui.DT_NOPREFIX);
    return rect.bottom - rect.top;
}

fn setVisible(control: ui.HWND, visible: bool) void {
    _ = ui.ShowWindow(control, if (visible) ui.SW_SHOW else ui.SW_HIDE);
}

const Area = struct { x: i32, y: i32, width: i32, bottom: i32 };

fn panelArea() Area {
    var client = ui.RECT{};
    _ = ui.GetClientRect(app.window, &client);
    const margin = scale(12);
    const tree_width = scale(300);
    const x = margin + tree_width + scale(16);
    return .{ .x = x, .y = margin, .width = client.right - x - margin, .bottom = mainBottom(client) };
}

fn mainBottom(client: ui.RECT) i32 {
    return client.bottom - scale(12) - scale(28) - scale(8) - scale(84) - scale(8);
}

fn layout() void {
    var client = ui.RECT{};
    _ = ui.GetClientRect(app.window, &client);
    const width = client.right;
    const margin = scale(12);
    const gap = scale(8);
    const button_width = scale(100);
    const button_height = scale(28);
    const buttons_y = client.bottom - margin - button_height;
    place(app.save, width - margin - button_width, buttons_y, button_width, button_height);
    place(app.revert, width - margin - 2 * button_width - gap, buttons_y, button_width, button_height);
    place(app.status, margin, buttons_y + scale(6), width - 2 * margin - 2 * button_width - 2 * gap, scale(20));
    const info_height = scale(84);
    const info_y = buttons_y - gap - info_height;
    place(app.info, margin, info_y, width - 2 * margin, info_height);
    const bottom = mainBottom(client);
    place(app.tree, margin, margin, scale(300), bottom - margin);
    const area = panelArea();
    const note_height = wrappedTextHeight(plugins_note_text, area.width) + scale(4);
    place(app.plugins, area.x, area.y, area.width, area.bottom - area.y - note_height - gap);
    place(app.plugins_note, area.x, area.bottom - note_height, area.width, note_height);
    sizePluginColumns(area.width);
    layoutLightingPanel();
}

fn sizePluginColumns(width: i32) void {
    const name_width = scale(150);
    const status_width = scale(330);
    _ = send(app.plugins, ui.LVM_SETCOLUMNWIDTH, 0, name_width);
    _ = send(app.plugins, ui.LVM_SETCOLUMNWIDTH, 1, status_width);
    _ = send(app.plugins, ui.LVM_SETCOLUMNWIDTH, 2, @max(width - name_width - status_width - scale(24), scale(120)));
}

// Rows of the zone panel from the top; a hidden row takes no space.
fn layoutLightingPanel() void {
    if (!app.created) return;
    const area = panelArea();
    const label_width = scale(90);
    const field_x = area.x + label_width;
    const field_width = @min(area.width - label_width, scale(380));
    var y = area.y;
    place(app.title, area.x, y, area.width, scale(26));
    y += scale(30);
    place(app.detail, area.x, y, area.width, scale(36));
    y += scale(46);
    place(app.effect_label, area.x, y + scale(4), label_width, scale(20));
    place(app.effect, field_x, y, field_width, scale(320));
    y += scale(40);
    if (isShown(app.colors_label)) {
        place(app.colors_label, area.x, y + scale(6), label_width, scale(20));
        const swatch = scale(30);
        const swatch_gap = scale(6);
        var rows: i32 = 0;
        for (app.swatches, 0..) |swatch_window, index| {
            const column: i32 = @intCast(index % 8);
            const row: i32 = @intCast(index / 8);
            place(swatch_window, field_x + column * (swatch + swatch_gap), y + row * (swatch + swatch_gap), swatch, swatch);
            if (isShown(swatch_window)) rows = row + 1;
        }
        y += @max(rows, 1) * (swatch + swatch_gap);
        if (isShown(app.add_color)) {
            place(app.add_color, field_x, y, scale(110), scale(28));
            place(app.remove_color, field_x + scale(118), y, scale(120), scale(28));
            y += scale(38);
        }
        y += scale(4);
    }
    if (isShown(app.speed)) {
        place(app.speed_label, area.x, y + scale(6), label_width, scale(20));
        place(app.speed, field_x, y, field_width - scale(52), scale(30));
        place(app.speed_value, field_x + field_width - scale(46), y + scale(6), scale(46), scale(20));
        y += scale(38);
    }
    if (isShown(app.brightness)) {
        place(app.brightness_label, area.x, y + scale(6), label_width, scale(20));
        place(app.brightness, field_x, y, field_width - scale(52), scale(30));
        place(app.brightness_value, field_x + field_width - scale(46), y + scale(6), scale(46), scale(20));
        y += scale(38);
    }
    if (isShown(app.leds)) {
        place(app.leds_label, area.x, y + scale(4), label_width, scale(20));
        place(app.leds, field_x, y, scale(90), scale(26));
        _ = send(app.leds_spin, ui.UDM_SETBUDDY, @intFromPtr(app.leds), 0);
        place(app.leds_range, field_x + scale(100), y + scale(4), field_width - scale(100), scale(20));
        y += scale(38);
    }
    place(app.note, area.x, y + scale(4), area.width, @max(area.bottom - y - scale(4), scale(20)));
}

fn isShown(control: ui.HWND) bool {
    const style: usize = @bitCast(GetWindowLongPtrW(control, -16));
    return style & ui.WS_VISIBLE != 0;
}

extern "user32" fn GetWindowLongPtrW(hwnd: ui.HWND, index: i32) callconv(.winapi) isize;

fn lightingControls() [26]ui.HWND {
    var list: [26]ui.HWND = undefined;
    const fixed = [_]ui.HWND{ app.title, app.detail, app.effect_label, app.effect, app.colors_label, app.add_color, app.remove_color, app.speed_label, app.speed, app.speed_value };
    @memcpy(list[0..fixed.len], &fixed);
    @memcpy(list[fixed.len..][0..model_module.max_colors], &app.swatches);
    return list;
}

fn showPage(page: Page) void {
    app.page = page;
    const lighting = page == .lighting;
    for (lightingControls()) |control| setVisible(control, lighting);
    for ([_]ui.HWND{ app.brightness_label, app.brightness, app.brightness_value, app.leds_label, app.leds, app.leds_spin, app.leds_range, app.note }) |control| setVisible(control, lighting);
    setVisible(app.plugins, !lighting);
    setVisible(app.plugins_note, !lighting);
    if (lighting) refreshNodePanel();
}

// The settings shown for a node: its own when it has them, else those of the nearest level
// above with settings of its own (as edited, before saving), else what rgbctrl uses from the
// files.
/// What the panel shows for a node: its own settings, or for a node that follows the levels
/// above, what rgbctrl will show there once the edits are saved (see Model.preview).
fn displayed(index: usize) Settings {
    const node = &app.model.nodes[index];
    if (node.current.choice != .inherit) return node.current;
    var scratch = std.heap.ArenaAllocator.init(heap.allocator);
    defer scratch.deinit();
    if (app.model.preview(scratch.allocator(), index)) |settings| return settings;
    var settings = node.current;
    settings.choice = node.effective_choice;
    return settings;
}

fn canEdit() bool {
    return app.model.canEdit() and !app.user_unreadable;
}

fn choiceLabel(buffer: []u8, index: usize, choice: Choice) []const u8 {
    const node = &app.model.nodes[index];
    return switch (choice) {
        .inherit => if (node.parent) |parent| print(buffer, "Same as {s}", .{app.model.nodes[parent].label}) else "Not set",
        .untouched => "Leave as it is",
        .off => "Off",
        .static => "Static color",
        .breathing => "Breathing",
        .flash => "Flash",
        .cycle => "Color cycle",
        .rainbow => "Rainbow",
        .gradient => "Gradient",
    };
}

fn fillChoices(index: usize) void {
    _ = send(app.effect, ui.CB_RESETCONTENT, 0, 0);
    var buffer: [9]Choice = undefined;
    const current = app.model.nodes[index].current.choice;
    var list = app.model.choices(index, &buffer);
    var found = false;
    for (list) |choice| {
        if (choice == current) found = true;
    }
    if (!found and list.len < buffer.len) {
        buffer[list.len] = current;
        list = buffer[0 .. list.len + 1];
    }
    for (list) |choice| {
        var text: [160]u8 = undefined;
        var label_text = choiceLabel(&text, index, choice);
        var extended: [200]u8 = undefined;
        if (!found and choice == current) label_text = print(&extended, "{s} (this zone cannot show it)", .{label_text});
        var wide: [200]u16 = undefined;
        const position = send(app.effect, ui.CB_ADDSTRING, 0, pointerParam(toWide(&wide, label_text).ptr));
        if (position < 0) continue;
        _ = send(app.effect, ui.CB_SETITEMDATA, @intCast(position), @intFromEnum(choice));
        if (choice == current) _ = send(app.effect, ui.CB_SETCURSEL, @intCast(position), 0);
    }
}

fn titleText(buffer: []u8, index: usize) []const u8 {
    const node = &app.model.nodes[index];
    return switch (node.level) {
        .all, .device => node.label,
        .zone => print(buffer, "{s} \u{203A} {s}", .{ app.model.nodes[node.parent.?].label, node.label }),
    };
}

fn detailText(buffer: []u8, index: usize) []const u8 {
    const node = &app.model.nodes[index];
    switch (node.level) {
        .all => return "Applies to every zone that has no settings of its own.",
        .device => {
            var zones: usize = 0;
            for (app.model.nodes) |other| {
                if (other.parent) |parent| {
                    if (parent == index) zones += 1;
                }
            }
            if (!node.detected) return print(buffer, "rgbctrl did not find this device. Configured as lighting.{s}.", .{node.device_key});
            const description = model_module.pluginDescription(node.plugin);
            return print(buffer, "{d} lighting zone{s}{s}{s}. Configured as lighting.{s}.", .{ zones, if (zones == 1) "" else "s", if (description.len > 0) " \u{00B7} " else "", description, node.device_key });
        },
        .zone => {
            const zone = node.zone orelse return print(buffer, "rgbctrl did not find this zone. Configured as lighting.{s}.{s}.", .{ node.device_key, node.zone_name });
            const in_device = zone.flags & sdk.abi.zone_host_frames == 0;
            return print(buffer, "{d} LED{s}{s}. Configured as lighting.{s}.{s}.", .{ zone.leds, if (zone.leds == 1) "" else "s", if (in_device) " \u{00B7} effects run in the device itself" else "", node.device_key, node.zone_name });
        },
    }
}

fn noteText(buffer: []u8, index: usize) []const u8 {
    const node = &app.model.nodes[index];
    var length: usize = 0;
    const append = struct {
        fn call(out: []u8, used: *usize, text: []const u8) void {
            if (used.* > 0 and used.* < out.len) {
                out[used.*] = ' ';
                used.* += 1;
            }
            const count = @min(text.len, out.len - used.*);
            @memcpy(out[used.* .. used.* + count], text[0..count]);
            used.* += count;
        }
    }.call;
    if (!canEdit()) {
        var issue_buffer: [400]u8 = undefined;
        append(buffer, &length, unreadableText(&issue_buffer));
        return buffer[0..length];
    }
    const choice = node.current.choice;
    var parent_buffer: [200]u8 = undefined;
    switch (choice) {
        .inherit => append(buffer, &length, switch (node.level) {
            .all => "Zones without settings of their own are left as they are. Choose an effect to set every device at once.",
            .device => "The zones of this device use the settings of All devices, unless a zone has its own. Choose an effect to set the whole device.",
            .zone => print(&parent_buffer, "This zone uses the settings of {s}. Choose an effect to give it its own.", .{app.model.nodes[node.parent.?].label}),
        }),
        .untouched => append(buffer, &length, "rgbctrl leaves this lighting as it is, so the device keeps showing its own lighting."),
        .off => append(buffer, &length, "The lights are turned off."),
        .static => {},
        .breathing => append(buffer, &length, "The light fades in and out; each breath uses the next color."),
        .flash => append(buffer, &length, "The light flashes; each flash uses the next color."),
        .cycle => append(buffer, &length, "With one color the hue moves around the whole color wheel; with more colors it blends from one to the next."),
        .rainbow => append(buffer, &length, "A moving rainbow across the LEDs."),
        .gradient => append(buffer, &length, "The colors spread across the LEDs from the first to the last."),
    }
    if (node.level == .all and choice != .inherit) append(buffer, &length, "Devices and zones with settings of their own keep them.");
    if (app.model.zoneNameLevel(index)) append(buffer, &length, print(&parent_buffer, "The settings file also sets lighting.*.{s}, which applies here wherever neither this zone nor its device has a setting of its own; change it in a text editor.", .{node.zone_name}));
    if (node.has_advanced_keys) append(buffer, &length, "The settings file also sets engine, reverse or per-LED colors here; rgbctrl Settings keeps them as they are.");
    if (node.resizable()) {
        const leds = node.leds_current orelse node.zone.?.leds;
        if (leds == 0) append(buffer, &length, "Set LEDs to the number of LEDs connected to this header; with 0 it shows nothing.");
    }
    return buffer[0..length];
}

// The settings file is named in the box at the bottom.
fn unreadableText(buffer: []u8) []const u8 {
    if (app.user_unreadable) return "rgbctrl Settings cannot open your settings file, so it cannot change anything.";
    const issue = app.model.user_issue.?;
    return print(buffer, "Your settings file has an error at line {d}, column {d}: {s}. Fix it in a text editor; rgbctrl Settings reads it again as soon as it is saved.", .{ issue.line, issue.column, issue.message });
}

fn refreshNodePanel() void {
    if (!app.created or app.page != .lighting or app.model.nodes.len == 0) return;
    if (app.selected >= app.model.nodes.len) app.selected = 0;
    app.filling = true;
    defer app.filling = false;
    const index = app.selected;
    const node = &app.model.nodes[index];
    const shown = displayed(index);
    app.shown = shown;
    const editable = canEdit();
    const own = node.current.choice != .inherit;
    var text: [1200]u8 = undefined;
    setText(app.title, titleText(&text, index));
    setText(app.detail, detailText(&text, index));
    fillChoices(index);
    _ = ui.EnableWindow(app.effect, @intFromBool(editable));
    const uses_colors = shown.choice.usesColors();
    const count: usize = if (uses_colors) shown.color_count else 0;
    setVisible(app.colors_label, uses_colors);
    for (app.swatches, 0..) |swatch, slot| {
        setVisible(swatch, slot < count);
        _ = ui.EnableWindow(swatch, @intFromBool(editable and own));
        var hex: [7]u8 = undefined;
        var name: [40]u8 = undefined;
        setText(swatch, print(&name, "Color {d}, {s}", .{ slot + 1, model_module.hexColor(&hex, shown.colors[slot]) }));
        _ = ui.InvalidateRect(swatch, null, 1);
    }
    setVisible(app.add_color, uses_colors and own);
    setVisible(app.remove_color, uses_colors and own);
    _ = ui.EnableWindow(app.add_color, @intFromBool(editable and own and count < app.model.maxColors(index, shown.choice)));
    _ = ui.EnableWindow(app.remove_color, @intFromBool(editable and own and count > Model.minColors(shown.choice)));
    const uses_speed = shown.choice.usesSpeed();
    for ([_]ui.HWND{ app.speed_label, app.speed, app.speed_value }) |control| setVisible(control, uses_speed);
    _ = ui.EnableWindow(app.speed, @intFromBool(editable and own));
    _ = send(app.speed, ui.TBM_SETPOS, 1, shown.speed);
    const uses_brightness = shown.choice.usesBrightness();
    for ([_]ui.HWND{ app.brightness_label, app.brightness, app.brightness_value }) |control| setVisible(control, uses_brightness);
    _ = ui.EnableWindow(app.brightness, @intFromBool(editable and own));
    _ = send(app.brightness, ui.TBM_SETPOS, 1, shown.brightness);
    updateSliderValues(shown);
    const resizable = node.resizable();
    for ([_]ui.HWND{ app.leds_label, app.leds, app.leds_spin, app.leds_range }) |control| setVisible(control, resizable);
    if (resizable) {
        const zone = node.zone.?;
        const leds = node.leds_current orelse zone.leds;
        _ = send(app.leds_spin, ui.UDM_SETRANGE32, 0, @intCast(zone.max_leds));
        _ = send(app.leds_spin, ui.UDM_SETPOS32, 0, @intCast(leds));
        setText(app.leds, print(&text, "{d}", .{leds}));
        setText(app.leds_range, print(&text, "connected to this header (0 to {d})", .{zone.max_leds}));
        _ = ui.EnableWindow(app.leds, @intFromBool(editable));
        _ = ui.EnableWindow(app.leds_spin, @intFromBool(editable));
    }
    setText(app.note, noteText(&text, index));
    layoutLightingPanel();
}

fn updateSliderValues(shown: Settings) void {
    var text: [16]u8 = undefined;
    setText(app.speed_value, print(&text, "{d}", .{shown.speed}));
    setText(app.brightness_value, print(&text, "{d} %", .{shown.brightness}));
}

fn treeLabel(buffer: []u8, index: usize) []const u8 {
    const node = &app.model.nodes[index];
    return if (node.isDirty()) print(buffer, "{s} *", .{node.label}) else node.label;
}

fn updateTreeItem(index: usize) void {
    if (index >= app.tree_items.len) return;
    const item = app.tree_items[index] orelse return;
    const node = &app.model.nodes[index];
    var text: [300]u8 = undefined;
    var wide: [300]u16 = undefined;
    var change = ui.TVITEMW{
        .mask = ui.TVIF_STATE | ui.TVIF_TEXT,
        .hItem = item,
        .state = if (node.current.choice != .inherit) ui.TVIS_BOLD else 0,
        .stateMask = ui.TVIS_BOLD,
        .pszText = toWide(&wide, treeLabel(&text, index)).ptr,
    };
    _ = send(app.tree, ui.TVM_SETITEMW, 0, pointerParam(&change));
}

fn insertTreeItem(parent: ?ui.HTREEITEM, text: []const u8, param: isize, bold: bool) ?ui.HTREEITEM {
    var wide: [300]u16 = undefined;
    var insert = ui.TVINSERTSTRUCTW{
        .hParent = parent orelse ui.TVI_ROOT,
        .hInsertAfter = ui.TVI_LAST,
        .item = .{ .mask = ui.TVIF_TEXT | ui.TVIF_PARAM | ui.TVIF_STATE, .pszText = toWide(&wide, text).ptr, .lParam = param, .state = if (bold) ui.TVIS_BOLD else 0, .stateMask = ui.TVIS_BOLD },
    };
    const result = send(app.tree, ui.TVM_INSERTITEMW, 0, pointerParam(&insert));
    if (result == 0) return null;
    return @ptrFromInt(@as(usize, @bitCast(result)));
}

fn rebuildTree(previous: SelectionKey) void {
    app.filling = true;
    defer app.filling = false;
    _ = send(app.tree, ui.TVM_DELETEITEM, 0, pointerParam(ui.TVI_ROOT));
    app.tree_items = app.arena.allocator().alloc(?ui.HTREEITEM, app.model.nodes.len) catch {
        app.tree_items = &.{};
        return;
    };
    for (app.tree_items, app.model.nodes, 0..) |*item, *node, index| {
        const parent = if (node.parent) |parent_index| app.tree_items[parent_index] else null;
        var text: [300]u8 = undefined;
        item.* = insertTreeItem(parent, treeLabel(&text, index), @intCast(index), node.current.choice != .inherit);
    }
    const plugins_item = insertTreeItem(null, "Plugins", plugins_page_param, false);
    for (app.tree_items, app.model.nodes) |item, node| {
        if (node.level != .zone) {
            if (item) |handle| _ = send(app.tree, ui.TVM_EXPAND, ui.TVE_EXPAND, pointerParam(handle));
        }
    }
    var page = previous.page;
    app.selected = 0;
    for (app.model.nodes, 0..) |node, index| {
        if (node.level == previous.level and std.mem.eql(u8, node.device_key, previous.device[0..previous.device_len]) and std.mem.eql(u8, node.zone_name, previous.zone[0..previous.zone_len])) app.selected = index;
    }
    if (page == .plugins and plugins_item == null) page = .lighting;
    const selected_item = if (page == .plugins) plugins_item else if (app.tree_items.len > 0) app.tree_items[app.selected] else null;
    if (selected_item) |item| _ = send(app.tree, ui.TVM_SELECTITEM, ui.TVGN_CARET, pointerParam(item));
    app.page = page;
}

fn selectionKey() SelectionKey {
    var key = SelectionKey{ .page = app.page };
    if (app.selected < app.model.nodes.len) {
        const node = &app.model.nodes[app.selected];
        key.level = node.level;
        key.device_len = @min(node.device_key.len, key.device.len);
        @memcpy(key.device[0..key.device_len], node.device_key[0..key.device_len]);
        key.zone_len = @min(node.zone_name.len, key.zone.len);
        @memcpy(key.zone[0..key.zone_len], node.zone_name[0..key.zone_len]);
    }
    return key;
}

fn pluginStatus(buffer: []u8, row: *const model_module.PluginRow) []const u8 {
    if (row.isDirty()) {
        if (!row.desired) return "Turns off when you save";
        if (app.model.enableNeedsBase(row)) return "Turns on when you save (needs administrator approval)";
        return "Turns on when you save";
    }
    // The files and the running rgbctrl disagree until rgbctrl applies the files.
    if (row.saved != row.info.enabled) return if (row.saved) "Turns on when rgbctrl applies the settings" else "Turns off when rgbctrl applies the settings";
    return switch (row.info.state) {
        .active => if (row.device_count > 0) print(buffer, "On, {d} device{s}", .{ row.device_count, if (row.device_count == 1) "" else "s" }) else if (row.info.sensors) "On, provides readings" else "On, no supported devices found",
        .disabled => if (row.info.opt_in) "Off (opt-in)" else "Off",
        .failed => "Could not start (see rgbctrl.log)",
        .opening => "Starting",
        .closed => "Stopped",
    };
}

fn setPluginCheck(index: usize, checked: bool) void {
    var item = ui.LVITEMW{ .stateMask = ui.LVIS_STATEIMAGEMASK, .state = @as(u32, if (checked) 2 else 1) << 12 };
    _ = send(app.plugins, ui.LVM_SETITEMSTATE, index, pointerParam(&item));
}

fn setPluginText(index: usize, column: i32, text: []const u8) void {
    var wide: [300]u16 = undefined;
    var item = ui.LVITEMW{ .iSubItem = column, .pszText = toWide(&wide, text).ptr };
    _ = send(app.plugins, ui.LVM_SETITEMTEXTW, index, pointerParam(&item));
}

fn rebuildPlugins() void {
    app.filling = true;
    defer app.filling = false;
    _ = send(app.plugins, ui.LVM_DELETEALLITEMS, 0, 0);
    for (app.model.plugins, 0..) |*row, index| {
        var wide: [64]u16 = undefined;
        var item = ui.LVITEMW{ .mask = ui.LVIF_TEXT | ui.LVIF_PARAM, .iItem = @intCast(index), .pszText = toWide(&wide, row.info.name).ptr, .lParam = @intCast(index) };
        const position = send(app.plugins, ui.LVM_INSERTITEMW, 0, pointerParam(&item));
        if (position < 0) continue;
        setPluginCheck(index, row.desired);
        var status: [80]u8 = undefined;
        setPluginText(index, 1, pluginStatus(&status, row));
        setPluginText(index, 2, model_module.pluginDescription(row.info.name));
    }
    _ = ui.EnableWindow(app.plugins, @intFromBool(canEdit()));
}

fn currentInventory() ?inventory.Inventory {
    return app.latest orelse app.model.inventory;
}

fn setNotice(text: []const u8) void {
    const count = @min(text.len, app.notice.len);
    @memcpy(app.notice[0..count], text[0..count]);
    app.notice_len = count;
}

fn clockText(buffer: []u8) []const u8 {
    var time: win32.SYSTEMTIME = undefined;
    win32.GetLocalTime(&time);
    return print(buffer, "{d:0>2}:{d:0>2}:{d:0>2}", .{ time.wHour, time.wMinute, time.wSecond });
}

fn refreshStatus() void {
    if (!app.created) return;
    const dirty = app.model.isDirty();
    _ = ui.EnableWindow(app.save, @intFromBool(dirty and canEdit()));
    _ = ui.EnableWindow(app.revert, @intFromBool(dirty or app.changed_on_disk));
    _ = send(app.save, ui.BCM_SETSHIELD, 0, @intFromBool(app.model.needsElevation()));
    var line: [700]u8 = undefined;
    const found = currentInventory();
    const status: []const u8 = blk: {
        if (dirty) break :blk if (app.model.needsElevation()) "You have unsaved changes. Saving asks for administrator approval to turn plugins on." else "You have unsaved changes. Click Save to apply them.";
        if (app.notice_len > 0) break :blk app.notice[0..app.notice_len];
        if (app.model.inventory_unreadable) break :blk "The device list rgbctrl wrote could not be read; it may be from a newer rgbctrl.";
        const devices = if (found) |list| list.devices.len else 0;
        if (found == null and app.inventory_skipped) break :blk "rgbctrl Settings ignored the device list it found (see below).";
        if (found == null) break :blk if (app.running) "rgbctrl is starting; your devices appear here once it has found them." else "rgbctrl has not listed your devices yet. Start it (it runs at startup), then they appear here.";
        if (app.running) break :blk print(&line, "rgbctrl is running and controls {d} device{s}.", .{ devices, if (devices == 1) "" else "s" });
        break :blk "rgbctrl is not running. Showing the devices it found when it last ran.";
    };
    setTextIfChanged(app.status, status, &app.status_hash);
    var info: std.ArrayList(u8) = .empty;
    defer info.deinit(heap.allocator);
    writeInfo(&info, found) catch {};
    setTextIfChanged(app.info, info.items, &app.info_hash);
}

fn writeInfo(out: *std.ArrayList(u8), found: ?inventory.Inventory) error{OutOfMemory}!void {
    const allocator = heap.allocator;
    var path_buffer: [1024]u8 = undefined;
    try out.appendSlice(allocator, "Settings file: ");
    try out.appendSlice(allocator, app.user_path.utf8(&path_buffer));
    try out.appendSlice(allocator, "\r\nAdministrator settings file, for opt-in plugins: ");
    try out.appendSlice(allocator, app.base_path.utf8(&path_buffer));
    if (!canEdit()) {
        var issue_buffer: [400]u8 = undefined;
        try out.appendSlice(allocator, "\r\n");
        try out.appendSlice(allocator, unreadableText(&issue_buffer));
    }
    if (app.changed_on_disk) try out.appendSlice(allocator, "\r\nA settings file changed outside rgbctrl Settings; Save writes your changes on top of it, Revert shows it.");
    if (app.inventory_skipped) try out.appendSlice(allocator, "\r\nrgbctrl Settings runs as administrator, so it ignores device lists that other accounts could change, such as the one of an rgbctrl that runs without administrator rights. Start rgbctrl Settings without \"Run as administrator\" to see that one.");
    const list = found orelse return;
    if (list.kept_previous) try out.appendSlice(allocator, "\r\nrgbctrl could not use the changed settings and keeps the ones from before.");
    for ([_]inventory.ConfigFile{ list.base, list.user }) |file| {
        if (!file.failed) continue;
        try out.appendSlice(allocator, "\r\nrgbctrl cannot use ");
        try out.appendSlice(allocator, file.path);
        try out.appendSlice(allocator, ": ");
        try out.appendSlice(allocator, file.status);
    }
    if (list.problems.len == 0) return;
    try out.appendSlice(allocator, "\r\nProblems rgbctrl reported:");
    for (list.problems) |problem| {
        try out.appendSlice(allocator, if (problem.severity == .@"error") "\r\n  Error: " else "\r\n  Warning: ");
        try out.appendSlice(allocator, problem.message);
    }
}

fn readTimes() void {
    app.user_times = files.times(app.user_path.terminated());
    app.base_times = files.times(app.base_path.terminated());
}

/// Reads the inventory and both settings files again; unsaved edits are dropped.
fn reload() void {
    const previous = selectionKey();
    var fresh = std.heap.ArenaAllocator.init(heap.allocator);
    const arena = fresh.allocator();
    var inventory_path = platform.PathBuffer{};
    const search = files.findInventory(&inventory_path, app.elevated);
    const found = search.found;
    const inventory_text: ?[]const u8 = if (found != null) (files.readText(arena, inventory_path.terminated()) catch null) else null;
    var user_path = platform.PathBuffer{};
    var have_user_path = false;
    if (inventory_text) |text| {
        if (inventory.parse(arena, text)) |parsed| {
            if (parsed.user.path.len > 0) have_user_path = platform.fullPathFromUtf8(parsed.user.path, &user_path);
        } else |_| {}
    }
    if (!have_user_path) _ = files.defaultUserConfig(&user_path);
    var base_path = platform.PathBuffer{};
    _ = files.baseConfig(&base_path);
    var user_unreadable = false;
    const user_text = files.readText(arena, user_path.terminated()) catch blk: {
        user_unreadable = true;
        break :blk null;
    };
    const base_text = files.readText(arena, base_path.terminated()) catch null;
    const model = Model.load(arena, .{ .inventory_text = inventory_text, .user_text = user_text, .base_text = base_text }) catch {
        fresh.deinit();
        _ = messageBox("rgbctrl Settings ran out of memory while reading the settings.", ui.MB_OK | ui.MB_ICONERROR);
        return;
    };
    app.arena.deinit();
    app.arena = fresh;
    app.model = model;
    app.user_path = user_path;
    app.base_path = base_path;
    app.inventory_path = inventory_path;
    app.inventory_time = if (found) |times| times.write_time else null;
    app.inventory_skipped = search.skipped_untrusted;
    app.user_unreadable = user_unreadable;
    app.changed_on_disk = false;
    app.latest = null;
    _ = app.status_arena.reset(.retain_capacity);
    readTimes();
    app.running = files.instanceRunning();
    rebuildTree(previous);
    rebuildPlugins();
    showPage(app.page);
    refreshStatus();
}

// The inventory changed while edits are unsaved: only the status uses the new one.
fn readLatestInventory(path: *platform.PathBuffer) void {
    _ = app.status_arena.reset(.retain_capacity);
    app.latest = null;
    const arena = app.status_arena.allocator();
    const text = (files.readText(arena, path.terminated()) catch return) orelse return;
    app.latest = inventory.parse(arena, text) catch null;
    // How rgbctrl runs decides which file turns a plugin on, so unsaved choices follow it.
    if (app.latest) |latest| {
        const previous_base = if (app.model.inventory) |found| found.base.privileged else true;
        if (latest.account != app.model.account or latest.base.privileged != previous_base) {
            app.model.setAccount(latest.account, latest.base.privileged);
            rebuildPlugins();
        }
    }
}

fn poll() void {
    if (app.busy) return;
    app.running = files.instanceRunning();
    var path = platform.PathBuffer{};
    const search = files.findInventory(&path, app.elevated);
    const time: ?u64 = if (search.found) |times| times.write_time else null;
    const inventory_changed = !std.meta.eql(time, app.inventory_time) or !std.mem.eql(u16, path.slice(), app.inventory_path.slice());
    const files_changed = !std.meta.eql(files.times(app.user_path.terminated()), app.user_times) or !std.meta.eql(files.times(app.base_path.terminated()), app.base_times);
    if ((inventory_changed or files_changed) and !app.model.isDirty()) {
        reload();
    } else {
        if (inventory_changed) {
            app.inventory_time = time;
            app.inventory_path = path;
            readLatestInventory(&path);
        }
        if (files_changed) {
            app.changed_on_disk = true;
            readTimes();
        }
    }
    checkPending();
    refreshStatus();
}

/// The plugins that the settings files turn on or off but rgbctrl does not run that way.
fn pluginsNotAsSet(found: *const inventory.Inventory) usize {
    var count: usize = 0;
    for (app.model.plugins) |*row| {
        for (found.plugins) |plugin| {
            if (std.mem.eql(u8, plugin.name, row.info.name) and plugin.enabled != row.saved) count += 1;
        }
    }
    return count;
}

fn checkPending() void {
    const pending = app.pending orelse return;
    var text: [700]u8 = undefined;
    var clock: [16]u8 = undefined;
    if (!app.running) {
        setNotice("Saved. rgbctrl is not running, so your changes apply the next time it starts.");
        app.pending = null;
        return;
    }
    const found = currentInventory() orelse return;
    const user_saved = pending.user_stamp[0..pending.user_stamp_len];
    const base_saved = pending.base_stamp[0..pending.base_stamp_len];
    const user_applied = user_saved.len == 0 or std.mem.eql(u8, found.user.applied_stamp, user_saved);
    const base_applied = base_saved.len == 0 or std.mem.eql(u8, found.base.applied_stamp, base_saved);
    if (user_applied and base_applied) {
        const differing = pluginsNotAsSet(&found);
        if (differing > 0) {
            setNotice(print(&text, "rgbctrl applied your changes at {s}, but {d} plugin{s} did not turn on or off as set (see Plugins).", .{ clockText(&clock), differing, if (differing == 1) "" else "s" }));
        } else if (found.problems.len > 0) {
            setNotice(print(&text, "rgbctrl applied your changes at {s}, with {d} problem{s} (see below).", .{ clockText(&clock), found.problems.len, if (found.problems.len == 1) "" else "s" }));
        } else {
            setNotice(print(&text, "rgbctrl applied your changes at {s}.", .{clockText(&clock)}));
        }
        app.pending = null;
        return;
    }
    // rgbctrl read the saved file but kept the configuration from before.
    const user_refused = !user_applied and std.mem.eql(u8, found.user.attempted_stamp, user_saved);
    const base_refused = !base_applied and std.mem.eql(u8, found.base.attempted_stamp, base_saved);
    if (user_refused or base_refused) {
        setNotice("rgbctrl could not use the saved settings and keeps the ones from before (see below).");
        app.pending = null;
        return;
    }
    if (win32.GetTickCount64() -| pending.since_ms > apply_patience_ms) {
        var path_buffer: [1024]u8 = undefined;
        setNotice(print(&text, "Saved, but rgbctrl has not picked up the change yet. It reads {s}.", .{if (found.user.path.len > 0) found.user.path else app.user_path.utf8(&path_buffer)}));
        app.pending = null;
    }
}

fn describeEditError(err: jsonc_edit.Error) []const u8 {
    return switch (err) {
        error.OutOfMemory => "rgbctrl Settings ran out of memory",
        error.Syntax => "the file has an error that rgbctrl cannot read either",
        error.NotAnObject => "a part of the file that should hold settings (such as \"lighting\" or \"plugins\") holds something else",
        error.EditFailed => "the change could not be made safely, so the file was left as it was",
    };
}

/// Writes the changes; returns false when nothing could be saved.
fn save() bool {
    const was_busy = enterModal();
    defer leaveModal(was_busy);
    if (!canEdit()) {
        var buffer: [600]u8 = undefined;
        _ = messageBox(unreadableText(&buffer), ui.MB_OK | ui.MB_ICONERROR);
        return false;
    }
    var scratch = std.heap.ArenaAllocator.init(heap.allocator);
    defer scratch.deinit();
    const arena = scratch.allocator();
    var message: [1600]u8 = undefined;
    var path_buffer: [1024]u8 = undefined;
    const user_path = app.user_path.terminated();
    const current = files.readText(arena, user_path) catch {
        _ = messageBox(print(&message, "rgbctrl Settings could not read {s}, so nothing was saved.", .{app.user_path.utf8(&path_buffer)}), ui.MB_OK | ui.MB_ICONERROR);
        return false;
    };
    const original = current orelse "";
    var editor = jsonc_edit.Editor.init(arena, original) catch |err| {
        _ = messageBox(print(&message, "Nothing was saved: in {s}, {s}.", .{ app.user_path.utf8(&path_buffer), describeEditError(err) }), ui.MB_OK | ui.MB_ICONERROR);
        return false;
    };
    app.model.applyUserEdits(&editor) catch |err| {
        _ = messageBox(print(&message, "Nothing was saved: in {s}, {s}.", .{ app.user_path.utf8(&path_buffer), describeEditError(err) }), ui.MB_OK | ui.MB_ICONERROR);
        return false;
    };
    var pending = Pending{ .since_ms = win32.GetTickCount64() };
    var saved_any = false;
    if (current == null or !std.mem.eql(u8, editor.text(), original)) {
        files.writeText(user_path, editor.text(), app.elevated) catch |err| {
            _ = messageBox(print(&message, "Nothing was saved: {s} could not be written ({s}).", .{ app.user_path.utf8(&path_buffer), safe_open.describe(err) }), ui.MB_OK | ui.MB_ICONERROR);
            return false;
        };
        pending.user_stamp_len = files.stampText(&pending.user_stamp, user_path).len;
        saved_any = true;
    }
    var names_buffer: [64][]const u8 = undefined;
    const names = app.model.pluginsToEnableInBase(&names_buffer);
    // Plugins left off because the base file could not be changed stay checked after the reload,
    // so the user can try again; the reload frees the model's names, hence the copies.
    var retry: []const []const u8 = &.{};
    if (names.len > 0) {
        const helper_was_busy = enterModal();
        _ = ui.EnableWindow(app.window, 0);
        const outcome = elevate.enablePluginsInBase(app.window, names, app.elevated);
        _ = ui.EnableWindow(app.window, 1);
        leaveModal(helper_was_busy);
        const others: []const u8 = if (saved_any) " Your other changes were saved." else "";
        switch (outcome) {
            .saved => {
                pending.base_stamp_len = files.stampText(&pending.base_stamp, app.base_path.terminated()).len;
                saved_any = true;
            },
            .declined => _ = messageBox(print(&message, "Administrator approval was declined, so the opt-in plugins stay off.{s}", .{others}), ui.MB_OK | ui.MB_ICONWARNING),
            .failed => |code| _ = messageBox(print(&message, "The opt-in plugins stay off: {s}.{s}", .{ elevate.describe(code), others }), ui.MB_OK | ui.MB_ICONWARNING),
        }
        if (outcome != .saved) retry = copyNames(arena, names) catch &.{};
    }
    var clock: [16]u8 = undefined;
    var notice: [200]u8 = undefined;
    if (saved_any) {
        app.pending = pending;
        setNotice(print(&notice, "Saved at {s}. Waiting for rgbctrl to apply the changes.", .{clockText(&clock)}));
    } else {
        app.pending = null;
        setNotice(if (retry.len > 0) "Nothing was saved." else "There was nothing to save.");
    }
    reload();
    keepChecked(retry);
    checkPending();
    refreshStatus();
    return true;
}

fn copyNames(arena: std.mem.Allocator, names: []const []const u8) error{OutOfMemory}![]const []const u8 {
    const copies = try arena.alloc([]const u8, names.len);
    for (names, copies) |name, *copy| copy.* = try arena.dupe(u8, name);
    return copies;
}

/// Checks the plugins again, as unsaved changes, after a reload.
fn keepChecked(names: []const []const u8) void {
    if (names.len == 0) return;
    for (app.model.plugins, 0..) |*row, index| {
        for (names) |name| {
            if (std.mem.eql(u8, row.info.name, name)) app.model.setPluginDesired(index, true);
        }
    }
    rebuildPlugins();
}

fn revert() void {
    if (app.model.isDirty() and messageBox("Discard your unsaved changes?", ui.MB_YESNOCANCEL | ui.MB_ICONWARNING) != ui.IDYES) return;
    app.notice_len = 0;
    reload();
}

fn confirmClose() bool {
    if (!app.model.isDirty()) return true;
    return switch (messageBox("Save your changes before closing?", ui.MB_YESNOCANCEL | ui.MB_ICONWARNING)) {
        ui.IDYES => save() and !app.model.isDirty(),
        ui.IDNO => true,
        else => false,
    };
}

fn afterEdit() void {
    app.notice_len = 0;
    updateTreeItem(app.selected);
    refreshNodePanel();
    refreshStatus();
}

fn onCommand(id: u16, code: u16) void {
    if (app.filling) return;
    switch (id) {
        id_effect => if (code == ui.CBN_SELCHANGE) effectChanged(),
        id_add_color => if (code == ui.BN_CLICKED) changeColorCount(1),
        id_remove_color => if (code == ui.BN_CLICKED) changeColorCount(-1),
        id_leds => if (code == ui.EN_CHANGE) ledsChanged(),
        id_save => if (code == ui.BN_CLICKED) {
            _ = save();
        },
        id_revert => if (code == ui.BN_CLICKED) revert(),
        else => if (id >= id_swatch_first and id < id_swatch_first + model_module.max_colors and code == ui.BN_CLICKED) pickColor(id - id_swatch_first),
    }
}

fn effectChanged() void {
    const position = send(app.effect, ui.CB_GETCURSEL, 0, 0);
    if (position < 0) return;
    const data = send(app.effect, ui.CB_GETITEMDATA, @intCast(position), 0);
    if (data < 0 or data > @as(isize, @intFromEnum(Choice.gradient))) return;
    const choice: Choice = @enumFromInt(@as(u8, @intCast(data)));
    const node = &app.model.nodes[app.selected];
    if (node.current.choice == .inherit and choice != .inherit) {
        const shown = displayed(app.selected);
        node.current.colors = shown.colors;
        node.current.color_count = @max(shown.color_count, 1);
        node.current.speed = shown.speed;
        node.current.brightness = shown.brightness;
    }
    app.model.setChoice(app.selected, choice);
    afterEdit();
}

fn changeColorCount(delta: i32) void {
    if (delta > 0) app.model.addColor(app.selected) else app.model.removeColor(app.selected);
    afterEdit();
}

fn colorFromRef(value: ui.COLORREF) Rgb {
    return .{ .r = @truncate(value), .g = @truncate(value >> 8), .b = @truncate(value >> 16) };
}

fn pickColor(slot: usize) void {
    const index = app.selected;
    const color = blk: {
        const node = &app.model.nodes[index];
        if (node.current.choice == .inherit or slot >= node.current.color_count or !canEdit()) return;
        break :blk node.current.colors[slot];
    };
    var choose = ui.CHOOSECOLORW{ .hwndOwner = app.window, .rgbResult = ui.rgb(color.r, color.g, color.b), .lpCustColors = &app.custom_colors, .Flags = ui.CC_RGBINIT | ui.CC_FULLOPEN | ui.CC_ANYCOLOR };
    const was_busy = enterModal();
    const picked = ui.ChooseColorW(&choose) != 0;
    leaveModal(was_busy);
    if (!picked or index >= app.model.nodes.len) return;
    const node = &app.model.nodes[index];
    if (slot >= node.current.color_count) return;
    node.current.colors[slot] = colorFromRef(choose.rgbResult);
    afterEdit();
}

fn onSlider(control: ui.HWND) void {
    if (app.filling or app.model.nodes.len == 0) return;
    const node = &app.model.nodes[app.selected];
    if (node.current.choice == .inherit) return;
    const position: u8 = @intCast(std.math.clamp(send(control, ui.TBM_GETPOS, 0, 0), 0, 100));
    if (control == app.speed) {
        node.current.speed = position;
    } else if (control == app.brightness) {
        node.current.brightness = position;
    } else {
        return;
    }
    app.notice_len = 0;
    updateSliderValues(node.current);
    updateTreeItem(app.selected);
    refreshStatus();
}

fn ledsChanged() void {
    const node = &app.model.nodes[app.selected];
    const zone = node.zone orelse return;
    var wide: [16]u16 = undefined;
    const length = ui.GetWindowTextW(app.leds, &wide, wide.len);
    if (length <= 0) return;
    var value: u64 = 0;
    for (wide[0..@intCast(length)]) |unit| {
        if (unit < '0' or unit > '9') return;
        value = value * 10 + (unit - '0');
    }
    const count: u32 = @intCast(@min(value, zone.max_leds));
    node.leds_current = if (node.leds_saved == null and count == zone.leds) null else count;
    app.notice_len = 0;
    updateTreeItem(app.selected);
    var text: [400]u8 = undefined;
    setText(app.note, noteText(&text, app.selected));
    refreshStatus();
}

fn onNotify(header: *const ui.NMHDR) void {
    if (app.filling) return;
    if (header.idFrom == id_tree and header.code == ui.TVN_SELCHANGEDW) {
        const change: *const ui.NMTREEVIEWW = @ptrCast(@alignCast(header));
        const param = change.itemNew.lParam;
        if (param == plugins_page_param) {
            showPage(.plugins);
        } else if (param >= 0 and @as(usize, @intCast(param)) < app.model.nodes.len) {
            app.selected = @intCast(param);
            showPage(.lighting);
        }
        return;
    }
    if (header.idFrom == id_plugins and header.code == ui.LVN_ITEMCHANGED) {
        const change: *const ui.NMLISTVIEW = @ptrCast(@alignCast(header));
        if (change.uChanged & ui.LVIF_STATE == 0 or change.iItem < 0) return;
        if ((change.uNewState ^ change.uOldState) & ui.LVIS_STATEIMAGEMASK == 0 or change.uOldState & ui.LVIS_STATEIMAGEMASK == 0) return;
        const index: usize = @intCast(change.iItem);
        if (index >= app.model.plugins.len) return;
        const checked = (change.uNewState & ui.LVIS_STATEIMAGEMASK) >> 12 == 2;
        if (!canEdit()) {
            app.filling = true;
            setPluginCheck(index, app.model.plugins[index].desired);
            app.filling = false;
            return;
        }
        app.model.setPluginDesired(index, checked);
        var status: [80]u8 = undefined;
        setPluginText(index, 1, pluginStatus(&status, &app.model.plugins[index]));
        app.notice_len = 0;
        refreshStatus();
    }
}

fn drawSwatch(item: *const ui.DRAWITEMSTRUCT) void {
    if (item.CtlID < id_swatch_first or item.CtlID >= id_swatch_first + model_module.max_colors or app.model.nodes.len == 0) return;
    const slot = item.CtlID - id_swatch_first;
    const color = app.shown.colors[slot];
    const face = ui.GetSysColorBrush(ui.COLOR_BTNFACE) orelse return;
    _ = ui.FillRect(item.hDC, &item.rcItem, face);
    const inset = scale(3);
    const inner = ui.RECT{ .left = item.rcItem.left + inset, .top = item.rcItem.top + inset, .right = item.rcItem.right - inset, .bottom = item.rcItem.bottom - inset };
    if (ui.CreateSolidBrush(ui.rgb(color.r, color.g, color.b))) |brush| {
        _ = ui.FillRect(item.hDC, &inner, brush);
        _ = ui.DeleteObject(brush);
    }
    const disabled = item.itemState & ui.ODS_DISABLED != 0;
    if (ui.GetSysColorBrush(if (disabled) ui.COLOR_BTNSHADOW else ui.COLOR_WINDOWTEXT)) |border| _ = ui.FrameRect(item.hDC, &inner, border);
    if (item.itemState & ui.ODS_FOCUS != 0) _ = ui.DrawFocusRect(item.hDC, &item.rcItem);
}
