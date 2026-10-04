const std = @import("std");

const plugin_names = [_][]const u8{
    "gigabyte_fusion2",
    "gigabyte_gpu",
    "corsair_ddr5",
    "keychron",
    "sudokoo_sk700v",
    "amd_cpu",
    "windows_metrics",
    "nvidia_gpu",
};

const c_plugin_variants = [_]struct { name: []const u8, define: ?[]const u8 }{
    .{ .name = "virtual_led", .define = null },
    .{ .name = "virtual_null_entry", .define = "RGBCTRL_TEST_NULL_ENTRY" },
    .{ .name = "virtual_abi0", .define = "RGBCTRL_TEST_ABI0" },
    .{ .name = "virtual_abi2", .define = "RGBCTRL_TEST_ABI2" },
    .{ .name = "virtual_short", .define = "RGBCTRL_TEST_SHORT_STRUCT" },
};

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{ .default_target = .{ .cpu_arch = .x86_64, .os_tag = .windows, .abi = .gnu } });
    const optimize = b.standardOptimizeOption(.{ .preferred_optimize_mode = .small });
    const strip = optimize != .debug;
    const bundle_compiler_rt = optimize == .debug;
    const install_pawnio_modules = b.option(bool, "pawnio-modules", "Install the PawnIO modules from the pinned official release (default true)") orelse true;

    const rt = b.createModule(.{
        .root_source_file = b.path("sdk/rt.zig"),
        .target = target,
        .optimize = optimize,
        .strip = strip,
        .no_builtin = true,
    });

    const sdk_host = b.createModule(.{ .root_source_file = b.path("sdk/sdk.zig"), .target = target, .optimize = optimize, .strip = strip });
    const sdk_plugin = b.createModule(.{ .root_source_file = b.path("sdk/sdk.zig"), .target = target, .optimize = optimize, .strip = strip, .single_threaded = true });
    const sdk_test = b.createModule(.{ .root_source_file = b.path("sdk/sdk.zig"), .target = target, .optimize = .debug });

    const host = b.createModule(.{ .root_source_file = b.path("src/main.zig"), .target = target, .optimize = optimize, .strip = strip });
    host.addImport("sdk", sdk_host);
    host.addImport("rt", rt);
    const exe = b.addExecutable(.{ .name = "rgbctrl", .root_module = host });
    exe.bundle_compiler_rt = bundle_compiler_rt;
    const install_exe = b.addInstallArtifact(exe, .{ .implib_dir = .disabled });
    b.getInstallStep().dependOn(&install_exe.step);
    const host_step = b.step("host", "Build rgbctrl.exe only");
    host_step.dependOn(&install_exe.step);

    const test_step = b.step("test", "Run all unit tests");

    const host_tests_module = b.createModule(.{ .root_source_file = b.path("src/host_tests.zig"), .target = target, .optimize = .debug });
    host_tests_module.addImport("sdk", sdk_test);
    host_tests_module.addAnonymousImport("example_config", .{ .root_source_file = b.path("rgbctrl.example.json") });
    const host_tests = b.addTest(.{ .name = "host-tests", .root_module = host_tests_module });
    const run_host_tests = b.addRunArtifact(host_tests);
    test_step.dependOn(&run_host_tests.step);
    b.step("test-host", "Run host unit tests").dependOn(&run_host_tests.step);

    const sdk_tests = b.addTest(.{ .name = "sdk-tests", .root_module = sdk_test });
    const run_sdk_tests = b.addRunArtifact(sdk_tests);
    test_step.dependOn(&run_sdk_tests.step);

    // The C header, translated so the test can compare it with the Zig ABI mirror. Its only
    // includes, <stddef.h> and <stdint.h>, come with Zig's C headers, so no libc is linked.
    const plugin_header = b.addTranslateC(.{
        .root_source_file = b.path("include/rgbctrl_plugin.h"),
        .target = target,
        .optimize = .debug,
        .link_libc = false,
    });
    const abi_c_module = b.createModule(.{ .root_source_file = b.path("sdk/abi_c_test.zig"), .target = target, .optimize = .debug });
    abi_c_module.addImport("rgbctrl_plugin_h", plugin_header.createModule());
    const abi_c_tests = b.addTest(.{ .name = "abi-c-tests", .root_module = abi_c_module });
    const run_abi_c_tests = b.addRunArtifact(abi_c_tests);
    test_step.dependOn(&run_abi_c_tests.step);
    b.step("test-sdk", "Run SDK unit tests").dependOn(&run_sdk_tests.step);

    for (plugin_names) |name| {
        const source = b.path(b.fmt("plugins/{s}/plugin.zig", .{name}));
        const module = b.createModule(.{ .root_source_file = source, .target = target, .optimize = optimize, .strip = strip, .single_threaded = true });
        module.addImport("sdk", sdk_plugin);
        module.addImport("rt", rt);
        const library = b.addLibrary(.{ .linkage = .dynamic, .name = name, .root_module = module });
        library.bundle_compiler_rt = bundle_compiler_rt;
        const install = b.addInstallArtifact(library, .{
            .dest_dir = .{ .override = .{ .custom = "bin/plugins" } },
            .implib_dir = .disabled,
            .pdb_dir = .disabled,
        });
        b.getInstallStep().dependOn(&install.step);
        b.step(b.fmt("plugin-{s}", .{name}), b.fmt("Build the {s} plugin only", .{name})).dependOn(&install.step);

        const test_module = b.createModule(.{ .root_source_file = source, .target = target, .optimize = .debug });
        test_module.addImport("sdk", sdk_test);
        const tests = b.addTest(.{ .name = b.fmt("{s}-tests", .{name}), .root_module = test_module });
        const run_tests = b.addRunArtifact(tests);
        test_step.dependOn(&run_tests.step);
        b.step(b.fmt("test-{s}", .{name}), b.fmt("Run the {s} plugin unit tests", .{name})).dependOn(&run_tests.step);
    }

    const examples_step = b.step("examples", "Build the C example plugin and its test variants");
    for (c_plugin_variants) |variant| {
        const module = b.createModule(.{ .target = target, .optimize = optimize, .strip = strip, .link_libc = true });
        module.addIncludePath(b.path("include"));
        const flags: []const []const u8 = if (variant.define) |define|
            b.dupeStrings(&.{ "-std=c11", "-Wall", "-Wextra", "-Werror", b.fmt("-D{s}=1", .{define}) })
        else
            &.{ "-std=c11", "-Wall", "-Wextra", "-Werror" };
        module.addCSourceFile(.{ .file = b.path("examples/c_plugin/virtual_led.c"), .flags = flags });
        const library = b.addLibrary(.{ .linkage = .dynamic, .name = variant.name, .root_module = module });
        const destination: []const u8 = if (variant.define == null) "bin/examples" else "test-plugins";
        const install = b.addInstallArtifact(library, .{
            .dest_dir = .{ .override = .{ .custom = destination } },
            .implib_dir = .disabled,
            .pdb_dir = .disabled,
        });
        examples_step.dependOn(&install.step);
        b.getInstallStep().dependOn(&install.step);
    }

    b.getInstallStep().dependOn(&b.addInstallFile(b.path("include/rgbctrl_plugin.h"), "include/rgbctrl_plugin.h").step);
    b.getInstallStep().dependOn(&b.addInstallFile(b.path("rgbctrl.example.json"), "bin/rgbctrl.example.json").step);

    if (install_pawnio_modules) {
        if (b.lazyDependency("pawnio_modules", .{})) |modules| {
            for ([_][]const u8{ "AMDFamily17.bin", "SmbusPIIX4.bin" }) |file_name| {
                const install = b.addInstallFileWithDir(modules.path(file_name), .{ .custom = "bin/pawnio" }, file_name);
                b.getInstallStep().dependOn(&install.step);
            }
        }
    }
}
