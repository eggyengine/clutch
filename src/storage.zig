const std = @import("std");
const entity_mod = @import("entity.zig");
const EntityId = entity_mod.EntityId;

/// A change tick: the world's frame counter. 0 means "never"; the world starts at 1.
// shortcut: u32 halves the tick arrays; after 2^32 ticks (over 2 years at 60 fps) a value left
// untouched that whole time could read as added or changed again. Use u64 if worlds live that long.
pub const Tick = u32;

/// Marks an entity id with no value in a `ComponentStorage`.
const absent = std.math.maxInt(u32);

/// A sparse set holding one component type, as EnTT and pico_ecs store them.
///
/// The dense arrays `entities`, `values`, `added_ticks` and `changed_ticks` are kept in
/// lockstep and stay packed: `entities.items[i]` owns `values.items[i]`. `sparse`, indexed by
/// entity id, holds each entity's dense index (or `absent`), so every lookup is an array read.
pub fn ComponentStorage(comptime T: type) type {
    return struct {
        const Self = @This();

        entities: std.ArrayList(EntityId) = .empty,
        values: std.ArrayList(T) = .empty,
        /// The tick each value was added on.
        added_ticks: std.ArrayList(Tick) = .empty,
        /// The tick each value last changed on (0 if never since it was added).
        changed_ticks: std.ArrayList(Tick) = .empty,
        /// Entity id -> dense index, or `absent`.
        sparse: std.ArrayList(u32) = .empty,
        /// Entity id -> the tick its value was last removed on, or 0.
        removed_ticks: std.ArrayList(Tick) = .empty,

        pub fn init(allocator: std.mem.Allocator) Self {
            _ = allocator;
            return .{};
        }

        pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
            self.entities.deinit(allocator);
            self.values.deinit(allocator);
            self.added_ticks.deinit(allocator);
            self.changed_ticks.deinit(allocator);
            self.sparse.deinit(allocator);
            self.removed_ticks.deinit(allocator);
        }

        /// Add a value for `entity`, or replace (and mark changed) the value it already has.
        pub fn add(self: *Self, allocator: std.mem.Allocator, entity: EntityId, value: T, tick: Tick) !void {
            _ = try self.insert(allocator, entity, value, tick);
        }

        /// `add`, returning whether `entity` had no value before (so on-add hooks should run).
        pub fn insert(self: *Self, allocator: std.mem.Allocator, entity: EntityId, value: T, tick: Tick) !bool {
            if (self.denseIndex(entity)) |index| {
                self.values.items[index] = value;
                self.changed_ticks.items[index] = tick;
                return false;
            }

            // Common case: one compare each. The growth paths are out of line.
            if (entity.id >= self.sparse.items.len) try self.growSparseTo(allocator, entity.id);
            if (self.entities.items.len == self.entities.capacity) try self.growDense(allocator);

            const index = self.entities.items.len;
            self.sparse.items[entity.id] = @intCast(index);
            self.entities.items.len += 1;
            self.values.items.len += 1;
            self.added_ticks.items.len += 1;
            self.changed_ticks.items.len += 1;
            self.entities.items[index] = entity;
            self.values.items[index] = value;
            self.added_ticks.items[index] = tick;
            self.changed_ticks.items[index] = 0;
            return true;
        }

        /// Make `id` a valid index of `sparse` and `removed_ticks` (sized together, so
        /// `remove` never allocates).
        fn growSparseTo(self: *Self, allocator: std.mem.Allocator, id: u32) !void {
            @branchHint(.cold);
            try growSparse(u32, &self.sparse, allocator, id, absent);
            try growSparse(Tick, &self.removed_ticks, allocator, id, 0);
        }

        /// Give the four dense arrays room for at least one more value, all with the same
        /// capacity, so `add` checks one of them. Leaves the storage unchanged on failure.
        fn growDense(self: *Self, allocator: std.mem.Allocator) !void {
            @branchHint(.cold);
            const len = self.entities.items.len;
            // Doubling: fewer reallocations, and half the copying of 1.5x growth.
            const capacity = @max(8, len * 2);
            try self.entities.ensureTotalCapacityPrecise(allocator, capacity);
            try self.values.ensureTotalCapacityPrecise(allocator, capacity);
            try self.added_ticks.ensureTotalCapacityPrecise(allocator, capacity);
            try self.changed_ticks.ensureTotalCapacityPrecise(allocator, capacity);
        }

        /// The dense index of `entity`'s value, or null if it has none.
        pub inline fn denseIndex(self: *const Self, entity: EntityId) ?u32 {
            if (entity.id >= self.sparse.items.len) return null;
            const index = self.sparse.items[entity.id];
            return if (index == absent) null else index;
        }

        /// A pointer to `entity`'s value, or null if it has none. Valid until the storage changes.
        pub inline fn get(self: *Self, entity: EntityId) ?*T {
            const index = self.denseIndex(entity) orelse return null;
            return &self.values.items[index];
        }

        pub inline fn has(self: *const Self, entity: EntityId) bool {
            return self.denseIndex(entity) != null;
        }

        /// Remove `entity`'s value, if any, by moving the last value into its slot.
        pub fn remove(self: *Self, entity: EntityId, tick: Tick) void {
            const index = self.denseIndex(entity) orelse return;
            const last = self.values.items.len - 1;
            if (index != last) {
                const moved = self.entities.items[last];
                self.entities.items[index] = moved;
                self.values.items[index] = self.values.items[last];
                self.added_ticks.items[index] = self.added_ticks.items[last];
                self.changed_ticks.items[index] = self.changed_ticks.items[last];
                self.sparse.items[moved.id] = index;
            }
            _ = self.entities.pop();
            _ = self.values.pop();
            _ = self.added_ticks.pop();
            _ = self.changed_ticks.pop();
            self.sparse.items[entity.id] = absent;
            self.removed_ticks.items[entity.id] = tick;
        }

        pub fn markChanged(self: *Self, entity: EntityId, tick: Tick) void {
            const index = self.denseIndex(entity) orelse return;
            self.changed_ticks.items[index] = tick;
        }

        pub fn wasAdded(self: *const Self, entity: EntityId, tick: Tick) bool {
            const index = self.denseIndex(entity) orelse return false;
            return self.added_ticks.items[index] == tick;
        }

        pub fn wasChanged(self: *const Self, entity: EntityId, tick: Tick) bool {
            const index = self.denseIndex(entity) orelse return false;
            return self.changed_ticks.items[index] == tick;
        }

        /// Whether `entity` lost its value on `tick` and hasn't been given one again since.
        pub fn wasRemoved(self: *const Self, entity: EntityId, tick: Tick) bool {
            if (self.has(entity) or entity.id >= self.removed_ticks.items.len) return false;
            return self.removed_ticks.items[entity.id] == tick;
        }
    };
}

