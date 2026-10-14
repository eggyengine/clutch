---
sidebar_position: 3
title: Systems and schedules
---

# Systems and schedules

A **system** is a function. The world fills in its parameters when it runs:

| Parameter | Gets |
| --- | --- |
| `clutch.Query(.{ ... })` | a query over the world |
| `clutch.Res(T)` or `*const T` | resource `T`, read only |
| `clutch.ResMut(T)` or `*T` | resource `T`, read and write |
| `clutch.Commands` | a queue of changes, applied when the system returns |

A system may return an error, which stops the stage and is returned from `runStage`. A missing resource returns `error.ResourceNotFound`.

## Schedules and stages

`clutch.Schedule(stage, .{ systems... })` groups systems for a stage, and `world.addSchedule` registers the group. Its systems run in the order you list them:

```zig
world.addSchedule(clutch.Schedule(.Update, .{ applyInput, move, collide }));
try world.runStage(.Update);
```

The built-in stages are `PreInit`, `Init`, `PostInit`, `PreUpdate`, `Update`, `PostUpdate`, `PreDeinit`, `Deinit` and `PostDeinit`. `world.runAll()` runs all of them in that order. Most programs run the init stages once, the update stages every frame, and the deinit stages on exit.

### Custom stages

A stage can also be named by a string, which you run yourself:

```zig
world.addSchedule(clutch.Schedule("render", .{draw}));
try world.runStage("render");
```

Alternatively, name it by a type and attach it after another stage, so it runs whenever that stage runs:

```zig
const AfterUpdate = struct {
    pub fn schedule() clutch.ScheduleStage {
        return clutch.ScheduleStage.after(.PostUpdate, @This());
    }
};
world.addSchedule(clutch.Schedule(AfterUpdate, .{lateSystem}));
```

## Commands

`Commands` queue changes instead of making them immediately: spawning, despawning, adding and removing components, inserting resources, sending events, and setting parents. They apply in order as soon as the system returns, so the system's own queries never see half-made changes:

```zig
fn spawnBullets(commands: clutch.Commands, guns: clutch.Query(.{*const Gun})) !void {
    var iter = guns;
    while (iter.next()) |view| {
        if (view.get(*const Gun).firing) try commands.spawn(.{ Bullet{}, Position{ .x = 0, .y = 0 } });
    }
}
```

Outside systems, a `clutch.CommandBuffer` does the same: queue changes, then call `apply(&world)`.
