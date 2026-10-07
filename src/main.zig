const std = @import("std");
const formatting = @import("diag/format.zig");
const builtin = @import("builtin");
const sdk = @import("sdk");
const heap = @import("heap.zig");
const platform = @import("platform.zig");
const args = @import("cli/args.zig");
const log = @import("diag/log.zig");
const console = @import("diag/console.zig");
const event_log = @import("diag/event_log.zig");
const install_check = @import("security/install_check.zig");
const safe_open = @import("security/safe_open.zig");
const named_objects = @import("security/named_objects.zig");
const generation = @import("config/generation.zig");
const settings = @import("config/settings.zig");
const loader = @import("plugin_host/loader.zig");
const supervisor_module = @import("runtime/supervisor.zig");
const sensors = @import("runtime/sensors.zig");
const clock_module = @import("runtime/clock.zig");

const win32 = sdk.win32;

pub const std_options: std.Options = .{
    .enable_segfault_handler = false,
};

comptime {
    if (!@hasDecl(@import("root"), "std_options")) @compileError("rgbctrl must explicitly define std_options");
    if (std.options.enable_segfault_handler) @compileError("rgbctrl requires Zig's segfault handler to be disabled for NVML SEH containment");
    if (!builtin.is_test) _ = @import("rt");
}

pub const panic = sdk.panic;

const version = "0.1.0";

const exit_ok: u8 = 0;
const exit_usage: u8 = 1;
const exit_singleton: u8 = 2;
const exit_insecure_install: u8 = 4;
const exit_base_untrusted: u8 = 5;
const max_plugins = 64;
const source = "host";

var stop_event: ?win32.HANDLE = null;
var cleanup_done: ?win32.HANDLE = null;
var running_as_system = false;

fn interactive() bool {
    return !running_as_system and console.hasStandardError();
}

fn reportPanic(message: []const u8) void {
    log.global.log(.err, source, "internal error: {s}", .{message});
    console.print(.err, "rgbctrl: internal error: {s}\n", .{message});
    if (!interactive()) event_log.report(.err, message);
}

fn consoleHandler(control: u32) callconv(.winapi) win32.BOOL {
    if (control == win32.CTRL_LOGOFF_EVENT and running_as_system) return win32.FALSE;
    const event = stop_event orelse return win32.FALSE;
    _ = win32.SetEvent(event);
    if (control == win32.CTRL_CLOSE_EVENT or control == win32.CTRL_LOGOFF_EVENT or control == win32.CTRL_SHUTDOWN_EVENT) {
        if (cleanup_done) |done| _ = win32.WaitForSingleObject(done, 4500);
    }
    return win32.TRUE;
}

pub fn main() u8 {
    _ = win32.SetDefaultDllDirectories(win32.LOAD_LIBRARY_SEARCH_SYSTEM32);
    sdk.panic.hook = reportPanic;
    var arena_state = std.heap.ArenaAllocator.init(heap.allocator);
    const arena = arena_state.allocator();
    const arguments = collectArguments(arena) catch {
        console.write(.err, "rgbctrl: out of memory\n");
        return exit_usage;
    };
    const tail = if (arguments.len > 0) arguments[1..] else arguments;
    switch (args.parse(tail)) {
        .usage_error => |message| {
            console.print(.err, "rgbctrl: {s}\n\n", .{message});
            console.write(.err, args.usage);
            return exit_usage;
        },
        .command => |command| return dispatch(arena, command),
    }
}

extern "shell32" fn CommandLineToArgvW(command_line: [*:0]const u16, count: *c_int) callconv(.winapi) ?[*][*:0]u16;

fn collectArguments(arena: std.mem.Allocator) ![]const []const u8 {
    var count: c_int = 0;
    const vector = CommandLineToArgvW(win32.GetCommandLineW(), &count) orelse return error.OutOfMemory;
    defer _ = win32.LocalFree(@ptrCast(vector));
    const total: usize = @intCast(@max(count, 0));
    const list = try arena.alloc([]const u8, total);
    for (list, 0..) |*argument, index| {
        const wide = std.mem.span(vector[index]);
        const utf8 = try arena.alloc(u8, wide.len * 3);
        argument.* = sdk.text.utf16ToUtf8(utf8, wide);
    }
    return list;
}

fn dispatch(arena: std.mem.Allocator, command: args.Command) u8 {
    return switch (command) {
        .version => blk: {
            console.print(.out, "rgbctrl {s}\n", .{version});
            break :blk exit_ok;
        },
        .help => blk: {
            console.write(.out, args.usage);
            break :blk exit_ok;
        },
        .stop => stopCommand(),
        .check_install => |directory| checkInstallCommand(arena, directory),
        .run => |options| runHost(arena, .run, options.config, options.allow_insecure_install),
        .apply => |options| runHost(arena, .apply, options.config, options.allow_insecure_install),
        .list => |options| runHost(arena, .list, options.config, options.allow_insecure_install),
    };
}

