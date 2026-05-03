//! examples to get a rough idea of what the API should look like.
//!
//! also conveniently works as a testing interface.
const std = @import("std");
const clutch = @import("root.zig");

const Position = struct { x: f32, y: f32 };
const Velocity = struct { dx: f32, dy: f32 };
const Health = struct { hp: f32 };
const Armor = struct { defense: f32 };

const Player = struct {};
const Enemy = struct {};
const Dead = struct {};

const Time = struct { delta: f32, elapsed: f32 };
const Gravity = struct { y: f32 };

const CollisionEvent = struct { a: clutch.EntityId, b: clutch.EntityId };
const DamageEvent = struct { target: clutch.EntityId, amount: f32 };

// --- filters ---

test "filter: With" {
    var world = clutch.World.init(std.testing.allocator);
    defer world.deinit();

    const player = try world.spawn(.{
        Position{ .x = 0, .y = 0 },
        Velocity{ .dx = 1, .dy = 0 },
        Player{},
    });
    const enemy = try world.spawn(.{
        Position{ .x = 5, .y = 5 },
        Velocity{ .dx = -1, .dy = 0 },
        Enemy{},
    });
    _ = enemy;

    var query = world.query(.{Position}, .{clutch.With(Player)});
    var count: usize = 0;
    while (query.next()) |view| {
        const pos = view.get(Position);
        try std.testing.expectEqual(player, view.entity);
        try std.testing.expectApproxEqAbs(@as(f32, 0), pos.x, 0.001);
        count += 1;
    }
    try std.testing.expectEqual(@as(usize, 1), count);
}

test "filter: Without" {
    var world = clutch.World.init(std.testing.allocator);
    defer world.deinit();

    _ = try world.spawn(.{ Position{ .x = 0, .y = 0 }, Player{} });
    _ = try world.spawn(.{ Position{ .x = 1, .y = 1 }, Enemy{} });
    _ = try world.spawn(.{ Position{ .x = 2, .y = 2 }, Enemy{} });

    var query = world.query(.{ Position, clutch.Without(Enemy) });
    var count: usize = 0;
    while (query.next()) |_| count += 1;
    try std.testing.expectEqual(@as(usize, 1), count);
}

test "filter: Added" {
    var world = clutch.World.init(std.testing.allocator);
    defer world.deinit();

    const e1 = try world.spawn(.{Position{ .x = 0, .y = 0 }});
    const e2 = try world.spawn(.{Position{ .x = 1, .y = 1 }});

    world.tick();

    try world.addComponent(e1, Health{ .hp = 100 });
    _ = e2;

    var query = world.query(.{clutch.Added(Health)});
    var count: usize = 0;
    while (query.next()) |view| {
        try std.testing.expectEqual(e1, view.entity);
        count += 1;
    }
    try std.testing.expectEqual(@as(usize, 1), count);
}

test "filter: Changed" {
    var world = clutch.World.init(std.testing.allocator);
    defer world.deinit();

    const e1 = try world.spawn(.{Position{ .x = 0, .y = 0 }});
    const e2 = try world.spawn(.{Position{ .x = 5, .y = 5 }});

    world.tick();

    const pos = world.get(e1, Position).?;
    pos.x += 1;
    world.markChanged(e1, Position);

    _ = e2;

    var query = world.query(.{clutch.Changed(Position)});
    var count: usize = 0;
    while (query.next()) |view| {
        try std.testing.expectEqual(e1, view.entity);
        count += 1;
    }
    try std.testing.expectEqual(@as(usize, 1), count);
}

// --- events ---

test "events: send and read" {
    var world = clutch.World.init(std.testing.allocator);
    defer world.deinit();

    const a = try world.spawn(.{Position{ .x = 0, .y = 0 }});
    const b = try world.spawn(.{Position{ .x = 1, .y = 0 }});

    try world.sendEvent(CollisionEvent{ .a = a, .b = b });
    try world.sendEvent(CollisionEvent{ .a = b, .b = a });

    var reader = world.eventReader(CollisionEvent);
    var count: usize = 0;
    while (reader.next()) |ev| {
        try std.testing.expect(ev.a.id != ev.b.id);
        count += 1;
    }
    try std.testing.expectEqual(@as(usize, 2), count);
}

