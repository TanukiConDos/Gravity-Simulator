# AGENTS.md

## Build & Run

```
odin run . -debug          # Run main app
odin test tests -debug     # Run tests
odin build . -o:speed -disable-assert   # Optimized build (asserts compiled out)
odin run bench -o:speed    # Physics benchmark
odin run bench -o:speed -- 1k   # Single sweep stage (all | 1k | 10k | 100k)
odin run bench -o:speed -define:PROFILE=true -- profile   # Record bench/results/trace_*.spall
```

- Requires Odin compiler (dev-2025-08+) in PATH
- Requires Vulkan SDK installed (vendor:vulkan)

### CPU features / AVX

By default LLVM targets generic x86-64 (SSE2 only). Adding `-microarch:native`
lets it use the host ISA (AVX2/AVX-512 here) and is worth ~1.5–4.6% on the bench:

```
odin build . -o:speed -disable-assert -microarch:native
odin run bench -o:speed -microarch:native
```

Use `-microarch:haswell` for a portable AVX2 build, or omit the flag for a
generic binary that runs anywhere (a `native` binary faults on older CPUs).

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
├── bench/                   # Octree parameter sweep (results in bench/results/)
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
    "algorithm": "BRUTE_FORCE",       // solver + collision: "BRUTE_FORCE" or "OCTREE"
    "tree_rebuild_interval": 50,      // sim-seconds between octree rebuilds
    "max_depth": 48,                  // octree depth cap (clamped to MAX_DEPTH_CAP)
    "min_half_size": 0.0001,          // octree leaf cell size floor
    "worker_threads": 8,              // threads used by the parallel solver
    "auto_adjust": false,             // adaptive theta + rebuild interval
    "target_tickrate": 60,            // target physics updates/sec when auto_adjust
    "theta_min": 0.2,                 // adaptive theta lower bound
    "theta_max": 1.2                  // adaptive theta upper bound
}
```

`theta` (Barnes-Hut opening angle, default 0.5) can be added to tune octree approximation vs. accuracy.

`tree_rebuild_interval` (sim-seconds, default 50) controls octree reuse. The tree is rebuilt when the accumulated sim time since the last build exceeds it (0 disables reuse = rebuild every tick).

`max_depth` (default 48, capped at `MAX_DEPTH_CAP`) bounds the octree subdivision depth; `min_half_size` (default `1e-4`) is the smallest leaf cell. The natural depth for N uniformly distributed bodies is about `log8(N)` (≈4 for 1k, ≈6 for 100k), so caps above that have no measurable effect; lower caps are useful to bound deep subdivision for near-coincident bodies. See `bench/` for the measured sweep.

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
`select` (apply a picked instance from the graphics thread to `Selected`),
`publish` (copy positions and selection into `RenderSnapshot`), `adapt`
(adaptive controller). `physic_register_systems` wires them up.

### Graphics as ECS

The Vulkan `Renderer` is a resource, not an entity. The `Camera` is a world
resource and `graphic_register_systems` adds the `RENDER`-phase input system that
mutates it from the keyboard (the window is reached through a `Window_Ref`
resource). The graphics thread runs the `RENDER` phase, then
`renderer_draw_frame`, which reads the camera resource and the render snapshot.

`renderer_draw_frame` is split into the swapchain acquire/present path and
`_renderer_record_frame`, which records a `Frame_Pass`. A pass is engine
bookkeeping (pipeline + `Render_Target`s + load/clear), not a `VkRenderPass`, and
every layout transition goes through `image_barrier`. The pick pass renders
1-based instance IDs to an offscreen `R32_UINT` target on demand (left mouse
press), reads one pixel back and hands the instance index to the physics thread
through the atomic `Selection_State`; `physic.select` applies it to `Selected`
and the next snapshot publishes the flags.

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

- Public: `Window` + `window_init/destroy/should_close/poll_events` /
  `wait_events_timeout`; `Renderer` + `renderer_init/destroy/draw_frame`.
- Everything else is marked `@(private)`. Odin's `@(private)` is package-scoped:
  visible across the package's files, hidden from importers.

### Vulkan usage

- API 1.4 core, no extension fallbacks: dynamic rendering, synchronization2,
  push descriptors (`vkCmdPushDescriptorSet2`), `vkCmdBindIndexBuffer2`,
  negative viewport height, one semaphore per image, one fence per frame in
  flight, FIFO present mode (vsync).
- The engine never enables validation layers itself (see Validation above).

## Physics

Config selects one algorithm (`algorithm`) used by both collision detection and gravity solving (BRUTE_FORCE or OCTREE). The OctTree implements Barnes-Hut with center-of-mass approximation and stores entity indices, so it does not dangle when pools grow.

Octree collision is **folded into the gravity traversal**: a node accepted by the opening angle is still descended into when its cell intersects the collision sphere (children marked `gravity_done` so the approximation is applied exactly once), so `theta` can never hide a contact and gravity results are bit-identical. The traversal appends the overlapping pairs, and the serial narrow phase then displaces each pair (resolution is order-dependent, so it cannot be parallelized without changing the result). Pairs are sorted before resolution so the outcome is deterministic regardless of scheduling.

The physics thread runs a **fixed-timestep** loop: one `PHYSICS` phase every 1/60 s of real time, each advancing `(1/60) * time` sim-seconds. An accumulator paces the loop; if the solver cannot keep up, the accumulator caps at 16 pending steps (the sim slows down rather than taking huge, unstable timesteps).

The octree gravity solver is split across `worker_threads` via `foundation.parallel_for` (a fork-join worker pool with an adaptive chunk size — see Benchmark). The tree itself is read-only during solve, so per-body queries are embarrassingly parallel.

Hot-path traversal stacks (`_calc_force`, `_calc_force_collect`) skip zero-initialization; every slot is written before it is read. Zero-initializing them cost ~5–12% of the tick at 100k bodies with `theta >= 0.75` (measured with the fold enabled; without it the effect was larger).

Each tick publishes body positions and selection flags into the `RenderSnapshot` resource; the graphics thread reads that snapshot, never the simulation pools.

## Benchmark

`bench/` sweeps the octree knobs and writes one CSV per stage to
`bench/results/` (gitignored). Run all stages or one:

```
odin run bench -o:speed -disable-assert -microarch:native          # all
odin run bench -o:speed -disable-assert -microarch:native -- 100k  # one stage
```

Per config it times the `PHYSICS` phase over `repeats` independent worlds,
each with discarded warmup ticks, and reports the median ms/tick. Accuracy is
the mean and max relative acceleration error of a fixed random query subset
against an exact O(N) sum, measured on one gravity solve from the
deterministic (seed 42) initial conditions. Stages: `1k` (full grid),
`10k` and `100k` (reduced grids).

### Profiling (spall)

The profiler is compiled out entirely without `-define:PROFILE=true`. Do **not**
combine the flag with timing runs: it leaves the (inactive) span calls in the
binary and skews the numbers.

**Bench.** Build with the flag and use the `profile` stage to record a spall
trace of one config (warmup untraced, then 5 ticks). Spans cover the six
`PHYSICS` systems (named by the scheduler), `octree.build`, `octree.solve`, and
one `parallel_for` span per worker, each worker thread recording to its own
buffer/timeline. Open the file at https://gravitymoth.com/spall/ or Perfetto.

```
odin run bench -o:speed -disable-assert -microarch:native -define:PROFILE=true -- profile [n] [depth] [theta] [interval] [workers]
```

**App.** With the flag the app traces its whole run to `trace_app.spall`
(gitignored). It covers every thread, each named in the viewer: the main loop
(`main.loop`), the physics thread (`physics.step` plus the per-system spans and
`octree.build`/`octree.solve`), the graphics thread (`graphics.frame`,
`graphics.draw` and the `RENDER` spans) and the worker pool (`parallel_for`).
Close the window to flush and exit; the file is truncated on each launch.

```
odin build . -o:speed -disable-assert -microarch:native -define:PROFILE=true
./Gravity-Simulator          # then close the window
```

A flat `profiler` API would need `when` gates at every call site, so the wrapper
(`foundation/profiler.odin`) exposes only `profile_scope`/`profile_start`/`profile_stop`/
`profile_thread_ensure`/`profile_thread_name`/`profile_thread_flush`, which fold
to nothing when the flag is off. Threads must get a buffer
(`profile_thread_ensure`) and be flushed before the context is destroyed; register
the flush as a `defer` so span ends run first.

Measured on a Ryzen 7 7800X3D, `-microarch:native` (see `bench/results/`).
Absolute numbers drift by up to ~20% between sessions (CPU boost/thermal/load),
so compare configs within one run; the CSVs are gitignored and rewritten per
stage.

- **Depth is not a sensitive knob.** Natural leaf depth is ≈`log8(N)` (median 4
  at 1k, 5 at 10k, 6 at 100k), so caps from that up to 48 change time and error
  by 2–4% at most. Caps of 8–16 are safe; they only bound pathological deep
  subdivision.
- **`theta` dominates** the speed/accuracy trade-off (100k, 16 workers,
  interval=50): `theta=1.0` runs ~21 ms/tick at ~1.8% mean error, `theta=0.75`
  ~39 ms at ~0.6%, `theta=0.5` ~98 ms at ~0.2%.
- **`tree_rebuild_interval` matters at high `theta`.** At 100k (16 workers),
  rebuilding every tick instead of every 50 sim-seconds costs +6% at
  `theta=0.5`, +16% at `theta=0.75` and +32% at `theta=1.0`: the build is serial
  and costs ~7 ms/tick, which is not negligible once the traversal is cheap. The
  default (50) and `auto_adjust` (staleness-driven) avoid rebuilding every tick.
- **Collision is folded into the gravity traversal.** Overlapping pairs are
  collected during the solve (`_calc_force_collect`) and the serial narrow phase
  just displaces them; pairs are sorted first so the outcome does not depend on
  scheduling. Measured back to back on the same harness (100k, interval=50,
  depth=48), folding cut tick time by ~26% at `theta=0.75` and ~45% at
  `theta=1.0` (8 workers), and ~53% at `theta=1.0` with 16 workers; at
  `theta=0.5` it is neutral because the deep traversal dominates. Gravity is
  bit-identical and the contact set is identical (see
  `test_octree_force_collect_equivalence`). `odin run bench -- contacts [n]
  [depth] [theta] [warmup] [scale]` measures why the separate pass was not worth
  keeping: at 100k it returns ~121–143k candidates (one per body is the body
  itself) for only 42 overlaps at t=0, rising to ~1.1k after 150 ticks — over
  96% of non-self candidates are false, because the query radius (~2.5e7) is an
  order of magnitude smaller than the leaf cell size (~3e8).
- **Third-law sharing is a dead end at the app's settings.** The `interactions`
  diagnostic (`odin run bench -- interactions [n] [depth] [theta] [warmup]
  [workers]`) tallies the gravity traversal's force applications. At 100k,
  leaves hold **exactly one body**, and every close pair is reached from *both*
  sides (measured asymmetry 1.00), so a third-law scheme would be exactly
  consistent — but the near-field share is only ~10% of applications at
  `theta=1.2` (~16% at `theta=0.5`, ~12% at `theta=1.0`): Newton's third law
  could remove at most ~5–8% of applications, before the deterministic
  pair-list collect/sort/apply bookkeeping. The cost is dominated by far-field
  accepted-node applications (~62–94 per body), which only a mutual/dual-tree
  traversal could halve.
- **Worker scaling uses an adaptive chunk.** `parallel_for` splits work into
  `chunk = ceil(count / (workers * PARALLEL_CHUNKS_PER_WORKER))`, floored at
  `PARALLEL_MIN_CHUNK`, so small jobs still produce enough chunks to keep every
  worker busy. At 1k (depth 16, interval=50) going from 1 to 16 workers takes
  2.00 ms/tick to 0.285 ms at `theta=0.5` (7.0x) and 0.50 to 0.093 ms at
  `theta=1.0` (5.3x); scaling is monotonic through 16 workers.

## App Flow

On launch the app loads `config.json`, creates a `World`, spawns the initial bodies accordingly (random or from a scene file), calls `physic_init` and builds a `Scheduler` with the physics systems. The renderer is initialised against the same world. Two threads run until the window closes: physics runs the `PHYSICS` phase on a fixed step, graphics runs `renderer_draw_frame`. The **main thread only pumps events**, blocking in `window_wait_events_timeout` (1/60 s) rather than busy-polling — a tight `glfwPollEvents` loop burns a full core in the GLib/libdecor event machinery. Frame/tick timings are logged to the console once per second.

## Tests

21 tests, split across the ECS core, physics and SPIR-V reflection:
- ECS: `test_ecs_spawn_despawn`, `test_ecs_components`, `test_ecs_pool_alignment`,
  `test_ecs_pool_remove_swap`, `test_ecs_flush_clears_all_pools`,
  `test_ecs_resource`, `test_ecs_scheduler_phase_order`.
- Physics: `test_octtree_create`, `test_octtree_depth_cap`, `test_octtree_force`,
  `test_octree_collision`, `test_octree_force_collect_equivalence`,
  `test_physic_init_defaults`, `test_brute_force`, `test_body_components`,
  `test_adaptive_decide`, `test_adaptive_tree_stale`.
- Reflection: `test_spirv_vertex_reflection`, `test_spirv_fragment_reflection`,
  `test_spirv_descriptors_and_push_constants`, `test_spirv_rejects_invalid_modules`.

Shader reflection tests read the engine's compiled shaders plus the committed
fixture in `tests/fixtures/` (rebuild it with `tests/fixtures/build.sh`).
