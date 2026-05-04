const std = @import("std");
const World = @import("world.zig").World;

pub const Stages = enum(u8) {
    PreInit,
    Init,
    PostInit,
    PreDeinit,
    Deinit,
    PostDeinit,
    PreUpdate,
    Update,
    PostUpdate,
};

pub const primary_order = [_]Stages{
    .PreInit,
    .Init,
    .PostInit,
    .PreUpdate,
    .Update,
    .PostUpdate,
    .PreDeinit,
    .Deinit,
    .PostDeinit,
};

pub const ScheduleStage = struct {
    id: u64,
    parent_id: ?u64 = null,

    pub fn primary(primary_stage: Stages) ScheduleStage {
        return .{ .id = @intFromEnum(primary_stage) };
    }

    pub fn custom(comptime label: []const u8) ScheduleStage {
        return .{ .id = customId(label) };
    }

    pub fn customType(comptime T: type) ScheduleStage {
        return custom(@typeName(T));
    }

    pub fn after(comptime parent_stage: anytype, comptime T: type) ScheduleStage {
        const parent = stage(parent_stage);
        return .{
            .id = customId(@typeName(T)),
            .parent_id = parent.id,
        };
    }
};

pub const Stage = ScheduleStage;

pub fn stage(comptime value: anytype) ScheduleStage {
    const T = @TypeOf(value);

    if (T == ScheduleStage) return value;
    if (T == Stages) return ScheduleStage.primary(value);
    if (T == type) {
        if (!@hasDecl(value, "schedule")) {
            @compileError("custom schedule labels must define `pub fn schedule() clutch.ScheduleStage`");
        }
        return value.schedule();
    }

    switch (@typeInfo(T)) {
        .@"enum" => return ScheduleStage.primary(value),
        .@"enum_literal" => return ScheduleStage.primary(@field(Stages, @tagName(value))),
        .pointer => |pointer| {
            if (pointer.size == .slice and pointer.child == u8) {
                return ScheduleStage.custom(value);
            }
            if (pointer.size == .one) {
                switch (@typeInfo(pointer.child)) {
                    .array => |array| {
                        if (array.child == u8) return ScheduleStage.custom(value[0..]);
                    },
                    else => {},
                }
            }
        },
        .array => |array| {
            if (array.child == u8) {
                return ScheduleStage.custom(value[0..]);
            }
        },
        else => {},
    }

    @compileError("schedule stage must be a clutch.Stages value, enum literal, string label, custom label type, or clutch.ScheduleStage");
}

fn customId(comptime label: []const u8) u64 {
    return (@as(u64, 1) << 63) | (std.hash.Wyhash.hash(0, label) & (std.math.maxInt(u64) >> 1));
}

pub fn Schedule(comptime schedule_stage: anytype, comptime systems: anytype) type {
    return struct {
        pub const stage_value = stage(schedule_stage);

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

test "primary schedules run in lifecycle order" {
    const State = struct {
        var index: usize = 0;
        var order: [9]Stages = undefined;

        fn record(primary_stage: Stages) void {
            order[index] = primary_stage;
            index += 1;
        }

        fn preInit() !void {
            record(.PreInit);
        }

        fn init() !void {
            record(.Init);
        }

        fn postInit() !void {
            record(.PostInit);
        }

        fn preUpdate() !void {
            record(.PreUpdate);
        }

        fn update() !void {
            record(.Update);
        }

        fn postUpdate() !void {
            record(.PostUpdate);
        }

        fn preDeinit() !void {
            record(.PreDeinit);
        }

        fn deinit() !void {
            record(.Deinit);
        }

        fn postDeinit() !void {
            record(.PostDeinit);
        }
    };

    var world = World.init(std.testing.allocator);
    defer world.deinit();

    world.addSchedule(Schedule(.PreInit, .{State.preInit}));
    world.addSchedule(Schedule(.Init, .{State.init}));
    world.addSchedule(Schedule(.PostInit, .{State.postInit}));
    world.addSchedule(Schedule(.PreUpdate, .{State.preUpdate}));
    world.addSchedule(Schedule(.Update, .{State.update}));
    world.addSchedule(Schedule(.PostUpdate, .{State.postUpdate}));
    world.addSchedule(Schedule(.PreDeinit, .{State.preDeinit}));
    world.addSchedule(Schedule(.Deinit, .{State.deinit}));
    world.addSchedule(Schedule(.PostDeinit, .{State.postDeinit}));

    try world.runAll();

    try std.testing.expectEqualSlices(Stages, &primary_order, &State.order);
}

test "custom schedules can be registered and run by label" {
    const State = struct {
        var ran: bool = false;

        fn custom() !void {
            ran = true;
        }
    };

    var world = World.init(std.testing.allocator);
    defer world.deinit();

    world.addSchedule(Schedule("render", .{State.custom}));
    try world.runStage("render");

    try std.testing.expect(State.ran);
}

test "custom schedule label attaches after primary parent" {
    const AfterUpdate = struct {
        const Self = @This();

        pub fn schedule() ScheduleStage {
            return ScheduleStage.after(.PostUpdate, Self);
        }
    };

    const State = struct {
        var index: usize = 0;
        var order: [2]u8 = undefined;

        fn postUpdate() !void {
            order[index] = 1;
            index += 1;
        }

        fn afterUpdate() !void {
            order[index] = 2;
            index += 1;
        }
    };

    var world = World.init(std.testing.allocator);
    defer world.deinit();

    world.addSchedule(Schedule(.PostUpdate, .{State.postUpdate}));
    world.addSchedule(Schedule(AfterUpdate, .{State.afterUpdate}));

    try world.runAll();

    try std.testing.expectEqualSlices(u8, &.{ 1, 2 }, &State.order);
}