test "events: cleared each tick" {
    var world = clutch.World.init(std.testing.allocator);
    defer world.deinit();

    const a = try world.spawn(.{Position{ .x = 0, .y = 0 }});
    const b = try world.spawn(.{Position{ .x = 1, .y = 0 }});

    try world.sendEvent(CollisionEvent{ .a = a, .b = b });

    world.tick();

    var reader = world.eventReader(CollisionEvent);
    var count: usize = 0;
    while (reader.next()) |_| count += 1;
    try std.testing.expectEqual(@as(usize, 0), count);
}

test "events: multiple event types" {
    var world = clutch.World.init(std.testing.allocator);
    defer world.deinit();

    const e = try world.spawn(.{Health{ .hp = 100 }});

    try world.sendEvent(DamageEvent{ .target = e, .amount = 25 });
    try world.sendEvent(DamageEvent{ .target = e, .amount = 10 });

    var reader = world.eventReader(DamageEvent);
    var total_damage: f32 = 0;
    while (reader.next()) |ev| total_damage += ev.amount;

    try std.testing.expectApproxEqAbs(@as(f32, 35), total_damage, 0.001);
}

// --- hierarchy ---

test "hierarchy: set and get parent" {
    var world = clutch.World.init(std.testing.allocator);
    defer world.deinit();

    const parent = try world.spawn(.{Position{ .x = 0, .y = 0 }});
    const child = try world.spawn(.{Position{ .x = 1, .y = 0 }});

    try world.setParent(child, parent);

    const retrieved = world.getParent(child) orelse return error.NoParent;
    try std.testing.expectEqual(parent, retrieved);
}

test "hierarchy: children iteration" {
    var world = clutch.World.init(std.testing.allocator);
    defer world.deinit();

    const parent = try world.spawn(.{Position{ .x = 0, .y = 0 }});
    const c1 = try world.spawn(.{Position{ .x = 1, .y = 0 }});
    const c2 = try world.spawn(.{Position{ .x = 2, .y = 0 }});
    const c3 = try world.spawn(.{Position{ .x = 3, .y = 0 }});

    try world.setParent(c1, parent);
    try world.setParent(c2, parent);
    try world.setParent(c3, parent);

    var children = world.children(parent);
    var count: usize = 0;
    while (children.next()) |_| count += 1;
    try std.testing.expectEqual(@as(usize, 3), count);
}

test "hierarchy: despawn parent cascades to children" {
    var world = clutch.World.init(std.testing.allocator);
    defer world.deinit();

    const parent = try world.spawn(.{Position{ .x = 0, .y = 0 }});
    const child = try world.spawn(.{Position{ .x = 1, .y = 0 }});
    try world.setParent(child, parent);

    world.despawnRecursive(parent);

    try std.testing.expect(!world.isAlive(parent));
    try std.testing.expect(!world.isAlive(child));
}

test "hierarchy: remove parent" {
    var world = clutch.World.init(std.testing.allocator);
    defer world.deinit();

    const parent = try world.spawn(.{Position{ .x = 0, .y = 0 }});
    const child = try world.spawn(.{Position{ .x = 1, .y = 0 }});

    try world.setParent(child, parent);
    world.removeParent(child);

    try std.testing.expect(world.getParent(child) == null);
}

// --- hooks and observers ---

var hook_add_count: usize = 0;
var hook_remove_count: usize = 0;

fn onHealthAdded(world: *clutch.World, entity: clutch.EntityId) void {
    _ = world;
    _ = entity;
    hook_add_count += 1;
}

fn onHealthRemoved(world: *clutch.World, entity: clutch.EntityId) void {
    _ = world;
    _ = entity;
    hook_remove_count += 1;
}

test "hooks: onAdd fires when component is added" {
    hook_add_count = 0;

    var world = clutch.World.init(std.testing.allocator);
    defer world.deinit();

    world.onAdd(Health, onHealthAdded);

    const e1 = try world.spawn(.{Health{ .hp = 50 }});
    const e2 = try world.spawn(.{Position{ .x = 0, .y = 0 }});
    try world.addComponent(e2, Health{ .hp = 80 });

    _ = e1;
    try std.testing.expectEqual(@as(usize, 2), hook_add_count);
}

test "hooks: onRemove fires when component is removed" {
    hook_remove_count = 0;

    var world = clutch.World.init(std.testing.allocator);
    defer world.deinit();

    world.onRemove(Health, onHealthRemoved);

    const e = try world.spawn(.{Health{ .hp = 100 }});
    world.remove(e, Health);

    try std.testing.expectEqual(@as(usize, 1), hook_remove_count);
}

