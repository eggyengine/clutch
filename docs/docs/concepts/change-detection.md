---
sidebar_position: 2
title: Change detection
---

# Change detection

The world counts frames in **ticks**. `world.tick()` ends one tick and starts the next. Three query filters look at what happened during the current tick:

| Filter | Matches entities that, this tick... |
| --- | --- |
| `Added(T)` | were given a `T` they didn't have before |
| `Changed(T)` | had their `T` replaced with `addComponent`, or marked with `markChanged` |
| `Removed(T)` | lost their `T` and are still alive |

```zig
try world.addComponent(player, Health{ .hp = 100 });

var fresh = world.query(.{clutch.Added(Health)});
while (fresh.next()) |view| { ... } // visits `player`

world.tick(); // next tick: `player` no longer matches Added(Health)
```

The single-entity versions are `wasAdded`, `wasChanged` and `wasRemoved`.

## Marking changes

Clutch doesn't notice writes made through pointers. After changing a component through `get` or `view.get`, call `markChanged` if anything filters on `Changed`:

```zig
world.get(player, Health).?.hp -= 10;
world.markChanged(player, Health);
```

Despawned entities never match `Removed`. Neither does a new entity that reuses a despawned entity's id.

## Opting out

Tracking costs a little memory and time on every add and remove. Components that nothing filters on can opt out:

```zig
const Particle = struct {
    pub const track_changes = false;
    life: f32,
};
```

Adding and removing such a component is about 20% faster. Using `Added`, `Changed`, `Removed` or `markChanged` with it becomes a compile error that names the reason.
