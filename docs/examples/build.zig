//! Builds the guide's full program from src/ (written there by check.sh).
const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const clutch = b.dependency("clutch", .{ .target = target, .optimize = optimize });
    const exe = b.addExecutable(.{
        .name = "example",
        .root_module = b.createModule(.{ .root_source_file = b.path("src/main.zig"), .target = target, .optimize = optimize }),
    });
    exe.root_module.addImport("clutch", clutch.module("clutch"));
    b.installArtifact(exe);
    // Run it too: the guides show what the program prints.
    b.getInstallStep().dependOn(&b.addRunArtifact(exe).step);
}