/// Grow `list` so `id` is a valid index, filling new slots with `fill`.
fn growSparse(comptime E: type, list: *std.ArrayList(E), allocator: std.mem.Allocator, id: u32, fill: E) !void {
    if (id < list.items.len) return;
    // Doubling, as for the dense arrays: ids usually arrive in order, one past the end.
    if (id >= list.capacity) try list.ensureTotalCapacityPrecise(allocator, @max(@as(usize, id) + 1, list.capacity * 2, 64));
    list.appendNTimesAssumeCapacity(fill, id + 1 - list.items.len);
}

test "component storage adds and gets values" {
    const Position = struct { x: f32, y: f32 };

    var storage = ComponentStorage(Position).init(std.testing.allocator);
    defer storage.deinit(std.testing.allocator);

    const entity = EntityId.init(0, 0);
    try storage.add(std.testing.allocator, entity, .{ .x = 1, .y = 2 }, 1);

    try std.testing.expect(storage.has(entity));

    const position = storage.get(entity).?;
    try std.testing.expectEqual(@as(f32, 1), position.x);
    try std.testing.expectEqual(@as(f32, 2), position.y);
}

test "component storage updates existing values" {
    const Health = struct { hp: f32 };

    var storage = ComponentStorage(Health).init(std.testing.allocator);
    defer storage.deinit(std.testing.allocator);

    const entity = EntityId.init(0, 0);
    try storage.add(std.testing.allocator, entity, .{ .hp = 50 }, 1);
    try storage.add(std.testing.allocator, entity, .{ .hp = 100 }, 2);

    try std.testing.expectEqual(@as(usize, 1), storage.values.items.len);
    try std.testing.expectEqual(@as(f32, 100), storage.get(entity).?.hp);
    try std.testing.expect(storage.wasChanged(entity, 2));
}

test "component storage removes values with swap remove" {
    const Position = struct { x: f32, y: f32 };

    var storage = ComponentStorage(Position).init(std.testing.allocator);
    defer storage.deinit(std.testing.allocator);

    const a = EntityId.init(0, 0);
    const b = EntityId.init(1, 0);

    try storage.add(std.testing.allocator, a, .{ .x = 1, .y = 2 }, 1);
    try storage.add(std.testing.allocator, b, .{ .x = 3, .y = 4 }, 1);

    storage.remove(a, 2);

    try std.testing.expect(!storage.has(a));
    try std.testing.expect(storage.has(b));
    try std.testing.expectEqual(@as(usize, 1), storage.values.items.len);
    try std.testing.expectEqual(@as(f32, 3), storage.get(b).?.x);
    try std.testing.expect(storage.wasRemoved(a, 2));
    try std.testing.expect(!storage.wasRemoved(a, 3));
}

test "component storage tracks added and changed ticks per value" {
    const Health = struct { hp: f32 };

    var storage = ComponentStorage(Health).init(std.testing.allocator);
    defer storage.deinit(std.testing.allocator);

    const entity = EntityId.init(7, 0);
    try storage.add(std.testing.allocator, entity, .{ .hp = 1 }, 3);
    try std.testing.expect(storage.wasAdded(entity, 3));
    try std.testing.expect(!storage.wasChanged(entity, 3));
    try std.testing.expect(!storage.wasAdded(entity, 4));

    storage.markChanged(entity, 4);
    try std.testing.expect(storage.wasChanged(entity, 4));
}
