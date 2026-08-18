# AGENTS.md

## Build & Run

```
odin run . -debug          # Run main app
odin test tests -debug     # Run tests
```

- Requires Odin compiler (dev-2025-08+) in PATH
- Requires Vulkan SDK installed (vendor:vulkan)

## Project Structure

```
.
├── main.odin               # App entry point + scene JSON loader
├── config.json             # Simulation configuration (edit by hand)
├── engine/
│   ├── graphic/            # Vulkan renderer
│   ├── physic/             # Physics simulation
│   └── state/              # (removed — ImGui UI panels deleted)
├── foundation/             # Config, arena, file I/O, timers
├── tests/                  # Odin test suite
├── Engine/Graphic/shader/  # SPIR-V shaders + GLSL sources + compilar.bat
└── scenes/                 # JSON scene files
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

## Physics

Config selects algorithms for collision detection and gravity solving (BRUTE_FORCE or OCTREE). The OctTree implements Barnes-Hut with center-of-mass approximation.

The physics thread runs a **fixed-timestep** loop: one physics update every 1/60 s of real time, each advancing `(1/60) * time` sim-seconds. An accumulator paces the loop; if the solver cannot keep up, the accumulator caps at 16 pending steps (the sim slows down rather than taking huge, unstable timesteps).

The octree gravity solver is split across `worker_threads` via `foundation.parallel_for` (a fork-join worker pool). The tree itself is read-only during solve, so per-object queries are embarrassingly parallel.

## App Flow

On launch the app loads `config.json`, creates the simulation accordingly (random or from a scene file), and runs until the window closes. Frame/tick timings are logged to the console once per second.

## Tests

6 tests: `test_octtree_create`, `test_octtree_force`, `test_brute_force`, `test_physic_object`, `test_adaptive_decide`, `test_adaptive_tree_stale`.
