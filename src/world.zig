const std = @import("std");
const root = @import("root.zig");

const ErasedStorage = struct {
    ptr: *anyopaque,
    deinitFn: *const fn (*anyopaque, std.mem.Allocator) void,
    removeEntityFn: *const fn (*anyopaque, root.EntityId) void,

    fn deinit(self: ErasedStorage, allocator: std.mem.Allocator) void {
        self.deinitFn(self.ptr, allocator);
    }

    fn removeEntity(self: ErasedStorage, entity: root.EntityId) void {
        self.removeEntityFn(self.ptr, entity);
    }
};

fn typeId(comptime T: type) u64 {
    return std.hash.Wyhash.hash(0, @typeName(T));
}

fn deinitTypedStorage(comptime T: type, ptr: *anyopaque, allocator: std.mem.Allocator) void {
    const Storage = root.storage.ComponentStorage(T);
    const storage: *Storage = @ptrCast(@alignCast(ptr));
    storage.deinit(allocator);
    allocator.destroy(storage);
}

fn removeEntityFromTypedStorage(comptime T: type, ptr: *anyopaque, entity: root.EntityId) void {
    const Storage = root.storage.ComponentStorage(T);
    const storage: *Storage = @ptrCast(@alignCast(ptr));
    storage.remove(entity);
}

/// Stores all components and entities using the ECS paradigm.
pub const World = struct {
    allocator: std.mem.Allocator,

    generations: std.ArrayList(u32),
    alive: std.ArrayList(bool),
    free_ids: std.ArrayList(u32),
    living_count: usize = 0,

    component_storages: std.AutoHashMap(u64, ErasedStorage),

    /// Creates a new World with the given allocator.
    pub fn init(allocator: std.mem.Allocator) World {
        return .{
            .allocator = allocator,
            .generations = .empty,
            .alive = .empty,
            .free_ids = .empty,
            .component_storages = std.AutoHashMap(u64, ErasedStorage).init(allocator),
        };
    }

    /// Frees all resources associated with the world.
    pub fn deinit(self: *World) void {
        var storage_iter = self.component_storages.valueIterator();
        while (storage_iter.next()) |storage| {
            storage.deinit(self.allocator);
        }
        self.component_storages.deinit();

        self.generations.deinit(self.allocator);
        self.alive.deinit(self.allocator);
        self.free_ids.deinit(self.allocator);
    }

    fn storageFor(self: *World, comptime T: type) !*root.storage.ComponentStorage(T) {
        const Storage = root.storage.ComponentStorage(T);
        const id = typeId(T);

        if (self.component_storages.get(id)) |erased| {
            return @ptrCast(@alignCast(erased.ptr));
        }

        const storage = try self.allocator.create(Storage);
        storage.* = Storage.init(self.allocator);

        try self.component_storages.put(id, .{
            .ptr = storage,
            .deinitFn = struct {
                fn run(ptr: *anyopaque, allocator: std.mem.Allocator) void {
                    deinitTypedStorage(T, ptr, allocator);
                }
            }.run,
            .removeEntityFn = struct {
                fn run(ptr: *anyopaque, entity: root.EntityId) void {
                    removeEntityFromTypedStorage(T, ptr, entity);
                }
            }.run,
        });

        return storage;
    }

    fn existingStorage(self: *World, comptime T: type) ?*root.storage.ComponentStorage(T) {
        const erased = self.component_storages.get(typeId(T)) orelse return null;
        return @ptrCast(@alignCast(erased.ptr));
    }

    /// Initialises a new empty entity in the world.
    fn createEntity(self: *World) !root.EntityId {
        if (self.free_ids.items.len > 0) {
            const id = self.free_ids.pop().?;
            self.alive.items[@intCast(id)] = true;
            self.living_count += 1;

            return root.EntityId.init(id, self.generations.items[@intCast(id)]);
        }

        const id: u32 = @intCast(self.generations.items.len);
        try self.generations.append(self.allocator, 0);
        try self.alive.append(self.allocator, true);
        self.living_count += 1;

        return root.EntityId.init(id, 0);
    }

    /// Spawns a new entity with the given components.
    pub fn spawn(self: *World, components: anytype) !root.EntityId {
        const entity = try self.createEntity();
        inline for (components) |component| {
            try self.addComponent(entity, component);
        }

        return entity;
    }

    /// Adds component(s) to an entity.
    pub fn addComponent(self: *World, entity: root.EntityId, component: anytype) !void {
        if (!self.isAlive(entity)) return error.EntityNotAlive;

        const T = @TypeOf(component);
        const storage = try self.storageFor(T);
        try storage.add(self.allocator, entity, component);
    }

    /// Removes component(s) from an entity.
    pub fn removeComponent(self: *World, entity: root.EntityId, comptime T: type) !void {
        if (!self.isAlive(entity)) return error.EntityNotAlive;

        const storage = self.existingStorage(T) orelse return;
        storage.remove(entity);
    }

    /// Returns whether the entity has the given component(s).
    pub fn hasComponent(self: *World, entity: root.EntityId, comptime T: type) bool {
        if (!self.isAlive(entity)) return false;

        const storage = self.existingStorage(T) orelse return false;
        return storage.has(entity);
    }

    pub fn get(self: *World, entity: root.EntityId, comptime T: type) ?*T {
        if (!self.isAlive(entity)) return null;

        const storage = self.existingStorage(T) orelse return null;
        return storage.get(entity);
    }

    pub fn query(self: *World, comptime terms: anytype) Query(terms) {
        return Query(terms).init(self);
    }

    /// Checks the generation validity of an entity and ensures that the latest generation matches the entity's generation.
    pub fn isAlive(self: *World, entity: root.EntityId) bool {
        if (entity.id >= self.alive.items.len) return false;
        const index = entity.index();
        return self.alive.items[index] and
            self.generations.items[index] == entity.generation;
    }

    /// Despawns an entity, marking it as dead and freeing its ID for reuse.
    pub fn despawn(self: *World, entity: root.EntityId) void {
        if (!self.isAlive(entity)) return;

        const index = entity.index();
        self.alive.items[index] = false;
        self.generations.items[index] += 1;
        self.free_ids.append(self.allocator, entity.id) catch unreachable;
        self.living_count -= 1;

        var storage_iter = self.component_storages.valueIterator();
        while (storage_iter.next()) |storage| {
            storage.removeEntity(entity);
        }
    }

    /// Returns the number of living entities in the world.
    pub fn entityCount(self: *World) usize {
        return self.living_count;
    }
};

