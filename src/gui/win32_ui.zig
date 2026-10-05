// The user32, gdi32, comctl32, comdlg32 and shell32 declarations rgbctrl-gui needs, next to the
// kernel32 ones in sdk/win32.zig.
const win32 = @import("sdk").win32;

pub const HWND = *opaque {};
pub const HINSTANCE = *opaque {};
pub const HMENU = *opaque {};
pub const HICON = *opaque {};
pub const HCURSOR = *opaque {};
pub const HBRUSH = *opaque {};
pub const HFONT = *opaque {};
pub const HDC = *opaque {};
pub const HGDIOBJ = *opaque {};
pub const HTREEITEM = *opaque {};
pub const WPARAM = usize;
pub const LPARAM = isize;
pub const LRESULT = isize;
pub const COLORREF = u32;
pub const BOOL = win32.BOOL;

pub const WNDPROC = *const fn (hwnd: HWND, message: u32, wparam: WPARAM, lparam: LPARAM) callconv(.winapi) LRESULT;

pub const POINT = extern struct { x: i32 = 0, y: i32 = 0 };

pub const RECT = extern struct {
    left: i32 = 0,
    top: i32 = 0,
    right: i32 = 0,
    bottom: i32 = 0,
};

pub const WNDCLASSEXW = extern struct {
    cbSize: u32 = @sizeOf(WNDCLASSEXW),
    style: u32 = 0,
    lpfnWndProc: WNDPROC,
    cbClsExtra: i32 = 0,
    cbWndExtra: i32 = 0,
    hInstance: ?HINSTANCE = null,
    hIcon: ?HICON = null,
    hCursor: ?HCURSOR = null,
    hbrBackground: ?HBRUSH = null,
    lpszMenuName: ?[*:0]const u16 = null,
    lpszClassName: [*:0]const u16,
    hIconSm: ?HICON = null,
};

pub const MSG = extern struct {
    hwnd: ?HWND = null,
    message: u32 = 0,
    wParam: WPARAM = 0,
    lParam: LPARAM = 0,
    time: u32 = 0,
    pt: POINT = .{},
    lPrivate: u32 = 0,
};

pub const PAINTSTRUCT = extern struct {
    hdc: ?HDC = null,
    fErase: BOOL = 0,
    rcPaint: RECT = .{},
    fRestore: BOOL = 0,
    fIncUpdate: BOOL = 0,
    rgbReserved: [32]u8 = @splat(0),
};

pub const NMHDR = extern struct {
    hwndFrom: ?HWND,
    idFrom: usize,
    code: u32,
};

pub const LOGFONTW = extern struct {
    lfHeight: i32 = 0,
    lfWidth: i32 = 0,
    lfEscapement: i32 = 0,
    lfOrientation: i32 = 0,
    lfWeight: i32 = 0,
    lfItalic: u8 = 0,
    lfUnderline: u8 = 0,
    lfStrikeOut: u8 = 0,
    lfCharSet: u8 = 0,
    lfOutPrecision: u8 = 0,
    lfClipPrecision: u8 = 0,
    lfQuality: u8 = 0,
    lfPitchAndFamily: u8 = 0,
    lfFaceName: [32]u16 = @splat(0),
};

pub const NONCLIENTMETRICSW = extern struct {
    cbSize: u32 = @sizeOf(NONCLIENTMETRICSW),
    iBorderWidth: i32 = 0,
    iScrollWidth: i32 = 0,
    iScrollHeight: i32 = 0,
    iCaptionWidth: i32 = 0,
    iCaptionHeight: i32 = 0,
    lfCaptionFont: LOGFONTW = .{},
    iSmCaptionWidth: i32 = 0,
    iSmCaptionHeight: i32 = 0,
    lfSmCaptionFont: LOGFONTW = .{},
    iMenuWidth: i32 = 0,
    iMenuHeight: i32 = 0,
    lfMenuFont: LOGFONTW = .{},
    lfStatusFont: LOGFONTW = .{},
    lfMessageFont: LOGFONTW = .{},
    iPaddedBorderWidth: i32 = 0,
};

