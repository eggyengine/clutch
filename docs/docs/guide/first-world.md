---
sidebar_position: 1
title: Your first world
---

# Your first world

This guide builds a small simulation: a few entities with positions and velocities, a system that moves them every frame, and a system that despawns the ones that leave the screen. It touches each part of clutch you use day to day. The full program is shown at the end.

It assumes you have added the `clutch` module as described in [Getting started](../getting-started.md).

## 1. Components

A component is any Zig type. Plain structs are the usual choice:

```zig
const Position = struct { x: f32, y: f32 };
const Velocity = struct { dx: f32, dy: f32 };
```

## 2. A world and some entities

The `World` owns every entity and component. `spawn` creates an entity with the components you pass as a tuple, and returns its `EntityId`:

```zig
var world = clutch.World.init(gpa);
defer world.deinit();

const ball = try world.spawn(.{
    Position{ .x = 0, .y = 0 },
    Velocity{ .dx = 3, .dy = 1 },
});
```

You can read or change a single entity's component with `get`, which returns `null` if the entity doesn't have it:

```zig
world.get(ball, Position).?.y = 5;
```

## 3. A system

A system is a function. Its parameters say what it needs, and the world fills them in when it runs: a `Query` for components, a pointer for a resource, `Commands` for changes that must wait until the system finishes.

This one moves everything that has both a `Position` and a `Velocity`. `*Position` asks for write access and `*const Velocity` for read-only access:

```zig
const Time = struct { delta: f32 };

fn move(query: clutch.Query(.{ *Position, *const Velocity }), time: clutch.Res(Time)) !void {
    var iter = query;
    while (iter.next()) |view| {
        const position = view.get(*Position);
        const velocity = view.get(*const Velocity);
        position.x += velocity.dx * time.delta;
        position.y += velocity.dy * time.delta;
    }
}
```

`Time` is a **resource**: one value for the whole world. Insert it before the system runs:

```zig
try world.insertResource(Time{ .delta = 1 });
```

## 4. Changing the world from a system

Despawning an entity while a query walks its storage is allowed, but most systems queue changes with `Commands` instead. They apply as soon as the system returns:

```zig
fn despawnOffscreen(commands: clutch.Commands, query: clutch.Query(.{*const Position})) !void {
    var iter = query;
    while (iter.next()) |view| {
        if (view.get(*const Position).x > 10) try commands.despawn(view.entity);
    }
}
```

## 5. Schedules

A schedule puts systems in a stage. The built-in stages run in a fixed order: the init stages, then `PreUpdate`, `Update` and `PostUpdate`, then the deinit stages. Run one with `runStage`:

```zig
world.addSchedule(clutch.Schedule(.Update, .{ move, despawnOffscreen }));

for (0..5) |_| {
    try world.runStage(.Update);
    world.tick();
}
```

`tick` ends a frame. It resets the change filters (`Added`, `Changed`, `Removed`) and clears the frame's events. See [Change detection](../concepts/change-detection.md).

## The full program

```zig title="src/main.zig"
const std = @import("std");
const clutch = @import("clutch");

const Position = struct { x: f32, y: f32 };
const Velocity = struct { dx: f32, dy: f32 };
const Time = struct { delta: f32 };

fn move(query: clutch.Query(.{ *Position, *const Velocity }), time: clutch.Res(Time)) !void {
    var iter = query;
    while (iter.next()) |view| {
        const position = view.get(*Position);
        const velocity = view.get(*const Velocity);
        position.x += velocity.dx * time.delta;
        position.y += velocity.dy * time.delta;
    }
}

fn despawnOffscreen(commands: clutch.Commands, query: clutch.Query(.{*const Position})) !void {
    var iter = query;
    while (iter.next()) |view| {
        if (view.get(*const Position).x > 10) try commands.despawn(view.entity);
    }
}

pub fn main(init: std.process.Init) !void {
    var world = clutch.World.init(init.gpa);
    defer world.deinit();

    const ball = try world.spawn(.{ Position{ .x = 0, .y = 0 }, Velocity{ .dx = 3, .dy = 1 } });
    _ = try world.spawn(.{ Position{ .x = 0, .y = 0 }, Velocity{ .dx = 1, .dy = 0 } });
    world.get(ball, Position).?.y = 5;

    try world.insertResource(Time{ .delta = 1 });
    world.addSchedule(clutch.Schedule(.Update, .{ move, despawnOffscreen }));

    for (0..5) |frame| {
        try world.runStage(.Update);
        world.tick();
        std.debug.print("frame {d}: {d} entities\n", .{ frame, world.entityCount() });
    }
}
```

It prints one line per frame. The fast ball passes `x = 10` on frame 3 and is despawned, leaving one entity:

```
frame 0: 2 entities
frame 1: 2 entities
frame 2: 2 entities
frame 3: 1 entities
frame 4: 1 entities
```