fn stopCommand() u8 {
    switch (named_objects.signalRunningInstance()) {
        .private_signaled, .local_signaled => {
            console.write(.out, "rgbctrl: stop requested; the running instance is shutting down\n");
            return exit_ok;
        },
        .not_found => {
            console.write(.err, "rgbctrl: no running instance was reachable. An instance started elevated or by the SYSTEM task needs \"rgbctrl stop\" from an elevated prompt, or: Stop-ScheduledTask -TaskName rgbctrl\n");
            return exit_singleton;
        },
    }
}

fn checkInstallCommand(arena: std.mem.Allocator, directory_option: ?[]const u8) u8 {
    var directory = platform.PathBuffer{};
    if (directory_option) |text| {
        if (!platform.fullPathFromUtf8(text, &directory)) {
            console.print(.err, "rgbctrl: invalid directory {s}\n", .{text});
            return exit_usage;
        }
    } else {
        var exe = platform.PathBuffer{};
        if (!platform.executablePath(&exe) or !directory.set(platform.directoryOf(exe.slice()))) {
            console.write(.err, "rgbctrl: cannot determine the executable path\n");
            return exit_usage;
        }
    }
    var findings: std.ArrayList(install_check.Finding) = .empty;
    const install_ok = install_check.checkInstall(arena, directory.slice(), &findings) catch false;
    var utf8_buffer: [2048]u8 = undefined;
    console.print(.out, "Install folder {s}:\n", .{directory.utf8(&utf8_buffer)});
    printFindings(findings.items);
    console.print(.out, "Install rules: {s}\n\n", .{if (install_ok) "passed" else "FAILED (run scripts\\install.ps1 from an elevated PowerShell to install into a protected folder)"});
    var base = platform.PathBuffer{};
    if (!platform.knownFolder(&platform.folder_program_data, &base)) _ = base.set(win32.L("C:\\ProgramData"));
    _ = base.append(win32.L("rgbctrl"));
    var base_findings: std.ArrayList(install_check.Finding) = .empty;
    const verdict = install_check.checkBase(arena, base.slice(), &base_findings) catch install_check.BaseVerdict{ .untrusted = "out of memory" };
    console.print(.out, "Base config folder {s}:\n", .{base.utf8(&utf8_buffer)});
    printFindings(base_findings.items);
    switch (verdict) {
        .absent => console.write(.out, "Base config: absent (no base layer; not a failure)\n"),
        .trusted => console.write(.out, "Base config: trusted\n"),
        .untrusted => |reason| console.print(.out, "Base config: untrusted ({s})\n", .{reason}),
    }
    if (!install_ok) return exit_insecure_install;
    if (verdict == .untrusted) return exit_base_untrusted;
    return exit_ok;
}

fn printFindings(findings: []const install_check.Finding) void {
    for (findings) |finding| {
        if (finding.problem) |problem| {
            var buffer: [512]u8 = undefined;
            console.print(.out, "  FAIL  {s}: {s}\n", .{ finding.path, install_check.describeProblem(&buffer, problem, finding.kind) });
        } else {
            console.print(.out, "  ok    {s}\n", .{finding.path});
        }
    }
}

fn fail(message: []const u8) void {
    console.print(.err, "rgbctrl: {s}\n", .{message});
    log.global.writeWithoutEcho(.err, source, message);
}

fn reportEarlyFailures(logger: *log.Logger) void {
    if (!interactive()) logger.reportUndeliveredToEventLog();
}

