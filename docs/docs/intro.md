---
slug: /
sidebar_position: 1
title: Introduction
---

# Clutch

Clutch is an entity component system (ECS) for Zig, inspired by [bevy_ecs](https://bevyengine.org/). It's named after a group of eggs, and it's the ECS behind the [eggy](https://github.com/eggyengine/eggy) engine.

An **entity** is just an id. Its data lives in **components**, which are plain Zig values of any type. **Systems** are functions that work on every entity with a given set of components, and **schedules** run them in order.

## What's in the box

| Area | Types and functions |
| --- | --- |
| World | `World`: `spawn`, `despawn`, `addComponent`, `removeComponent`, `get` |
| Queries | `Query`, with the filters `With`, `Without`, `Added`, `Changed` and `Removed` |
| Systems | `Schedule`, `Stages`, `Commands`, `Res` and `ResMut` |
| Resources and events | `insertResource`, `getResource`, `sendEvent`, `EventReader` |
| Hierarchy | `setParent`, `getParent`, `children`, `despawnRecursive` |
| Hooks | `onAdd`, `onRemove` |
| Bulk work | `spawnBatch`, `addComponents`, `removeComponents`, `despawnBatch`, `reserve` |

## How it stores data

Each component type gets its own **sparse set**, the design EnTT and pico_ecs use. Looking up, adding or removing a component is a couple of array operations, and a query walks the packed values of the smallest component storage it needs. [Performance](./concepts/performance.md) covers what that means for your code.

## Where to go next

- [Getting started](./getting-started.md) adds clutch to your project.
- [Your first world](./guide/first-world.md) walks through a complete program.
- The [API reference](pathname:///api/) lists every public declaration.
