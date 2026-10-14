//! Entity handles. An entity is only an id; its data lives in component storages.
/// Represents an entity handle, consisting of a slot id and a generation counter.
pub const EntityId = struct {
    id: u32,
    generation: u32,

    /// The handle for slot `id` at `generation`. Worlds hand these out; build one yourself only
    /// for ids and generations a world gave you.
    pub fn init(id: u32, generation: u32) EntityId {
        return .{ .id = id, .generation = generation };
    }

    /// Whether `a` and `b` name the same entity: same slot and same generation.
    pub fn eql(a: EntityId, b: EntityId) bool {
        return a.id == b.id and a.generation == b.generation;
    }

    /// The slot as an index into per-entity arrays.
    pub fn index(self: EntityId) usize {
        return @intCast(self.id);
    }
};