/// A query requests components for entities from the world.
///
/// Create one with `world.query(.{Position, Health})` or even add filters with
/// `world.query(.{Position, Health, With(Position)})`
pub fn Query(comptime terms: anytype) type {
    return struct {
        const Self = @This();

        world: *World,
        index: usize = 0,

        /// Represents a view into the world, providing access to one entity and its components.
        pub const View = struct {
            /// The world this view is associated with.
            world: *World,
            /// Represents the current entity in the existing view
            entity: root.EntityId,

            /// Returns a pointer to the component of type `T` for this entity.
            pub fn get(self: View, comptime T: type) *T {
                return self.world.get(self.entity, T).?;
            }
        };

        /// Initialises a new `Query` for the given terms.
        ///
        /// The more appropriate method of initialisation is `world.query(.{...})`, as this
        /// function is used internally. But who am I (the author) to say what you can do 🤷
        pub fn init(world: *World) Self {
            return .{
                .world = world,
                .index = 0,
            };
        }

        /// Iterates to the next View
        pub fn next(self: *Self) ?View {
            while (self.index < self.world.generations.items.len) {
                const id: u32 = @intCast(self.index);
                const entity = root.EntityId.init(id, self.world.generations.items[self.index]);
                self.index += 1;

                if (!self.world.isAlive(entity)) continue;
                if (!matches(self.world, entity)) continue;

                return .{
                    .world = self.world,
                    .entity = entity,
                };
            }

            return null;
        }

        fn matches(world: *World, entity: root.EntityId) bool {
            inline for (terms) |term| {
                if (comptime root.filters.isWith(term)) {
                    if (!world.hasComponent(entity, term.component)) return false;
                } else if (comptime root.filters.isWithout(term)) {
                    if (world.hasComponent(entity, term.component)) return false;
                } else {
                    if (!world.hasComponent(entity, term)) return false;
                }
            }

            return true;
        }
    };
}

test "world creates living entities" {
    var world = World.init(std.testing.allocator);
    defer world.deinit();

    try std.testing.expectEqual(@as(usize, 0), world.entityCount());

    const entity = try world.spawn(.{});

    try std.testing.expect(world.isAlive(entity));
    try std.testing.expectEqual(@as(usize, 1), world.entityCount());
}

test "world despawns entities" {
    var world = World.init(std.testing.allocator);
    defer world.deinit();

    const entity = try world.spawn(.{});
    world.despawn(entity);

    try std.testing.expect(!world.isAlive(entity));
    try std.testing.expectEqual(@as(usize, 0), world.entityCount());
}

test "world reuses ids with a new generation" {
    var world = World.init(std.testing.allocator);
    defer world.deinit();

    const old = try world.spawn(.{});
    world.despawn(old);

    const new = try world.spawn(.{});

    try std.testing.expectEqual(old.id, new.id);
    try std.testing.expect(old.generation != new.generation);
    try std.testing.expect(!world.isAlive(old));
    try std.testing.expect(world.isAlive(new));
}

test "world adds and gets components" {
    const Position = struct { x: f32, y: f32 };

    var world = World.init(std.testing.allocator);
    defer world.deinit();

    const entity = try world.spawn(.{});
    try world.addComponent(entity, Position{ .x = 1, .y = 2 });

    try std.testing.expect(world.hasComponent(entity, Position));

    const position = world.get(entity, Position).?;
    try std.testing.expectEqual(@as(f32, 1), position.x);
    try std.testing.expectEqual(@as(f32, 2), position.y);
}

test "world spawns with components" {
    const Position = struct { x: f32, y: f32 };
    const Player = struct {};

    var world = World.init(std.testing.allocator);
    defer world.deinit();

    const entity = try world.spawn(.{
        Position{ .x = 5, .y = 10 },
        Player{},
    });

    try std.testing.expect(world.hasComponent(entity, Position));
    try std.testing.expect(world.hasComponent(entity, Player));
    try std.testing.expectEqual(@as(f32, 5), world.get(entity, Position).?.x);
}

test "world removes components" {
    const Health = struct { hp: f32 };

    var world = World.init(std.testing.allocator);
    defer world.deinit();

    const entity = try world.spawn(.{Health{ .hp = 100 }});
    try std.testing.expect(world.hasComponent(entity, Health));

    try world.removeComponent(entity, Health);
    try std.testing.expect(!world.hasComponent(entity, Health));
    try std.testing.expect(world.get(entity, Health) == null);
}

test "world despawn removes components" {
    const Position = struct { x: f32, y: f32 };

    var world = World.init(std.testing.allocator);
    defer world.deinit();

    const entity = try world.spawn(.{Position{ .x = 1, .y = 2 }});
    world.despawn(entity);

    try std.testing.expect(!world.hasComponent(entity, Position));
    try std.testing.expect(world.get(entity, Position) == null);
}
