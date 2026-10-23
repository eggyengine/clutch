//! clutch: an entity component system for Zig, inspired by bevy_ecs.
//!
//! A `World` holds entities, each a set of components (plain values of any type). Queries walk
//! the entities that have a given set of components; systems are functions whose parameters
//! (queries, resources, `Commands`) the world fills in; schedules run systems in stages.
//!
//! ```zig
//! var world = clutch.World.init(gpa);
//! defer world.deinit();
//! _ = try world.spawn(.{ Position{ .x = 0 }, Velocity{ .dx = 1 } });
//!
//! var query = world.query(.{ *Position, *const Velocity });
//! while (query.next()) |view| view.get(*Position).x += view.get(*const Velocity).dx;
//! ```
//!
//! Components live in sparse sets, one per component type: adding, removing and looking up a
//! component are array operations, and queries walk the smallest storage they need.
const std = @import("std");
const examples = @import("example.zig"); // do not make this public, only for tests

// file imports
/// Modules, for the types not re-exported below.
pub const world = @import("world.zig");
pub const entity = @import("entity.zig");
pub const storage = @import("storage.zig");
pub const filters = @import("filters.zig");
pub const resources = @import("resources.zig");
pub const schedules = @import("schedules.zig");
pub const utils = @import("utils.zig");
pub const command = @import("command.zig");

// type imports
/// The world: entities, components, resources, events and schedules.
pub const World = world.World;
pub const Query = world.Query;
pub const EventReader = world.EventReader;
pub const EntityId = entity.EntityId;

/// Query filters; see `filters`.
pub const With = filters.With;
pub const Without = filters.Without;
pub const Added = filters.Added;
pub const Changed = filters.Changed;
pub const Removed = filters.Removed;

/// System parameters for resources; see `resources`.
pub const Res = resources.Res;
pub const ResMut = resources.ResMut;

/// Schedules: systems grouped into stages; see `schedules`.
pub const Stages = schedules.Stages;
pub const Stage = schedules.Stage;
pub const ScheduleStage = schedules.ScheduleStage;
pub const Schedule = schedules.Schedule;
pub const stage = schedules.stage;

/// Component bundles and deferred mutations.
pub const Bundle = utils.Bundle;
pub const CommandBuffer = command.CommandBuffer;
pub const Commands = command.Commands;

test {
    std.testing.refAllDecls(@This());
    std.testing.refAllDecls(examples);
}
