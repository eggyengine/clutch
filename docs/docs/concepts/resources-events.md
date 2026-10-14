---
sidebar_position: 4
title: Resources, events and hierarchy
---

# Resources, events and hierarchy

## Resources

A resource is one value of a type, shared by the whole world: time, settings, input state. Inserting a resource of a type the world already has replaces it:

```zig
try world.insertResource(Gravity{ .y = -9.81 });
const gravity = world.getResource(Gravity).?; // *Gravity, or null if there is none
```

Systems take a resource as `clutch.Res(T)` (read only) or `clutch.ResMut(T)` (read and write).

## Events

Events are messages sent during a tick. They're cleared when the tick ends:

```zig
try world.sendEvent(Damage{ .target = enemy, .amount = 25 });

var reader = world.eventReader(Damage);
while (reader.next()) |damage| { ... } // *const Damage
```

## Hierarchy

Entities can have a parent and children:

```zig
try world.setParent(child, parent);              // one child
try world.setParent(parent, .{ first, second }); // or several at once

const p = world.getParent(child);                // ?EntityId
var iter = world.children(parent);
while (iter.next()) |c| { ... }

world.despawnRecursive(parent);                  // the parent and everything below it
```

Making an entity its own ancestor returns `error.InvalidHierarchy`.

## Hooks

Hooks run when a component type is added to or removed from an entity, including on despawn:

```zig
world.onAdd(Health, struct {
    fn run(w: *clutch.World, entity: clutch.EntityId) void { ... }
}.run);
```
