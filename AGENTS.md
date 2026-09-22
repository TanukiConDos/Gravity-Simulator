# AGENTS.md

## Build & Run

```
odin run . -debug          # Run main app
odin test tests -debug     # Run tests
odin build . -o:speed -disable-assert   # Optimized build (asserts compiled out)
```

- Requires Odin compiler (dev-2025-08+) in PATH
- Requires Vulkan SDK installed (vendor:vulkan)

### Shaders

GLSL sources live in `Engine/Graphic/shader/` and compile to SPIR-V 1.6
(`--target-env=vulkan1.4`). Re-run after editing them:

```
Engine/Graphic/shader/build.sh        # Linux
Engine/Graphic/shader/compilar.bat    # Windows (requires VULKAN_SDK)
```

## Validation

The engine never enables layers itself. Enable `VK_LAYER_KHRONOS_validation`
externally with **Vulkan Configurator** (`vkconfig` from `vulkan-extra-tools`):
create a configuration with Best Practices on
(`khronos_validation.validate_best_practices = true`) and apply it globally, or
launch the app from vkconfig.

For headless/scripted runs (no GUI), the equivalent fallback is:

```
VK_INSTANCE_LAYERS=VK_LAYER_KHRONOS_validation \
VK_LAYER_SETTINGS_PATH=/path/to/vk_layer_settings.txt odin run . -debug
```

A `vk_layer_settings.txt` enabling best practices is generated with
`vkconfig settings --generate txt --layers VK_LAYER_KHRONOS_validation`.

## Project Structure

```
.
├── main.odin                # App entry point + scene JSON loader
├── config.json              # Simulation configuration (edit by hand)
├── Engine/Graphic/          # Vulkan renderer
│   ├── spirv/               # SPIR-V reflection (CPU only, no Vulkan calls)
│   ├── shader/              # GLSL sources, compiled SPIR-V + build scripts
│   └── renderer_config.odin # Declarative shaders, vertex streams, descriptors
├── Engine/ecs/              # Entity-component-system core
├── Engine/physic/           # Physics components + systems
├── foundation/              # Config, arena, file I/O, timers
├── tests/                   # Odin test suite (+ fixtures/)
└── scenes/                  # JSON scene files
```

## Configuration

Simulation parameters are read from `config.json` at startup. It can be edited by hand; missing or invalid fields fall back to defaults.

```json
{
    "system_creation_mode": "FILE",   // "RANDOM" or "FILE"
    "num_objects": 998,               // random objects when mode = RANDOM
    "time": 1000,                     // simulation time multiplier
    "filename": "tierra.json",        // scene file when mode = FILE (in scenes/)
    "collision_algorithm": "BRUTE_FORCE", // "BRUTE_FORCE" or "OCTREE"
    "solver_algorithm": "BRUTE_FORCE",    // "BRUTE_FORCE" or "OCTREE"
    "tree_rebuild_interval": 50,      // sim-seconds between octree rebuilds
    "worker_threads": 8,              // threads used by the parallel solver
    "auto_adjust": false,             // adaptive theta + rebuild interval
    "target_tickrate": 60,            // target physics updates/sec when auto_adjust
    "theta_min": 0.2,                 // adaptive theta lower bound
    "theta_max": 1.2                  // adaptive theta upper bound
}
```

`theta` (Barnes-Hut opening angle, default 0.5) can be added to tune octree approximation vs. accuracy.

`tree_rebuild_interval` (sim-seconds, default 50) controls octree reuse. The tree is rebuilt when the accumulated sim time since the last build exceeds it (0 disables reuse = rebuild every tick).

`worker_threads` (default 8) sizes the worker pool used to parallelize the octree gravity solver.

### Adaptive tuning (`auto_adjust`)

When `auto_adjust` is `true`, the physics system measures its own per-update cost (EMA-smoothed) and adjusts two values to keep cost near `(1000 / target_tickrate) * 0.85` ms (85% headroom so the fixed-step loop can keep up):