pub const INITCOMMONCONTROLSEX = extern struct {
    dwSize: u32 = @sizeOf(INITCOMMONCONTROLSEX),
    dwICC: u32,
};

pub const CHOOSECOLORW = extern struct {
    lStructSize: u32 = @sizeOf(CHOOSECOLORW),
    hwndOwner: ?HWND = null,
    hInstance: ?HWND = null,
    rgbResult: COLORREF = 0,
    lpCustColors: *[16]COLORREF,
    Flags: u32 = 0,
    lCustData: LPARAM = 0,
    lpfnHook: ?*const anyopaque = null,
    lpTemplateName: ?[*:0]const u16 = null,
};

pub const TVITEMEXW = extern struct {
    mask: u32 = 0,
    hItem: ?HTREEITEM = null,
    state: u32 = 0,
    stateMask: u32 = 0,
    pszText: ?[*:0]const u16 = null,
    cchTextMax: i32 = 0,
    iImage: i32 = 0,
    iSelectedImage: i32 = 0,
    cChildren: i32 = 0,
    lParam: LPARAM = 0,
    iIntegral: i32 = 0,
    uStateEx: u32 = 0,
    hwnd: ?HWND = null,
    iExpandedImage: i32 = 0,
    iReserved: i32 = 0,
};

pub const TVITEMW = extern struct {
    mask: u32 = 0,
    hItem: ?HTREEITEM = null,
    state: u32 = 0,
    stateMask: u32 = 0,
    pszText: ?[*:0]const u16 = null,
    cchTextMax: i32 = 0,
    iImage: i32 = 0,
    iSelectedImage: i32 = 0,
    cChildren: i32 = 0,
    lParam: LPARAM = 0,
};

pub const TVINSERTSTRUCTW = extern struct {
    hParent: ?HTREEITEM = null,
    hInsertAfter: ?HTREEITEM = null,
    item: TVITEMEXW = .{},
};

pub const NMTREEVIEWW = extern struct {
    hdr: NMHDR,
    action: u32,
    itemOld: TVITEMW,
    itemNew: TVITEMW,
    ptDrag: POINT,
};

pub const LVCOLUMNW = extern struct {
    mask: u32 = 0,
    fmt: i32 = 0,
    cx: i32 = 0,
    pszText: ?[*:0]const u16 = null,
    cchTextMax: i32 = 0,
    iSubItem: i32 = 0,
    iImage: i32 = 0,
    iOrder: i32 = 0,
    cxMin: i32 = 0,
    cxDefault: i32 = 0,
    cxIdeal: i32 = 0,
};

pub const LVITEMW = extern struct {
    mask: u32 = 0,
    iItem: i32 = 0,
    iSubItem: i32 = 0,
    state: u32 = 0,
    stateMask: u32 = 0,
    pszText: ?[*:0]const u16 = null,
    cchTextMax: i32 = 0,
    iImage: i32 = 0,
    lParam: LPARAM = 0,
    iIndent: i32 = 0,
    iGroupId: i32 = 0,
    cColumns: u32 = 0,
    puColumns: ?*u32 = null,
    piColFmt: ?*i32 = null,
    iGroup: i32 = 0,
};

pub const NMLISTVIEW = extern struct {
    hdr: NMHDR,
    iItem: i32,
    iSubItem: i32,
    uNewState: u32,
    uOldState: u32,
    uChanged: u32,
    ptAction: POINT,
    lParam: LPARAM,
};

pub const DRAWITEMSTRUCT = extern struct {
    CtlType: u32,
    CtlID: u32,
    itemID: u32,
    itemAction: u32,
    itemState: u32,
    hwndItem: HWND,
    hDC: HDC,
    rcItem: RECT,
    itemData: usize,
};

pub const MINMAXINFO = extern struct {
    ptReserved: POINT,
    ptMaxSize: POINT,
    ptMaxPosition: POINT,
    ptMinTrackSize: POINT,
    ptMaxTrackSize: POINT,
};