fn runHost(arena: std.mem.Allocator, mode: supervisor_module.Mode, config_option: ?[]const u8, allow_insecure_install: bool) u8 {
    const logger = &log.global;
    var exe = platform.PathBuffer{};
    if (!platform.executablePath(&exe)) {
        fail("cannot determine the executable path");
        return exit_usage;
    }
    var exe_directory = platform.PathBuffer{};
    _ = exe_directory.set(platform.directoryOf(exe.slice()));
    const privilege = platform.currentPrivilege();
    running_as_system = privilege.system;
    logger.echo_to_stderr = interactive();
    logger.event_log_fallback = !interactive();

    var install_note: []const u8 = "skipped (not elevated)";
    if (privilege.elevated) {
        var findings: std.ArrayList(install_check.Finding) = .empty;
        const install_ok = install_check.checkInstall(arena, exe_directory.slice(), &findings) catch false;
        install_check.logFindings(logger, findings.items, true);
        if (!install_ok) {
            if (!allow_insecure_install) {
                fail("refusing to run elevated from an insecure install folder (see the problems above); install with scripts\\install.ps1 from an elevated PowerShell, or run unelevated");
                reportEarlyFailures(logger);
                return exit_insecure_install;
            }
            install_note = "FAILED, continuing because of --allow-insecure-install (development only)";
            logger.log(.warn, source, "the install folder is not protected; continuing because of --allow-insecure-install (development only)", .{});
        } else {
            install_note = "passed";
        }
    }

    const singleton = named_objects.acquireSingleton();
    switch (singleton) {
        .acquired => {},
        .held => |holder| {
            var sid_buffer: [96]u8 = undefined;
            const owner: []const u8 = switch (holder) {
                .owner => |sid| sid.format(&sid_buffer),
                .unknown_owner => "unknown owner",
                .other_type => "an object of another type (possible squatting)",
            };
            var message: [900]u8 = undefined;
            fail(formatting.print(&message, "another rgbctrl instance is running (held by {s}). Its log is rgbctrl.log (unless log.file changes it) in the folder of that instance's rgbctrl.exe, or in %LOCALAPPDATA%\\rgbctrl\\ for an unelevated instance that cannot write there. Stop it with \"rgbctrl stop\" (elevated for an elevated or SYSTEM instance) or Stop-ScheduledTask -TaskName rgbctrl; start the task again with Start-ScheduledTask -TaskName rgbctrl.", .{owner}));
            reportEarlyFailures(logger);
            return exit_singleton;
        },
        .failed => |code| {
            var message: [200]u8 = undefined;
            fail(formatting.print(&message, "cannot create the instance lock (Win32 error {d})", .{code}));
            reportEarlyFailures(logger);
            return exit_singleton;
        },
    }

    openLog(logger, exe_directory.slice(), privilege.elevated, settings.default_log_file);

    const stop = named_objects.createStopEvent(privilege.elevated) orelse {
        fail("cannot create the stop event");
        return exit_singleton;
    };
    stop_event = stop.event;
    if (!stop.reachable) logger.log(.warn, source, "the private stop event could not be created; \"rgbctrl stop\" cannot reach this instance (use Ctrl+C or Stop-ScheduledTask -TaskName rgbctrl)", .{});
    cleanup_done = win32.CreateEventW(null, win32.TRUE, win32.FALSE, null);
    _ = win32.SetConsoleCtrlHandler(consoleHandler, win32.TRUE);

    var base_directory = platform.PathBuffer{};
    if (!platform.knownFolder(&platform.folder_program_data, &base_directory)) _ = base_directory.set(win32.L("C:\\ProgramData"));
    _ = base_directory.append(win32.L("rgbctrl"));
    var base_file = platform.PathBuffer{};
    _ = base_file.set(base_directory.slice());
    _ = base_file.append(win32.L("rgbctrl.json"));
    var user_file = platform.PathBuffer{};
    if (config_option) |path| {
        if (!platform.fullPathFromUtf8(path, &user_file)) {
            fail("the --config path is invalid");
            return exit_usage;
        }
    } else {
        if (!platform.knownFolder(&platform.folder_local_app_data, &user_file)) _ = user_file.set(win32.L("C:\\nonexistent"));
        _ = user_file.append(win32.L("rgbctrl"));
        _ = user_file.append(win32.L("rgbctrl.json"));
    }
    const sources = generation.Sources{
        .base_directory = base_directory.terminated(),
        .base_file = base_file.terminated(),
        .user_file = user_file.terminated(),
        .elevated = privilege.elevated,
    };

    logBanner(logger, mode, &exe, privilege, install_note);

    const config = generation.load(1, &sources) catch {
        fail("out of memory while loading the configuration");
        return exit_usage;
    };
    supervisor_module.Supervisor.logConfigDiagnostics(logger, config);
    if (config.layer_failed and mode == .apply) {
        fail("apply stopped because a configuration file could not be used (see above); no lighting was changed");
        return exit_usage;
    }
    if (config.layer_failed and mode == .run) logger.log(.warn, "config", "continuing without the configuration file that could not be used", .{});
    logger.configure(config.settings.log_level, config.settings.log_max_size_kb);
    if (!std.mem.eql(u8, config.settings.log_file, settings.default_log_file)) {
        if (logger.isOpen()) {
            logger.switchFileName(config.settings.log_file) catch |err| {
                logger.log(.err, source, "cannot open log file {s}: {s}; keeping the current log", .{ config.settings.log_file, safe_open.describe(err) });
            };
        } else {
            openLog(logger, exe_directory.slice(), privilege.elevated, config.settings.log_file);
        }
    }

    var plugins_directory = platform.PathBuffer{};
    _ = plugins_directory.set(exe_directory.slice());
    _ = plugins_directory.append(win32.L("plugins"));
    const loaded = loader.loadDirectory(arena, plugins_directory.slice()) catch {
        fail("out of memory while loading plugins");
        return exit_usage;
    };
    var plugins = loaded.plugins;
    if (plugins.len > max_plugins) {
        logger.log(.warn, source, "{d} plugins found; only the first {d} are used", .{ plugins.len, max_plugins });
        plugins = plugins[0..max_plugins];
    }
    for (plugins) |*plugin| {
        var flags_buffer: [96]u8 = undefined;
        logger.log(.info, source, "loaded plugin {s} {s} from {s} [{s}]", .{ plugin.name, plugin.version, plugin.file_name, supervisor_module.describePluginFlags(&flags_buffer, plugin) });
    }
    for (loaded.failures) |failure| logger.log(.warn, source, "plugin {s} not loaded: {s}", .{ failure.file_name, failure.reason });
    if (plugins.len == 0) logger.log(.warn, source, "no plugins were loaded from the plugins folder next to rgbctrl.exe", .{});

    var sensor_table = sensors.SensorTable{};
    const clock = clock_module.Clock.init();
    const supervisor = supervisor_module.Supervisor.create(.{
        .mode = mode,
        .logger = logger,
        .clock = &clock,
        .sensor_table = &sensor_table,
        .host_dir = exe_directory.terminated().ptr,
        .sources = &sources,
        .stop_event = stop.event,
        .plugins = plugins,
        .failures = loaded.failures,
        .config = config,
        .version = version,
        .account = if (privilege.system) .system else if (privilege.elevated) .elevated else .standard,
    }) catch {
        fail("cannot start the plugin workers");
        return exit_usage;
    };
    supervisor.startPlugins();
    const code: u8 = switch (mode) {
        .run => blk: {
            supervisor.runResident();
            break :blk exit_ok;
        },
        .apply => supervisor.runApply(),
        .list => supervisor.runList(),
    };
    const clean = supervisor.shutdown();
    logger.log(.info, source, "exiting with code {d}{s}", .{ code, if (clean) "" else " (abandoned unresponsive plugins)" });
    if (!logger.isOpen()) reportEarlyFailures(logger);
    if (cleanup_done) |done| _ = win32.SetEvent(done);
    if (!clean) win32.ExitProcess(code);
    return code;
}

