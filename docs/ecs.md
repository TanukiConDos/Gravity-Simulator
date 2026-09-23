# ECS (`Engine/ecs`)

The engine is built around a small entity-component-system core. There is no
archetype graph: storage is a struct-of-arrays column per component, indexed by
`entity.index`.

- `Entity{index, generation}`. Despawning bumps the generation, so a stale
  handle can never alias the entity that reuses the index.
- `Pool($T)` is the component column: `data` indexed by entity index, plus
  `dense`/`dense_pos` for O(1) swap-removal and iteration. Because every pool is
  indexed the same way, the entries for one entity line up across all of its
  components — no lookup is needed to walk several components together. That is
  what keeps the physics hot path cache-friendly.
- `World` owns the entity registry, the pools keyed by `typeid`, and the
  resources (singletons such as the solver state and the render snapshot).
  Access them with `world_pool(w, T)` / `world_resource(w, T)`; systems cache the
  returned pointer instead of looking it up in a loop.
- `world_set`/`world_remove` bump `world.revision` only on structural changes
  (component added/removed, spawn, despawn), never on value updates. Physics uses
  the revision to know when its octree is stale.
- Despawns are deferred: `world_despawn` queues, `world_flush_despawns` recycles.
  This makes it safe to destroy entities while iterating pools.
- Systems are plain `proc(w, dt)` grouped by `Phase` (`PHYSICS` / `RENDER`) and
  run in registration order by the `Scheduler`.

## Physics as ECS

The physics components (`Position`, `Velocity`, `Acceleration`, `Mass`,
`Radius`, `Selected`) live in the physical body's pools; `Body` is a tag marking
the entities the simulation iterates, and its `dense` list is the canonical body
list. `Physic_State` is a world resource holding the solver and adaptive-tuning
state, including the index-based `OctTree`. The `PHYSICS` phase runs, in order:
`begin` (reset acceleration, ensure tree), `gravity`, `collision`, `integrate`,
`select` (apply a picked instance from the graphics thread to `Selected`),
`publish` (copy positions and selection into `RenderSnapshot`), `adapt`
(adaptive controller). `physic_register_systems` wires them up.

## Graphics as ECS

The Vulkan `Renderer` is a resource, not an entity. The `Camera` is a world
resource and `graphic_register_systems` adds the `RENDER`-phase input system that
mutates it from the keyboard (the window is reached through a `Window_Ref`
resource). The graphics thread runs the `RENDER` phase, then
`renderer_draw_frame`, which reads the camera resource and the render snapshot.

The frame itself is data-driven. `Engine/Graphic/frame_graph.json` declares the
resources (imported or transient) and the passes (`inputs`/`outputs`, `bindings`,
`optional`). `frame_graph.odin` loads it, resolves pipelines, builds the
dependency edges and, every frame, culls disabled/unused passes, topologically
sorts the rest and executes it: it emits the layout barriers derived from each
resource's usage and opens the rendering scope around the pass's record callback.
Passes are bound to code by name in the renderer (`_renderer_record_pass`), so the
JSON owns the structure and the code owns the draw calls.

The main pass writes both the swapchain color and, as a second output (MRT), a
1-based instance ID to a transient `R32_UINT` target owned by the graph. On a left
mouse press the optional `pick_copy` pass records a one-pixel copy of that ID into
the frame command buffer (no separate draw and no extra submission), so the result
is read once the frame's fence signals. The resolved index is handed to the
physics thread through the atomic `Selection_State`; `physic.select` applies it to
`Selected`, and the next snapshot publishes the flags.

## Threading

The world is not synchronised; one thread owns it at a time. The physics thread
runs the `PHYSICS` phase; the graphics thread reads only `RenderSnapshot`, which
is guarded by its own mutex. All pools and resources are created during
`physic_init`/`renderer_init`, before the threads start, so afterwards the
graphics thread only performs concurrent reads of the registries.
