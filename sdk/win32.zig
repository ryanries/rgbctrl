pub const HANDLE = *anyopaque;
pub const HMODULE = *opaque {};
pub const BOOL = c_int;
pub const BOOLEAN = u8;
pub const NTSTATUS = i32;
pub const PSID = *anyopaque;

pub const TRUE: BOOL = 1;
pub const FALSE: BOOL = 0;
pub const INVALID_HANDLE_VALUE: HANDLE = @ptrFromInt(~@as(usize, 0));

pub const GUID = extern struct {
    data1: u32,
    data2: u16,
    data3: u16,
    data4: [8]u8,
};

pub const SECURITY_ATTRIBUTES = extern struct {
    nLength: u32 = @sizeOf(SECURITY_ATTRIBUTES),
    lpSecurityDescriptor: ?*anyopaque = null,
    bInheritHandle: BOOL = FALSE,
};

pub const OVERLAPPED = extern struct {
    Internal: usize = 0,
    InternalHigh: usize = 0,
    Offset: u32 = 0,
    OffsetHigh: u32 = 0,
    hEvent: ?HANDLE = null,
};

pub const FILETIME = extern struct {
    dwLowDateTime: u32 = 0,
    dwHighDateTime: u32 = 0,

    pub fn toU64(self: FILETIME) u64 {
        return (@as(u64, self.dwHighDateTime) << 32) | self.dwLowDateTime;
    }
};

pub const SYSTEMTIME = extern struct {
    wYear: u16,
    wMonth: u16,
    wDayOfWeek: u16,
    wDay: u16,
    wHour: u16,
    wMinute: u16,
    wSecond: u16,
    wMilliseconds: u16,
};

pub const BY_HANDLE_FILE_INFORMATION = extern struct {
    dwFileAttributes: u32,
    ftCreationTime: FILETIME,
    ftLastAccessTime: FILETIME,
    ftLastWriteTime: FILETIME,
    dwVolumeSerialNumber: u32,
    nFileSizeHigh: u32,
    nFileSizeLow: u32,
    nNumberOfLinks: u32,
    nFileIndexHigh: u32,
    nFileIndexLow: u32,
};

pub const WIN32_FILE_ATTRIBUTE_DATA = extern struct {
    dwFileAttributes: u32,
    ftCreationTime: FILETIME,
    ftLastAccessTime: FILETIME,
    ftLastWriteTime: FILETIME,
    nFileSizeHigh: u32,
    nFileSizeLow: u32,
};

pub const WIN32_FIND_DATAW = extern struct {
    dwFileAttributes: u32,
    ftCreationTime: FILETIME,
    ftLastAccessTime: FILETIME,
    ftLastWriteTime: FILETIME,
    nFileSizeHigh: u32,
    nFileSizeLow: u32,
    dwReserved0: u32,
    dwReserved1: u32,
    cFileName: [260]u16,
    cAlternateFileName: [14]u16,
};

pub const MEMORYSTATUSEX = extern struct {
    dwLength: u32 = @sizeOf(MEMORYSTATUSEX),
    dwMemoryLoad: u32 = 0,
    ullTotalPhys: u64 = 0,
    ullAvailPhys: u64 = 0,
    ullTotalPageFile: u64 = 0,
    ullAvailPageFile: u64 = 0,
    ullTotalVirtual: u64 = 0,
    ullAvailVirtual: u64 = 0,
    ullAvailExtendedVirtual: u64 = 0,
};

pub const SRWLOCK = extern struct {
    ptr: ?*anyopaque = null,
};

pub const RTL_OSVERSIONINFOW = extern struct {
    dwOSVersionInfoSize: u32 = @sizeOf(RTL_OSVERSIONINFOW),
    dwMajorVersion: u32 = 0,
    dwMinorVersion: u32 = 0,
    dwBuildNumber: u32 = 0,
    dwPlatformId: u32 = 0,
    szCSDVersion: [128]u16 = [_]u16{0} ** 128,
};

pub const IO_STATUS_BLOCK = extern struct {
    Status: usize = 0,
    Information: usize = 0,
};

pub const HIDD_ATTRIBUTES = extern struct {
    Size: u32 = @sizeOf(HIDD_ATTRIBUTES),
    VendorID: u16 = 0,
    ProductID: u16 = 0,
    VersionNumber: u16 = 0,
};