pub const SHELLEXECUTEINFOW = extern struct {
    cbSize: u32 = @sizeOf(SHELLEXECUTEINFOW),
    fMask: u32 = 0,
    hwnd: ?HWND = null,
    lpVerb: ?[*:0]const u16 = null,
    lpFile: ?[*:0]const u16 = null,
    lpParameters: ?[*:0]const u16 = null,
    lpDirectory: ?[*:0]const u16 = null,
    nShow: i32 = 0,
    hInstApp: ?HINSTANCE = null,
    lpIDList: ?*anyopaque = null,
    lpClass: ?[*:0]const u16 = null,
    hkeyClass: ?*anyopaque = null,
    dwHotKey: u32 = 0,
    hIconOrMonitor: ?*anyopaque = null,
    hProcess: ?win32.HANDLE = null,
};

pub const WM_CREATE: u32 = 0x0001;
pub const WM_DESTROY: u32 = 0x0002;
pub const WM_SIZE: u32 = 0x0005;
pub const WM_CLOSE: u32 = 0x0010;
pub const WM_GETMINMAXINFO: u32 = 0x0024;
pub const WM_SETFONT: u32 = 0x0030;
pub const WM_DRAWITEM: u32 = 0x002B;
pub const WM_NOTIFY: u32 = 0x004E;
pub const WM_COMMAND: u32 = 0x0111;
pub const WM_TIMER: u32 = 0x0113;
pub const WM_HSCROLL: u32 = 0x0114;
pub const WM_DPICHANGED: u32 = 0x02E0;
pub const WM_USER: u32 = 0x0400;

pub const WS_OVERLAPPEDWINDOW: u32 = 0x00CF0000;
pub const WS_CHILD: u32 = 0x40000000;
pub const WS_VISIBLE: u32 = 0x10000000;
pub const WS_DISABLED: u32 = 0x08000000;
pub const WS_CLIPSIBLINGS: u32 = 0x04000000;
pub const WS_CLIPCHILDREN: u32 = 0x02000000;
pub const WS_BORDER: u32 = 0x00800000;
pub const WS_VSCROLL: u32 = 0x00200000;
pub const WS_GROUP: u32 = 0x00020000;
pub const WS_TABSTOP: u32 = 0x00010000;
pub const WS_EX_CLIENTEDGE: u32 = 0x00000200;
pub const WS_EX_CONTROLPARENT: u32 = 0x00010000;
pub const CW_USEDEFAULT: i32 = @bitCast(@as(u32, 0x80000000));

pub const SW_HIDE: i32 = 0;
pub const SW_SHOW: i32 = 5;
pub const SW_SHOWNORMAL: i32 = 1;
pub const SWP_NOZORDER: u32 = 0x0004;
pub const SWP_NOACTIVATE: u32 = 0x0010;

pub const BS_PUSHBUTTON: u32 = 0x0;
pub const BS_OWNERDRAW: u32 = 0xB;
pub const BN_CLICKED: u32 = 0;
pub const BCM_SETSHIELD: u32 = 0x160C;

pub const CBS_DROPDOWNLIST: u32 = 0x0003;
pub const CB_ADDSTRING: u32 = 0x0143;
pub const CB_GETCURSEL: u32 = 0x0147;
pub const CB_RESETCONTENT: u32 = 0x014B;
pub const CB_SETCURSEL: u32 = 0x014E;
pub const CB_GETITEMDATA: u32 = 0x0150;
pub const CB_SETITEMDATA: u32 = 0x0151;
pub const CBN_SELCHANGE: u32 = 1;

pub const SS_LEFT: u32 = 0x0000;
pub const SS_NOPREFIX: u32 = 0x0080;
pub const SS_ENDELLIPSIS: u32 = 0x4000;

