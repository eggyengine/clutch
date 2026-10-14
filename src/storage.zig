const std = @import("std");
const entity_mod = @import("entity.zig");
const EntityId = entity_mod.EntityId;

/// A change tick: the world's frame counter. 0 means "never"; the world starts at 1.
// shortcut: u32 halves the tick arrays; after 2^32 ticks (over 2 years at 60 fps) a value left
// untouched that whole time could read as added or changed again. Use u64 if worlds live that long.
pub const Tick = u32;

/// When a value was added, and when it last changed (0 if never since it was added).
pub const Ticks = struct { added: Tick, changed: Tick };

/// Marks an entity id with no value in a `ComponentStorage`.
const absent = std.math.maxInt(u32);

/// Whether component type `T` keeps change ticks, which `Added`, `Changed`, `Removed` and
/// `markChanged` need. On by default; a component opts out, making its adds and removals
/// cheaper, by declaring `pub const track_changes = false;`.
pub fn tracksChanges(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        .@"struct", .@"union", .@"enum", .@"opaque" => !@hasDecl(T, "track_changes") or T.track_changes,
        else => true,
    };
}

/// A sparse set holding one component type, as EnTT and pico_ecs store them.
///
/// The dense arrays `entities`, `values` and `ticks` are kept in lockstep and stay packed:
/// `entities.items[i]` owns `values.items[i]`. `sparse`, indexed by entity id, holds each
/// entity's dense index, so every lookup is an array read.
///
/// Data used together is stored together (ticks in one array, an id's index and removal tick
/// in another): each removal then touches fewer cache lines, which matters once a world has
/// several storages. `entities` and `values` stay separate so queries stream only what they use.
pub fn ComponentStorage(comptime T: type) type {
    const tracked = tracksChanges(T);
    return struct {
        const Self = @This();

        /// One entity id's entry in `sparse`.
        const Slot = if (tracked) struct {
            /// The entity's position in the dense arrays, or `absent`.
            index: u32,
            /// The tick the entity's value was last removed on, or 0.
            removed: Tick,
        } else struct { index: u32 };
        const empty_slot: Slot = if (tracked) .{ .index = absent, .removed = 0 } else .{ .index = absent };

        entities: std.ArrayList(EntityId) = .empty,
        values: std.ArrayList(T) = .empty,
        /// Empty, and never touched, when `T` opts out of change tracking.
        ticks: std.ArrayList(Ticks) = .empty,
        /// Entity id -> `Slot`.
        sparse: std.ArrayList(Slot) = .empty,

        pub fn init(allocator: std.mem.Allocator) Self {
            _ = allocator;
            return .{};
        }

        pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
            self.entities.deinit(allocator);
            self.values.deinit(allocator);
            self.ticks.deinit(allocator);
            self.sparse.deinit(allocator);
        }

        /// Add a value for `entity`, or replace (and mark changed) the value it already has.
        pub fn add(self: *Self, allocator: std.mem.Allocator, entity: EntityId, value: T, tick: Tick) !void {
            _ = try self.insert(allocator, entity, value, tick);
        }

        /// `add`, returning whether `entity` had no value before (so on-add hooks should run).
        pub fn insert(self: *Self, allocator: std.mem.Allocator, entity: EntityId, value: T, tick: Tick) !bool {
            if (self.denseIndex(entity)) |index| {
                self.values.items[index] = value;
                if (tracked) self.ticks.items[index].changed = tick;
                return false;
            }

            // Common case: one compare each. The growth paths are out of line.
            if (entity.id >= self.sparse.items.len) try self.growSparseTo(allocator, entity.id);
            if (self.entities.items.len == self.entities.capacity) try self.growDense(allocator);

            const index = self.entities.items.len;
            self.sparse.items[entity.id].index = @intCast(index);
            self.entities.items.len += 1;
            self.values.items.len += 1;
            self.entities.items[index] = entity;
            self.values.items[index] = value;
            if (tracked) {
                self.ticks.items.len += 1;
                self.ticks.items[index] = .{ .added = tick, .changed = 0 };
            }
            return true;
        }

        /// Allocate room for `count` values, for entity ids below `count`, so adding that many
        /// never reallocates.
        pub fn reserve(self: *Self, allocator: std.mem.Allocator, count: usize) !void {
            try self.entities.ensureTotalCapacityPrecise(allocator, count);
            try self.values.ensureTotalCapacityPrecise(allocator, count);
            if (tracked) try self.ticks.ensureTotalCapacityPrecise(allocator, count);
            try self.sparse.ensureTotalCapacityPrecise(allocator, count);
        }

        /// Make `id` a valid index of `sparse`, doubling: ids usually arrive in order.
        fn growSparseTo(self: *Self, allocator: std.mem.Allocator, id: u32) !void {
            @branchHint(.cold);
            if (id >= self.sparse.capacity) {
                try self.sparse.ensureTotalCapacityPrecise(allocator, @max(@as(usize, id) + 1, self.sparse.capacity * 2, 64));
            }
            self.sparse.appendNTimesAssumeCapacity(empty_slot, id + 1 - self.sparse.items.len);
        }

        /// Give the dense arrays room for at least one more value, all with the same capacity,
        /// so `insert` checks one of them. Leaves the storage unchanged on failure.
        fn growDense(self: *Self, allocator: std.mem.Allocator) !void {
            @branchHint(.cold);
            // Doubling: fewer reallocations, and half the copying of 1.5x growth.
            const capacity = @max(8, self.entities.items.len * 2);
            try self.entities.ensureTotalCapacityPrecise(allocator, capacity);
            try self.values.ensureTotalCapacityPrecise(allocator, capacity);
            if (tracked) try self.ticks.ensureTotalCapacityPrecise(allocator, capacity);
        }

        /// The dense index of `entity`'s value, or null if it has none.
        pub inline fn denseIndex(self: *const Self, entity: EntityId) ?u32 {
            if (entity.id >= self.sparse.items.len) return null;
            const index = self.sparse.items[entity.id].index;
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

        /// Remove `entity`'s value, if any, by moving the last value into its slot. Never allocates.
        pub fn remove(self: *Self, entity: EntityId, tick: Tick) void {
            const index = self.denseIndex(entity) orelse return;
            const last = self.entities.items.len - 1;
            if (index != last) {
                const moved = self.entities.items[last];
                self.entities.items[index] = moved;
                self.values.items[index] = self.values.items[last];
                if (tracked) self.ticks.items[index] = self.ticks.items[last];
                self.sparse.items[entity.id].index = absent;
                self.sparse.items[moved.id].index = index;
            } else self.sparse.items[entity.id].index = absent;
            self.entities.items.len = last;
            self.values.items.len = last;
            if (tracked) {
                self.ticks.items.len = last;
                self.sparse.items[entity.id].removed = tick;
            }
        }

        pub fn markChanged(self: *Self, entity: EntityId, tick: Tick) void {
            if (!tracked) @compileError(@typeName(T) ++ " opts out of change tracking (track_changes = false)");
            const index = self.denseIndex(entity) orelse return;
            self.ticks.items[index].changed = tick;
        }

        pub fn wasAdded(self: *const Self, entity: EntityId, tick: Tick) bool {
            if (!tracked) @compileError(@typeName(T) ++ " opts out of change tracking (track_changes = false)");
            const index = self.denseIndex(entity) orelse return false;
            return self.ticks.items[index].added == tick;
        }

        pub fn wasChanged(self: *const Self, entity: EntityId, tick: Tick) bool {
            if (!tracked) @compileError(@typeName(T) ++ " opts out of change tracking (track_changes = false)");
            const index = self.denseIndex(entity) orelse return false;
            return self.ticks.items[index].changed == tick;
        }

        /// Whether `entity` lost its value on `tick` and hasn't been given one again since.
        pub fn wasRemoved(self: *const Self, entity: EntityId, tick: Tick) bool {
            if (!tracked) @compileError(@typeName(T) ++ " opts out of change tracking (track_changes = false)");
            if (entity.id >= self.sparse.items.len) return false;
            const slot = self.sparse.items[entity.id];
            return slot.index == absent and slot.removed == tick;
        }
    };
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

test "a value added back after removal is no longer reported as removed" {
    const Health = struct { hp: f32 };

    var storage = ComponentStorage(Health).init(std.testing.allocator);
    defer storage.deinit(std.testing.allocator);

    const entity = EntityId.init(2, 0);
    try storage.add(std.testing.allocator, entity, .{ .hp = 1 }, 1);
    storage.remove(entity, 2);
    try std.testing.expect(storage.wasRemoved(entity, 2));
    try storage.add(std.testing.allocator, entity, .{ .hp = 5 }, 2);
    try std.testing.expect(!storage.wasRemoved(entity, 2));
}

test "a component that opts out of change tracking still adds, gets and removes" {
    const Particle = struct {
        pub const track_changes = false;
        life: f32,
    };

    var storage = ComponentStorage(Particle).init(std.testing.allocator);
    defer storage.deinit(std.testing.allocator);

    const a = EntityId.init(0, 0);
    const b = EntityId.init(1, 0);
    try storage.add(std.testing.allocator, a, .{ .life = 1 }, 1);
    try storage.add(std.testing.allocator, b, .{ .life = 2 }, 1);
    storage.remove(a, 2);

    try std.testing.expect(!storage.has(a));
    try std.testing.expectEqual(@as(f32, 2), storage.get(b).?.life);
    try std.testing.expectEqual(@as(usize, 0), storage.ticks.items.len);
    try std.testing.expectEqual(@as(usize, 4), @sizeOf(@TypeOf(storage).Slot));
}