pub const HIDP_CAPS = extern struct {
    Usage: u16,
    UsagePage: u16,
    InputReportByteLength: u16,
    OutputReportByteLength: u16,
    FeatureReportByteLength: u16,
    Reserved: [17]u16,
    NumberLinkCollectionNodes: u16,
    NumberInputButtonCaps: u16,
    NumberInputValueCaps: u16,
    NumberInputDataIndices: u16,
    NumberOutputButtonCaps: u16,
    NumberOutputValueCaps: u16,
    NumberOutputDataIndices: u16,
    NumberFeatureButtonCaps: u16,
    NumberFeatureValueCaps: u16,
    NumberFeatureDataIndices: u16,
};

pub const PDH_FMT_COUNTERVALUE = extern struct {
    CStatus: u32 = 0,
    padding: u32 = 0,
    doubleValue: f64 = 0,
};

pub const ACL = opaque {};

pub const ACE_HEADER = extern struct {
    AceType: u8,
    AceFlags: u8,
    AceSize: u16,
};

pub const ACCESS_ALLOWED_ACE = extern struct {
    Header: ACE_HEADER,
    Mask: u32,
    SidStart: u32,
};

pub const ACL_SIZE_INFORMATION = extern struct {
    AceCount: u32 = 0,
    AclBytesInUse: u32 = 0,
    AclBytesFree: u32 = 0,
};

pub const GENERIC_MAPPING = extern struct {
    GenericRead: u32,
    GenericWrite: u32,
    GenericExecute: u32,
    GenericAll: u32,
};

pub const TOKEN_ELEVATION = extern struct {
    TokenIsElevated: u32 = 0,
};

pub const SID_AND_ATTRIBUTES = extern struct {
    Sid: ?PSID,
    Attributes: u32,
};

pub const TOKEN_USER = extern struct {
    User: SID_AND_ATTRIBUTES,
};

pub const GENERIC_READ: u32 = 0x80000000;
pub const GENERIC_WRITE: u32 = 0x40000000;
pub const GENERIC_EXECUTE: u32 = 0x20000000;
pub const GENERIC_ALL: u32 = 0x10000000;
pub const DELETE: u32 = 0x00010000;
pub const READ_CONTROL: u32 = 0x00020000;
pub const WRITE_DAC: u32 = 0x00040000;
pub const WRITE_OWNER: u32 = 0x00080000;
pub const SYNCHRONIZE: u32 = 0x00100000;
pub const FILE_READ_DATA: u32 = 0x0001;
pub const FILE_WRITE_DATA: u32 = 0x0002;
pub const FILE_APPEND_DATA: u32 = 0x0004;
pub const FILE_ADD_FILE: u32 = 0x0002;
pub const FILE_ADD_SUBDIRECTORY: u32 = 0x0004;
pub const FILE_DELETE_CHILD: u32 = 0x0040;
pub const FILE_READ_ATTRIBUTES: u32 = 0x0080;
pub const FILE_GENERIC_READ: u32 = 0x00120089;
pub const FILE_GENERIC_WRITE: u32 = 0x00120116;
pub const FILE_GENERIC_EXECUTE: u32 = 0x001200A0;
pub const FILE_ALL_ACCESS: u32 = 0x001F01FF;
pub const MUTEX_ALL_ACCESS: u32 = 0x001F0001;
pub const EVENT_MODIFY_STATE: u32 = 0x0002;
pub const TIMER_ALL_ACCESS: u32 = 0x001F0003;

