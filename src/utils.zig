const std = @import("std");

/// A bundle of components.
///
/// # Example
/// ```zig
///const PlayerBundle = clutch.Bundle(.{
///     Position{ .x = 0, .y = 0 },
///     Velocity{ .dx = 0, .dy = 0 },
///     Health{ .hp = 100 },
///     Player{},
/// });
///
/// test "bundles: spawn with default bundle" {
///     var world = clutch.World.init(std.testing.allocator);
///     defer world.deinit();
///
///     const p = try world.spawn(PlayerBundle.init());
///
///     try std.testing.expect(world.hasComponent(p, Position));
///     try std.testing.expect(world.hasComponent(p, Velocity));
///     try std.testing.expect(world.hasComponent(p, Health));
///     try std.testing.expect(world.hasComponent(p, Player));
/// }
/// ```
pub fn Bundle(comptime defaults: anytype) type {
    const Components = comptime blk: {
        var types: [defaults.len]type = undefined;
        for (defaults, 0..) |default, index| {
            types[index] = @TypeOf(default);
        }
        break :blk std.meta.Tuple(&types);
    };

    return struct {
        pub fn init() Components {
            var result: Components = undefined;
            inline for (defaults, 0..) |default, index| {
                result[index] = default;
            }
            return result;
        }

        pub fn with(overrides: anytype) Components {
            var result = init();
            inline for (defaults, 0..) |default, index| {
                inline for (overrides) |override| {
                    if (@TypeOf(default) == @TypeOf(override)) {
                        result[index] = override;
                    }
                }
            }
            return result;
        }
    };
}
