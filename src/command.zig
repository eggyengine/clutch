const std = @import("std");
const EntityId = @import("entity.zig").EntityId;
const World = @import("world.zig").World;

/// One queued command: where its payload starts in `CommandBuffer.payloads`, and how to apply it.
const Command = struct {
    offset: usize,
    applyFn: *const fn ([*]const u8, *World) anyerror!void,
};

/// A deferred queue of world mutations.
///
/// Commands are applied in insertion order when `apply` is called. As in Bevy, each command's
/// payload is copied into one byte buffer and read back out unaligned when applied, so queuing
/// allocates only when the buffers grow; `apply` and `clearRetainingCapacity` keep that memory.
pub const CommandBuffer = struct {
    const Self = @This();

    allocator: std.mem.Allocator,
    commands: std.ArrayList(Command) = .empty,
    payloads: std.ArrayList(u8) = .empty,

    pub fn init(allocator: std.mem.Allocator) Self {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Self) void {
        self.commands.deinit(self.allocator);
        self.payloads.deinit(self.allocator);
    }

    pub fn isEmpty(self: *const Self) bool {
        return self.commands.items.len == 0;
    }

    pub fn clearRetainingCapacity(self: *Self) void {
        self.commands.clearRetainingCapacity();
        self.payloads.clearRetainingCapacity();
    }

    pub fn apply(self: *Self, world: *World) !void {
        defer self.clearRetainingCapacity();

        // By index, re-reading both lists: a command may queue more while it applies.
        var index: usize = 0;
        while (index < self.commands.items.len) : (index += 1) {
            const command = self.commands.items[index];
            try command.applyFn(self.payloads.items.ptr + command.offset, world);
        }
    }

    pub fn spawn(self: *Self, components: anytype) !void {
        const Components = @TypeOf(components);
        try self.queue(struct {
            components: Components,

            fn apply(payload: @This(), world: *World) !void {
                _ = try world.spawn(payload.components);
            }
        }{ .components = components });
    }

    pub fn insertResource(self: *Self, resource: anytype) !void {
        const Resource = @TypeOf(resource);
        try self.queue(struct {
            resource: Resource,

            fn apply(payload: @This(), world: *World) !void {
                try world.insertResource(payload.resource);
            }
        }{ .resource = resource });
    }

    pub fn addComponent(self: *Self, entity: EntityId, component: anytype) !void {
        const Component = @TypeOf(component);
        try self.queue(struct {
            entity: EntityId,
            component: Component,

            fn apply(payload: @This(), world: *World) !void {
                try world.addComponent(payload.entity, payload.component);
            }
        }{ .entity = entity, .component = component });
    }

    pub fn removeComponent(self: *Self, entity: EntityId, comptime T: type) !void {
        try self.queue(struct {
            entity: EntityId,

            fn apply(payload: @This(), world: *World) !void {
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

            fn apply(payload: @This(), world: *World) !void {
                world.despawn(payload.entity);
            }
        }{ .entity = entity });
    }

    pub fn despawnRecursive(self: *Self, entity: EntityId) !void {
        try self.queue(struct {
            entity: EntityId,

            fn apply(payload: @This(), world: *World) !void {
                world.despawnRecursive(payload.entity);
            }
        }{ .entity = entity });
    }

    pub fn sendEvent(self: *Self, event: anytype) !void {
        const Event = @TypeOf(event);
        try self.queue(struct {
            event: Event,

            fn apply(payload: @This(), world: *World) !void {
                try world.sendEvent(payload.event);
            }
        }{ .event = event });
    }

    pub fn setParent(self: *Self, first: EntityId, second: anytype) !void {
        const Second = @TypeOf(second);
        try self.queue(struct {
            first: EntityId,
            second: Second,

            fn apply(payload: @This(), world: *World) !void {
                try world.setParent(payload.first, payload.second);
            }
        }{ .first = first, .second = second });
    }

    pub fn removeParent(self: *Self, child: EntityId) !void {
        try self.queue(struct {
            child: EntityId,

            fn apply(payload: @This(), world: *World) !void {
                world.removeParent(payload.child);
            }
        }{ .child = child });
    }

    fn queue(self: *Self, payload: anytype) !void {
        const Payload = @TypeOf(payload);
        try self.commands.ensureUnusedCapacity(self.allocator, 1);
        const offset = self.payloads.items.len;
        try self.payloads.appendSlice(self.allocator, std.mem.asBytes(&payload));
        self.commands.appendAssumeCapacity(.{
            .offset = offset,
            .applyFn = struct {
                fn run(bytes: [*]const u8, world: *World) !void {
                    // Unaligned: payloads are packed back to back.
                    const copy = std.mem.bytesToValue(Payload, bytes[0..@sizeOf(Payload)]);
                    try copy.apply(world);
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