pub const FILE_SHARE_READ: u32 = 0x1;
pub const FILE_SHARE_WRITE: u32 = 0x2;
pub const FILE_SHARE_DELETE: u32 = 0x4;
pub const CREATE_NEW: u32 = 1;
pub const CREATE_ALWAYS: u32 = 2;
pub const OPEN_EXISTING: u32 = 3;
pub const OPEN_ALWAYS: u32 = 4;
pub const FILE_ATTRIBUTE_DIRECTORY: u32 = 0x10;
pub const FILE_ATTRIBUTE_NORMAL: u32 = 0x80;
pub const FILE_ATTRIBUTE_REPARSE_POINT: u32 = 0x400;
pub const INVALID_FILE_ATTRIBUTES: u32 = 0xFFFFFFFF;
pub const FILE_FLAG_OVERLAPPED: u32 = 0x40000000;
pub const FILE_FLAG_BACKUP_SEMANTICS: u32 = 0x02000000;
pub const FILE_FLAG_OPEN_REPARSE_POINT: u32 = 0x00200000;
pub const FILE_TYPE_DISK: u32 = 1;
pub const DRIVE_FIXED: u32 = 3;
pub const MOVEFILE_REPLACE_EXISTING: u32 = 1;
pub const FILE_NAME_NORMALIZED: u32 = 0;
pub const VOLUME_NAME_DOS: u32 = 0;
pub const GET_FILE_EX_INFO_STANDARD: u32 = 0;
pub const FILE_END: u32 = 2;

pub const WAIT_OBJECT_0: u32 = 0;
pub const WAIT_ABANDONED: u32 = 0x80;
pub const WAIT_TIMEOUT: u32 = 0x102;
pub const WAIT_FAILED: u32 = 0xFFFFFFFF;
pub const INFINITE: u32 = 0xFFFFFFFF;

pub const ERROR_SUCCESS: u32 = 0;
pub const ERROR_FILE_NOT_FOUND: u32 = 2;
pub const ERROR_PATH_NOT_FOUND: u32 = 3;
pub const ERROR_ACCESS_DENIED: u32 = 5;
pub const ERROR_INVALID_HANDLE: u32 = 6;
pub const ERROR_SHARING_VIOLATION: u32 = 32;
pub const ERROR_FILE_EXISTS: u32 = 80;
pub const ERROR_INSUFFICIENT_BUFFER: u32 = 122;
pub const ERROR_ALREADY_EXISTS: u32 = 183;
pub const ERROR_OPERATION_ABORTED: u32 = 995;
pub const ERROR_IO_INCOMPLETE: u32 = 996;
pub const ERROR_IO_PENDING: u32 = 997;
pub const ERROR_DEVICE_NOT_CONNECTED: u32 = 1167;

pub const LOAD_LIBRARY_SEARCH_DLL_LOAD_DIR: u32 = 0x00000100;
pub const LOAD_LIBRARY_SEARCH_SYSTEM32: u32 = 0x00000800;
pub const CREATE_WAITABLE_TIMER_HIGH_RESOLUTION: u32 = 0x00000002;
pub const FORMAT_MESSAGE_FROM_SYSTEM: u32 = 0x00001000;
pub const FORMAT_MESSAGE_IGNORE_INSERTS: u32 = 0x00000200;
pub const STD_OUTPUT_HANDLE: u32 = @bitCast(@as(i32, -11));
pub const STD_ERROR_HANDLE: u32 = @bitCast(@as(i32, -12));
pub const CTRL_C_EVENT: u32 = 0;
pub const CTRL_BREAK_EVENT: u32 = 1;
pub const CTRL_CLOSE_EVENT: u32 = 2;
pub const CTRL_LOGOFF_EVENT: u32 = 5;
pub const CTRL_SHUTDOWN_EVENT: u32 = 6;
pub const TOKEN_QUERY: u32 = 0x0008;
pub const TOKEN_USER_CLASS: u32 = 1;
pub const TOKEN_ELEVATION_CLASS: u32 = 20;
pub const SE_FILE_OBJECT: u32 = 1;
pub const SE_KERNEL_OBJECT: u32 = 6;
pub const OWNER_SECURITY_INFORMATION: u32 = 0x1;
pub const DACL_SECURITY_INFORMATION: u32 = 0x4;
pub const SDDL_REVISION_1: u32 = 1;
pub const ACL_SIZE_INFORMATION_CLASS: u32 = 2;
pub const ACCESS_ALLOWED_ACE_TYPE: u8 = 0;
pub const ACCESS_DENIED_ACE_TYPE: u8 = 1;
pub const INHERIT_ONLY_ACE: u8 = 0x08;
pub const EVENTLOG_ERROR_TYPE: u16 = 0x0001;
pub const EVENTLOG_WARNING_TYPE: u16 = 0x0002;
pub const WIN_LOCAL_SYSTEM_SID: u32 = 22;
pub const WIN_BUILTIN_ADMINISTRATORS_SID: u32 = 26;
pub const WIN_CREATOR_OWNER_RIGHTS_SID: u32 = 71;
pub const SECURITY_MAX_SID_SIZE: usize = 68;
pub const CM_GET_DEVICE_INTERFACE_LIST_PRESENT: u32 = 0;
pub const CR_SUCCESS: u32 = 0;
pub const HIDP_STATUS_SUCCESS: NTSTATUS = 0x00110000;
pub const PDH_FMT_DOUBLE: u32 = 0x00000200;
pub const IOCTL_HID_GET_FEATURE: u32 = 0x000B0192;

