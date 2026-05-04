const std = @import("std");
const root = @import("root.zig");

const ErasedStorage = struct {
    ptr: *anyopaque,
    deinitFn: *const fn (*anyopaque, std.mem.Allocator) void,
    removeEntityFn: *const fn (*anyopaque, root.EntityId) void,
    clearTrackingFn: *const fn (*anyopaque) void,

    fn deinit(self: ErasedStorage, allocator: std.mem.Allocator) void {
        self.deinitFn(self.ptr, allocator);
    }

    fn removeEntity(self: ErasedStorage, entity: root.EntityId) void {
        self.removeEntityFn(self.ptr, entity);
    }

    fn clearTracking(self: ErasedStorage) void {
        self.clearTrackingFn(self.ptr);
    }
};

const ErasedEventStorage = struct {
    ptr: *anyopaque,
    deinitFn: *const fn (*anyopaque, std.mem.Allocator) void,
    clearFn: *const fn (*anyopaque) void,

    fn deinit(self: ErasedEventStorage, allocator: std.mem.Allocator) void {
        self.deinitFn(self.ptr, allocator);
    }

    fn clear(self: ErasedEventStorage) void {
        self.clearFn(self.ptr);
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

fn clearTypedStorageTracking(comptime T: type, ptr: *anyopaque) void {
    const Storage = root.storage.ComponentStorage(T);
    const storage: *Storage = @ptrCast(@alignCast(ptr));
    storage.clearTracking();
}

fn deinitTypedEventStorage(comptime T: type, ptr: *anyopaque, allocator: std.mem.Allocator) void {
    const EventStorage = std.ArrayList(T);
    const storage: *EventStorage = @ptrCast(@alignCast(ptr));
    storage.deinit(allocator);
    allocator.destroy(storage);
}

fn clearTypedEventStorage(comptime T: type, ptr: *anyopaque) void {
    const EventStorage = std.ArrayList(T);
    const storage: *EventStorage = @ptrCast(@alignCast(ptr));
    storage.clearRetainingCapacity();
}

/// Stores all components and entities using the ECS paradigm.
pub const World = struct {
    allocator: std.mem.Allocator,

    generations: std.ArrayList(u32),
    alive: std.ArrayList(bool),
    free_ids: std.ArrayList(u32),
    living_count: usize = 0,

    component_storages: std.AutoHashMap(u64, ErasedStorage),
    event_storages: std.AutoHashMap(u64, ErasedEventStorage),
    parent_by_child: std.AutoHashMap(u32, root.EntityId),
    children_by_parent: std.AutoHashMap(u32, std.ArrayList(root.EntityId)),

    /// Creates a new World with the given allocator.
    pub fn init(allocator: std.mem.Allocator) World {
        return .{
            .allocator = allocator,
            .generations = .empty,
            .alive = .empty,
            .free_ids = .empty,
            .component_storages = std.AutoHashMap(u64, ErasedStorage).init(allocator),
            .event_storages = std.AutoHashMap(u64, ErasedEventStorage).init(allocator),
            .parent_by_child = std.AutoHashMap(u32, root.EntityId).init(allocator),
            .children_by_parent = std.AutoHashMap(u32, std.ArrayList(root.EntityId)).init(allocator),
        };
    }

    /// Frees all resources associated with the world.
    pub fn deinit(self: *World) void {
        var storage_iter = self.component_storages.valueIterator();
        while (storage_iter.next()) |storage| {
            storage.deinit(self.allocator);
        }
        self.component_storages.deinit();

        var event_iter = self.event_storages.valueIterator();
        while (event_iter.next()) |storage| {
            storage.deinit(self.allocator);
        }
        self.event_storages.deinit();

        var children_iter = self.children_by_parent.valueIterator();
        while (children_iter.next()) |child_list| {
            child_list.deinit(self.allocator);
        }
        self.children_by_parent.deinit();
        self.parent_by_child.deinit();

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
            .clearTrackingFn = struct {
                fn run(ptr: *anyopaque) void {
                    clearTypedStorageTracking(T, ptr);
                }
            }.run,
        });

        return storage;
    }

    fn eventStorageFor(self: *World, comptime T: type) !*std.ArrayList(T) {
        const EventStorage = std.ArrayList(T);
        const id = typeId(T);

        if (self.event_storages.get(id)) |erased| {
            return @ptrCast(@alignCast(erased.ptr));
        }

        const storage = try self.allocator.create(EventStorage);
        storage.* = .empty;

        try self.event_storages.put(id, .{
            .ptr = storage,
            .deinitFn = struct {
                fn run(ptr: *anyopaque, allocator: std.mem.Allocator) void {
                    deinitTypedEventStorage(T, ptr, allocator);
                }
            }.run,
            .clearFn = struct {
                fn run(ptr: *anyopaque) void {
                    clearTypedEventStorage(T, ptr);
                }
            }.run,
        });

        return storage;
    }

    fn existingEventStorage(self: *World, comptime T: type) ?*std.ArrayList(T) {
        const erased = self.event_storages.get(typeId(T)) orelse return null;
        return @ptrCast(@alignCast(erased.ptr));
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
    ///
    /// Components can also be an empty struct if you wish to spawn a blank entity.
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

    /// Fetches a mutable pointer to **a** component
    pub fn get(self: *World, entity: root.EntityId, comptime T: type) ?*T {
        if (!self.isAlive(entity)) return null;

        const storage = self.existingStorage(T) orelse return null;
        return storage.get(entity);
    }

    /// Set the type to be changed for an entity.
    pub fn markChanged(self: *World, entity: root.EntityId, comptime T: type) void {
        if (!self.isAlive(entity)) return;

        const storage = self.existingStorage(T) orelse return;
        storage.markChanged(entity) catch unreachable;
    }

    /// Was a type recently added to an entity?
    pub fn wasAdded(self: *World, entity: root.EntityId, comptime T: type) bool {
        if (!self.isAlive(entity)) return false;

        const storage = self.existingStorage(T) orelse return false;
        return storage.wasAdded(entity);
    }

    /// Was a component's data mutated for an entity?
    pub fn wasChanged(self: *World, entity: root.EntityId, comptime T: type) bool {
        if (!self.isAlive(entity)) return false;

        const storage = self.existingStorage(T) orelse return false;
        return storage.wasChanged(entity);
    }

    /// Was a component removed from an entity?
    pub fn wasRemoved(self: *World, entity: root.EntityId, comptime T: type) bool {
        if (!self.isAlive(entity)) return false;

        const storage = self.existingStorage(T) orelse return false;
        return storage.wasRemoved(entity);
    }

    /// Ticks and iterates through modifications, allowing for filters such as
    /// `Changed(T)` and `Added(T)` to be available.
    pub fn tick(self: *World) void {
        var storage_iter = self.component_storages.valueIterator();
        while (storage_iter.next()) |storage| {
            storage.clearTracking();
        }

        var event_iter = self.event_storages.valueIterator();
        while (event_iter.next()) |storage| {
            storage.clear();
        }
    }

    /// Sends/emits a signal for an event (as specified by a specific type)
    pub fn sendEvent(self: *World, event: anytype) !void {
        const T = @TypeOf(event);
        const storage = try self.eventStorageFor(T);
        try storage.append(self.allocator, event);
    }

    /// Returns an `EventReader` for the types specfied
    pub fn eventReader(self: *World, comptime T: type) EventReader(T) {
        return EventReader(T).init(self);
    }

    /// Create a `Query` with the terms (an anonymous struct of types)
    pub fn query(self: *World, comptime terms: anytype) Query(terms) {
        return Query(terms).init(self);
    }

    /// Sets a parent/child relationship.
    ///
    /// Accepts either `setParent(child, parent)` or `setParent(parent, .{ child1, child2 })`.
    pub fn setParent(self: *World, first: root.EntityId, second: anytype) !void {
        if (comptime @TypeOf(second) == root.EntityId) {
            try self.setSingleParent(first, second);
            return;
        }

        inline for (second) |child| {
            try self.setSingleParent(child, first);
        }
    }

    fn setSingleParent(self: *World, child: root.EntityId, parent: root.EntityId) !void {
        if (!self.isAlive(child) or !self.isAlive(parent)) return error.EntityNotAlive;
        if (root.EntityId.eql(child, parent)) return error.InvalidHierarchy;
        if (self.isDescendantOf(parent, child)) return error.InvalidHierarchy;

        self.removeParent(child);

        try self.parent_by_child.put(child.id, parent);

        const entry = try self.children_by_parent.getOrPut(parent.id);
        if (!entry.found_existing) {
            entry.value_ptr.* = .empty;
        }
        try entry.value_ptr.append(self.allocator, child);
    }

    fn isDescendantOf(self: *World, entity: root.EntityId, possible_parent: root.EntityId) bool {
        var current = self.getParent(entity);
        while (current) |parent| {
            if (root.EntityId.eql(parent, possible_parent)) return true;
            current = self.getParent(parent);
        }
        return false;
    }

    /// Fetches the parent of an entity if one is set.
    pub fn getParent(self: *World, child: root.EntityId) ?root.EntityId {
        if (!self.isAlive(child)) return null;
        const parent = self.parent_by_child.get(child.id) orelse return null;
        if (!self.isAlive(parent)) return null;
        return parent;
    }

    /// Removed the parent if one is set, or just simply returns.
    pub fn removeParent(self: *World, child: root.EntityId) void {
        const parent = self.parent_by_child.get(child.id) orelse return;
        _ = self.parent_by_child.remove(child.id);

        const child_list = self.children_by_parent.getPtr(parent.id) orelse return;
        var index: usize = 0;
        while (index < child_list.items.len) : (index += 1) {
            if (root.EntityId.eql(child_list.items[index], child)) {
                _ = child_list.swapRemove(index);
                break;
            }
        }
    }

    /// Returns an iterator (`ChildrenIterator`) containing all items.
    pub fn children(self: *World, parent: root.EntityId) ChildrenIterator {
        return .{
            .world = self,
            .items = if (self.children_by_parent.getPtr(parent.id)) |list| list.items else &.{},
        };
    }

    /// Recursively despawn entities and their children
    pub fn despawnRecursive(self: *World, entity: root.EntityId) void {
        if (!self.isAlive(entity)) return;

        while (true) {
            const child = blk: {
                const child_list = self.children_by_parent.getPtr(entity.id) orelse break;
                if (child_list.items.len == 0) break;

                const current_child = child_list.items[child_list.items.len - 1];
                if (!self.isAlive(current_child)) {
                    _ = child_list.pop();
                    _ = self.parent_by_child.remove(current_child.id);
                    continue;
                }

                break :blk current_child;
            };

            self.despawnRecursive(child);
        }

        self.despawn(entity);
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

        self.removeParent(entity);
        if (self.children_by_parent.getPtr(entity.id)) |child_list| {
            for (child_list.items) |child| {
                _ = self.parent_by_child.remove(child.id);
            }
            child_list.clearRetainingCapacity();
        }

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
/// Create one with `world.query(.{ *Position, *const Health })` or even add filters with
/// `world.query(.{ *Position, With(Player) })`.
pub fn Query(comptime terms: anytype) type {
    comptime validateQueryTerms(terms);

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

            /// Returns a pointer to the component requested by `*T` or `*const T`.
            pub fn get(self: View, comptime Ptr: type) Ptr {
                comptime {
                    if (!isQueryPointerTerm(Ptr)) {
                        @compileError("View.get expects *T or *const T");
                    }
                }

                return self.world.get(self.entity, queryComponentType(Ptr)).?;
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
                } else if (comptime root.filters.isAdded(term)) {
                    if (!world.wasAdded(entity, term.component)) return false;
                } else if (comptime root.filters.isChanged(term)) {
                    if (!world.wasChanged(entity, term.component)) return false;
                } else if (comptime root.filters.isRemoved(term)) {
                    if (!world.wasRemoved(entity, term.component)) return false;
                } else {
                    if (!world.hasComponent(entity, queryComponentType(term))) return false;
                }
            }

            return true;
        }
    };
}