pub const ES_AUTOHSCROLL: u32 = 0x0080;
pub const ES_MULTILINE: u32 = 0x0004;
pub const ES_READONLY: u32 = 0x0800;
pub const ES_NUMBER: u32 = 0x2000;
pub const EN_CHANGE: u32 = 0x0300;
pub const EM_SETLIMITTEXT: u32 = 0x00C5;

pub const TBS_NOTICKS: u32 = 0x0010;
pub const TBM_GETPOS: u32 = WM_USER;
pub const TBM_SETPOS: u32 = WM_USER + 5;
pub const TBM_SETRANGE: u32 = WM_USER + 6;
pub const TBM_SETPAGESIZE: u32 = WM_USER + 21;
pub const TBM_SETLINESIZE: u32 = WM_USER + 23;

pub const UDS_SETBUDDYINT: u32 = 0x0002;
pub const UDS_ALIGNRIGHT: u32 = 0x0004;
pub const UDS_ARROWKEYS: u32 = 0x0020;
pub const UDS_NOTHOUSANDS: u32 = 0x0080;
pub const UDM_SETBUDDY: u32 = WM_USER + 105;
pub const UDM_SETRANGE32: u32 = WM_USER + 111;
pub const UDM_SETPOS32: u32 = WM_USER + 113;
pub const UDM_GETPOS32: u32 = WM_USER + 114;

pub const TVS_HASBUTTONS: u32 = 0x0001;
pub const TVS_HASLINES: u32 = 0x0002;
pub const TVS_LINESATROOT: u32 = 0x0004;
pub const TVS_DISABLEDRAGDROP: u32 = 0x0010;
pub const TVS_SHOWSELALWAYS: u32 = 0x0020;
pub const TVM_DELETEITEM: u32 = 0x1101;
pub const TVM_EXPAND: u32 = 0x1102;
pub const TVM_SELECTITEM: u32 = 0x110B;
pub const TVM_SETEXTENDEDSTYLE: u32 = 0x112C;
pub const TVM_INSERTITEMW: u32 = 0x1132;
pub const TVM_SETITEMW: u32 = 0x113F;
pub const TVS_EX_DOUBLEBUFFER: u32 = 0x0004;
pub const TVIF_TEXT: u32 = 0x0001;
pub const TVIF_PARAM: u32 = 0x0004;
pub const TVIF_STATE: u32 = 0x0008;
pub const TVIS_BOLD: u32 = 0x0010;
pub const TVIS_EXPANDED: u32 = 0x0020;
pub const TVE_EXPAND: usize = 0x0002;
pub const TVGN_CARET: usize = 0x0009;
pub const TVI_ROOT: HTREEITEM = @ptrFromInt(@as(usize, @bitCast(@as(isize, -0x10000))));
pub const TVI_LAST: HTREEITEM = @ptrFromInt(@as(usize, @bitCast(@as(isize, -0x0FFFE))));
pub const TVN_SELCHANGEDW: u32 = @bitCast(@as(i32, -451));

pub const LVS_REPORT: u32 = 0x0001;
pub const LVS_SINGLESEL: u32 = 0x0004;
pub const LVS_SHOWSELALWAYS: u32 = 0x0008;
pub const LVS_NOSORTHEADER: u32 = 0x8000;
pub const LVS_EX_CHECKBOXES: u32 = 0x00000004;
pub const LVS_EX_FULLROWSELECT: u32 = 0x00000020;
pub const LVS_EX_DOUBLEBUFFER: u32 = 0x00010000;
pub const LVM_DELETEALLITEMS: u32 = 0x1009;
pub const LVM_SETCOLUMNWIDTH: u32 = 0x101E;
pub const LVM_SETITEMSTATE: u32 = 0x102B;
pub const LVM_GETITEMSTATE: u32 = 0x102C;
pub const LVM_SETEXTENDEDLISTVIEWSTYLE: u32 = 0x1036;
pub const LVM_INSERTITEMW: u32 = 0x104D;
pub const LVM_INSERTCOLUMNW: u32 = 0x1061;
pub const LVM_SETITEMTEXTW: u32 = 0x1074;
pub const LVCF_WIDTH: u32 = 0x0002;
pub const LVCF_TEXT: u32 = 0x0004;
pub const LVCF_SUBITEM: u32 = 0x0008;
pub const LVIF_TEXT: u32 = 0x0001;
pub const LVIF_PARAM: u32 = 0x0004;
pub const LVIF_STATE: u32 = 0x0008;
pub const LVIS_STATEIMAGEMASK: u32 = 0xF000;
pub const LVN_ITEMCHANGED: u32 = @bitCast(@as(i32, -101));