pub const ThreadProc = *const fn (param: ?*anyopaque) callconv(.winapi) u32;
pub const ConsoleCtrlHandler = *const fn (ctrl_type: u32) callconv(.winapi) BOOL;

pub extern "kernel32" fn GetLastError() callconv(.winapi) u32;
pub extern "kernel32" fn SetLastError(code: u32) callconv(.winapi) void;
pub extern "kernel32" fn CloseHandle(handle: HANDLE) callconv(.winapi) BOOL;
pub extern "kernel32" fn CreateFileW(name: [*:0]const u16, access: u32, share: u32, security: ?*SECURITY_ATTRIBUTES, disposition: u32, flags: u32, template: ?HANDLE) callconv(.winapi) HANDLE;
pub extern "kernel32" fn ReadFile(file: HANDLE, buffer: [*]u8, to_read: u32, read: ?*u32, overlapped: ?*OVERLAPPED) callconv(.winapi) BOOL;
pub extern "kernel32" fn WriteFile(file: HANDLE, buffer: [*]const u8, to_write: u32, written: ?*u32, overlapped: ?*OVERLAPPED) callconv(.winapi) BOOL;
pub extern "kernel32" fn DeviceIoControl(device: HANDLE, code: u32, in_buffer: ?*const anyopaque, in_size: u32, out_buffer: ?*anyopaque, out_size: u32, returned: ?*u32, overlapped: ?*OVERLAPPED) callconv(.winapi) BOOL;
pub extern "kernel32" fn GetOverlappedResult(file: HANDLE, overlapped: *OVERLAPPED, transferred: *u32, wait: BOOL) callconv(.winapi) BOOL;
pub extern "kernel32" fn CancelIoEx(file: HANDLE, overlapped: ?*OVERLAPPED) callconv(.winapi) BOOL;
pub extern "kernel32" fn CreateEventW(security: ?*SECURITY_ATTRIBUTES, manual_reset: BOOL, initial_state: BOOL, name: ?[*:0]const u16) callconv(.winapi) ?HANDLE;
pub extern "kernel32" fn OpenEventW(access: u32, inherit: BOOL, name: [*:0]const u16) callconv(.winapi) ?HANDLE;
pub extern "kernel32" fn SetEvent(event: HANDLE) callconv(.winapi) BOOL;
pub extern "kernel32" fn ResetEvent(event: HANDLE) callconv(.winapi) BOOL;
pub extern "kernel32" fn WaitForSingleObject(handle: HANDLE, milliseconds: u32) callconv(.winapi) u32;
pub extern "kernel32" fn WaitForMultipleObjects(count: u32, handles: [*]const HANDLE, wait_all: BOOL, milliseconds: u32) callconv(.winapi) u32;
pub extern "kernel32" fn CreateMutexW(security: ?*SECURITY_ATTRIBUTES, initial_owner: BOOL, name: ?[*:0]const u16) callconv(.winapi) ?HANDLE;
pub extern "kernel32" fn OpenMutexW(access: u32, inherit: BOOL, name: [*:0]const u16) callconv(.winapi) ?HANDLE;
pub extern "kernel32" fn ReleaseMutex(mutex: HANDLE) callconv(.winapi) BOOL;
pub extern "kernel32" fn CreateWaitableTimerExW(security: ?*SECURITY_ATTRIBUTES, name: ?[*:0]const u16, flags: u32, access: u32) callconv(.winapi) ?HANDLE;
pub extern "kernel32" fn SetWaitableTimer(timer: HANDLE, due_time: *const i64, period: i32, completion: ?*anyopaque, completion_arg: ?*anyopaque, @"resume": BOOL) callconv(.winapi) BOOL;
pub extern "kernel32" fn CreateThread(security: ?*SECURITY_ATTRIBUTES, stack_size: usize, start: ThreadProc, parameter: ?*anyopaque, flags: u32, thread_id: ?*u32) callconv(.winapi) ?HANDLE;
pub extern "kernel32" fn ExitProcess(code: u32) callconv(.winapi) noreturn;
pub extern "kernel32" fn GetCurrentProcess() callconv(.winapi) HANDLE;
pub extern "kernel32" fn Sleep(milliseconds: u32) callconv(.winapi) void;
pub extern "kernel32" fn GetTickCount64() callconv(.winapi) u64;
pub extern "kernel32" fn QueryPerformanceCounter(count: *i64) callconv(.winapi) BOOL;
pub extern "kernel32" fn QueryPerformanceFrequency(frequency: *i64) callconv(.winapi) BOOL;
pub extern "kernel32" fn QueryUnbiasedInterruptTime(time: *u64) callconv(.winapi) BOOL;
pub extern "kernel32" fn GetLocalTime(time: *SYSTEMTIME) callconv(.winapi) void;
pub extern "kernel32" fn InitializeSRWLock(lock: *SRWLOCK) callconv(.winapi) void;
pub extern "kernel32" fn AcquireSRWLockExclusive(lock: *SRWLOCK) callconv(.winapi) void;
pub extern "kernel32" fn ReleaseSRWLockExclusive(lock: *SRWLOCK) callconv(.winapi) void;
pub extern "kernel32" fn LoadLibraryExW(name: [*:0]const u16, file: ?HANDLE, flags: u32) callconv(.winapi) ?HMODULE;
pub extern "kernel32" fn GetProcAddress(module: HMODULE, name: [*:0]const u8) callconv(.winapi) ?*const anyopaque;
pub extern "kernel32" fn FreeLibrary(module: HMODULE) callconv(.winapi) BOOL;
pub extern "kernel32" fn GetModuleFileNameW(module: ?HMODULE, file_name: [*]u16, size: u32) callconv(.winapi) u32;
pub extern "kernel32" fn SetDefaultDllDirectories(flags: u32) callconv(.winapi) BOOL;
pub extern "kernel32" fn GetStdHandle(which: u32) callconv(.winapi) ?HANDLE;
pub extern "kernel32" fn GetConsoleWindow() callconv(.winapi) ?HANDLE;
pub extern "kernel32" fn GetFileType(file: HANDLE) callconv(.winapi) u32;
pub extern "kernel32" fn SetConsoleCtrlHandler(handler: ?ConsoleCtrlHandler, add: BOOL) callconv(.winapi) BOOL;
pub extern "kernel32" fn GetFileAttributesW(name: [*:0]const u16) callconv(.winapi) u32;
pub extern "kernel32" fn GetFileAttributesExW(name: [*:0]const u16, level: u32, info: *WIN32_FILE_ATTRIBUTE_DATA) callconv(.winapi) BOOL;
pub extern "kernel32" fn GetFileInformationByHandle(file: HANDLE, info: *BY_HANDLE_FILE_INFORMATION) callconv(.winapi) BOOL;
pub extern "kernel32" fn GetFinalPathNameByHandleW(file: HANDLE, path: [*]u16, size: u32, flags: u32) callconv(.winapi) u32;
pub extern "kernel32" fn GetDriveTypeW(root: ?[*:0]const u16) callconv(.winapi) u32;
pub extern "kernel32" fn GetFileSizeEx(file: HANDLE, size: *i64) callconv(.winapi) BOOL;
pub extern "kernel32" fn SetFilePointerEx(file: HANDLE, distance: i64, new_position: ?*i64, method: u32) callconv(.winapi) BOOL;
pub extern "kernel32" fn MoveFileExW(existing: [*:0]const u16, new: ?[*:0]const u16, flags: u32) callconv(.winapi) BOOL;
pub extern "kernel32" fn CreateDirectoryW(path: [*:0]const u16, security: ?*SECURITY_ATTRIBUTES) callconv(.winapi) BOOL;
pub extern "kernel32" fn DeleteFileW(path: [*:0]const u16) callconv(.winapi) BOOL;
pub extern "kernel32" fn FindFirstFileW(pattern: [*:0]const u16, data: *WIN32_FIND_DATAW) callconv(.winapi) HANDLE;
pub extern "kernel32" fn FindNextFileW(find: HANDLE, data: *WIN32_FIND_DATAW) callconv(.winapi) BOOL;
pub extern "kernel32" fn FindClose(find: HANDLE) callconv(.winapi) BOOL;
pub extern "kernel32" fn GetEnvironmentVariableW(name: [*:0]const u16, buffer: ?[*]u16, size: u32) callconv(.winapi) u32;
pub extern "kernel32" fn GetCommandLineW() callconv(.winapi) [*:0]const u16;
pub extern "kernel32" fn FormatMessageW(flags: u32, source: ?*const anyopaque, message_id: u32, language_id: u32, buffer: [*]u16, size: u32, arguments: ?*anyopaque) callconv(.winapi) u32;
pub extern "kernel32" fn GetSystemTimes(idle: *FILETIME, kernel: *FILETIME, user: *FILETIME) callconv(.winapi) BOOL;
pub extern "kernel32" fn GlobalMemoryStatusEx(status: *MEMORYSTATUSEX) callconv(.winapi) BOOL;
pub extern "kernel32" fn LocalFree(memory: ?*anyopaque) callconv(.winapi) ?*anyopaque;
pub extern "kernel32" fn CreateBoundaryDescriptorW(name: [*:0]const u16, flags: u32) callconv(.winapi) ?HANDLE;
pub extern "kernel32" fn AddSIDToBoundaryDescriptor(boundary: *HANDLE, sid: PSID) callconv(.winapi) BOOL;
pub extern "kernel32" fn DeleteBoundaryDescriptor(boundary: HANDLE) callconv(.winapi) void;
pub extern "kernel32" fn CreatePrivateNamespaceW(security: ?*SECURITY_ATTRIBUTES, boundary: HANDLE, alias_prefix: [*:0]const u16) callconv(.winapi) ?HANDLE;
pub extern "kernel32" fn OpenPrivateNamespaceW(boundary: HANDLE, alias_prefix: [*:0]const u16) callconv(.winapi) ?HANDLE;
pub extern "kernel32" fn ClosePrivateNamespace(namespace: HANDLE, flags: u32) callconv(.winapi) BOOLEAN;