fn validateQueryTerms(comptime terms: anytype) void {
    inline for (terms) |term| {
        if (comptime isFilterTerm(term)) continue;
        if (comptime isQueryPointerTerm(term)) continue;

        @compileError("Query terms must be *T, *const T, or a filter such as With(T), Without(T), Added(T), Changed(T), or Removed(T)");
    }
}

fn isFilterTerm(comptime term: type) bool {
    return root.filters.isWith(term) or
        root.filters.isWithout(term) or
        root.filters.isAdded(term) or
        root.filters.isChanged(term) or
        root.filters.isRemoved(term);
}

fn isQueryPointerTerm(comptime term: type) bool {
    return switch (@typeInfo(term)) {
        .pointer => |pointer| pointer.size == .one,
        else => false,
    };
}

fn queryComponentType(comptime term: type) type {
    return switch (@typeInfo(term)) {
        .pointer => |pointer| pointer.child,
        else => @compileError("expected a query pointer term"),
    };
}

/// An event reader allows for checking if any events have occured during the tick.
///
/// The event provided is provided with `T`.
pub fn EventReader(comptime T: type) type {
    return struct {
        const Self = @This();

        events: ?*std.ArrayList(T),
        index: usize = 0,

        /// Initialises the event reader for the world.
        ///
        /// Typically done through `world.eventReader(T);`
        pub fn init(world: *World) Self {
            return .{
                .events = world.existingEventStorage(T),
                .index = 0,
            };
        }

        /// Iterates through all events queried by the event reader.
        ///
        /// # Examples
        /// ```zig
        /// try world.sendEvent(DamageEvent{ .target = e, .amount = 25 });
        /// try world.sendEvent(DamageEvent{ .target = e, .amount = 10 });
        ///
        /// var reader = world.eventReader(DamageEvent);
        /// while (reader.next()) |ev| {
        ///     // ev is *const DamageEvent
        /// }
        /// ```
        pub fn next(self: *Self) ?*const T {
            const events = self.events orelse return null;
            if (self.index >= events.items.len) return null;

            const event = &events.items[self.index];
            self.index += 1;
            return event;
        }
    };
}