pub const COLOR_WINDOW: i32 = 5;
pub const COLOR_WINDOWTEXT: i32 = 8;
pub const COLOR_BTNFACE: i32 = 15;
pub const COLOR_BTNSHADOW: i32 = 16;
pub const COLOR_GRAYTEXT: i32 = 17;

pub const IDC_ARROW: usize = 32512;
pub const IDOK: usize = 1;
pub const IDCANCEL: usize = 2;
pub const IDYES: i32 = 6;
pub const IDNO: i32 = 7;

pub const MB_OK: u32 = 0x00000000;
pub const MB_YESNOCANCEL: u32 = 0x00000003;
pub const MB_ICONERROR: u32 = 0x00000010;
pub const MB_ICONWARNING: u32 = 0x00000030;
pub const MB_ICONINFORMATION: u32 = 0x00000040;

pub const SPI_GETNONCLIENTMETRICS: u32 = 0x0029;
pub const FW_BOLD: i32 = 700;

pub const CC_RGBINIT: u32 = 0x00000001;
pub const CC_FULLOPEN: u32 = 0x00000002;
pub const CC_ANYCOLOR: u32 = 0x00000100;

pub const ICC_LISTVIEW_CLASSES: u32 = 0x00000001;
pub const ICC_TREEVIEW_CLASSES: u32 = 0x00000002;
pub const ICC_BAR_CLASSES: u32 = 0x00000004;
pub const ICC_UPDOWN_CLASS: u32 = 0x00000010;
pub const ICC_STANDARD_CLASSES: u32 = 0x00004000;

pub const ODS_DISABLED: u32 = 0x0004;
pub const ODS_FOCUS: u32 = 0x0010;

pub const DT_SINGLELINE: u32 = 0x0020;
pub const DT_VCENTER: u32 = 0x0004;
pub const DT_CENTER: u32 = 0x0001;
pub const DT_NOPREFIX: u32 = 0x0800;

pub const SEE_MASK_NOCLOSEPROCESS: u32 = 0x00000040;
pub const SEE_MASK_NOASYNC: u32 = 0x00000100;
pub const ERROR_CANCELLED: u32 = 1223;

