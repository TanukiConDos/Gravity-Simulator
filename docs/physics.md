# Physics

Config selects one algorithm (`algorithm`) used by both collision detection and gravity solving (BRUTE_FORCE or OCTREE). The OctTree implements Barnes-Hut with center-of-mass approximation and stores entity indices, so it does not dangle when pools grow.

Octree collision is **folded into the gravity traversal**: a node accepted by the opening angle is still descended into when its cell intersects the collision sphere (children marked `gravity_done` so the approximation is applied exactly once), so `theta` can never hide a contact and gravity results are bit-identical. The traversal appends the overlapping pairs, and the serial narrow phase then displaces each pair (resolution is order-dependent, so it cannot be parallelized without changing the result). Pairs are sorted before resolution so the outcome is deterministic regardless of scheduling.

The physics thread runs a **fixed-timestep** loop: one `PHYSICS` phase every 1/60 s of real time, each advancing `(1/60) * time` sim-seconds. An accumulator paces the loop; if the solver cannot keep up, the accumulator caps at 16 pending steps (the sim slows down rather than taking huge, unstable timesteps).

The octree gravity solver is split across `worker_threads` via `foundation.parallel_for` (a fork-join worker pool with an adaptive chunk size — see `docs/benchmark.md`). The tree itself is read-only during solve, so per-body queries are embarrassingly parallel.

Hot-path traversal stacks (`_calc_force`, `_calc_force_collect`) skip zero-initialization; every slot is written before it is read. Zero-initializing them cost ~5–12% of the tick at 100k bodies with `theta >= 0.75` (measured with the fold enabled; without it the effect was larger).

Each tick publishes body positions and selection flags into the `RenderSnapshot` resource; the graphics thread reads that snapshot, never the simulation pools.

## Adaptive tuning (`auto_adjust`)

When `auto_adjust` is `true`, the physics system measures its own per-update cost (EMA-smoothed) and adjusts two values to keep cost near `(1000 / target_tickrate) * 0.85` ms (85% headroom so the fixed-step loop can keep up):

- **`theta`** (cost-feedback): raised when over budget (cheaper traversal), lowered toward `theta_min` when under budget (more accurate). `theta`/`theta_max` bound it. The tree's traversal theta is refreshed every update, so changes take effect immediately.
- **Rebuild interval** (motion/staleness-driven): the tree is rebuilt when the maximum object displacement since the last build exceeds `0.5 ×` the median leaf cell size. Fast-moving sims rebuild often; slow/static ones rarely. `tree_rebuild_interval` remains as an upper cap in sim-seconds. Keeping the tree fresh also keeps `theta` effective (aged trees degrade to ~constant traversal cost regardless of theta).

Convergence is smoothed (EMA α=0.1, 20-update warmup, 2-consecutive-out-of-band confirmations, ±15% deadband). If the target is unreachable (e.g. too many objects), the knobs pin at their bounds and the sim simply runs as fast as the hardware allows.

## App flow

On launch the app loads `config.json`, creates a `World`, spawns the initial bodies accordingly (random or from a scene file), calls `physic_init` and builds a `Scheduler` with the physics systems. The renderer is initialised against the same world. Two threads run until the window closes: physics runs the `PHYSICS` phase on a fixed step (flushing deferred structural changes after each step), graphics runs the `RENDER` phase, whose `graphic.input` and `graphic.render` systems update the camera and draw the frame. The **main thread only pumps events**, blocking in `window_wait_events_timeout` (1/60 s) rather than busy-polling — a tight `glfwPollEvents` loop burns a full core in the GLib/libdecor event machinery. Frame/tick timings are logged to the console once per second.