/// Iterates over the direct children of a parent entity.
pub const ChildrenIterator = struct {
    world: *World,
    items: []const root.EntityId,
    index: usize = 0,

    /// Iterates to the next entity. 
    /// # Examples
    /// ```zig
    /// var iter = world.children(parent);
    /// while (iter.next()) |child| {
    ///     // child is clutch.EntityId
    /// }
    /// ```
    pub fn next(self: *ChildrenIterator) ?root.EntityId {
        while (self.index < self.items.len) {
            const child = self.items[self.index];
            self.index += 1;
            if (self.world.isAlive(child)) return child;
        }

        return null;
    }
};

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

test "query accepts pointer component terms and filters" {
    const Position = struct { x: f32, y: f32 };
    const Velocity = struct { dx: f32, dy: f32 };
    const Player = struct {};

    var world = World.init(std.testing.allocator);
    defer world.deinit();

    const player = try world.spawn(.{
        Position{ .x = 1, .y = 2 },
        Velocity{ .dx = 3, .dy = 4 },
        Player{},
    });
    _ = try world.spawn(.{Position{ .x = 5, .y = 6 }});

    var query = world.query(.{ *const Position, *Velocity, root.filters.With(Player) });
    const view = query.next().?;

    try std.testing.expectEqual(player, view.entity);
    try std.testing.expectEqual(@as(f32, 1), view.get(*const Position).x);

    const velocity = view.get(*Velocity);
    velocity.dx = 8;
    try std.testing.expectEqual(@as(f32, 8), world.get(player, Velocity).?.dx);
    try std.testing.expect(query.next() == null);
}

