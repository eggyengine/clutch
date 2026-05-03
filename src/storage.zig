const std = @import("std");
const entity_mod = @import("entity.zig");

/// A dense component store for one component type.
///
/// `entities` and `values` are kept in lockstep:
/// - `entities.items[i]` owns `values.items[i]`
/// - `indices` maps an entity id to that dense index
pub fn ComponentStorage(comptime T: type) type {
    return struct {
        const Self = @This();

        entities: std.ArrayList(entity_mod.EntityId),
        values: std.ArrayList(T),
        indices: std.AutoHashMap(u32, usize),

        pub fn init(allocator: std.mem.Allocator) Self {
            return .{
                .entities = .empty,
                .values = .empty,
                .indices = std.AutoHashMap(u32, usize).init(allocator),
            };
        }

        pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
            self.entities.deinit(allocator);
            self.values.deinit(allocator);
            self.indices.deinit();
        }

        /// Add a value for the given entity, or update the existing value if one already exists.
        pub fn add(self: *Self, allocator: std.mem.Allocator, entity: entity_mod.EntityId, value: T) !void {
            if (self.indices.get(entity.id)) |index| {
                self.values.items[index] = value;
                return;
            }

            const index = self.values.items.len;
            try self.entities.append(allocator, entity);
            try self.values.append(allocator, value);
            try self.indices.put(entity.id, index);
        }

        /// Get a pointer to the value for the given entity, or null if the entity does not have a value.
        pub fn get(self: *Self, entity: entity_mod.EntityId) ?*T {
            const index = self.indices.get(entity.id) orelse return null;
            return &self.values.items[index];
        }

        /// Returns whether the given entity has a value in this storage.
        pub fn has(self: *Self, entity: entity_mod.EntityId) bool {
            return self.indices.contains(entity.id);
        }

        /// Remove the value for the given entity, if one exists.
        pub fn remove(self: *Self, entity: entity_mod.EntityId) void {
            const index = self.indices.get(entity.id) orelse return;

            const last_index = self.values.items.len - 1;
            const last_entity = self.entities.items[last_index];

            if (index != last_index) {
                self.values.items[index] = self.values.items[last_index];
                self.entities.items[index] = last_entity;
                self.indices.put(last_entity.id, index) catch unreachable;
            }

            _ = self.values.pop();
            _ = self.entities.pop();
            _ = self.indices.remove(entity.id);
        }
    };
}

test "component storage adds and gets values" {
    const Position = struct { x: f32, y: f32 };
    const EntityId = entity_mod.EntityId;

    var storage = ComponentStorage(Position).init(std.testing.allocator);
    defer storage.deinit(std.testing.allocator);

    const entity = EntityId.init(0, 0);
    try storage.add(std.testing.allocator, entity, .{ .x = 1, .y = 2 });

    try std.testing.expect(storage.has(entity));

    const position = storage.get(entity).?;
    try std.testing.expectEqual(@as(f32, 1), position.x);
    try std.testing.expectEqual(@as(f32, 2), position.y);
}

test "component storage updates existing values" {
    const Health = struct { hp: f32 };
    const EntityId = entity_mod.EntityId;

    var storage = ComponentStorage(Health).init(std.testing.allocator);
    defer storage.deinit(std.testing.allocator);

    const entity = EntityId.init(0, 0);
    try storage.add(std.testing.allocator, entity, .{ .hp = 50 });
    try storage.add(std.testing.allocator, entity, .{ .hp = 100 });

    try std.testing.expectEqual(@as(usize, 1), storage.values.items.len);
    try std.testing.expectEqual(@as(f32, 100), storage.get(entity).?.hp);
}

test "component storage removes values with swap remove" {
    const Position = struct { x: f32, y: f32 };
    const EntityId = entity_mod.EntityId;

    var storage = ComponentStorage(Position).init(std.testing.allocator);
    defer storage.deinit(std.testing.allocator);

    const a = EntityId.init(0, 0);
    const b = EntityId.init(1, 0);

    try storage.add(std.testing.allocator, a, .{ .x = 1, .y = 2 });
    try storage.add(std.testing.allocator, b, .{ .x = 3, .y = 4 });

    storage.remove(a);

    try std.testing.expect(!storage.has(a));
    try std.testing.expect(storage.has(b));
    try std.testing.expectEqual(@as(usize, 1), storage.values.items.len);
    try std.testing.expectEqual(@as(f32, 3), storage.get(b).?.x);
}
