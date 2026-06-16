//! zetl - Multi-source MySQL data aggregation ETL engine (V1).
//! Build:
//!   zig build                            (sqlite-only build, for tests)
//!   zig build -Ddriver_mysql=true        (full build, links mysqlclient)
//!   zig build run -Ddriver_mysql=true    (build + run server on :8080)
//!   zig build test                       (compile + run unit tests)

const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const driver_mysql = b.option(bool, "driver_mysql", "Enable MySQL driver") orelse false;

    // --- zfinal dependency ---
    const zfinal_dep = b.dependency("zfinal", .{
        .target = target,
        .optimize = optimize,
        .driver_mysql = driver_mysql,
    });
    const zfinal_mod = zfinal_dep.module("zfinal");

    // --- Main executable ---
    const app_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "zfinal", .module = zfinal_mod }},
    });
    app_mod.link_libc = true;
    app_mod.linkSystemLibrary("sqlite3", .{});
    if (driver_mysql) {
        app_mod.linkSystemLibrary("mysqlclient", .{});
    }

    const exe = b.addExecutable(.{
        .name = "zetl",
        .root_module = app_mod,
    });
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    const run_step = b.step("run", "Build and run zetl server");
    run_step.dependOn(&run_cmd.step);

    // --- Tests ---
    const test_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "zfinal", .module = zfinal_mod }},
    });
    test_mod.link_libc = true;
    test_mod.linkSystemLibrary("sqlite3", .{});
    if (driver_mysql) {
        test_mod.linkSystemLibrary("mysqlclient", .{});
    }

    const lib_unit_tests = b.addTest(.{ .root_module = test_mod });
    const run_lib_unit_tests = b.addRunFile(lib_unit_tests.getEmittedBin());
    run_lib_unit_tests.expectExitCode(0);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_lib_unit_tests.step);
}