test "query matches removed component filters for the current tick" {
    const Health = struct { hp: f32 };

    var world = World.init(std.testing.allocator);
    defer world.deinit();

    const entity = try world.spawn(.{Health{ .hp = 100 }});
    world.tick();

    try world.removeComponent(entity, Health);

    var removed = world.query(.{root.filters.Removed(Health)});
    const view = removed.next().?;
    try std.testing.expectEqual(entity, view.entity);
    try std.testing.expect(removed.next() == null);

    world.tick();

    var cleared = world.query(.{root.filters.Removed(Health)});
    try std.testing.expect(cleared.next() == null);
}

test "world hierarchy stores parent and iterates children" {
    var world = World.init(std.testing.allocator);
    defer world.deinit();

    const parent = try world.spawn(.{});
    const first = try world.spawn(.{});
    const second = try world.spawn(.{});

    try world.setParent(parent, .{ first, second });

    try std.testing.expectEqual(parent, world.getParent(first).?);
    try std.testing.expectEqual(parent, world.getParent(second).?);

    var children = world.children(parent);
    var count: usize = 0;
    while (children.next()) |_| count += 1;
    try std.testing.expectEqual(@as(usize, 2), count);
}

test "world hierarchy despawns recursively" {
    var world = World.init(std.testing.allocator);
    defer world.deinit();

    const parent = try world.spawn(.{});
    const child = try world.spawn(.{});
    const grandchild = try world.spawn(.{});

    try world.setParent(child, parent);
    try world.setParent(grandchild, child);

    world.despawnRecursive(parent);

    try std.testing.expect(!world.isAlive(parent));
    try std.testing.expect(!world.isAlive(child));
    try std.testing.expect(!world.isAlive(grandchild));
    try std.testing.expectEqual(@as(usize, 0), world.entityCount());
}

test "world hierarchy removes parent links" {
    var world = World.init(std.testing.allocator);
    defer world.deinit();

    const parent = try world.spawn(.{});
    const child = try world.spawn(.{});

    try world.setParent(child, parent);
    world.removeParent(child);

    try std.testing.expect(world.getParent(child) == null);
    var children = world.children(parent);
    try std.testing.expect(children.next() == null);
}
