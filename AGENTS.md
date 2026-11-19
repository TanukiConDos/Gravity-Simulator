# AGENTS.md

## Build & Run

```
odin run . -debug          # Run main app
odin test tests -debug     # Run tests
odin build . -o:speed -disable-assert   # Optimized build (asserts compiled out)
odin run bench -o:speed    # Physics benchmark
odin run bench -o:speed -- 1k   # Single sweep stage (all | 1k | 10k | 100k)
odin run bench -o:speed -- gpu [elements] [dispatches] [samples]  # Headless compute probe
odin run bench -o:speed -- gpu-force [n] [ticks] [samples]  # GPU vs CPU gravity
odin run bench -o:speed -- gpu-tree [n] [depth] [theta] [ticks] [samples]  # GPU vs CPU Barnes-Hut
odin run bench -o:speed -- gpu-tick [n] [depth] [theta] [ticks] [samples] [octree|brute]  # whole-tick CPU vs GPU
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

GLSL sources live in `Engine/Graphic/shader/` and compile to SPIR-V 1.6. Re-run
`Engine/Graphic/shader/build.sh` (Linux; `compilar.bat` on Windows) after editing
them. The `shader-pipeline` skill covers the full edit/rebuild workflow.

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

Package layering is checked separately, without building:

```
scripts/check_layering.sh
```

It fails if the front or `shared` package mentions `vendor:vulkan`, if the
backend imports `ecs`/`physic` or mentions `Graphic/front`/`Graphic/gpu`, or if
`gpu` mentions `Graphic/front`.

## Project Structure

```
.
├── main.odin                # App entry point + scene JSON loader
├── config.json              # Simulation configuration (edit by hand)
├── bench/                   # Octree parameter sweep (results in bench/results/)
├── docs/                    # Deeper design notes (read on demand)
├── scripts/                 # check_layering.sh (front/backend dependency check)
├── Engine/Graphic/
│   ├── shared/              # package gfx: plain data seam (no Vulkan, ECS or GLFW)
│   ├── front/               # package graphic: camera, input, instancing, Renderer, ECS integration
│   ├── backend/             # package vk: window, GPU, swapchain, pipelines, frame graph, compute (no ECS)
│   ├── gpu/                 # package gpu: GPU gravity solver, GPU tree build, render stream
│   ├── spirv/               # SPIR-V reflection (CPU only, no Vulkan calls)
│   ├── shader/              # GLSL sources, compiled SPIR-V + build scripts
│   └── frame_graph.json     # Frame graph structure (loaded by the backend)
├── Engine/ecs/              # Entity-component-system core
├── Engine/physic/           # Physics components + systems
├── foundation/              # Config, arena, file I/O, timers
├── tests/                   # Odin test suite (+ fixtures/)
└── scenes/                  # JSON scene files
```

`Engine/Graphic` is split into `shared` (`gfx`), `front` (`graphic`), `backend`
(`vk`) and `gpu` (`gpu`): `front -> {backend, gpu} -> shared`. The front never
imports `vendor:vulkan`, the backend imports no ECS/physics state, and `gpu` is
the only graphics package that may import `physic`/`ecs` besides the front.

## Configuration

Simulation parameters are read from `config.json` at startup (hand-edited;
missing/invalid fields fall back to defaults).

```json
{
    "system_creation_mode": "FILE",   // "RANDOM" or "FILE"
    "num_objects": 998,               // random objects when mode = RANDOM
    "time": 1000,                     // simulation time multiplier
    "filename": "tierra.json",        // scene file when mode = FILE (in scenes/)
    "algorithm": "BRUTE_FORCE",       // solver + collision: "BRUTE_FORCE" or "OCTREE"
    "gravity_backend": "CPU",         // brute-force gravity: "CPU" or "GPU"
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

- `theta` (Barnes-Hut opening angle, default 0.5) trades octree speed for accuracy.
- `gravity_backend` ("CPU"/"GPU") swaps the gravity solve for either algorithm;
  the GPU backend attaches to the graphics backend's device and falls back to CPU
  on failure. See `docs/gpu_physics.md`.
- `tree_rebuild_interval` (sim-seconds, default 50; 0 = rebuild every tick).
- `max_depth` (default 48, capped) and `min_half_size` (default `1e-4`) bound octree subdivision.
- `worker_threads` (default 8) sizes the pool for the parallel gravity solver.
- `auto_adjust` drives `theta` and the rebuild interval from measured cost and
  body motion; see `docs/physics.md`.

## Deeper docs (read on demand)

- `docs/architecture.md` — top-level map: packages, runtime threads, startup and tick/frame lifecycle, backend selection, cross-thread data flow.
- `docs/ecs.md` — ECS core, physics/graphics as ECS, threading.
- `docs/physics.md` — solver, collision fold, fixed timestep, adaptive tuning, app flow.
- `docs/renderer.md` — graphics front/backend split, frame graph, reflection, ownership/error handling, visibility, Vulkan usage.
- `docs/gpu_physics.md` — compute context, timeline semaphores, GPU physics roadmap.
- `docs/benchmark.md` — bench harness, spall profiling, measured results.
- `docs/performance.md` — performance model, measured optimizations, open directions.

## Skills

Project skills under `.opencode/skills/` load on demand (only their description
is always in context): `shader-pipeline`, `physics-bench`, `verify-engine`,
`octree-tuning`.

## Tests

Run `odin test tests -debug`. The `verify-engine` skill lists the pre-commit
checks; `octree-tuning` and `shader-pipeline` name the tests that pin each
subsystem.