pub extern "advapi32" fn OpenProcessToken(process: HANDLE, access: u32, token: *HANDLE) callconv(.winapi) BOOL;
pub extern "advapi32" fn GetTokenInformation(token: HANDLE, class: u32, info: ?*anyopaque, length: u32, return_length: *u32) callconv(.winapi) BOOL;
pub extern "advapi32" fn CreateWellKnownSid(kind: u32, domain: ?PSID, sid: ?PSID, size: *u32) callconv(.winapi) BOOL;
pub extern "advapi32" fn EqualSid(a: PSID, b: PSID) callconv(.winapi) BOOL;
pub extern "advapi32" fn IsValidSid(sid: PSID) callconv(.winapi) BOOL;
pub extern "advapi32" fn ConvertStringSidToSidW(text: [*:0]const u16, sid: *?PSID) callconv(.winapi) BOOL;
pub extern "advapi32" fn ConvertSidToStringSidW(sid: PSID, text: *?[*:0]u16) callconv(.winapi) BOOL;
pub extern "advapi32" fn GetSecurityInfo(handle: HANDLE, object_type: u32, info: u32, owner: ?*?PSID, group: ?*?PSID, dacl: ?*?*ACL, sacl: ?*?*ACL, descriptor: *?*anyopaque) callconv(.winapi) u32;
pub extern "advapi32" fn ConvertStringSecurityDescriptorToSecurityDescriptorW(text: [*:0]const u16, revision: u32, descriptor: *?*anyopaque, size: ?*u32) callconv(.winapi) BOOL;
pub extern "advapi32" fn GetSecurityDescriptorOwner(descriptor: *anyopaque, owner: *?PSID, defaulted: *BOOL) callconv(.winapi) BOOL;
pub extern "advapi32" fn GetSecurityDescriptorDacl(descriptor: *anyopaque, present: *BOOL, dacl: *?*ACL, defaulted: *BOOL) callconv(.winapi) BOOL;
pub extern "advapi32" fn GetAclInformation(acl: *ACL, info: *anyopaque, length: u32, class: u32) callconv(.winapi) BOOL;
pub extern "advapi32" fn GetAce(acl: *ACL, index: u32, ace: *?*anyopaque) callconv(.winapi) BOOL;
pub extern "advapi32" fn MapGenericMask(mask: *u32, mapping: *const GENERIC_MAPPING) callconv(.winapi) void;
pub extern "advapi32" fn RegisterEventSourceW(server: ?[*:0]const u16, source: [*:0]const u16) callconv(.winapi) ?HANDLE;
pub extern "advapi32" fn ReportEventW(log: HANDLE, kind: u16, category: u16, event_id: u32, user_sid: ?PSID, string_count: u16, data_size: u32, strings: ?[*]const [*:0]const u16, data: ?*anyopaque) callconv(.winapi) BOOL;
pub extern "advapi32" fn DeregisterEventSource(log: HANDLE) callconv(.winapi) BOOL;