- **`theta`** (cost-feedback): raised when over budget (cheaper traversal), lowered toward `theta_min` when under budget (more accurate). `theta`/`theta_max` bound it. The tree's traversal theta is refreshed every update, so changes take effect immediately.
- **Rebuild interval** (motion/staleness-driven): the tree is rebuilt when the maximum object displacement since the last build exceeds `0.5 ×` the median leaf cell size. Fast-moving sims rebuild often; slow/static ones rarely. `tree_rebuild_interval` remains as an upper cap in sim-seconds. Keeping the tree fresh also keeps `theta` effective (aged trees degrade to ~constant traversal cost regardless of theta).

Convergence is smoothed (EMA α=0.1, 20-update warmup, 2-consecutive-out-of-band confirmations, ±15% deadband). If the target is unreachable (e.g. too many objects), the knobs pin at their bounds and the sim simply runs as fast as the hardware allows.

## ECS (`Engine/ecs`)

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

### Physics as ECS

The physics components (`Position`, `Velocity`, `Acceleration`, `Mass`,
`Radius`, `Selected`) live in the physical body's pools; `Body` is a tag marking
the entities the simulation iterates, and its `dense` list is the canonical body
list. `Physic_State` is a world resource holding the solver and adaptive-tuning
state, including the index-based `OctTree`. The `PHYSICS` phase runs, in order:
`begin` (reset acceleration, ensure tree), `gravity`, `collision`, `integrate`,
`publish` (copy positions into `RenderSnapshot`), `adapt` (adaptive controller).
`physic_register_systems` wires them up.

### Threading

The world is not synchronised; one thread owns it at a time. The physics thread
runs the `PHYSICS` phase; the graphics thread reads only `RenderSnapshot`, which
is guarded by its own mutex. All pools and resources are created during
`physic_init`/`renderer_init`, before the threads start, so afterwards the
graphics thread only performs concurrent reads of the registries.

## Renderer (`Engine/Graphic`)

### Configuration and reflection

The pipeline is built from data, not from hand-written Vulkan structs:

- `Engine/Graphic/spirv/` parses the compiled SPIR-V to expose entry points, stage
  inputs/outputs, descriptor bindings and push constants. It makes no Vulkan
  calls and has unit tests (`tests/shader_reflection.odin`).
- `renderer_config.odin` is the single source of truth for shaders, vertex
  streams and push descriptors. `pipeline_config.odin` defines those types.
- `pipeline.odin` derives shader modules, descriptor set layouts and the vertex
  input from the reflection.
- Vertex attributes are paired by declarative order: each `Vertex_Buffer_Spec`
  names a packed CPU struct whose non-`_` fields, in declaration order, consume
  the shader's input locations in ascending order. Formats are taken from
  SPIR-V; offsets and strides from the struct. A mismatch (wrong type, reordered
  field, missing input) fails at pipeline build time with a log error.
- `descriptors.odin` owns the per-binding buffers and pushes them with
  `vkCmdPushDescriptorSet2`; `push_descriptors_validate` checks each configured
  binding against the shader interface.

Adding an attribute therefore means editing the GLSL interface and the CPU
struct; adding a resource means editing the GLSL interface and
`renderer_config.odin`.

### Comments

Code should be self-explanatory. Comments are reserved for non-obvious Vulkan
behaviour, invariants and ordering constraints. Ownership and error handling are
covered by this document, not repeated per function.

### Ownership and lifecycle

Constructors return the created value and never hand out partial state:

```odin
buffer := buffer_init(gpu, size, usage, kind) or_return   // (T, bool)
```

- `*_init(args) -> (T, bool)` builds into a local and returns it. On any failure
  it releases what it already created before returning `false`, so the caller
  receives either a complete value or nothing.
- When more than one fallible step creates a resource, the local is released by
  its own defer until the value is complete:

  ```odin
  tmp := Thing{gpu = gpu}
  committed := false
  defer if !committed {thing_destroy(&tmp)}
  ...
  committed = true
  return tmp, true
  ```

- Public handles allocate and own their object until they return:
  `window_init(w, h) -> (^Window, bool)` and
  `renderer_init(...) -> (^Renderer, bool)`. On failure they free it and return
  `nil`.
