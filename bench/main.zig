//! `zig build bench`: times clutch's common operations on a large world, always in ReleaseFast.
//! Each case runs `runs` times on fresh data; the fastest run is reported, as ns per entity.
const std = @import("std");
const clutch = @import("clutch");

/// Default entity count; `zig build bench -- <count>` overrides it.
const default_entity_count = 100_000;
const runs = 5;

const Position = struct { x: f32 = 0, y: f32 = 0, z: f32 = 0 };
const Velocity = struct { x: f32 = 1, y: f32 = 2, z: f32 = 3 };
const Health = struct { hp: f32 = 100 };
/// On 1% of entities, for queries that should skip almost everything.
const Rare = struct { id: u32 = 0 };

const Case = struct {
    name: []const u8,
    /// Builds the world the timed part needs; not timed.
    setup: *const fn (*clutch.World, []clutch.EntityId) anyerror!void,
    /// The timed part.
    run: *const fn (*clutch.World, []clutch.EntityId) anyerror!void,
};

const cases = [_]Case{
    .{ .name = "spawn (2 components)", .setup = setupNothing, .run = spawnTwo },
    .{ .name = "spawn (2 components, reserved)", .setup = setupReserved, .run = spawnTwo },
    .{ .name = "get", .setup = setupMoving, .run = getEach },
    .{ .name = "query 1 component", .setup = setupMoving, .run = queryOne },
    .{ .name = "query 2 components", .setup = setupMoving, .run = queryTwo },
    .{ .name = "query 1% sparse", .setup = setupSparse, .run = querySparse },
    .{ .name = "add + remove component", .setup = setupMoving, .run = addRemove },
    .{ .name = "add component (cold storage)", .setup = setupMoving, .run = addHealth },
    .{ .name = "add component (warm storage)", .setup = setupWarmHealth, .run = addHealth },
    .{ .name = "add component (reserved)", .setup = setupReservedHealth, .run = addHealth },
    .{ .name = "remove component", .setup = setupWithHealth, .run = removeHealth },
    .{ .name = "markChanged 10% + query Changed", .setup = setupMoving, .run = changedTenth },
    .{ .name = "commands: add component", .setup = setupMoving, .run = commandAdd },
    .{ .name = "despawn", .setup = setupMoving, .run = despawnAll },
};

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    const entity_count = if (args.len > 1) try std.fmt.parseInt(usize, args[1], 10) else default_entity_count;
    const entities = try gpa.alloc(clutch.EntityId, entity_count);
    defer gpa.free(entities);

    std.debug.print("clutch bench: {d} entities, best of {d} runs\n\n", .{ entity_count, runs });
    std.debug.print("{s:<34} {s:>10} {s:>12}\n", .{ "case", "total ms", "ns/entity" });
    for (cases) |case| {
        var best_ns: i96 = std.math.maxInt(i96);
        for (0..runs) |_| {
            var world = clutch.World.init(gpa);
            defer world.deinit();
            try case.setup(&world, entities);
            const start = std.Io.Timestamp.now(init.io, .awake);
            try case.run(&world, entities);
            const elapsed = start.durationTo(std.Io.Timestamp.now(init.io, .awake)).nanoseconds;
            best_ns = @min(best_ns, elapsed);
        }
        const ms = @as(f64, @floatFromInt(best_ns)) / std.time.ns_per_ms;
        const per_entity = @as(f64, @floatFromInt(best_ns)) / @as(f64, @floatFromInt(entity_count));
        std.debug.print("{s:<34} {d:>10.3} {d:>12.1}\n", .{ case.name, ms, per_entity });
    }
}

fn setupNothing(_: *clutch.World, _: []clutch.EntityId) !void {}

/// What a game that knows its size would do up front, as pico_ecs requires.
fn setupReserved(world: *clutch.World, entities: []clutch.EntityId) !void {
    try world.reserveEntities(entities.len);
    try world.reserve(Position, entities.len);
    try world.reserve(Velocity, entities.len);
}

