# clutch

clutch is an ecs system (named after a group of eggs) written in Zig. 

## add to project
requires zig `0.16.0`

to use this with the zig build system, import as so:
```bash
zig fetch --save git+https://github.com/eggyengine/clutch
```

and then in `build.zig`:
```zig
const clutch = b.dependency("clutch", .{
    .target = target,
    .optimize = optimize,
});

exe.root_module.addImport("clutch", clutch.module("clutch"));
```

and lastly in your library/executable:
```zig
const clutch = @import("clutch");
```
