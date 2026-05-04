# clutch

clutch is an ecs system (named after a group of eggs) written in Zig, and inspired by bevy_ecs

## add to project
requires zig `0.16.0`

to use this with the zig build system, import as so:
```bash
zig fetch --save git+https://github.com/eggyengine/clutch
```

and then in `build.zig`:
```zig
const clutch = b.dependency("clutch", .{
    .target = target,
    .optimize = optimize,
});

exe.root_module.addImport("clutch", clutch.module("clutch"));
```

and lastly in your library/executable:
```zig
const clutch = @import("clutch");
```

## usage

at its simplest:
```zig
const std = @import("std");
const clutch = @import("clutch");

const Position = struct { x: f32, y: f32 };
const Velocity = struct { dx: f32, dy: f32 };
const Player = struct {};
const Gravity = struct { y: f32 };

// example provided in test "basics"
pub fn main(init: std.process.Init) !void {
    const world = clutch.World.init(init.gpa);
    defer world.deinit();

    const launch_angle: f32 = std.math.pi / 4.0;
    // spawn your entity here
    const player = try world.spawn(.{
        Position{ .x = 0, .y = 0 },
        Gravity{ .y = -9.81 },
        Velocity{ .dx = 10 * @cos(launch_angle), .dy = 10 * @sin(launch_angle) },
        Player{},
    });

    // then create a query
    var query = world.query(.{ *Position, *Velocity, *const Gravity }); // gravity cannot be mutated
    while (query.next()) |view| { // iterate through all entities
        const pos = view.get(*Position);
        const vel = view.get(*Velocity);
        const gravity = view.get(*const Gravity);

        // mutate or do whatever you wish
        vel.dy += gravity.y;
        pos.x += vel.dx;
        pos.y += vel.dy;
    }

    const pos = world.get(player, Position).?;
    try std.testing.expect(pos.x > 0);
    try std.testing.expect(pos.y < 0);
}
```