fn setupReservedHealth(world: *clutch.World, entities: []clutch.EntityId) !void {
    try setupMoving(world, entities);
    try world.reserve(Health, entities.len);
}

fn setupMoving(world: *clutch.World, entities: []clutch.EntityId) !void {
    for (entities) |*entity| entity.* = try world.spawn(.{ Position{}, Velocity{} });
    world.tick();
}

fn setupSparse(world: *clutch.World, entities: []clutch.EntityId) !void {
    for (entities, 0..) |*entity, i| {
        entity.* = try world.spawn(.{Position{}});
        if (i % 100 == 0) try world.addComponent(entity.*, Rare{ .id = @intCast(i) });
    }
    world.tick();
}

/// Health's arrays grown to full size, then emptied: adds that never reallocate.
fn setupWarmHealth(world: *clutch.World, entities: []clutch.EntityId) !void {
    try setupMoving(world, entities);
    for (entities) |entity| try world.addComponent(entity, Health{});
    for (entities) |entity| try world.removeComponent(entity, Health);
}

fn setupWithHealth(world: *clutch.World, entities: []clutch.EntityId) !void {
    try setupMoving(world, entities);
    for (entities) |entity| try world.addComponent(entity, Health{});
}

fn addHealth(world: *clutch.World, entities: []clutch.EntityId) !void {
    for (entities) |entity| try world.addComponent(entity, Health{});
}

fn removeHealth(world: *clutch.World, entities: []clutch.EntityId) !void {
    for (entities) |entity| try world.removeComponent(entity, Health);
}

fn spawnTwo(world: *clutch.World, entities: []clutch.EntityId) !void {
    for (entities) |*entity| entity.* = try world.spawn(.{ Position{}, Velocity{} });
}

fn getEach(world: *clutch.World, entities: []clutch.EntityId) !void {
    var sum: f32 = 0;
    for (entities) |entity| sum += world.get(entity, Velocity).?.x;
    std.mem.doNotOptimizeAway(sum);
}

fn queryOne(world: *clutch.World, _: []clutch.EntityId) !void {
    var query = world.query(.{*Position});
    while (query.next()) |view| view.get(*Position).x += 1;
}

fn queryTwo(world: *clutch.World, _: []clutch.EntityId) !void {
    var query = world.query(.{ *Position, *const Velocity });
    while (query.next()) |view| {
        const position = view.get(*Position);
        const velocity = view.get(*const Velocity);
        position.x += velocity.x;
        position.y += velocity.y;
        position.z += velocity.z;
    }
}

fn querySparse(world: *clutch.World, _: []clutch.EntityId) !void {
    var sum: u64 = 0;
    var query = world.query(.{ *const Rare, *const Position });
    while (query.next()) |view| sum += view.get(*const Rare).id;
    std.mem.doNotOptimizeAway(sum);
}

fn addRemove(world: *clutch.World, entities: []clutch.EntityId) !void {
    for (entities) |entity| try world.addComponent(entity, Health{});
    for (entities) |entity| try world.removeComponent(entity, Health);
}

fn changedTenth(world: *clutch.World, entities: []clutch.EntityId) !void {
    for (entities, 0..) |entity, i| if (i % 10 == 0) world.markChanged(entity, Position);
    var count: usize = 0;
    var query = world.query(.{clutch.Changed(Position)});
    while (query.next()) |_| count += 1;
    if (count != (entities.len + 9) / 10) return error.WrongChangedCount;
}

fn commandAdd(world: *clutch.World, entities: []clutch.EntityId) !void {
    var commands = clutch.CommandBuffer.init(world.allocator);
    defer commands.deinit();
    for (entities) |entity| try commands.addComponent(entity, Health{});
    try commands.apply(world);
}

fn despawnAll(world: *clutch.World, entities: []clutch.EntityId) !void {
    for (entities) |entity| world.despawn(entity);
}