test "hooks: onRemove fires on despawn" {
    hook_remove_count = 0;

    var world = clutch.World.init(std.testing.allocator);
    defer world.deinit();

    world.onRemove(Health, onHealthRemoved);

    const e = try world.spawn(.{ Health{ .hp = 100 }, Position{ .x = 0, .y = 0 } });
    world.despawn(e);

    try std.testing.expectEqual(@as(usize, 1), hook_remove_count);
}

// --- tags ---

test "tags: zero-size components work as filters" {
    var world = clutch.World.init(std.testing.allocator);
    defer world.deinit();

    _ = try world.spawn(.{ Position{ .x = 0, .y = 0 }, Player{} });
    _ = try world.spawn(.{ Position{ .x = 1, .y = 1 }, Enemy{} });
    _ = try world.spawn(.{ Position{ .x = 2, .y = 2 }, Enemy{}, Dead{} });

    var living_enemies = world.query(.{ Position, clutch.With(Enemy), clutch.Without(Dead) });
    var count: usize = 0;
    while (living_enemies.next()) |_| count += 1;
    try std.testing.expectEqual(@as(usize, 1), count);
}

test "tags: adding a tag to an existing entity" {
    var world = clutch.World.init(std.testing.allocator);
    defer world.deinit();

    const e = try world.spawn(.{Health{ .hp = 0 }});

    try world.addComponent(e, Dead{});
    try std.testing.expect(world.hasComponent(e, Dead));
}

// --- bundles ----

const PlayerBundle = clutch.Bundle(.{
    Position{ .x = 0, .y = 0 },
    Velocity{ .dx = 0, .dy = 0 },
    Health{ .hp = 100 },
    Player{},
});

const EnemyBundle = clutch.Bundle(.{
    Position{ .x = 0, .y = 0 },
    Health{ .hp = 50 },
    Enemy{},
});

test "bundles: spawn with default bundle" {
    var world = clutch.World.init(std.testing.allocator);
    defer world.deinit();

    const p = try world.spawn(PlayerBundle.init());

    try std.testing.expect(world.hasComponent(p, Position));
    try std.testing.expect(world.hasComponent(p, Velocity));
    try std.testing.expect(world.hasComponent(p, Health));
    try std.testing.expect(world.hasComponent(p, Player));
}

test "bundles: spawn with overridden values" {
    var world = clutch.World.init(std.testing.allocator);
    defer world.deinit();

    const p = try world.spawn(PlayerBundle.with(.{
        Position{ .x = 5, .y = 10 },
        Health{ .hp = 200 },
    }));

    const pos = world.get(p, Position).?;
    const hp = world.get(p, Health).?;
    try std.testing.expectApproxEqAbs(@as(f32, 5), pos.x, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 200), hp.hp, 0.001);
}

test "bundles: multiple bundle types" {
    var world = clutch.World.init(std.testing.allocator);
    defer world.deinit();

    _ = try world.spawn(PlayerBundle.init());
    _ = try world.spawn(EnemyBundle.init());
    _ = try world.spawn(EnemyBundle.init());

    var players = world.query(.{clutch.With(Player)});
    var player_count: usize = 0;
    while (players.next()) |_| player_count += 1;

    var enemies = world.query(.{clutch.With(Enemy)});
    var enemy_count: usize = 0;
    while (enemies.next()) |_| enemy_count += 1;

    try std.testing.expectEqual(@as(usize, 1), player_count);
    try std.testing.expectEqual(@as(usize, 2), enemy_count);
}

// --- world utils ---

test "world: entityCount" {
    var world = clutch.World.init(std.testing.allocator);
    defer world.deinit();

    try std.testing.expectEqual(@as(usize, 0), world.entityCount());

    const e1 = try world.spawn(.{Position{ .x = 0, .y = 0 }});
    const e2 = try world.spawn(.{Position{ .x = 1, .y = 0 }});
    try std.testing.expectEqual(@as(usize, 2), world.entityCount());

    world.despawn(e1);
    try std.testing.expectEqual(@as(usize, 1), world.entityCount());

    world.despawn(e2);
    try std.testing.expectEqual(@as(usize, 0), world.entityCount());
}

test "world: hasComponent" {
    var world = clutch.World.init(std.testing.allocator);
    defer world.deinit();

    const e = try world.spawn(.{ Position{ .x = 0, .y = 0 }, Health{ .hp = 100 } });

    try std.testing.expect(world.hasComponent(e, Position));
    try std.testing.expect(world.hasComponent(e, Health));
    try std.testing.expect(!world.hasComponent(e, Velocity));
}

