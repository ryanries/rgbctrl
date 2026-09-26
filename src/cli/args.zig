const std = @import("std");

const HostOptions = struct {
    config: ?[]const u8 = null,
    allow_insecure_install: bool = false,
};

pub const Command = union(enum) {
    run: HostOptions,
    apply: HostOptions,
    list: HostOptions,
    stop,
    check_install: ?[]const u8,
    version,
    help,
};

const Parsed = union(enum) {
    command: Command,
    usage_error: []const u8,
};

pub const usage =
    \\Usage: rgbctrl <command> [options]
    \\
    \\Commands:
    \\  run [--config <path>] [--allow-insecure-install]
    \\                     Apply the configuration and keep animating, updating displays and
    \\                     watching for config changes, hotplug and resume until stopped.
    \\  apply [--config <path>] [--allow-insecure-install]
    \\                     Apply hardware effects and one frame per zone, then exit.
    \\  list [--config <path>] [--allow-insecure-install]
    \\                     Show plugins, devices, zones, sensors and configuration problems
    \\                     without changing lighting.
    \\  --allow-insecure-install lets an elevated run start from a folder that is not
    \\                     admin-only (development only; the install check still runs).
    \\  stop               Ask the running instance to exit.
    \\  check-install [--dir <path>]
    \\                     Check that the install folder and the base config are admin-only.
    \\  version            Print the version.
    \\  help               Print this text.
    \\
    \\Configuration (JSON with comments and trailing commas):
    \\  %ProgramData%\rgbctrl\rgbctrl.json      base layer (trusted when admin-only)
    \\  %LOCALAPPDATA%\rgbctrl\rgbctrl.json     user layer (or --config <path>)
    \\
    \\Exit codes: 0 ok, 1 usage or config error, 2 another instance is running (stop: nothing
    \\running), 3 internal error, 4 insecure install, 5 base config present but untrusted.
    \\
;

pub fn parse(arguments: []const []const u8) Parsed {
    if (arguments.len == 0) return .{ .usage_error = "missing command" };
    const name = arguments[0];
    const rest = arguments[1..];
    if (std.mem.eql(u8, name, "run")) return parseHostOptions(rest, .run);
    if (std.mem.eql(u8, name, "apply")) return parseHostOptions(rest, .apply);
    if (std.mem.eql(u8, name, "list")) return parseHostOptions(rest, .list);
    if (std.mem.eql(u8, name, "stop")) return noOptions(rest, .stop);
    if (std.mem.eql(u8, name, "version") or std.mem.eql(u8, name, "--version")) return noOptions(rest, .version);
    if (std.mem.eql(u8, name, "help") or std.mem.eql(u8, name, "--help") or std.mem.eql(u8, name, "-h") or std.mem.eql(u8, name, "/?")) return noOptions(rest, .help);
    if (std.mem.eql(u8, name, "check-install")) return parseCheckInstall(rest);
    return .{ .usage_error = "unknown command" };
}

fn noOptions(rest: []const []const u8, command: Command) Parsed {
    if (rest.len != 0) return .{ .usage_error = "this command takes no options" };
    return .{ .command = command };
}

fn parseHostOptions(rest: []const []const u8, comptime tag: std.meta.Tag(Command)) Parsed {
    var options = HostOptions{};
    var index: usize = 0;
    while (index < rest.len) : (index += 1) {
        const argument = rest[index];
        if (std.mem.eql(u8, argument, "--config")) {
            if (options.config != null) return .{ .usage_error = "--config given twice" };
            index += 1;
            if (index >= rest.len or rest[index].len == 0) return .{ .usage_error = "--config needs a path" };
            options.config = rest[index];
        } else if (std.mem.eql(u8, argument, "--allow-insecure-install")) {
            if (options.allow_insecure_install) return .{ .usage_error = "--allow-insecure-install given twice" };
            options.allow_insecure_install = true;
        } else {
            return .{ .usage_error = "unknown option; only --config <path> and --allow-insecure-install are accepted" };
        }
    }
    return .{ .command = @unionInit(Command, @tagName(tag), options) };
}

fn parseCheckInstall(rest: []const []const u8) Parsed {
    if (rest.len == 0) return .{ .command = .{ .check_install = null } };
    if (rest.len == 2 and std.mem.eql(u8, rest[0], "--dir") and rest[1].len > 0) return .{ .command = .{ .check_install = rest[1] } };
    return .{ .usage_error = "check-install accepts only --dir <path>" };
}

const testing = std.testing;

test "run accepts a config path and the insecure-install switch" {
    const parsed = parse(&.{ "run", "--config", "C:\\x.json", "--allow-insecure-install" });
    try testing.expectEqualStrings("C:\\x.json", parsed.command.run.config.?);
    try testing.expect(parsed.command.run.allow_insecure_install);
    try testing.expect(parse(&.{"run"}).command.run.config == null);
}

test "apply and list accept --config and the insecure-install switch" {
    try testing.expectEqualStrings("a.json", parse(&.{ "apply", "--config", "a.json" }).command.apply.config.?);
    try testing.expect(parse(&.{"list"}).command.list.config == null);
    try testing.expect(parse(&.{ "apply", "--allow-insecure-install" }).command.apply.allow_insecure_install);
    try testing.expect(parse(&.{ "apply", "--force" }) == .usage_error);
    try testing.expect(parse(&.{ "list", "--config" }) == .usage_error);
    try testing.expect(parse(&.{ "list", "--config", "a", "--config", "b" }) == .usage_error);
}

test "simple commands reject extra arguments and unknown commands are usage errors" {
    try testing.expect(parse(&.{"stop"}).command == .stop);
    try testing.expect(parse(&.{"version"}).command == .version);
    try testing.expect(parse(&.{"/?"}).command == .help);
    try testing.expect(parse(&.{ "stop", "now" }) == .usage_error);
    try testing.expect(parse(&.{"start"}) == .usage_error);
    try testing.expect(parse(&.{}) == .usage_error);
}

test "check-install takes an optional directory" {
    try testing.expect(parse(&.{"check-install"}).command.check_install == null);
    try testing.expectEqualStrings("D:\\rgb", parse(&.{ "check-install", "--dir", "D:\\rgb" }).command.check_install.?);
    try testing.expect(parse(&.{ "check-install", "--dir" }) == .usage_error);
}
