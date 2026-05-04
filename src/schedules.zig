const std = @import("std");
const world_mod = @import("world.zig");
const EntityId = @import("entity.zig").EntityId;
const Query = world_mod.Query;
const World = world_mod.World;
const command = @import("command.zig");

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

/// Converts all valid schedule values to a `ScheduleStage`.
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
        .enum_literal => return ScheduleStage.primary(@field(Stages, @tagName(value))),
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
    comptime validateSystemAccess(info.params);

    try runSystemWithArgs(world, system, info.params);
}

fn runSystemWithArgs(world: *World, comptime system: anytype, comptime params: []const std.builtin.Type.Fn.Param) !void {
    const needs_commands = comptime systemHasCommandsParam(params);
    var command_buffer: command.CommandBuffer = undefined;
    if (needs_commands) {
        command_buffer = command.CommandBuffer.init(world.allocator);
    }
    defer if (needs_commands) command_buffer.deinit();

    const ArgTypes = comptime blk: {
        var types: [params.len]type = undefined;
        for (params, 0..) |param, i| {
            types[i] = param.type orelse @compileError("system arguments must have concrete types");
        }
        break :blk types;
    };

    var args: std.meta.Tuple(&ArgTypes) = undefined;
    inline for (params, 0..) |param, i| {
        args[i] = try systemArg(world, if (needs_commands) &command_buffer else null, param.type.?);
    }

    try @call(.auto, system, args);

    if (needs_commands) {
        try command_buffer.apply(world);
    }
}

fn systemArg(world: *World, command_buffer: ?*command.CommandBuffer, comptime Param: type) !Param {
    if (comptime isCommandsParam(Param)) {
        return command.Commands.init(command_buffer.?);
    }

    switch (@typeInfo(Param)) {
        .@"struct", .@"enum", .@"union", .@"opaque" => {
            if (@hasDecl(Param, "is_query") and Param.is_query) {
                return Param.init(world);
            }
        },
        else => {},
    }

    switch (@typeInfo(Param)) {
        .pointer => |pointer| {
            if (pointer.size != .one) {
                @compileError("system pointer arguments must be resources of type *T or *const T");
            }

            return world.getResource(pointer.child) orelse error.ResourceNotFound;
        },
        else => @compileError("system arguments must be Query(...), Res(T), ResMut(T), or Commands"),
    }
}

fn systemHasCommandsParam(comptime params: []const std.builtin.Type.Fn.Param) bool {
    for (params) |param| {
        if (isCommandsParam(param.type.?)) return true;
    }
    return false;
}

fn isCommandsParam(comptime Param: type) bool {
    return switch (@typeInfo(Param)) {
        .@"struct", .@"enum", .@"union", .@"opaque" => @hasDecl(Param, "is_commands") and Param.is_commands,
        else => false,
    };
}

fn validateSystemAccess(comptime params: []const std.builtin.Type.Fn.Param) void {
    inline for (params, 0..) |left, left_index| {
        const Left = left.type.?;
        validateParamSelfAccess(Left);

        inline for (params[0..left_index]) |right| {
            validateParamPairAccess(Left, right.type.?);
        }
    }
}

fn validateParamSelfAccess(comptime Param: type) void {
    if (!isQueryType(Param)) return;

    inline for (Param.query_terms, 0..) |left, left_index| {
        inline for (Param.query_terms, 0..) |right, right_index| {
            if (right_index < left_index) {
                validateQueryTermPairAccess(left, right);
            }
        }
    }
}

fn validateParamPairAccess(comptime Left: type, comptime Right: type) void {
    if (comptime isQueryType(Left) and isQueryType(Right)) {
        inline for (Left.query_terms) |left_term| {
            inline for (Right.query_terms) |right_term| {
                validateQueryTermPairAccess(left_term, right_term);
            }
        }
        return;
    }

    if (comptime isResourceParam(Left) and isResourceParam(Right)) {
        validateResourcePairAccess(Left, Right);
    }
}

fn validateQueryTermPairAccess(comptime Left: type, comptime Right: type) void {
    if (!isQueryPointerTerm(Left) or !isQueryPointerTerm(Right)) return;

    const LeftComponent = queryComponentType(Left);
    const RightComponent = queryComponentType(Right);
    if (LeftComponent != RightComponent) return;
    if (isConstPointer(Left) and isConstPointer(Right)) return;

    @compileError("system has conflicting query access to component `" ++ @typeName(LeftComponent) ++ "`");
}

fn validateResourcePairAccess(comptime Left: type, comptime Right: type) void {
    const LeftResource = pointerChild(Left);
    const RightResource = pointerChild(Right);
    if (LeftResource != RightResource) return;
    if (isConstPointer(Left) and isConstPointer(Right)) return;

    @compileError("system has conflicting resource access to `" ++ @typeName(LeftResource) ++ "`");
}

fn isQueryType(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        .@"struct", .@"enum", .@"union", .@"opaque" => @hasDecl(T, "is_query") and T.is_query,
        else => false,
    };
}

fn isResourceParam(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        .pointer => |pointer| pointer.size == .one,
        else => false,
    };
}

fn isQueryPointerTerm(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        .pointer => |pointer| pointer.size == .one,
        else => false,
    };
}

fn queryComponentType(comptime T: type) type {
    return pointerChild(T);
}

fn pointerChild(comptime T: type) type {
    return switch (@typeInfo(T)) {
        .pointer => |pointer| pointer.child,
        else => @compileError("expected pointer type"),
    };
}

fn isConstPointer(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        .pointer => |pointer| pointer.is_const,
        else => false,
    };
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

test "systems support more than four arguments" {
    const A = struct { value: u8 };
    const B = struct { value: u8 };
    const C = struct { value: u8 };
    const D = struct { value: u8 };
    const E = struct { value: u8 };

    const State = struct {
        var sum: u8 = 0;

        fn update(a: *const A, b: *const B, c: *const C, d: *const D, e: *const E) !void {
            sum = a.value + b.value + c.value + d.value + e.value;
        }
    };

    var world = World.init(std.testing.allocator);
    defer world.deinit();

    try world.insertResource(A{ .value = 1 });
    try world.insertResource(B{ .value = 2 });
    try world.insertResource(C{ .value = 3 });
    try world.insertResource(D{ .value = 4 });
    try world.insertResource(E{ .value = 5 });

    world.addSchedule(Schedule(.Update, .{State.update}));
    try world.runStage(.Update);

    try std.testing.expectEqual(15, State.sum);
}

test "systems can defer mutations with commands" {
    const Position = struct { x: i32, y: i32 };
    const Velocity = struct { x: i32, y: i32 };

    const State = struct {
        var entity: EntityId = undefined;

        fn update(commands: command.Commands, query: Query(.{*const Position})) !void {
            var iter = query;
            const view = iter.next().?;
            entity = view.entity;

            try commands.addComponent(view.entity, Velocity{ .x = 1, .y = 2 });
            try std.testing.expect(view.world.get(view.entity, Velocity) == null);
        }
    };

    var world = World.init(std.testing.allocator);
    defer world.deinit();

    const entity = try world.spawn(.{Position{ .x = 3, .y = 4 }});

    world.addSchedule(Schedule(.Update, .{State.update}));
    try world.runStage(.Update);

    try std.testing.expect(EntityId.eql(entity, State.entity));
    try std.testing.expect(world.hasComponent(entity, Velocity));
}