- `*_destroy(handle)` is idempotent and tolerates a partially initialized value;
  the owner registers `defer x_destroy(x)` after a successful init.
- `self` only appears where the resource already exists: destructors, in-place
  recreation (`swapchain_recreate`) and per-frame use (`model_bind`,
  `uniforms_write`, ...).

### Error handling

| Helper | Use | Behaviour |
|---|---|---|
| `vk_check` | Creation/allocation the caller can abort on (instance, device, swapchain, buffers, pipelines, pools) | Logs and returns `false`, so it propagates with `or_return` |
| `vk_assert` | Secondary/internal creation (image views, semaphores, fences, shader modules, command buffers) and calls that only fail on API misuse (bind, map, query, sync) | Panics in debug, logs in release; no recovery path |
| `assert` | Pure CPU invariants and programming errors | Removed with `-disable-assert` |

- **Never put a side-effecting call inside `assert(...)`.** With
  `-disable-assert` the whole expression is removed. Assign first, then assert:
  `created := f(); assert(created, "...")`.
- `or_return` propagates `(T, bool)` results and works in assignments to
  variables, fields and array elements.

### Visibility

The package exposes only handles and their lifecycle/draw procedures:

- Public: `Window` + `window_init/destroy/should_close/poll_events`; `Renderer` +
  `renderer_init/destroy/draw_frame`.
- Everything else is marked `@(private)`. Odin's `@(private)` is package-scoped:
  visible across the package's files, hidden from importers.

### Vulkan usage

- API 1.4 core, no extension fallbacks: dynamic rendering, synchronization2,
  push descriptors (`vkCmdPushDescriptorSet2`), `vkCmdBindIndexBuffer2`,
  negative viewport height, one semaphore per image, one fence per frame in
  flight.
- The engine never enables validation layers itself (see Validation above).

## Physics

Config selects algorithms for collision detection and gravity solving (BRUTE_FORCE or OCTREE). The OctTree implements Barnes-Hut with center-of-mass approximation and stores entity indices, so it does not dangle when pools grow.

The physics thread runs a **fixed-timestep** loop: one `PHYSICS` phase every 1/60 s of real time, each advancing `(1/60) * time` sim-seconds. An accumulator paces the loop; if the solver cannot keep up, the accumulator caps at 16 pending steps (the sim slows down rather than taking huge, unstable timesteps).

The octree gravity solver is split across `worker_threads` via `foundation.parallel_for` (a fork-join worker pool). The tree itself is read-only during solve, so per-body queries are embarrassingly parallel.

Each tick publishes body positions into the `RenderSnapshot` resource; the graphics thread reads that snapshot, never the simulation pools.

## App Flow

On launch the app loads `config.json`, creates a `World`, spawns the initial bodies accordingly (random or from a scene file), calls `physic_init` and builds a `Scheduler` with the physics systems. The renderer is initialised against the same world. Two threads run until the window closes: physics runs the `PHYSICS` phase on a fixed step, graphics runs `renderer_draw_frame`. Frame/tick timings are logged to the console once per second.

## Tests

17 tests, split across the ECS core, physics and SPIR-V reflection:

- ECS: `test_ecs_spawn_despawn`, `test_ecs_components`, `test_ecs_pool_alignment`,
  `test_ecs_pool_remove_swap`, `test_ecs_flush_clears_all_pools`,
  `test_ecs_resource`, `test_ecs_scheduler_phase_order`.
- Physics: `test_octtree_create`, `test_octtree_force`, `test_brute_force`,
  `test_body_components`, `test_adaptive_decide`, `test_adaptive_tree_stale`.
- Reflection: `test_spirv_vertex_reflection`, `test_spirv_fragment_reflection`,
  `test_spirv_descriptors_and_push_constants`, `test_spirv_rejects_invalid_modules`.

Shader reflection tests read the engine's compiled shaders plus the committed
fixture in `tests/fixtures/` (rebuild it with `tests/fixtures/build.sh`).
