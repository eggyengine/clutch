const std = @import("std");

/// Specifies the type of filter.
///
/// Linked to `isWith`, `isWithout` and other util functions
pub const FilterKind = enum {
    with,
    without,
    added,
    changed,
};

// --- With ---

/// A filter that requires the component `T` to be present without querying for the data.
///
/// # Example
/// ```zig
/// var world = clutch.World.init(std.heap.page_allocator);
/// defer world.deinit();
///
/// const player = try world.spawn(.{
///     Position{ .x = 0, .y = 0 },
///     Velocity{ .dx = 1, .dy = 0 },
///     Player{},
/// });
/// const enemy = try world.spawn(.{
///     Position{ .x = 5, .y = 5 },
///     Velocity{ .dx = -1, .dy = 0 },
///     Enemy{},
/// });
/// _ = enemy;
///
/// // Queries the Position component that also contains the Player component
/// var query = world.query(.{ Position, clutch.With(Player) });
/// var count: usize = 0;
/// while (query.next()) |view| {
///     const pos = view.get(Position);
///     try std.testing.expectEqual(player, view.entity);
///     try std.testing.expectApproxEqAbs(@as(f32, 0), pos.x, 0.001);
///     count += 1;
/// }
/// try std.testing.expectEqual(@as(usize, 1), count);
/// ```
pub fn With(comptime T: type) type {
    return struct {
        pub const kind: FilterKind = .with;
        pub const component = T;
    };
}

pub fn isWith(comptime Term: type) bool {
    return @hasDecl(Term, "kind") and Term.kind == .with;
}

test "isWith filter works" {
    const Player = struct {};
    const filter = With(Player);
    try std.testing.expect(isWith(filter));
}

// --- Without ---

/// A filter that requires the component `T` to be absent without querying for the data.
///
/// # Example
/// ```zig
/// var world = clutch.World.init(std.heap.page_allocator);
/// defer world.deinit();
///
/// _ = try world.spawn(.{ Position{ .x = 0, .y = 0 }, Player{} });
/// _ = try world.spawn(.{ Position{ .x = 1, .y = 1 }, Enemy{} });
/// _ = try world.spawn(.{ Position{ .x = 2, .y = 2 }, Enemy{} });
///
/// // Query for entities with Position but not Enemy
/// var query = world.query(.{ Position, clutch.Without(Enemy) });
/// var count: usize = 0;
/// while (query.next()) |_| count += 1;
/// // Only one entity is returned
/// try std.testing.expectEqual(@as(usize, 1), count);
/// ```
pub fn Without(comptime T: type) type {
    return struct {
        pub const kind: FilterKind = .without;
        pub const component = T;
    };
}

pub fn isWithout(comptime Term: type) bool {
    return @hasDecl(Term, "kind") and Term.kind == .without;
}

test "isWithout filter works" {
    const Player = struct {};
    const filter = Without(Player);
    try std.testing.expect(isWithout(filter));
}

// --- Added ---

/// A filter that requires the component `T` to have been added during the current tick.
///
/// This is useful for systems that should react only when a component first appears on an
/// entity, instead of every tick where the component is present.
///
/// # Example
/// ```zig
/// const e1 = try world.spawn(.{Position{ .x = 0, .y = 0 }});
/// const e2 = try world.spawn(.{Position{ .x = 1, .y = 1 }});
///
/// world.tick();
///
/// try world.addComponent(e1, Health{ .hp = 100 });
/// _ = e2;
///
/// // Query for entities where Health was added this tick
/// var query = world.query(.{clutch.Added(Health)});
/// var count: usize = 0;
/// while (query.next()) |view| {
///     try std.testing.expectEqual(e1, view.entity);
///     count += 1;
/// }
/// try std.testing.expectEqual(@as(usize, 1), count);
/// ```
pub fn Added(comptime T: type) type {
    return struct {
        pub const kind: FilterKind = .added;
        pub const component = T;
    };
}

pub fn isAdded(comptime Term: type) bool {
    return @hasDecl(Term, "kind") and Term.kind == .added;
}

test "isAdded filter works" {
    const Health = struct {};
    const filter = Added(Health);
    try std.testing.expect(isAdded(filter));
}

// --- Changed ---

/// A filter that requires the component `T` to have been changed during the current tick.
///
/// The ECS cannot reliably detect direct pointer mutation by itself, so code that mutates a
/// component through `world.get` should call `world.markChanged(entity, T)` afterward.
///
/// # Example
/// ```zig
/// const e1 = try world.spawn(.{Position{ .x = 0, .y = 0 }});
/// const e2 = try world.spawn(.{Position{ .x = 5, .y = 5 }});
///
/// world.tick();
///
/// const pos = world.get(e1, Position).?;
/// pos.x += 1;
/// world.markChanged(e1, Position);
///
/// _ = e2;
///
/// // Query for entities where Position changed this tick
/// var query = world.query(.{clutch.Changed(Position)});
/// var count: usize = 0;
/// while (query.next()) |view| {
///     try std.testing.expectEqual(e1, view.entity);
///     count += 1;
/// }
/// try std.testing.expectEqual(@as(usize, 1), count);
/// ```
pub fn Changed(comptime T: type) type {
    return struct {
        pub const kind: FilterKind = .changed;
        pub const component = T;
    };
}

pub fn isChanged(comptime Term: type) bool {
    return @hasDecl(Term, "kind") and Term.kind == .changed;
}

test "isChanged filter works" {
    const Position = struct {};
    const filter = Changed(Position);
    try std.testing.expect(isChanged(filter));
}
