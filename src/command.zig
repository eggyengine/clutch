const std = @import("std");
const EntityId = @import("entity.zig").EntityId;
const World = @import("world.zig").World;

const Command = struct {
    ptr: *anyopaque,
    applyFn: *const fn (*anyopaque, *World) anyerror!void,
    deinitFn: *const fn (*anyopaque, std.mem.Allocator) void,

    fn apply(self: Command, world: *World) !void {
        try self.applyFn(self.ptr, world);
    }

    fn deinit(self: Command, allocator: std.mem.Allocator) void {
        self.deinitFn(self.ptr, allocator);
    }
};

/// A deferred queue of world mutations.
///
/// Commands are applied in insertion order when `apply` is called. Payload memory is
/// owned by the buffer and released by `apply`, `clearRetainingCapacity`, or `deinit`.
pub const CommandBuffer = struct {
    const Self = @This();

    allocator: std.mem.Allocator,
    commands: std.ArrayList(Command) = .empty,

    pub fn init(allocator: std.mem.Allocator) Self {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Self) void {
        self.clearRetainingCapacity();
        self.commands.deinit(self.allocator);
    }

    pub fn clearRetainingCapacity(self: *Self) void {
        for (self.commands.items) |command| {
            command.deinit(self.allocator);
        }
        self.commands.clearRetainingCapacity();
    }

    pub fn apply(self: *Self, world: *World) !void {
        defer self.clearRetainingCapacity();

        for (self.commands.items) |command| {
            try command.apply(world);
        }
    }

    pub fn spawn(self: *Self, components: anytype) !void {
        const Components = @TypeOf(components);
        try self.queue(struct {
            components: Components,

            fn apply(ptr: *anyopaque, world: *World) !void {
                const payload: *@This() = @ptrCast(@alignCast(ptr));
                _ = try world.spawn(payload.components);
            }
        }{ .components = components });
    }

    pub fn insertResource(self: *Self, resource: anytype) !void {
        const Resource = @TypeOf(resource);
        try self.queue(struct {
            resource: Resource,

            fn apply(ptr: *anyopaque, world: *World) !void {
                const payload: *@This() = @ptrCast(@alignCast(ptr));
                try world.insertResource(payload.resource);
            }
        }{ .resource = resource });
    }

    pub fn addComponent(self: *Self, entity: EntityId, component: anytype) !void {
        const Component = @TypeOf(component);
        try self.queue(struct {
            entity: EntityId,
            component: Component,

            fn apply(ptr: *anyopaque, world: *World) !void {
                const payload: *@This() = @ptrCast(@alignCast(ptr));
                try world.addComponent(payload.entity, payload.component);
            }
        }{ .entity = entity, .component = component });
    }

    pub fn removeComponent(self: *Self, entity: EntityId, comptime T: type) !void {
        try self.queue(struct {
            entity: EntityId,

            fn apply(ptr: *anyopaque, world: *World) !void {
                const payload: *@This() = @ptrCast(@alignCast(ptr));
                try world.removeComponent(payload.entity, T);
            }
        }{ .entity = entity });
    }

    pub fn remove(self: *Self, entity: EntityId, comptime T: type) !void {
        try self.removeComponent(entity, T);
    }

    pub fn despawn(self: *Self, entity: EntityId) !void {
        try self.queue(struct {
            entity: EntityId,

            fn apply(ptr: *anyopaque, world: *World) !void {
                const payload: *@This() = @ptrCast(@alignCast(ptr));
                world.despawn(payload.entity);
            }
        }{ .entity = entity });
    }

    pub fn despawnRecursive(self: *Self, entity: EntityId) !void {
        try self.queue(struct {
            entity: EntityId,

            fn apply(ptr: *anyopaque, world: *World) !void {
                const payload: *@This() = @ptrCast(@alignCast(ptr));
                world.despawnRecursive(payload.entity);
            }
        }{ .entity = entity });
    }

    pub fn sendEvent(self: *Self, event: anytype) !void {
        const Event = @TypeOf(event);
        try self.queue(struct {
            event: Event,

            fn apply(ptr: *anyopaque, world: *World) !void {
                const payload: *@This() = @ptrCast(@alignCast(ptr));
                try world.sendEvent(payload.event);
            }
        }{ .event = event });
    }

    pub fn setParent(self: *Self, first: EntityId, second: anytype) !void {
        const Second = @TypeOf(second);
        try self.queue(struct {
            first: EntityId,
            second: Second,

            fn apply(ptr: *anyopaque, world: *World) !void {
                const payload: *@This() = @ptrCast(@alignCast(ptr));
                try world.setParent(payload.first, payload.second);
            }
        }{ .first = first, .second = second });
    }

    pub fn removeParent(self: *Self, child: EntityId) !void {
        try self.queue(struct {
            child: EntityId,

            fn apply(ptr: *anyopaque, world: *World) !void {
                const payload: *@This() = @ptrCast(@alignCast(ptr));
                world.removeParent(payload.child);
            }
        }{ .child = child });
    }

    fn queue(self: *Self, payload: anytype) !void {
        const Payload = @TypeOf(payload);
        const stored = try self.allocator.create(Payload);
        stored.* = payload;
        errdefer self.allocator.destroy(stored);

        try self.commands.append(self.allocator, .{
            .ptr = stored,
            .applyFn = Payload.apply,
            .deinitFn = struct {
                fn run(ptr: *anyopaque, allocator: std.mem.Allocator) void {
                    const typed: *Payload = @ptrCast(@alignCast(ptr));
                    allocator.destroy(typed);
                }
            }.run,
        });
    }
};