pub extern "user32" fn RegisterClassExW(class: *const WNDCLASSEXW) callconv(.winapi) u16;
pub extern "user32" fn CreateWindowExW(ex_style: u32, class: [*:0]const u16, name: ?[*:0]const u16, style: u32, x: i32, y: i32, width: i32, height: i32, parent: ?HWND, menu: ?HMENU, instance: ?HINSTANCE, param: ?*anyopaque) callconv(.winapi) ?HWND;
pub extern "user32" fn DefWindowProcW(hwnd: HWND, message: u32, wparam: WPARAM, lparam: LPARAM) callconv(.winapi) LRESULT;
pub extern "user32" fn DestroyWindow(hwnd: HWND) callconv(.winapi) BOOL;
pub extern "user32" fn ShowWindow(hwnd: HWND, command: i32) callconv(.winapi) BOOL;
pub extern "user32" fn UpdateWindow(hwnd: HWND) callconv(.winapi) BOOL;
pub extern "user32" fn GetMessageW(message: *MSG, hwnd: ?HWND, first: u32, last: u32) callconv(.winapi) BOOL;
pub extern "user32" fn TranslateMessage(message: *const MSG) callconv(.winapi) BOOL;
pub extern "user32" fn DispatchMessageW(message: *const MSG) callconv(.winapi) LRESULT;
pub extern "user32" fn IsDialogMessageW(hwnd: HWND, message: *MSG) callconv(.winapi) BOOL;
pub extern "user32" fn PostQuitMessage(code: i32) callconv(.winapi) void;
pub extern "user32" fn SendMessageW(hwnd: HWND, message: u32, wparam: WPARAM, lparam: LPARAM) callconv(.winapi) LRESULT;
pub extern "user32" fn SetWindowPos(hwnd: HWND, after: ?HWND, x: i32, y: i32, width: i32, height: i32, flags: u32) callconv(.winapi) BOOL;
pub extern "user32" fn MoveWindow(hwnd: HWND, x: i32, y: i32, width: i32, height: i32, repaint: BOOL) callconv(.winapi) BOOL;
pub extern "user32" fn GetClientRect(hwnd: HWND, rect: *RECT) callconv(.winapi) BOOL;
pub extern "user32" fn InvalidateRect(hwnd: HWND, rect: ?*const RECT, erase: BOOL) callconv(.winapi) BOOL;
pub extern "user32" fn SetWindowTextW(hwnd: HWND, text: [*:0]const u16) callconv(.winapi) BOOL;
pub extern "user32" fn GetWindowTextW(hwnd: HWND, text: [*]u16, capacity: i32) callconv(.winapi) i32;
pub extern "user32" fn EnableWindow(hwnd: HWND, enable: BOOL) callconv(.winapi) BOOL;
pub extern "user32" fn SetFocus(hwnd: ?HWND) callconv(.winapi) ?HWND;
pub extern "user32" fn LoadCursorW(instance: ?HINSTANCE, name: usize) callconv(.winapi) ?HCURSOR;
pub extern "user32" fn MessageBoxW(hwnd: ?HWND, text: [*:0]const u16, caption: [*:0]const u16, kind: u32) callconv(.winapi) i32;
pub extern "user32" fn SetTimer(hwnd: HWND, id: usize, elapse: u32, callback: ?*const anyopaque) callconv(.winapi) usize;
pub extern "user32" fn GetDpiForWindow(hwnd: HWND) callconv(.winapi) u32;
pub extern "user32" fn GetDpiForSystem() callconv(.winapi) u32;
pub extern "user32" fn SystemParametersInfoForDpi(action: u32, param: u32, data: ?*anyopaque, win_ini: u32, dpi: u32) callconv(.winapi) BOOL;
pub extern "user32" fn GetSysColor(index: i32) callconv(.winapi) COLORREF;
pub extern "user32" fn GetSysColorBrush(index: i32) callconv(.winapi) ?HBRUSH;
pub extern "user32" fn FillRect(hdc: HDC, rect: *const RECT, brush: HBRUSH) callconv(.winapi) i32;
pub extern "user32" fn FrameRect(hdc: HDC, rect: *const RECT, brush: HBRUSH) callconv(.winapi) i32;
pub extern "user32" fn DrawFocusRect(hdc: HDC, rect: *const RECT) callconv(.winapi) BOOL;
pub extern "user32" fn IsWindowEnabled(hwnd: HWND) callconv(.winapi) BOOL;
pub extern "user32" fn SetForegroundWindow(hwnd: HWND) callconv(.winapi) BOOL;
pub extern "user32" fn FindWindowW(class: ?[*:0]const u16, name: ?[*:0]const u16) callconv(.winapi) ?HWND;
pub extern "user32" fn IsIconic(hwnd: HWND) callconv(.winapi) BOOL;
pub extern "user32" fn GetDC(hwnd: ?HWND) callconv(.winapi) ?HDC;
pub extern "user32" fn ReleaseDC(hwnd: ?HWND, hdc: HDC) callconv(.winapi) i32;
pub extern "user32" fn DrawTextW(hdc: HDC, text: [*]const u16, count: i32, rect: *RECT, format: u32) callconv(.winapi) i32;
pub extern "user32" fn MsgWaitForMultipleObjects(count: u32, handles: [*]const win32.HANDLE, wait_all: BOOL, milliseconds: u32, wake_mask: u32) callconv(.winapi) u32;
pub extern "user32" fn PeekMessageW(message: *MSG, hwnd: ?HWND, first: u32, last: u32, remove: u32) callconv(.winapi) BOOL;
pub extern "gdi32" fn SelectObject(hdc: HDC, object: *anyopaque) callconv(.winapi) ?*anyopaque;

