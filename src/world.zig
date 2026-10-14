const std = @import("std");
const root = @import("root.zig");

const Tick = root.storage.Tick;

const ErasedStorage = struct {
    ptr: *anyopaque,
    deinitFn: *const fn (*anyopaque, std.mem.Allocator) void,
    hasEntityFn: *const fn (*anyopaque, root.EntityId) bool,
    removeEntityFn: *const fn (*anyopaque, root.EntityId, Tick) void,
    removeManyFn: *const fn (*anyopaque, []const root.EntityId, Tick) void,

    fn deinit(self: ErasedStorage, allocator: std.mem.Allocator) void {
        self.deinitFn(self.ptr, allocator);
    }

    fn hasEntity(self: ErasedStorage, entity: root.EntityId) bool {
        return self.hasEntityFn(self.ptr, entity);
    }

    fn removeEntity(self: ErasedStorage, entity: root.EntityId, tick: Tick) void {
        self.removeEntityFn(self.ptr, entity, tick);
    }

    /// `removeEntity` for each of `entities`, in one call into typed code.
    fn removeMany(self: ErasedStorage, entities: []const root.EntityId, tick: Tick) void {
        self.removeManyFn(self.ptr, entities, tick);
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

const ErasedResource = struct {
    ptr: *anyopaque,
    deinitFn: *const fn (*anyopaque, std.mem.Allocator) void,

    fn deinit(self: ErasedResource, allocator: std.mem.Allocator) void {
        self.deinitFn(self.ptr, allocator);
    }
};

fn typeId(comptime T: type) u64 {
    return comptime std.hash.Wyhash.hash(0, @typeName(T));
}

/// Next free component type index; see `typeIndex`.
var next_type_index = std.atomic.Value(u32).init(0);
const unassigned_type_index = std.math.maxInt(u32);

/// A small number for component type `T`, the same in every world: the position of its
/// storage in `World.component_storages`, so finding a storage is an array read, not a hash.
/// Assigned on first use; safe to call from several threads.
inline fn typeIndex(comptime T: type) u32 {
    const Slot = struct {
        const Component = T; // one `Slot` per component type
        var index = std.atomic.Value(u32).init(unassigned_type_index);
    };
    _ = Slot.Component;
    const known = Slot.index.load(.acquire);
    if (known != unassigned_type_index) return known;
    const fresh = next_type_index.fetchAdd(1, .monotonic);
    // Another thread may have assigned one meanwhile; theirs wins and `fresh` goes unused.
    return Slot.index.cmpxchgStrong(unassigned_type_index, fresh, .acq_rel, .acquire) orelse fresh;
}

fn deinitTypedStorage(comptime T: type, ptr: *anyopaque, allocator: std.mem.Allocator) void {
    const Storage = root.storage.ComponentStorage(T);
    const storage: *Storage = @ptrCast(@alignCast(ptr));
    storage.deinit(allocator);
    allocator.destroy(storage);
}

fn typedStorageHasEntity(comptime T: type, ptr: *anyopaque, entity: root.EntityId) bool {
    const Storage = root.storage.ComponentStorage(T);
    const storage: *Storage = @ptrCast(@alignCast(ptr));
    return storage.has(entity);
}

fn removeEntityFromTypedStorage(comptime T: type, ptr: *anyopaque, entity: root.EntityId, tick: Tick) void {
    const Storage = root.storage.ComponentStorage(T);
    const storage: *Storage = @ptrCast(@alignCast(ptr));
    storage.remove(entity, tick);
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

fn deinitTypedResource(comptime T: type, ptr: *anyopaque, allocator: std.mem.Allocator) void {
    const resource: *T = @ptrCast(@alignCast(ptr));
    allocator.destroy(resource);
}

/// One entity id's generation (bumped on despawn, so stale handles stop matching), liveness,
/// and which component types it has (see `components`).
const EntitySlot = struct {
    generation: u32,
    alive: bool,
    /// Bit `i` set: the entity may have the component with type index `i` (for `i` below
    /// `overflow_bit_index`); the top bit covers all larger type indices. Set on add and only
    /// cleared on despawn, so it can over-report: removing from a storage the entity isn't in
    /// is a no-op. Lets `despawn` skip the storages the entity was never in.
    components: u64 = 0,
};

const overflow_bit_index = 63;
const overflow_bit: u64 = 1 << overflow_bit_index;

/// The `EntitySlot.components` bit for type index `type_index`.
inline fn componentBit(type_index: usize) u64 {
    return if (type_index < overflow_bit_index) @as(u64, 1) << @intCast(type_index) else overflow_bit;
}

/// Stores all components and entities using the ECS paradigm.
///
/// Typically should not be received as an argument in a system. Use `clutch.Command` instead.
pub const World = struct {
    const HookFn = *const fn (*World, root.EntityId) void;

    const ErasedSchedule = struct {
        runFn: *const fn (*World) anyerror!void,

        fn run(self: ErasedSchedule, world: *World) !void {
            try self.runFn(world);
        }
    };

    allocator: std.mem.Allocator,

    /// Indexed by entity id: generation and liveness together, so `isAlive` reads one cache line.
    slots: std.ArrayList(EntitySlot),
    free_ids: std.ArrayList(u32),
    living_count: usize = 0,
    /// The current change tick: `Added`, `Changed` and `Removed` match what happened during it.
    /// Starts at 1 (0 means "never") and advances with `tick`.
    change_tick: Tick = 1,

    /// Reused by every system that takes `Commands`, so running one allocates nothing.
    system_commands: root.CommandBuffer,
    /// Reused by `despawnBatch` for the entities it is despawning.
    despawn_scratch: std.ArrayList(root.EntityId) = .empty,

    /// Indexed by `typeIndex`; null for component types this world hasn't stored yet.
    component_storages: std.ArrayList(?ErasedStorage),
    event_storages: std.AutoHashMap(u64, ErasedEventStorage),
    resources: std.AutoHashMap(u64, ErasedResource),
    on_add_hooks: std.AutoHashMap(u64, std.ArrayList(HookFn)),
    on_remove_hooks: std.AutoHashMap(u64, std.ArrayList(HookFn)),
    schedules: std.AutoHashMap(u64, std.ArrayList(ErasedSchedule)),
    schedule_children: std.AutoHashMap(u64, std.ArrayList(u64)),
    parent_by_child: std.AutoHashMap(u32, root.EntityId),
    children_by_parent: std.AutoHashMap(u32, std.ArrayList(root.EntityId)),

    /// Creates a new World with the given allocator.
    pub fn init(allocator: std.mem.Allocator) World {
        return .{
            .allocator = allocator,
            .slots = .empty,
            .free_ids = .empty,
            .component_storages = .empty,
            .system_commands = .init(allocator),
            .event_storages = std.AutoHashMap(u64, ErasedEventStorage).init(allocator),
            .resources = std.AutoHashMap(u64, ErasedResource).init(allocator),
            .on_add_hooks = std.AutoHashMap(u64, std.ArrayList(HookFn)).init(allocator),
            .on_remove_hooks = std.AutoHashMap(u64, std.ArrayList(HookFn)).init(allocator),
            .schedules = std.AutoHashMap(u64, std.ArrayList(ErasedSchedule)).init(allocator),
            .schedule_children = std.AutoHashMap(u64, std.ArrayList(u64)).init(allocator),
            .parent_by_child = std.AutoHashMap(u32, root.EntityId).init(allocator),
            .children_by_parent = std.AutoHashMap(u32, std.ArrayList(root.EntityId)).init(allocator),
        };
    }

    /// Frees all resources associated with the world.
    pub fn deinit(self: *World) void {
        var schedule_iter = self.schedules.valueIterator();
        while (schedule_iter.next()) |schedules| {
            schedules.deinit(self.allocator);
        }
        self.schedules.deinit();

        var schedule_child_iter = self.schedule_children.valueIterator();
        while (schedule_child_iter.next()) |child_stages| {
            child_stages.deinit(self.allocator);
        }
        self.schedule_children.deinit();

        var add_hook_iter = self.on_add_hooks.valueIterator();
        while (add_hook_iter.next()) |hooks| {
            hooks.deinit(self.allocator);
        }
        self.on_add_hooks.deinit();

        var remove_hook_iter = self.on_remove_hooks.valueIterator();
        while (remove_hook_iter.next()) |hooks| {
            hooks.deinit(self.allocator);
        }
        self.on_remove_hooks.deinit();

        for (self.component_storages.items) |maybe_storage| {
            if (maybe_storage) |storage| storage.deinit(self.allocator);
        }
        self.component_storages.deinit(self.allocator);

        var event_iter = self.event_storages.valueIterator();
        while (event_iter.next()) |storage| {
            storage.deinit(self.allocator);
        }
        self.event_storages.deinit();

        var resource_iter = self.resources.valueIterator();
        while (resource_iter.next()) |resource| {
            resource.deinit(self.allocator);
        }
        self.resources.deinit();

        var children_iter = self.children_by_parent.valueIterator();
        while (children_iter.next()) |child_list| {
            child_list.deinit(self.allocator);
        }
        self.children_by_parent.deinit();
        self.parent_by_child.deinit();

        self.system_commands.deinit();
        self.despawn_scratch.deinit(self.allocator);
        self.slots.deinit(self.allocator);
        self.free_ids.deinit(self.allocator);
    }

    inline fn storageFor(self: *World, comptime T: type) !*root.storage.ComponentStorage(T) {
        if (self.existingStorage(T)) |storage| return storage;
        return self.createStorage(T);
    }

    fn createStorage(self: *World, comptime T: type) !*root.storage.ComponentStorage(T) {
        @branchHint(.cold);
        const Storage = root.storage.ComponentStorage(T);
        const index = typeIndex(T);
        if (index >= self.component_storages.items.len) {
            try self.component_storages.appendNTimes(self.allocator, null, index + 1 - self.component_storages.items.len);
        }
        const storage = try self.allocator.create(Storage);
        storage.* = Storage.init(self.allocator);

        self.component_storages.items[index] = (ErasedStorage{
            .ptr = storage,
            .deinitFn = struct {
                fn run(ptr: *anyopaque, allocator: std.mem.Allocator) void {
                    deinitTypedStorage(T, ptr, allocator);
                }
            }.run,
            .hasEntityFn = struct {
                fn run(ptr: *anyopaque, entity: root.EntityId) bool {
                    return typedStorageHasEntity(T, ptr, entity);
                }
            }.run,
            .removeEntityFn = struct {
                fn run(ptr: *anyopaque, entity: root.EntityId, at: Tick) void {
                    removeEntityFromTypedStorage(T, ptr, entity, at);
                }
            }.run,
            .removeManyFn = struct {
                fn run(ptr: *anyopaque, entities: []const root.EntityId, at: Tick) void {
                    const typed: *Storage = @ptrCast(@alignCast(ptr));
                    typed.removeMany(entities, at);
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

    inline fn existingStorage(self: *World, comptime T: type) ?*root.storage.ComponentStorage(T) {
        const index = typeIndex(T);
        if (index >= self.component_storages.items.len) return null;
        const erased = self.component_storages.items[index] orelse return null;
        return @ptrCast(@alignCast(erased.ptr));
    }

    /// Inserts or replaces a resource of the same type.
    pub fn insertResource(self: *World, resource: anytype) !void {
        const T = @TypeOf(resource);
        const id = typeId(T);

        if (self.resources.get(id)) |erased| {
            const existing: *T = @ptrCast(@alignCast(erased.ptr));
            existing.* = resource;
            return;
        }

        const stored = try self.allocator.create(T);
        stored.* = resource;

        try self.resources.put(id, .{
            .ptr = stored,
            .deinitFn = struct {
                fn run(ptr: *anyopaque, allocator: std.mem.Allocator) void {
                    deinitTypedResource(T, ptr, allocator);
                }
            }.run,
        });
    }

    /// Returns a mutable pointer to a resource if one exists.
    pub fn getResource(self: *World, comptime T: type) ?*T {
        const erased = self.resources.get(typeId(T)) orelse return null;
        return @ptrCast(@alignCast(erased.ptr));
    }

    /// Initialises a new empty entity in the world.
    fn createEntity(self: *World) !root.EntityId {
        if (self.free_ids.items.len == 0) {
            // Room for every id in `free_ids` now, so `despawn` never allocates.
            try self.free_ids.ensureTotalCapacity(self.allocator, self.slots.items.len + 1);
            try self.slots.ensureUnusedCapacity(self.allocator, 1);
        }
        return self.createEntityAssumeCapacity();
    }

    /// `createEntity` once `free_ids` has an id or `slots` and `free_ids` have room for one more.
    fn createEntityAssumeCapacity(self: *World) root.EntityId {
        if (self.free_ids.items.len > 0) {
            const id = self.free_ids.pop().?;
            self.slots.items[@intCast(id)].alive = true;
            self.living_count += 1;

            return root.EntityId.init(id, self.slots.items[@intCast(id)].generation);
        }

        const id: u32 = @intCast(self.slots.items.len);
        self.slots.appendAssumeCapacity(.{ .generation = 0, .alive = true });
        self.living_count += 1;

        return root.EntityId.init(id, 0);
    }

    /// Allocate room for `count` entities in total, so spawning (and despawning) that many
    /// never reallocates. Optional: the world grows on its own.
    pub fn reserveEntities(self: *World, count: usize) !void {
        try self.slots.ensureTotalCapacityPrecise(self.allocator, count);
        try self.free_ids.ensureTotalCapacityPrecise(self.allocator, count);
    }

    /// Allocate room for `count` values of component `T` (for entity ids below `count`), so
    /// adding that many never reallocates. Optional: storages grow on their own.
    pub fn reserve(self: *World, comptime T: type, count: usize) !void {
        const storage = try self.storageFor(T);
        try storage.reserve(self.allocator, count);
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
        if (try storage.insert(self.allocator, entity, component, self.change_tick)) {
            self.slots.items[entity.index()].components |= componentBit(typeIndex(T));
            self.runHooks(&self.on_add_hooks, typeIndex(T), entity);
        }
    }

    /// Removes component(s) from an entity.
    pub fn removeComponent(self: *World, entity: root.EntityId, comptime T: type) !void {
        if (!self.isAlive(entity)) return error.EntityNotAlive;

        const storage = self.existingStorage(T) orelse return;
        // Hooks see the component before it goes, so only they need the separate check;
        // `remove` already ignores entities without one.
        if (self.on_remove_hooks.count() != 0 and storage.has(entity)) {
            self.runHooks(&self.on_remove_hooks, typeIndex(T), entity);
        }
        // The entity's `components` bit stays set until despawn (see `EntitySlot`).
        storage.remove(entity, self.change_tick);
    }

    /// Removes component(s) from an entity, ignoring missing or dead entities.
    pub fn remove(self: *World, entity: root.EntityId, comptime T: type) void {
        self.removeComponent(entity, T) catch {};
    }

    /// Registers a hook that runs when the component type is added to an entity.
    pub fn onAdd(self: *World, comptime T: type, hook: HookFn) void {
        self.addHook(&self.on_add_hooks, typeIndex(T), hook) catch @panic("failed to add onAdd hook");
    }

    /// Registers a hook that runs when the component type is removed from an entity.
    pub fn onRemove(self: *World, comptime T: type, hook: HookFn) void {
        self.addHook(&self.on_remove_hooks, typeIndex(T), hook) catch @panic("failed to add onRemove hook");
    }

    fn addHook(self: *World, hooks: *std.AutoHashMap(u64, std.ArrayList(HookFn)), component_id: u64, hook: HookFn) !void {
        const entry = try hooks.getOrPut(component_id);
        if (!entry.found_existing) {
            entry.value_ptr.* = .empty;
        }

        try entry.value_ptr.append(self.allocator, hook);
    }

    fn runHooks(self: *World, hooks: *std.AutoHashMap(u64, std.ArrayList(HookFn)), component_id: u64, entity: root.EntityId) void {
        if (hooks.count() == 0) return; // the common case: skip the hash
        const registered_hooks = hooks.getPtr(component_id) orelse return;
        for (registered_hooks.items) |hook| {
            hook(self, entity);
        }
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
        storage.markChanged(entity, self.change_tick);
    }

    /// Was a type recently added to an entity?
    pub fn wasAdded(self: *World, entity: root.EntityId, comptime T: type) bool {
        if (!self.isAlive(entity)) return false;

        const storage = self.existingStorage(T) orelse return false;
        return storage.wasAdded(entity, self.change_tick);
    }

    /// Was a component's data mutated for an entity?
    pub fn wasChanged(self: *World, entity: root.EntityId, comptime T: type) bool {
        if (!self.isAlive(entity)) return false;

        const storage = self.existingStorage(T) orelse return false;
        return storage.wasChanged(entity, self.change_tick);
    }

    /// Was a component removed from an entity?
    pub fn wasRemoved(self: *World, entity: root.EntityId, comptime T: type) bool {
        if (!self.isAlive(entity)) return false;

        const storage = self.existingStorage(T) orelse return false;
        return storage.wasRemoved(entity, self.change_tick);
    }

    /// Ticks and iterates through modifications, allowing for filters such as
    /// `Changed(T)` and `Added(T)` to be available.
    pub fn tick(self: *World) void {
        // Wraps after 2^32 ticks, skipping 0 ("never").
        self.change_tick +%= 1;
        if (self.change_tick == 0) self.change_tick = 1;

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

    /// Adds a schedule to its declared stage.
    pub fn addSchedule(self: *World, comptime ScheduleType: type) void {
        self.addScheduleFallible(ScheduleType) catch @panic("failed to add schedule");
    }

    /// Adds a schedule to its declared stage, returning allocation errors to the caller.
    pub fn addScheduleFallible(self: *World, comptime ScheduleType: type) !void {
        const schedule_stage = ScheduleType.stage_value;
        const entry = try self.schedules.getOrPut(schedule_stage.id);
        if (!entry.found_existing) {
            entry.value_ptr.* = .empty;
        }

        try entry.value_ptr.append(self.allocator, .{
            .runFn = struct {
                fn run(world: *World) !void {
                    try ScheduleType.run(world);
                }
            }.run,
        });

        if (schedule_stage.parent_id) |parent_id| {
            try self.addScheduleChild(parent_id, schedule_stage.id);
        }
    }

    /// Runs all schedules registered for the stage.
    pub fn runStage(self: *World, comptime stage_value: anytype) !void {
        const id = scheduleId(stage_value);
        try self.runStageById(id);
    }

    fn runStageById(self: *World, id: u64) !void {
        if (self.schedules.getPtr(id)) |schedules_for_stage| {
            for (schedules_for_stage.items) |registered| {
                try registered.run(self);
            }
        }

        const child_stages = self.schedule_children.getPtr(id) orelse return;
        for (child_stages.items) |child_id| {
            try self.runStageById(child_id);
        }
    }

    /// Runs primary schedules in their built-in order.
    pub fn runAll(self: *World) !void {
        inline for (root.schedules.primary_order) |primary_stage| {
            try self.runStageById(scheduleId(primary_stage));
        }
    }

    fn addScheduleChild(self: *World, parent_id: u64, child_id: u64) !void {
        const entry = try self.schedule_children.getOrPut(parent_id);
        if (!entry.found_existing) {
            entry.value_ptr.* = .empty;
        }

        for (entry.value_ptr.items) |existing_child_id| {
            if (existing_child_id == child_id) return;
        }

        try entry.value_ptr.append(self.allocator, child_id);
    }

    fn scheduleId(comptime stage_value: anytype) u64 {
        const T = @TypeOf(stage_value);
        if (T == root.schedules.ScheduleStage) return stage_value.id;
        if (T == root.Stages) return root.schedules.Stage.primary(stage_value).id;

        return root.schedules.stage(stage_value).id;
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
    pub inline fn isAlive(self: *World, entity: root.EntityId) bool {
        if (entity.id >= self.slots.items.len) return false;
        const index = entity.index();
        const slot = self.slots.items[index];
        return slot.alive and slot.generation == entity.generation;
    }

    /// Despawns an entity, marking it as dead and freeing its ID for reuse.
    pub fn despawn(self: *World, entity: root.EntityId) void {
        if (!self.isAlive(entity)) return;

        // Worlds that never set a parent skip both hash lookups.
        if (self.parent_by_child.count() != 0) {
            self.removeParent(entity);
            if (self.children_by_parent.getPtr(entity.id)) |child_list| {
                for (child_list.items) |child| {
                    _ = self.parent_by_child.remove(child.id);
                }
                child_list.clearRetainingCapacity();
            }
        }

        // Remove only the components the entity has. Tick 0: a despawned entity never matches
        // `Removed`, so a reused id doesn't either. Re-read the mask each round, since a remove
        // hook may add components to the entity being despawned.
        const index = entity.index();
        if (self.on_remove_hooks.count() == 0) {
            // Nothing can add components meanwhile: walk a copy of the mask, clear it once.
            var components = self.slots.items[index].components;
            while (components & ~overflow_bit != 0) : (components &= components - 1) {
                self.component_storages.items[@ctz(components)].?.removeEntity(entity, 0);
            }
            if (components & overflow_bit != 0) {
                for (self.component_storages.items[overflow_bit_index..]) |maybe_storage| {
                    if (maybe_storage) |storage| storage.removeEntity(entity, 0);
                }
            }
            self.slots.items[index].components = 0;
        }
        while (self.slots.items[index].components != 0) {
            const components = self.slots.items[index].components;
            if (components & ~overflow_bit != 0) {
                const type_index: usize = @ctz(components);
                self.slots.items[index].components &= ~componentBit(type_index);
                // The mask may over-report (see `EntitySlot`): only real components get hooks.
                const storage = self.component_storages.items[type_index].?;
                if (!storage.hasEntity(entity)) continue;
                self.runHooks(&self.on_remove_hooks, type_index, entity);
                storage.removeEntity(entity, 0);
                continue;
            }
            // Only large type indices left, which the mask doesn't track one by one.
            self.slots.items[index].components &= ~overflow_bit;
            var type_index: usize = overflow_bit_index;
            while (type_index < self.component_storages.items.len) : (type_index += 1) {
                const storage = self.component_storages.items[type_index] orelse continue;
                if (!storage.hasEntity(entity)) continue;
                self.runHooks(&self.on_remove_hooks, type_index, entity);
                storage.removeEntity(entity, 0);
            }
        }

        self.slots.items[index].alive = false;
        self.slots.items[index].generation += 1;
        self.free_ids.appendAssumeCapacity(entity.id);
        self.living_count -= 1;
    }

    /// Spawns `out.len` entities, each with `components` (a tuple, as in `spawn`), and writes
    /// their ids to `out`. Like calling `spawn` that many times, but each component's storage
    /// is found and grown once for the whole batch. On error nothing is spawned.
    pub fn spawnBatch(self: *World, out: []root.EntityId, components: anytype) !void {
        if (out.len == 0) return;
        // A hook may add components, using up capacity reserved for the batch: go one by one.
        if (self.on_add_hooks.count() != 0) {
            var spawned: usize = 0;
            errdefer for (out[0..spawned]) |entity| self.despawn(entity);
            for (out) |*entity| {
                entity.* = try self.spawn(components);
                spawned += 1;
            }
            return;
        }

        // Reserve everything first, so a failed allocation leaves the world unchanged.
        const reused = @min(self.free_ids.items.len, out.len);
        const fresh = out.len - reused;
        try self.slots.ensureUnusedCapacity(self.allocator, fresh);
        try self.free_ids.ensureTotalCapacity(self.allocator, self.slots.items.len + fresh);
        var max_id: u32 = if (fresh > 0) @intCast(self.slots.items.len + fresh - 1) else 0;
        for (self.free_ids.items[self.free_ids.items.len - reused ..]) |id| max_id = @max(max_id, id);
        inline for (components) |component| {
            const storage = try self.storageFor(@TypeOf(component));
            try storage.ensureUnusedCapacity(self.allocator, out.len, max_id);
        }

        var mask: u64 = 0;
        inline for (components) |component| mask |= componentBit(typeIndex(@TypeOf(component)));
        for (out) |*entity| {
            entity.* = self.createEntityAssumeCapacity();
            self.slots.items[entity.index()].components = mask;
        }
        inline for (components) |component| {
            const storage = self.existingStorage(@TypeOf(component)).?;
            for (out) |entity| _ = storage.insertAssumeCapacity(entity, component, self.change_tick);
        }
    }

    /// Adds `component` to every entity in `entities` (replacing values they already have),
    /// finding and growing its storage once. Fails with `EntityNotAlive`, changing nothing, if
    /// any entity is dead.
    pub fn addComponents(self: *World, entities: []const root.EntityId, component: anytype) !void {
        const T = @TypeOf(component);
        // A hook may add components, using up capacity reserved for the batch: go one by one.
        if (self.on_add_hooks.count() != 0) {
            for (entities) |entity| if (!self.isAlive(entity)) return error.EntityNotAlive;
            for (entities) |entity| try self.addComponent(entity, component);
            return;
        }

        // Check every entity before changing anything. Each one's `components` bit is set on
        // the way: the mask may over-report (see `EntitySlot`), so a failure here is harmless,
        // and the add loop below doesn't touch the slots again.
        const bit = componentBit(typeIndex(T));
        var max_id: u32 = 0;
        for (entities) |entity| {
            if (!self.isAlive(entity)) return error.EntityNotAlive;
            self.slots.items[entity.index()].components |= bit;
            max_id = @max(max_id, entity.id);
        }
        if (entities.len == 0) return;

        const storage = try self.storageFor(T);
        try storage.ensureUnusedCapacity(self.allocator, entities.len, max_id);
        for (entities) |entity| _ = storage.insertAssumeCapacity(entity, component, self.change_tick);
    }

    /// Removes component `T` from every entity in `entities` that has it, finding its storage
    /// once. Fails with `EntityNotAlive`, changing nothing, if any entity is dead.
    pub fn removeComponents(self: *World, entities: []const root.EntityId, comptime T: type) !void {
        for (entities) |entity| if (!self.isAlive(entity)) return error.EntityNotAlive;
        if (self.on_remove_hooks.count() != 0) {
            for (entities) |entity| try self.removeComponent(entity, T);
            return;
        }

        // Their `components` bits stay set until despawn (see `EntitySlot`).
        const storage = self.existingStorage(T) orelse return;
        storage.removeMany(entities, self.change_tick);
    }

    /// Despawns every living entity in `entities`; dead ids and repeats are skipped. Removes
    /// each component type from the whole batch in one loop. Fails only if it cannot allocate,
    /// before changing anything.
    pub fn despawnBatch(self: *World, entities: []const root.EntityId) !void {
        // Hierarchy links and remove hooks need `despawn`'s per-entity bookkeeping.
        if (self.parent_by_child.count() != 0 or self.on_remove_hooks.count() != 0) {
            for (entities) |entity| self.despawn(entity);
            return;
        }

        try self.despawn_scratch.ensureTotalCapacity(self.allocator, entities.len);
        self.despawn_scratch.clearRetainingCapacity();
        // One pass over the slots: kill each entity and free its id. The bumped generation
        // makes a repeat of it in `entities` fail `isAlive`, so it is skipped.
        var components: u64 = 0;
        for (entities) |entity| {
            if (!self.isAlive(entity)) continue;
            const slot = &self.slots.items[entity.index()];
            components |= slot.components;
            slot.* = .{ .generation = slot.generation + 1, .alive = false };
            self.free_ids.appendAssumeCapacity(entity.id);
            self.despawn_scratch.appendAssumeCapacity(entity);
        }
        const doomed = self.despawn_scratch.items;
        self.living_count -= doomed.len;

        // Tick 0: despawned entities never match `Removed` (see `despawn`).
        var low = components & ~overflow_bit;
        while (low != 0) : (low &= low - 1) {
            self.component_storages.items[@ctz(low)].?.removeMany(doomed, 0);
        }
        if (components & overflow_bit != 0) {
            for (self.component_storages.items[overflow_bit_index..]) |maybe_storage| {
                if (maybe_storage) |storage| storage.removeMany(doomed, 0);
            }
        }
    }

    /// Returns the number of living entities in the world.
    pub fn entityCount(self: *World) usize {
        return self.living_count;
    }

    /// Despawns all living entities while keeping resources and registered hooks/schedules.
    pub fn clear(self: *World) void {
        var index: usize = 0;
        while (index < self.slots.items.len) : (index += 1) {
            if (!self.slots.items[index].alive) continue;

            const entity = root.EntityId.init(@intCast(index), self.slots.items[index].generation);
            self.despawn(entity);
        }
    }
};

/// A query requests components for entities from the world.
///
/// Create one with `world.query(.{ *Position, *const Health })` or even add filters with
/// `world.query(.{ *Position, With(Player) })`.
///
/// It looks up its storages once, then walks only the entities in the smallest storage every
/// match must have, checking the other terms with array reads. It walks backwards, so removing
/// the current entity's components (or despawning it) mid-iteration skips nothing.
pub fn Query(comptime terms: anytype) type {
    comptime validateQueryTerms(terms);

    const Storages = comptime blk: {
        var types: [terms.len]type = undefined;
        for (terms, 0..) |term, i| types[i] = ?*root.storage.ComponentStorage(termComponent(term));
        break :blk std.meta.Tuple(&types);
    };

    // Per term, the matched entity's position in that term's storage (set for component terms).
    const Indices = [terms.len]u32;

    return struct {
        const Self = @This();

        world: *World,
        /// Per term, the storage of the component it names; null if no entity has had one.
        storages: Storages,
        /// Which term's storage `driver` is; its dense index is the walk position itself.
        driver_term: usize = std.math.maxInt(usize),
        /// The entities to walk: the smallest storage that every match is in. Null when no
        /// term requires a component, in which case the query walks every entity slot.
        driver: ?*const std.ArrayList(root.EntityId),
        /// Counts down through `driver`, or up through entity slots when there is none.
        index: usize = 0,
        /// A required component has no storage, so nothing can match.
        exhausted: bool = false,

        pub const is_query = true;
        pub const query_terms = terms;

        /// Represents a view into the world, providing access to one entity and its components.
        pub const View = struct {
            /// The world this view is associated with.
            world: *World,
            /// Represents the current entity in the existing view
            entity: root.EntityId,
            storages: Storages,
            indices: Indices,

            /// Returns a pointer to the component requested by `*T` or `*const T`.
            pub inline fn get(self: View, comptime Ptr: type) Ptr {
                comptime {
                    if (!isQueryPointerTerm(Ptr)) {
                        @compileError("View.get expects *T or *const T");
                    }
                }
                const Component = queryComponentType(Ptr);
                // A component the query matched on: read it through the storage it already has.
                inline for (terms, 0..) |term, i| {
                    if (comptime isQueryPointerTerm(term) and queryComponentType(term) == Component) {
                        return &self.storages[i].?.values.items[self.indices[i]];
                    }
                }
                return self.world.get(self.entity, Component).?;
            }
        };

        /// Initialises a new `Query` for the given terms.
        ///
        /// The more appropriate method of initialisation is `world.query(.{...})`, as this
        /// function is used internally. But who am I (the author) to say what you can do 🤷
        pub fn init(world: *World) Self {
            var self = Self{ .world = world, .storages = undefined, .driver = null };
            var smallest: usize = std.math.maxInt(usize);
            inline for (terms, 0..) |term, i| {
                self.storages[i] = world.existingStorage(termComponent(term));
                if (comptime termRequiresComponent(term)) {
                    if (self.storages[i]) |storage| {
                        if (storage.entities.items.len < smallest) {
                            smallest = storage.entities.items.len;
                            self.driver = &storage.entities;
                            self.driver_term = i;
                        }
                    } else self.exhausted = true;
                }
            }
            if (self.driver) |driver| self.index = driver.items.len;
            return self;
        }

        /// Iterates to the next View
        pub fn next(self: *Self) ?View {
            if (self.exhausted) return null;
            if (self.driver) |driver| {
                while (self.index > 0) {
                    self.index -= 1;
                    // Entities removed earlier in the walk can shrink the list below `index`.
                    if (self.index >= driver.items.len) continue;
                    const entity = driver.items[self.index];
                    var indices: Indices = undefined;
                    if (self.matches(entity, &indices)) return self.view(entity, indices);
                }
                return null;
            }

            const world = self.world;
            while (self.index < world.slots.items.len) {
                const id: u32 = @intCast(self.index);
                const entity = root.EntityId.init(id, world.slots.items[self.index].generation);
                self.index += 1;
                var indices: Indices = undefined;
                if (world.slots.items[self.index - 1].alive and self.matches(entity, &indices)) return self.view(entity, indices);
            }
            return null;
        }

        inline fn view(self: *const Self, entity: root.EntityId, indices: Indices) View {
            return .{ .world = self.world, .entity = entity, .storages = self.storages, .indices = indices };
        }

        /// Whether `entity` matches every term; fills `indices` for the component terms.
        inline fn matches(self: *const Self, entity: root.EntityId, indices: *Indices) bool {
            const tick = self.world.change_tick;
            inline for (terms, 0..) |term, i| {
                const storage = self.storages[i];
                if (comptime root.filters.isWithout(term)) {
                    if (storage) |s| if (s.has(entity)) return false;
                } else if (comptime root.filters.isRemoved(term)) {
                    const s = storage orelse return false;
                    if (!s.wasRemoved(entity, tick)) return false;
                } else if (comptime root.filters.isAdded(term)) {
                    if (!storage.?.wasAdded(entity, tick)) return false;
                } else if (comptime root.filters.isChanged(term)) {
                    if (!storage.?.wasChanged(entity, tick)) return false;
                } else if (i == self.driver_term) {
                    // The storage being walked: the entity is at the walk position.
                    indices[i] = @intCast(self.index);
                } else {
                    // `*T`, `*const T` and `With(T)`: required, so its storage exists.
                    indices[i] = storage.?.denseIndex(entity) orelse return false;
                }
            }
            return true;
        }
    };
}

/// The component a query term names.
fn termComponent(comptime term: type) type {
    return if (isFilterTerm(term)) term.component else queryComponentType(term);
}

/// Whether every entity a term matches must have its component.
fn termRequiresComponent(comptime term: type) bool {
    return !root.filters.isWithout(term) and !root.filters.isRemoved(term);
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

test "world onAdd hook runs when component is added" {
    const Health = struct { hp: f32 };
    const State = struct {
        var count: usize = 0;

        fn onAdd(world: *World, entity: root.EntityId) void {
            _ = world;
            _ = entity;
            count += 1;
        }
    };

    var world = World.init(std.testing.allocator);
    defer world.deinit();

    world.onAdd(Health, State.onAdd);

    const first = try world.spawn(.{Health{ .hp = 50 }});
    const second = try world.spawn(.{});
    try world.addComponent(second, Health{ .hp = 80 });
    try world.addComponent(first, Health{ .hp = 100 });

    try std.testing.expectEqual(@as(usize, 2), State.count);
}

test "world onRemove hook runs when component is removed and despawned" {
    const Health = struct { hp: f32 };
    const Position = struct { x: f32, y: f32 };
    const State = struct {
        var count: usize = 0;

        fn onRemove(world: *World, entity: root.EntityId) void {
            _ = world;
            _ = entity;
            count += 1;
        }
    };

    var world = World.init(std.testing.allocator);
    defer world.deinit();

    world.onRemove(Health, State.onRemove);

    const removed = try world.spawn(.{Health{ .hp = 100 }});
    world.remove(removed, Health);

    const despawned = try world.spawn(.{ Health{ .hp = 100 }, Position{ .x = 0, .y = 0 } });
    world.despawn(despawned);

    try std.testing.expectEqual(@as(usize, 2), State.count);
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

test "despawning entities mid-query still visits every entity exactly once" {
    const Position = struct { x: u32 };

    var world = World.init(std.testing.allocator);
    defer world.deinit();

    for (0..10) |i| _ = try world.spawn(.{Position{ .x = @intCast(i) }});

    var seen = [_]u32{0} ** 10;
    var query = world.query(.{*const Position});
    while (query.next()) |view| {
        seen[view.get(*const Position).x] += 1;
        world.despawn(view.entity);
    }

    try std.testing.expectEqualSlices(u32, &([_]u32{1} ** 10), &seen);
    try std.testing.expectEqual(@as(usize, 0), world.entityCount());
}

test "query views read each entity's own components after removals reshuffle storages" {
    const Position = struct { id: u32 };
    const Velocity = struct { id: u32 };

    var world = World.init(std.testing.allocator);
    defer world.deinit();

    var entities: [8]root.EntityId = undefined;
    for (&entities, 0..) |*entity, i| {
        entity.* = try world.spawn(.{ Position{ .id = @intCast(i) }, Velocity{ .id = @intCast(i) } });
    }
    // Swap-removals move other entities' Positions to new dense slots.
    try world.removeComponent(entities[0], Position);
    try world.removeComponent(entities[3], Position);
    try world.removeComponent(entities[5], Velocity);

    var matched: usize = 0;
    var query = world.query(.{ *const Position, *const Velocity });
    while (query.next()) |view| {
        try std.testing.expectEqual(view.get(*const Position).id, view.get(*const Velocity).id);
        try std.testing.expectEqual(view.entity.id, view.get(*const Position).id);
        matched += 1;
    }
    try std.testing.expectEqual(@as(usize, 5), matched); // all but 0, 3 and 5
}

test "reserved worlds spawn and add without reallocating" {
    const Position = struct { x: f32 };

    var world = World.init(std.testing.allocator);
    defer world.deinit();
    try world.reserveEntities(64);
    try world.reserve(Position, 64);
    const storage = world.existingStorage(Position).?;
    const values_before = storage.values.items.ptr;
    const slots_before = world.slots.items.ptr;

    for (0..64) |i| _ = try world.spawn(.{Position{ .x = @floatFromInt(i) }});

    try std.testing.expectEqual(values_before, storage.values.items.ptr);
    try std.testing.expectEqual(slots_before, world.slots.items.ptr);
    try std.testing.expectEqual(@as(usize, 64), world.entityCount());
}

test "a despawned entity's reused id does not match Removed in the same tick" {
    const Health = struct { hp: f32 };

    var world = World.init(std.testing.allocator);
    defer world.deinit();

    const old = try world.spawn(.{Health{ .hp = 1 }});
    world.tick();
    world.despawn(old);
    const reused = try world.spawn(.{});
    try std.testing.expectEqual(old.id, reused.id);

    try std.testing.expect(!world.wasRemoved(reused, Health));
    var removed = world.query(.{root.filters.Removed(Health)});
    try std.testing.expect(removed.next() == null);
}

test "batch operations leave the world as the one-by-one calls would" {
    const Position = struct { x: u32 };
    const Velocity = struct { dx: u32 };

    var world = World.init(std.testing.allocator);
    defer world.deinit();

    var entities: [6]root.EntityId = undefined;
    try world.spawnBatch(&entities, .{ Position{ .x = 1 }, Velocity{ .dx = 2 } });
    try std.testing.expectEqual(@as(usize, 6), world.entityCount());
    for (entities) |entity| {
        try std.testing.expectEqual(@as(u32, 1), world.get(entity, Position).?.x);
        try std.testing.expectEqual(@as(u32, 2), world.get(entity, Velocity).?.dx);
    }

    try world.removeComponents(entities[0..3], Velocity);
    for (entities, 0..) |entity, i| try std.testing.expectEqual(i >= 3, world.hasComponent(entity, Velocity));

    try world.addComponents(entities[0..2], Velocity{ .dx = 9 });
    try std.testing.expectEqual(@as(u32, 9), world.get(entities[1], Velocity).?.dx);
    try std.testing.expect(!world.hasComponent(entities[2], Velocity));

    try world.despawnBatch(entities[0..4]);
    try std.testing.expectEqual(@as(usize, 2), world.entityCount());
    for (entities[0..4]) |entity| try std.testing.expect(!world.isAlive(entity));
    // The survivors keep their components; a full query sees exactly them.
    var count: usize = 0;
    var query = world.query(.{ *const Position, *const Velocity });
    while (query.next()) |view| {
        try std.testing.expect(view.entity.id == entities[4].id or view.entity.id == entities[5].id);
        count += 1;
    }
    try std.testing.expectEqual(@as(usize, 2), count);
}

test "despawnBatch skips repeats and dead ids, and frees each id once" {
    const Position = struct { x: u32 };

    var world = World.init(std.testing.allocator);
    defer world.deinit();

    const a = try world.spawn(.{Position{ .x = 1 }});
    const b = try world.spawn(.{Position{ .x = 2 }});
    const gone = try world.spawn(.{});
    world.despawn(gone);
    const c = try world.spawn(.{Position{ .x = 3 }}); // reuses `gone`'s id

    try world.despawnBatch(&.{ a, a, gone, b, a });
    try std.testing.expectEqual(@as(usize, 1), world.entityCount());
    try std.testing.expect(world.isAlive(c)); // the stale handle to its id didn't touch it
    try std.testing.expectEqual(@as(u32, 3), world.get(c, Position).?.x);

    // Each freed id is handed out once: two new entities get two different ids.
    const x = try world.spawn(.{});
    const y = try world.spawn(.{});
    try std.testing.expect(x.id != y.id);
}

test "addComponents and removeComponents change nothing if any entity is dead" {
    const Health = struct { hp: u32 };

    var world = World.init(std.testing.allocator);
    defer world.deinit();

    const alive = try world.spawn(.{Health{ .hp = 1 }});
    const dead = try world.spawn(.{});
    world.despawn(dead);

    try std.testing.expectError(error.EntityNotAlive, world.addComponents(&.{ alive, dead }, Health{ .hp = 5 }));
    try std.testing.expectEqual(@as(u32, 1), world.get(alive, Health).?.hp);
    try std.testing.expectError(error.EntityNotAlive, world.removeComponents(&.{ alive, dead }, Health));
    try std.testing.expect(world.hasComponent(alive, Health));
}

test "batch adds and removes still run hooks" {
    const Health = struct { hp: u32 };
    const Count = struct {
        var added: usize = 0;
        var removed: usize = 0;
        fn onAdd(_: *World, _: root.EntityId) void {
            added += 1;
        }
        fn onRemove(_: *World, _: root.EntityId) void {
            removed += 1;
        }
    };

    var world = World.init(std.testing.allocator);
    defer world.deinit();
    world.onAdd(Health, Count.onAdd);
    world.onRemove(Health, Count.onRemove);

    var entities: [3]root.EntityId = undefined;
    try world.spawnBatch(&entities, .{Health{ .hp = 1 }});
    try world.removeComponents(entities[0..2], Health);
    try world.despawnBatch(&entities);
    try std.testing.expectEqual(@as(usize, 3), Count.added);
    try std.testing.expectEqual(@as(usize, 3), Count.removed);
}
