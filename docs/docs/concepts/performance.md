---
sidebar_position: 5
title: Performance
---

# Performance

## How data is stored

Each component type has its own sparse set:

- a **dense** array of values, packed with no gaps, beside the entity that owns each one
- a **sparse** array indexed by entity id, pointing into the dense array

Looking up, adding and removing a component are therefore array operations. A removal moves the last value into the gap, so the dense array stays packed. A query walks the dense array of its smallest required component and checks the others through their sparse arrays.

This makes adding and removing components cheap, which suits an editor that changes entities constantly. The trade-off, compared with archetype-based ECSes such as Flecs, is that queries over several components check each extra component through its sparse array.

## Doing things in bulk

Every single operation finds the component's storage and checks its capacity. The batch versions do that once for the whole batch:

```zig
var bullets: [1000]clutch.EntityId = undefined;
try world.spawnBatch(&bullets, .{ Position{ .x = 0, .y = 0 }, Bullet{} });

try world.addComponents(&bullets, Velocity{ .dx = 10, .dy = 0 });
try world.removeComponents(bullets[0..500], Velocity);
try world.despawnBatch(&bullets);
```

`addComponents` and `removeComponents` check every entity first and change nothing if one is dead. `despawnBatch` skips dead entities and repeats. When add or remove hooks are registered (and, for `despawnBatch`, when entities have parents), the batch versions fall back to one-by-one work so those still behave correctly.

## Reserving memory

If you know how big a world will get, reserve it up front, so adding entities never reallocates mid-frame:

```zig
try world.reserveEntities(100_000);
try world.reserve(Position, 100_000);
```

## Measuring

`zig build bench` times common operations on 100,000 entities in ReleaseFast. `zig build bench -- 2000000` uses 2 million. These are results from one desktop machine (best of five runs, nanoseconds per entity). Run the benchmark on your own hardware before relying on them:

| Operation | ns per entity |
| --- | --- |
| Query over 1 component | 1.0 |
| Query over 2 components | 3 |
| `get` | 1.6 |
| Add a component (storage already grown) | 8 |
| Remove a component | 6 |
| `spawnBatch`, 2 components | 30 |
| `addComponents` + `removeComponents`, untracked component | 12 |
| `despawnBatch` | 10 |
