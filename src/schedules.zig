const std = @import("std");
const World = @import("world.zig").World;

pub const Stages = enum {
    PreUpdate,
    Update,
    PostUpdate,
};

pub fn Schedule(comptime stage_value: Stages, comptime systems: anytype) type {
    return struct {
        pub const stage = stage_value;

        pub fn run(world: *World) !void {
            inline for (systems) |system| {
                try runSystem(world, system);
            }
        }
    };
}

fn runSystem(world: *World, comptime system: anytype) !void {
    const info = @typeInfo(@TypeOf(system)).@"fn";
    if (info.params.len == 0) {
        try system();
        return;
    }

    try runSystemWithArgs(world, system, info.params);
}

fn runSystemWithArgs(world: *World, comptime system: anytype, comptime params: []const std.builtin.Type.Fn.Param) !void {
    _ = params;
    _ = world;
    _ = system;
    @compileError("systems with arguments are not supported yet");
}
