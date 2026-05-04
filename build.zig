const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const mod = b.addModule("clutch", .{ .root_source_file = b.path("src/root.zig"), .target = target, .optimize = optimize });

    const test_step = b.step("test", "Run tests");
    const test_runner = defaultTestRunner(b);

    addTestArtifact(b, test_step, mod, test_runner);

    var src_dir = b.build_root.handle.openDir(b.graph.io, "src", .{ .iterate = true }) catch |err| {
        std.debug.panic("failed to open src directory: {s}", .{@errorName(err)});
    };
    defer src_dir.close(b.graph.io);

    var iter = src_dir.iterate();
    while (iter.next(b.graph.io) catch |err| {
        std.debug.panic("failed to iterate src directory: {s}", .{@errorName(err)});
    }) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.name, ".zig")) continue;
        if (std.mem.eql(u8, entry.name, "root.zig")) continue;

        const test_file = b.fmt("src/{s}", .{entry.name});
        const test_module = b.createModule(.{
            .root_source_file = b.path(test_file),
            .target = target,
            .optimize = optimize,
        });
        addTestArtifact(b, test_step, test_module, test_runner);
    }
}

fn addTestArtifact(
    b: *std.Build,
    test_step: *std.Build.Step,
    module: *std.Build.Module,
    test_runner: std.Build.Step.Compile.TestRunner,
) void {
    const tests = b.addTest(.{
        .root_module = module,
        .test_runner = test_runner,
    });
    const run_tests = b.addRunArtifact(tests);
    run_tests.stdio = .inherit;
    test_step.dependOn(&run_tests.step);
}

fn defaultTestRunner(b: *std.Build) std.Build.Step.Compile.TestRunner {
    const path = b.graph.zig_lib_directory.join(b.allocator, &.{ "compiler", "test_runner.zig" }) catch {
        @panic("failed to resolve Zig default test runner path");
    };

    return .{
        .path = .{ .cwd_relative = path },
        .mode = .simple,
    };
}