fn openLog(logger: *log.Logger, exe_directory: []const u16, elevated: bool, file_name: []const u8) void {
    var path_buffer: [2048]u8 = undefined;
    if (logger.open(exe_directory, file_name)) {
        if (interactive()) console.print(.err, "rgbctrl: logging to {s}\n", .{logger.pathUtf8(&path_buffer)});
        return;
    } else |err| {
        if (elevated) {
            var message: [300]u8 = undefined;
            fail(formatting.print(&message, "cannot open the log file next to rgbctrl.exe ({s}); logging to stderr only", .{safe_open.describe(err)}));
            return;
        }
    }
    var fallback = platform.PathBuffer{};
    if (!platform.knownFolder(&platform.folder_local_app_data, &fallback) or !fallback.append(win32.L("rgbctrl"))) {
        fail("cannot determine %LOCALAPPDATA% for the log file; logging to stderr only");
        return;
    }
    _ = platform.ensureDirectory(fallback.terminated());
    logger.open(fallback.slice(), file_name) catch |err| {
        var message: [300]u8 = undefined;
        fail(formatting.print(&message, "cannot open the log file in %LOCALAPPDATA%\\rgbctrl ({s}); logging to stderr only", .{safe_open.describe(err)}));
        return;
    };
    if (interactive()) console.print(.err, "rgbctrl: logging to {s}\n", .{logger.pathUtf8(&path_buffer)});
}

fn logBanner(logger: *log.Logger, mode: supervisor_module.Mode, exe: *const platform.PathBuffer, privilege: platform.Privilege, install_note: []const u8) void {
    var path_buffer: [2048]u8 = undefined;
    var log_buffer: [2048]u8 = undefined;
    logger.log(.info, source, "rgbctrl {s} starting ({s})", .{ version, @tagName(mode) });
    logger.log(.info, source, "executable {s}", .{exe.utf8(&path_buffer)});
    logger.log(.info, source, "log file {s}", .{if (logger.isOpen()) logger.pathUtf8(&log_buffer) else "(none; stderr only)"});
    logger.log(.info, source, "Windows build {d}; {s}", .{ platform.windowsBuild(), if (privilege.system) "running as SYSTEM" else if (privilege.elevated) "running elevated" else "running as a standard user" });
    logger.log(.info, source, "install check {s}", .{install_note});
    if (sdk.pawnio.driverVersion()) |driver_version| {
        logger.log(.info, source, "PawnIO driver present (version 0x{x})", .{driver_version});
    } else if (sdk.pawnio.deviceExists()) {
        logger.log(.info, source, "PawnIO driver present (version not readable without elevation)", .{});
    } else {
        logger.log(.info, source, "PawnIO driver not installed (needed for CPU temperature, CPU power and DDR5 lighting: winget install namazso.PawnIO)", .{});
    }
}
