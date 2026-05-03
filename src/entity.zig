/// Represents an entity handle, consisting of a slot id and a generation counter.
pub const EntityId = struct {
    id: u32,
    generation: u32,

    pub fn init(id: u32, generation: u32) EntityId {
        return .{ .id = id, .generation = generation };
    }

    pub fn eql(a: EntityId, b: EntityId) bool {
        return a.id == b.id and a.generation == b.generation;
    }

    pub fn index(self: EntityId) usize {
        return @intCast(self.id);
    }
};