pub extern "ntdll" fn NtDeviceIoControlFile(file: HANDLE, event: ?HANDLE, apc: ?*anyopaque, apc_context: ?*anyopaque, status: *IO_STATUS_BLOCK, code: u32, in_buffer: ?*anyopaque, in_size: u32, out_buffer: ?*anyopaque, out_size: u32) callconv(.winapi) NTSTATUS;
pub extern "ntdll" fn RtlGetVersion(info: *RTL_OSVERSIONINFOW) callconv(.winapi) NTSTATUS;
pub extern "ntdll" fn RtlNtStatusToDosError(status: NTSTATUS) callconv(.winapi) u32;

pub extern "hid" fn HidD_GetHidGuid(guid: *GUID) callconv(.winapi) void;
pub extern "hid" fn HidD_GetAttributes(device: HANDLE, attributes: *HIDD_ATTRIBUTES) callconv(.winapi) BOOLEAN;
pub extern "hid" fn HidD_GetPreparsedData(device: HANDLE, data: *?*anyopaque) callconv(.winapi) BOOLEAN;
pub extern "hid" fn HidD_FreePreparsedData(data: *anyopaque) callconv(.winapi) BOOLEAN;
pub extern "hid" fn HidP_GetCaps(data: *anyopaque, caps: *HIDP_CAPS) callconv(.winapi) NTSTATUS;
pub extern "hid" fn HidD_SetFeature(device: HANDLE, buffer: *anyopaque, length: u32) callconv(.winapi) BOOLEAN;
pub extern "hid" fn HidD_GetProductString(device: HANDLE, buffer: *anyopaque, length: u32) callconv(.winapi) BOOLEAN;