test "world: isAlive" {
    var world = clutch.World.init(std.testing.allocator);
    defer world.deinit();

    const e = try world.spawn(.{Position{ .x = 0, .y = 0 }});
    try std.testing.expect(world.isAlive(e));

    world.despawn(e);
    try std.testing.expect(!world.isAlive(e));
}

test "world: clear removes all entities but keeps resources" {
    var world = clutch.World.init(std.testing.allocator);
    defer world.deinit();

    _ = try world.spawn(.{Position{ .x = 0, .y = 0 }});
    _ = try world.spawn(.{Position{ .x = 1, .y = 0 }});
    try world.insertResource(Time{ .delta = 0.016, .elapsed = 0 });

    world.clear();

    try std.testing.expectEqual(@as(usize, 0), world.entityCount());
    try std.testing.expect(world.getResource(Time) != null);
}

test "world: entity id reuse after despawn" {
    var world = clutch.World.init(std.testing.allocator);
    defer world.deinit();

    const e1 = try world.spawn(.{Position{ .x = 0, .y = 0 }});
    world.despawn(e1);

    const e2 = try world.spawn(.{Position{ .x = 1, .y = 0 }});
    try std.testing.expect(!world.isAlive(e1));
    try std.testing.expect(world.isAlive(e2));
}

// --- schedules ---

fn movementSystem(query: clutch.Query(.{ *Position, Velocity }), time: clutch.Res(Time)) !void {
    var q = query;
    const dt = time.delta;
    while (q.next()) |view| {
        const pos = view.get(Position);
        const vel = view.get(Velocity);
        pos.x += vel.dx * dt;
        pos.y += vel.dy * dt;
    }
}

fn gravitySystem(query: clutch.Query(.{*Velocity}), gravity: clutch.Res(Gravity)) !void {
    var q = query;
    const g = gravity.y;
    while (q.next()) |view| {
        const vel = view.get(Velocity);
        vel.dy += g * 0.016;
    }
}

fn tickTimeSystem(time: clutch.ResMut(Time)) !void {
    time.elapsed += time.delta;
}

test "schedules: basic stage execution" {
    var world = clutch.World.init(std.testing.allocator);
    defer world.deinit();

    try world.insertResource(Time{ .delta = 0.016, .elapsed = 0 });
    try world.insertResource(Gravity{ .y = -9.8 });

    const e = try world.spawn(.{
        Position{ .x = 0, .y = 0 },
        Velocity{ .dx = 5, .dy = 0 },
    });

    const UpdateSchedule = clutch.Schedule(clutch.Stages.Update, .{
        gravitySystem,
        movementSystem,
    });

    world.addSchedule(UpdateSchedule);
    try world.runStage(clutch.Stages.Update);

    const pos = world.get(e, Position).?;
    try std.testing.expect(pos.x > 0); // moved right
    try std.testing.expect(pos.y < 0); // fell due to gravity
}

test "schedules: multiple stages run in order" {
    var world = clutch.World.init(std.testing.allocator);
    defer world.deinit();

    try world.insertResource(Time{ .delta = 0.016, .elapsed = 0 });
    try world.insertResource(Gravity{ .y = -9.8 });

    const PreUpdate = clutch.Schedule(clutch.Stages.PreUpdate, .{
        tickTimeSystem,
    });

    const Update = clutch.Schedule(clutch.Stages.Update, .{
        gravitySystem,
        movementSystem,
    });

    world.addSchedule(PreUpdate);
    world.addSchedule(Update);

    try world.runAll();

    const time = world.getResource(Time).?;
    try std.testing.expectApproxEqAbs(@as(f32, 0.016), time.elapsed, 0.0001);
}

test "schedules: error in system halts chain" {
    var world = clutch.World.init(std.testing.allocator);
    defer world.deinit();

    const FailSystem = struct {
        fn run() !void {
            return error.IntentionalFailure;
        }
    };

    const AfterFail = struct {
        var ran: bool = false;
        fn run() !void {
            ran = true;
        }
    };

    const Sched = clutch.Schedule(clutch.Stages.Update, .{
        FailSystem.run,
        AfterFail.run,
    });

    world.addSchedule(Sched);
    const result = world.runStage(clutch.Stages.Update);

    try std.testing.expectError(error.IntentionalFailure, result);
    try std.testing.expect(!AfterFail.ran); // should not have run
}
