---
sidebar_position: 1
title: Queries
---

# Queries

A query visits every entity that has a set of components. Build one from a tuple of **terms**:

```zig
var query = world.query(.{ *Position, *const Velocity });
while (query.next()) |view| {
    view.get(*Position).x += view.get(*const Velocity).dx;
}
```

`view.entity` is the current entity, and `view.get(*T)` or `view.get(*const T)` returns a pointer to one of its components.

## Terms

| Term | Matches entities that... | Access |
| --- | --- | --- |
| `*T` | have a `T` | read and write |
| `*const T` | have a `T` | read only |
| `clutch.With(T)` | have a `T` | none |
| `clutch.Without(T)` | don't have a `T` | none |
| `clutch.Added(T)` | were given a `T` this tick | none |
| `clutch.Changed(T)` | had their `T` changed this tick | none |
| `clutch.Removed(T)` | lost their `T` this tick | none |

Every term must hold for an entity to match. The last three are covered in [Change detection](./change-detection.md).

## Order and changes during a query

A query walks the packed entries of the smallest component storage that every match must have. That's why a query for a rare component costs almost nothing, even in a huge world. The order of the visits is unspecified, so don't rely on it.

You may despawn the current entity, or add and remove its components, while a query runs. The query still visits every other entity exactly once. Pointers you got from `view.get` stop being valid once that component's storage changes, so take them again after a change instead of keeping them.

## Queries in systems

A system takes a query as a parameter, and the world builds it before the system runs:

```zig
fn move(query: clutch.Query(.{ *Position, *const Velocity })) !void {
    var iter = query;
    while (iter.next()) |view| { ... }
}
```

Two parameters that both write the same component, or a write and a read of it, are a compile error, so a system can't alias its own data.
