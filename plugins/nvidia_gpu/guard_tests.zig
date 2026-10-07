const std = @import("std");
const builtin = @import("builtin");
const nvidia_plugin = @import("nvidia_plugin");

comptime {
    if (builtin.mode != .small) @compileError("NVML guard tests must use ReleaseSmall");
    if (std.options.enable_segfault_handler) @compileError("NVML guard tests require Zig's segfault handler to be disabled");
}

const access_violation: u32 = 0xC0000005;
const test_exception: u32 = 0xE0001234;

const KindValueFunction = nvidia_plugin.testing.KindValueFunction;

extern fn rgbctrl_nvml_test_value(device: *anyopaque, kind: u32, value: *u32) callconv(.c) i32;
extern fn rgbctrl_nvml_test_access_violation(device: *anyopaque, kind: u32, value: *u32) callconv(.c) i32;
extern fn rgbctrl_nvml_test_continue_search(exception_code: *u32) callconv(.c) i32;

const Outcome = struct {
    completed: bool,
    status: i32,
    exception_code: u32,
    value: u32,
};

fn run(function: KindValueFunction) Outcome {
    var value: u32 = 0;
    const result = nvidia_plugin.testing.guardedKindValue(function, @ptrFromInt(1), 0, &value);
    return switch (result) {
        .completed => |status| .{
            .completed = true,
            .status = status,
            .exception_code = 0,
            .value = value,
        },
        .fault => |exception_code| .{
            .completed = false,
            .status = -1,
            .exception_code = exception_code,
            .value = value,
        },
    };
}

test "production NVML guard adapter preserves a completed vendor result" {
    const outcome = run(rgbctrl_nvml_test_value);
    try std.testing.expect(outcome.completed);
    try std.testing.expectEqual(@as(i32, 3), outcome.status);
    try std.testing.expectEqual(@as(u32, 0), outcome.exception_code);
    try std.testing.expectEqual(@as(u32, 1455), outcome.value);
}

test "production NVML guard adapter contains a vendor access violation" {
    const outcome = run(rgbctrl_nvml_test_access_violation);
    try std.testing.expect(!outcome.completed);
    try std.testing.expectEqual(access_violation, outcome.exception_code);
}

test "NVML guard continues search for unrelated structured exceptions" {
    var exception_code: u32 = 0;
    try std.testing.expectEqual(@as(i32, 1), rgbctrl_nvml_test_continue_search(&exception_code));
    try std.testing.expectEqual(test_exception, exception_code);
}
