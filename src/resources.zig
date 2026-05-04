/// A more typed version of `*const T`, allowing viewing-only access (no mutation) for resources.
pub fn Res(comptime T: type) type {
    return *const T;
}

/// A more typed version of `*T`, allowing mutation for resources.
pub fn ResMut(comptime T: type) type {
    return *T;
}
