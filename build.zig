const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const mod = b.addModule("clutch", .{ .root_source_file = b.path("src/root.zig"), .target = target, .optimize = optimize });
    addDocs(b, mod);

    // Benchmarks always build `.fast`: debug timings say nothing about real use.
    const bench = b.addExecutable(.{
        .name = "clutch-bench",
        .root_module = b.createModule(.{
            .root_source_file = b.path("bench/main.zig"),
            .target = target,
            .optimize = .fast,
            .imports = &.{.{ .name = "clutch", .module = b.createModule(.{ .root_source_file = b.path("src/root.zig"), .target = target, .optimize = .fast }) }},
        }),
    });
    const run_bench = b.addRunArtifact(bench);
    run_bench.addPassthruArgs();
    b.step("bench", "Time clutch's common operations (`.fast`); `-- <count>` sets the entity count").dependOn(&run_bench.step);

    // root.zig's test block reaches every file's tests.
    const run_tests = b.addRunArtifact(b.addTest(.{ .root_module = mod }));
    b.step("test", "Run tests").dependOn(&run_tests.step);
}

/// `zig build docs`: Zig's HTML API reference for `mod` in zig-out/docs, which
/// .github/workflows/docs.yml publishes under api/.
fn addDocs(b: *std.Build, mod: *std.Build.Module) void {
    const docs = b.addObject(.{ .name = "clutch", .root_module = mod });
    const install = b.addInstallDirectory(.{ .source_dir = docs.getEmittedDocs(), .install_dir = .prefix, .install_subdir = "docs" });
    b.step("docs", "Build the API docs into zig-out/docs").dependOn(&install.step);
}
