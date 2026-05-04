pub fn Res(comptime T: type) type {
    return *const T;
}

pub fn ResMut(comptime T: type) type {
    return *T;
}