/// System parameter for deferred world mutations.
///
/// Add `commands: clutch.Commands` to a system, queue mutations on it, and they
/// will be applied after that system returns successfully.
pub const Commands = struct {
    pub const is_commands = true;

    buffer: *CommandBuffer,

    pub fn init(buffer: *CommandBuffer) Commands {
        return .{ .buffer = buffer };
    }

    pub fn spawn(self: Commands, components: anytype) !void {
        try self.buffer.spawn(components);
    }

    pub fn insertResource(self: Commands, resource: anytype) !void {
        try self.buffer.insertResource(resource);
    }

    pub fn addComponent(self: Commands, entity: EntityId, component: anytype) !void {
        try self.buffer.addComponent(entity, component);
    }

    pub fn removeComponent(self: Commands, entity: EntityId, comptime T: type) !void {
        try self.buffer.removeComponent(entity, T);
    }

    pub fn remove(self: Commands, entity: EntityId, comptime T: type) !void {
        try self.buffer.remove(entity, T);
    }

    pub fn despawn(self: Commands, entity: EntityId) !void {
        try self.buffer.despawn(entity);
    }

    pub fn despawnRecursive(self: Commands, entity: EntityId) !void {
        try self.buffer.despawnRecursive(entity);
    }

    pub fn sendEvent(self: Commands, event: anytype) !void {
        try self.buffer.sendEvent(event);
    }

    pub fn setParent(self: Commands, first: EntityId, second: anytype) !void {
        try self.buffer.setParent(first, second);
    }

    pub fn removeParent(self: Commands, child: EntityId) !void {
        try self.buffer.removeParent(child);
    }
};

test "command buffer applies queued mutations in order" {
    const Position = struct { x: i32, y: i32 };
    const Velocity = struct { x: i32, y: i32 };
    const Time = struct { delta: f32 };

    var world = World.init(std.testing.allocator);
    defer world.deinit();

    const entity = try world.spawn(.{Position{ .x = 1, .y = 2 }});

    var commands = CommandBuffer.init(std.testing.allocator);
    defer commands.deinit();

    try commands.addComponent(entity, Velocity{ .x = 3, .y = 4 });
    try commands.removeComponent(entity, Position);
    try commands.insertResource(Time{ .delta = 0.016 });

    try std.testing.expect(!world.hasComponent(entity, Velocity));
    try std.testing.expect(world.hasComponent(entity, Position));
    try std.testing.expect(world.getResource(Time) == null);

    try commands.apply(&world);

    try std.testing.expect(world.hasComponent(entity, Velocity));
    try std.testing.expect(!world.hasComponent(entity, Position));
    try std.testing.expectEqual(0.016, world.getResource(Time).?.delta);
}
