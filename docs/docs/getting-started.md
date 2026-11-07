---
sidebar_position: 2
title: Getting started
---

# Getting started

Clutch requires Zig `0.16.0`.

## Add the dependency

```bash
zig fetch --save git+https://github.com/eggyengine/clutch
```

Then import the module in `build.zig`:

```zig
const clutch = b.dependency("clutch", .{
    .target = target,
    .optimize = optimize,
});

exe.root_module.addImport("clutch", clutch.module("clutch"));
```

And in your code:

```zig
const clutch = @import("clutch");
```

## Local commands

```bash
zig build test   # run the tests
zig build bench  # time common operations in ReleaseFast; `zig build bench -- 2000000` sets the entity count
zig build docs   # write the API reference to zig-out/docs
docs/examples/check.sh  # build and run the full programs from these guides
```