pub const SW_RESTORE: i32 = 9;
pub const DT_WORDBREAK: u32 = 0x0010;
pub const DT_CALCRECT: u32 = 0x0400;
pub const QS_ALLINPUT: u32 = 0x04FF;
pub const PM_REMOVE: u32 = 0x0001;
pub const WM_QUIT: u32 = 0x0012;

pub extern "gdi32" fn CreateFontIndirectW(font: *const LOGFONTW) callconv(.winapi) ?HFONT;
pub extern "gdi32" fn CreateSolidBrush(color: COLORREF) callconv(.winapi) ?HBRUSH;
pub extern "gdi32" fn DeleteObject(object: *anyopaque) callconv(.winapi) BOOL;

pub extern "comctl32" fn InitCommonControlsEx(init: *const INITCOMMONCONTROLSEX) callconv(.winapi) BOOL;
pub extern "comdlg32" fn ChooseColorW(choose: *CHOOSECOLORW) callconv(.winapi) BOOL;
pub extern "shell32" fn ShellExecuteExW(info: *SHELLEXECUTEINFOW) callconv(.winapi) BOOL;
pub extern "kernel32" fn GetModuleHandleW(name: ?[*:0]const u16) callconv(.winapi) ?HINSTANCE;
pub extern "kernel32" fn GetExitCodeProcess(process: win32.HANDLE, code: *u32) callconv(.winapi) BOOL;

pub fn rgb(red: u8, green: u8, blue: u8) COLORREF {
    return @as(COLORREF, red) | (@as(COLORREF, green) << 8) | (@as(COLORREF, blue) << 16);
}

pub fn lowWord(value: usize) u16 {
    return @truncate(value);
}

pub fn highWord(value: usize) u16 {
    return @truncate(value >> 16);
}

pub fn makeLong(low: u16, high: u16) LPARAM {
    return @intCast((@as(u32, high) << 16) | low);
}

/// A control id or a predefined item as the menu argument of CreateWindowExW.
pub fn idParam(id: usize) ?HMENU {
    return @ptrFromInt(id);
}

const std = @import("std");

test "structure sizes match the 64-bit Windows headers" {
    try std.testing.expectEqual(@as(usize, 80), @sizeOf(WNDCLASSEXW));
    try std.testing.expectEqual(@as(usize, 48), @sizeOf(MSG));
    try std.testing.expectEqual(@as(usize, 92), @sizeOf(LOGFONTW));
    try std.testing.expectEqual(@as(usize, 504), @sizeOf(NONCLIENTMETRICSW));
    try std.testing.expectEqual(@as(usize, 72), @sizeOf(CHOOSECOLORW));
    try std.testing.expectEqual(@as(usize, 80), @sizeOf(TVITEMEXW));
    try std.testing.expectEqual(@as(usize, 96), @sizeOf(TVINSERTSTRUCTW));
    try std.testing.expectEqual(@as(usize, 152), @sizeOf(NMTREEVIEWW));
    try std.testing.expectEqual(@as(usize, 88), @sizeOf(LVITEMW));
    try std.testing.expectEqual(@as(usize, 56), @sizeOf(LVCOLUMNW));
    try std.testing.expectEqual(@as(usize, 64), @sizeOf(NMLISTVIEW));
    try std.testing.expectEqual(@as(usize, 64), @sizeOf(DRAWITEMSTRUCT));
    try std.testing.expectEqual(@as(usize, 112), @sizeOf(SHELLEXECUTEINFOW));
    try std.testing.expectEqual(@as(usize, 24), @sizeOf(NMHDR));
}