pub extern "cfgmgr32" fn CM_Get_Device_Interface_List_SizeW(length: *u32, guid: *const GUID, device_id: ?[*:0]const u16, flags: u32) callconv(.winapi) u32;
pub extern "cfgmgr32" fn CM_Get_Device_Interface_ListW(guid: *const GUID, device_id: ?[*:0]const u16, buffer: [*]u16, length: u32, flags: u32) callconv(.winapi) u32;

pub extern "pdh" fn PdhOpenQueryW(source: ?[*:0]const u16, user_data: usize, query: *?*anyopaque) callconv(.winapi) u32;
pub extern "pdh" fn PdhAddEnglishCounterW(query: *anyopaque, path: [*:0]const u16, user_data: usize, counter: *?*anyopaque) callconv(.winapi) u32;
pub extern "pdh" fn PdhCollectQueryData(query: *anyopaque) callconv(.winapi) u32;
pub extern "pdh" fn PdhGetFormattedCounterValue(counter: *anyopaque, format: u32, kind: ?*u32, value: *PDH_FMT_COUNTERVALUE) callconv(.winapi) u32;
pub extern "pdh" fn PdhCloseQuery(query: *anyopaque) callconv(.winapi) u32;

pub fn isValid(handle: HANDLE) bool {
    return handle != INVALID_HANDLE_VALUE;
}

pub const L = @import("std").unicode.utf8ToUtf16LeStringLiteral;
