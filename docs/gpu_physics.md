# GPU physics

The physics solver runs on the CPU today (`docs/physics.md`). Work is staged so
the dominant cost — gravity — can move to compute without changing the CPU
pipeline's contracts (fixed timestep, deterministic collision resolution,
snapshot publishing, adaptive tuning).

## Status

**M0 (compute plumbing), M1 (GPU brute-force gravity), M2 (GPU Barnes-Hut),
M3 (GPU integration), M4 (GPU tree build) and M5 (direct rendering) are done.** The engine can create a
compute device (headless or attached to the renderer's), build compute pipelines
from SPIR-V, run dispatch chains against storage buffers and synchronize them
with a timeline semaphore. `gravity_backend = GPU` replaces either gravity solve
with its compute path: the octree backend builds its tree on the GPU, traverses
it, applies the velocity update (`vel += acc * dt`) and returns the collision
contacts, while physic keeps collision resolution, the position update,
selection, snapshot publishing and the adaptive controller. The renderer draws
those GPU buffers directly instead of reading the CPU snapshot. All of it is
verified by the bench and pinned by tests.

## Solve pipeline (M3)

The `physic.Gravity_Solver` hook is asynchronous: a tick submits a solve early
and applies its results only when a consumer needs them.

1. `physic_system_gravity` calls `submit`, which packs, uploads, dispatches and
   submits without waiting. Results stay in the backend's buffers; the pools are
   untouched.
2. The first consumer calls `finish`, which waits on the submission's timeline
   value, scatters the velocities into the `Velocity` pool and appends the
   contacts it found. `finish` is idempotent.
3. `finish_at_collision` picks that consumer:
   - the octree backend sets it: its traversal produces the contacts the narrow
     phase resolves, so `physic.collision` finishes first;
   - the brute-force backend leaves it false: its serial collision pass reads
     positions and masses only, so the dispatch stays in flight across it and
     `physic.integrate` finishes before the position update.

A failed `submit` (over capacity, no tree) falls back to the CPU solver in the
same tick, exactly like a failing hook in M1. A failed `finish` (contact-list
overflow, device loss) is detected before the pools are touched, so `physic`
uninstalls the hook and re-runs the CPU solver for that tick.

## Backends

`Engine/Graphic/gpu_physics.odin` owns the backend (device attachment, staging,
pipeline and submission ring); `gpu_tree.odin` adds the octree-specific buffers
and traversal.

### Brute force (`physics_brute.comp`)

1. packs the live bodies into `vec4(position, mass)` and `vec4(velocity)` records
   in host-visible staging (mass is converted to f32 there, so the shader matches
   the CPU solver's arithmetic exactly);
2. records one command buffer: host→transfer barriers, the two uploads,
   transfer→compute barriers, push constants (body count, `dt`) and push
   descriptors, one dispatch, compute→transfer barrier, velocity readback to a
   host-visible buffer, transfer→host barrier;
3. submits on the compute queue and signals the timeline value.

The kernel tiles the body array through shared memory in 256-body tiles; every
invocation accumulates its own acceleration and applies `vel += acc * dt` in
place. Ordered pairs are evaluated from both sides (2× the CPU's third-law pair
count, traded for a branch-free parallel loop). The distance floor matches the
CPU brute-force softening (`r² >= 1e-6`).

### Barnes-Hut (`physics_tree.comp`)

1. when physic rebuilt the tree (tracked through `PhysicState.rebuild_count`),
   the nodes are widened into a std430 record and the tree's permuted body list
   (`order`) is uploaded. The body columns (position, mass, velocity, radius) are
   pool-indexed and uploaded every tick;
2. the dispatch walks `order`, so lanes in a warp sit in nearby leaves and the
   divergent traversal reuses cache lines. The traversal keeps a frame stack of
   (node, child cursor); the depth is bounded by `MAX_DEPTH_CAP`, so 64 frames
   cover it;
3. theta-accepted nodes apply their center of mass as a far-field term, and an
   accepted cell that intersects the collision sphere is still descended into
   (the fold), exactly like `_calc_force_collect`. Overlapping pairs land in an
   atomic contact list; the CPU sorts them into `collision_contacts`, so
   `_collision_resolve` is unchanged. The kernel applies `vel += acc * dt` in
   place;
4. contacts are bounded by a pre-allocated capacity; an overflow fails the solve
   before the pools are written, so the CPU solver takes over instead of
   resolving a partial list.

Buffer capacity is pre-reserved before the simulation threads start; runtime
growth would touch the (not thread-safe) device allocator and is only safe from
the main thread.

## GPU tree build (M4)

`shader/tree_build.comp` is one source compiled six times (`tree_build_0..5.spv`)
and run in one command buffer. It reproduces the CPU builder's structure exactly
(`_octtree_build`): the same root cell from the body bounds, the same
`pos >= center` octant split, the same leaf rules (`obj_count <= 1`,
`depth >= max_depth`, `half_size <= min_half`) and the same center-of-mass
aggregation. Only node ids and the order of bodies inside a leaf differ, which
the parity test pins cell by cell.

1. **init/setup/root**: one thread prepares the counters, one thread per body
   copies the live list into the order buffer and reduces the bounds and maximum
   radius (`atomicMin`/`atomicMax` over a monotonic float-to-uint mapping), and
   one thread derives the root cell and enqueues it.
2. **level pass**, one dispatch per depth: one workgroup per cell counts its
   objects into eight shared-memory octant bins, decides whether the cell is a
   leaf, allocates its children, scatters the objects into the children's ranges
   and copies leaf objects through, so the order buffer is complete after every
   level. Children are stored compactly in octant order, exactly like the CPU
   builder writes them, and the per-level cell counts are produced on the device
   so the dispatches are indirect: a level with no cells costs a no-op command.
3. **COM pass**, deepest level first: one thread per node aggregates masses and
   centers of mass bottom-up with an online weighted mean, which never forms
   `position * mass` (that would overflow f32 for planetary masses).
4. **order finalize**: the finished order (whichever parity buffer the last level
   wrote) is copied into the traversal's buffer, and the control block comes back
   to the host for the tree metrics (`Physic_State.tree_info`). The tree itself
   never leaves the GPU.

Physic keeps the rebuild decision (interval, adaptive drift) and calls the
backend's `build_tree` hook; the CPU tree is only built when the backend fails
and the run falls back to the CPU solver.

The GPU's centers of mass accumulate in f32 while the CPU's use f64, so the
per-body velocity error against the CPU tree is f32-level on average
(mean ≈ 5e-07 at 100k bodies) but can reach a few 1e-3 for a body whose
acceleration is dominated by a tight cluster inside one large node. The contact
sets stay exact.

## Direct rendering (M5)

The renderer never reads the CPU snapshot while a GPU backend owns the world.
The solver publishes a *render view* for the renderer thread:

- `bodies`, `radii`, `selected` and `live`, all CONCURRENT buffers the compute
  and graphics queues share. `live` maps the draw slot to the entity, so the
  instance order, the draw count and the pick IDs stay the same as the snapshot
  path (`view.bodies` order). `mode` says whether `bodies` is entity-indexed
  (octree) or packed by slot (brute force).
- The solve timeline `value` whose completion makes the buffers safe to read, and
  the `count` of live bodies.

`shader/instance_pack.comp` runs on the graphics queue at the start of the
frame, before the render pass begins (compute may not be recorded inside one):
one invocation per instance reads position, radius and selection and writes the
per-frame instance record. The main pipeline is untouched, and the frame
submission waits on the solver's timeline before any of it runs.

A single set of buffers cannot be made safe with a "latest value" check: a solve
can resolve its view to solve `T` and then submit solve `T+1` before the frame
that reads `T` publishes its value, overwriting the buffers in flight. The view
is therefore **vended**, not shared. The solver owns `RENDER_VIEW_SETS` (3)
device snapshots and a per-set state machine:

- Solver, per solve: acquire a set that is `FREE` **and** whose reader has
  completed — the frame timeline's counter is at least the set's
  `release_value` (`vkGetSemaphoreCounterValue`, no host block) — by a
  `FREE -> WRITING` CAS. Upload the columns into that set and dispatch against
  it, then publish (`published_value`/`published_count`, then state
  `PUBLISHED`) and free the previously published set unless the renderer claimed
  it (`PUBLISHED -> FREE`; a `READING` set is left to the renderer). When no set
  is usable the solve still runs against the backend's working copy and simply
  skips the render view; physics never blocks.
- Renderer, per frame: claim the published set (`PUBLISHED -> READING`), pack the
  instances from it and submit the frame waiting on its solve value. The set
  stays `READING` for the frames that read it; when a newer view is claimed the
  previous set is released by storing `release_value[set] = frame_value` **before**
  releasing `READING -> FREE` (release/acquire ordering), so the solver will not
  acquire it until the frame that read it has completed. Each set carries its own
  solve value and count, written before `PUBLISHED`, so a claim always describes
  one complete submission.

Headless contexts (bench, tests) have no frame timeline: `release_value` stays
zero and the sets cycle freely.

Measured at 100k bodies: the per-frame instance work drops from 1.14 ms of CPU
time (snapshot copy + host-visible instance fill) to 0.004 ms (the pack
dispatch), and the solver's positions are one integration step behind the CPU
snapshot - the renderer draws what the solve used. A CPU backend, or a GPU
backend that failed and was uninstalled, keeps the snapshot path unchanged.

## Measurements

Dev machine: RTX 4070 Ti SUPER, 16 CPU workers, `theta = 0.8`, depth 16.

Solve-level, `odin run bench -o:speed -- gpu-force` (includes the GPU velocity
update, so the CPU column includes its inline `vel += acc * dt`):

| bodies | cpu ms/solve | gpu ms/solve | speedup | max rel. error |
|-------:|-------------:|-------------:|--------:|---------------:|
| 1 024  |         2.12 |        0.056 |    38×  | 5.3e-07        |
| 4 096  |        34.22 |        0.125 |   275×  | 6.0e-07        |
| 16 384 |       542.29 |        0.410 | 1 324×  | 1.5e-06        |

Solve-level, `odin run bench -o:speed -- gpu-tree`:

| bodies | tree | cpu ms/solve | gpu ms/solve | speedup |
|-------:|------|-------------:|-------------:|--------:|
| 10 000 | cached tree       | 1.98 | 0.43 |  4.6× |
| 10 000 | rebuilt each tick | 2.81 | 1.33 |  2.1× |
| 100 000 | cached tree      | 31.81 | 2.87 | 11.1× |
| 100 000 | rebuilt each tick | 42.73 | 13.35 | 3.2× |

Velocity error vs the CPU tree stays at the f32 rounding level (mean ≈ 3e-07,
max ≈ 5.5e-06) and the contact sets match exactly. The "rebuilt each tick" row
includes the CPU tree build (≈7 ms at 100k) plus the structure upload (≈12 MB at
100k nodes), which only happens on rebuild.

Full tick, `odin run bench -o:speed -- gpu-tick` (the whole PHYSICS phase:
begin, gravity, collision, integrate, select, publish, adapt; octree rows rebuild
the tree every tick):

| mode | bodies | cpu ms/tick | gpu ms/tick | speedup |
|------|-------:|------------:|------------:|--------:|
| octree | 10 000 | 2.87 | 1.14 | 2.53× |
| octree | 100 000 | 42.47 | 6.06 | 7.01× |
| brute  | 2 000 | 10.73 | 2.61 | 4.12× |
| brute  | 4 096 | 45.18 | 10.65 | 4.24× |

Position error after one tick stays at f32 rounding (≤ 1e-07 in the table
above). The brute-force tick is where the deferred finish shows: the GPU solve
(0.06–0.13 ms) disappears behind the serial CPU collision pass, so the tick
keeps only collision plus the readback. The octree tick used to be dominated by
the serial CPU tree build; with the GPU build (M4) the remaining cost is the
per-tick velocity readback plus, when the tree is cached, the traversal.

The solve-level benches warm the GPU clocks before every GPU sample (see
`_gpu_warm_clocks` in the bench): the device idles at ≈210 MHz and a short solve
loop would otherwise report numbers several times too slow and far noisier. The
app never sees that state because the renderer keeps the device busy.

In the app (release build, shipped config: 10 000 bodies, rebuild every ~60
ticks, 8 workers) the octree tick drops from ≈2.5 ms on CPU to ≈0.57 ms on GPU;
at 2 000 bodies the brute-force tick drops from ≈10.8 ms to ≈2.6 ms.

## Architecture decisions

- **One compute queue, chosen at device creation.** A dedicated compute-only
  queue family is preferred; otherwise a second queue from the graphics family;
  on single-queue families the compute queue aliases the graphics queue. The dev
  machine exposes a dedicated compute family, so the solver gets its own queue
  handle; when compute would share the graphics handle, `gpu_gravity_init`
  refuses and the CPU solver runs (the two threads would otherwise race on one
  queue).
- **Timeline semaphores, not fences, for GPU work.** A compute context owns one
  timeline semaphore and a ring of command slots. A submission signals the next
  timeline value; the host waits with `vkWaitSemaphores` and later consumers
  (the renderer, when it draws GPU-produced state) wait on a value in
  `vkQueueSubmit2`. Binary semaphores stay where the window system requires
  them: swapchain acquire and present.
- **The hook is submit/finish, not one blocking call.** The pool writes happen in
  `finish`; nothing between `submit` and `finish` depends on them, so the wait
  lands at the first consumer instead of at the dispatch. The ring's slots stay
  in flight longer and the backend's failure modes separate cleanly into
  "nothing happened yet" (submit) and "results are unusable" (finish).
- **Compute pipelines follow the data-driven pipeline.** Workgroup size comes
  from the shader's `LocalSize` execution mode; descriptor set layouts and push
  constant ranges come from SPIR-V reflection (`Engine/Graphic/spirv`).
  Storage buffers are bound through external push descriptors
  (`push_descriptors_bind_buffer`), so no descriptor pools are involved.
- **f32, rewritten to avoid overflow.** The CPU computes `G * m1 * m2` in f64
  because it overflows f32 (`6e-11 * 6e27 * 6e27 ≈ 2.4e45`). The GPU form must
  cancel the per-body mass and evaluate `acc = (G * m_other) / dist_sq * dir`,
  which stays in f32 range. No `shaderFloat64` needed.
- **Host-visible memory prefers `HOST_CACHED`.** The solve reads velocities (and
  contacts) back through mapped memory; without a cached memory type those reads
  are uncached PCIe accesses and dominated the octree solve (18.6 ms → 3.2 ms at
  100k bodies once the allocator preferred cacheable host memory). The fallback
  keeps working on devices that only expose write-combined host memory.
- **The GPU path is a backend of the CPU pipeline, not a second engine.** It
  produces velocities (and, for Barnes-Hut, contact pairs) and leaves collision
  resolution, the position update, selection, snapshot publishing and the
  adaptive controller where they are. CPU collision determinism
  (`verify-engine`) stays intact.
- **The frame graph owns render passes only.** Physics compute is a per-tick
  chain submitted by the compute side; it is not a render-frame pass. When the
  renderer consumes GPU-produced body state (M5), the wait lives in the frame
  submission rather than inside the graph: the instance pack is recorded before
  the graph's passes and the submit waits on the solver's timeline value. The
  graph itself stays a render-pass scheduler; a per-pass queue model is deferred
  until there is more than one async producer.

## Milestones

- **M0 — plumbing (done).** Compute pipelines, reflection `LocalSize`, push
  constant ranges, external push descriptors, device-local buffers + staging
  copies, buffer barriers, timestamp queries, timeline semaphore, headless device
  (`compute_init_headless`) and the bench probe.
- **M1 — GPU brute-force gravity (done).** The `Gpu_Gravity` backend attached to
  the renderer's device (headless in bench/tests), packed `vec4` body staging,
  the tiled `physics_brute.comp`, `gravity_backend` config with CPU fallback, the
  `gpu-force` bench stage and the CPU/GPU match test.
- **M2 — GPU Barnes-Hut (done).** Tree upload on rebuild, the
  `physics_tree.comp` traversal with the collision fold and the atomic contact
  list, dispatch in tree order, contact readback into `collision_contacts`, the
  `gpu-tree` bench stage and the CPU/GPU parity test (velocities and contact
  sets). `theta`, rebuild intervals and the adaptive controller keep working
  unchanged.
- **M3 — GPU integration (done).** The kernels apply `vel += acc * dt` in place;
  the hook is split into `submit`/`finish` so the octree solve feeds collision
  while the brute-force solve overlaps the collision pass; the `gpu-tick` stage
  prices the whole PHYSICS phase. Position integration and collision stay on the
  CPU (they need the positions the next dispatch consumes, so moving them to the
  GPU would not remove the readback).
- **M4 — GPU tree build (done).** `tree_build.comp` (six passes in one
  submission) rebuilds the octree on the GPU, produces the metrics physic needs
  as a small readback, and leaves the tree in the traversal's buffers. The CPU
  builder runs only as the fallback; `gpu-tree` compares the two structures and
  `test_gpu_tree_build_matches_cpu` pins them cell by cell.
- **M5 — direct rendering (done).** The solver publishes a render view as one of
  three vended device snapshots; the renderer claims the published set, packs the
  per-frame instance data from it with a compute pass, and the frame submission
  waits on that set's solve value. A set is only written once the frame that last
  read it has completed (per-set `release_value` on the frame timeline), so
  neither side ever sees a buffer the other is writing. The snapshot path remains
  for CPU backends.

## Bench

```
odin run bench -o:speed -- gpu [elements] [dispatches] [samples]
odin run bench -o:speed -- gpu-force [n] [ticks] [samples]
odin run bench -o:speed -- gpu-tree [n] [depth] [theta] [ticks] [samples]
odin run bench -o:speed -- gpu-tick [n] [depth] [theta] [ticks] [samples] [octree|brute]
```

`gpu` creates a windowless compute context, runs the transfer → dispatch →
transfer probe (`shader/compute_probe.comp`), verifies the output and reports
the GPU time per dispatch (timestamp queries) plus the host submit→wait round
trip. The round trip is the per-tick latency floor the solver inherits; measure it
before choosing how much readback to pipeline.

`gpu-force` builds the deterministic bench bodies (seed 42), solves them with
the serial CPU brute force and with `Gpu_Gravity`, compares the velocity updates
and reports ms per solve plus the speedup. The GPU number includes the whole
round trip — packing, upload, dispatch, readback, scatter — so it is the honest
per-solve cost of the backend.

`gpu-tree` does the same for the octree backend: the CPU solve runs on the
worker pool, and the report covers both the cached-tree case and rebuilding the
tree every tick (the CPU world rebuilds with the CPU builder, the GPU world with
the GPU build). It prints both trees' node counts and leaf depths and compares
the contact sets exactly.

`gpu-tick` runs the whole PHYSICS phase through the scheduler on two identical
worlds and reports ms per tick, so the numbers price the tick the app actually
runs, not just the solve. The brute-force mode is one flat argument list
(`[n] [depth] [theta] [ticks] [samples] brute`), where depth and theta are
ignored.
