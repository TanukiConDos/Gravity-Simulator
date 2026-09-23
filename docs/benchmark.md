# Benchmark

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

## Profiling (spall)

The profiler is compiled out entirely without `-define:PROFILE=true`. Do **not**
combine the flag with timing runs: it leaves the (inactive) span calls in the
binary and skews the numbers.

The spall wire format only carries Begin/End and thread/process names; the Odin
viewer rejects anything else, so there are no counters or instant events. Extra
data rides as free-form `args` text on a span (shown as "user data"), and
point-in-time facts (`adaptive.theta`, `octree.built`, `graphics.acquired`,
`graphics.recreate`, `physics.updates`, ...) are emitted as zero-duration
"marker" spans via `profile_mark`.

**Bench.** Build with the flag and use the `profile` stage to record a spall
trace of one config (warmup untraced, then 5 ticks). Spans cover the `PHYSICS`
systems (named by the scheduler), `tree.ensure`/`octree.build` (with node/leaf
metrics), `octree.solve` (with `n`, `theta`, worker count and contact count),
`collision.narrow`, `snapshot.publish`, `physic.adapt`, and one `parallel_for`
span per worker with its job size/chunking. Each worker records to its own named
timeline (`worker.0`...). Open the file at https://gravitymoth.com/spall/ or
Perfetto.

```
odin run bench -o:speed -disable-assert -microarch:native -define:PROFILE=true -- profile [n] [depth] [theta] [interval] [workers]
```

**App.** With the flag the app traces its whole run to `trace_app.spall`
(gitignored). It covers every thread, each named in the viewer: the main loop
(`main.wait_events`/`main.tick`), the physics thread (`physics.step` plus the
per-system spans, `tree.ensure`, `octree.build`/`octree.solve`,
`collision.narrow`, `snapshot.publish`, `physic.adapt`), the graphics thread
(`graphics.frame`, `graphics.wait_frame`/`acquire`/`framegraph`/`submit`/`present`,
one span per frame-graph pass named by pass, and `graphics.draw`/`draw_indexed`,
`graphics.snapshot_read`, `graphics.instances`, `graphics.push_descriptors`), and
the worker pool (`parallel_for` per worker). The process is named
`Gravity-Simulator`. Close the window to flush and exit; the file is truncated
on each launch.

```
odin build . -o:speed -disable-assert -microarch:native -define:PROFILE=true
./Gravity-Simulator          # then close the window
```

A flat `profiler` API would need `when` gates at every call site, so the wrapper
(`foundation/profiler.odin`) exposes only the `profile_*` procedures, which fold
to nothing when the flag is off. `profile_scope`/`profile_scope_args` open a span
closed at the end of the enclosing scope; `profile_scope_args` formats its
printf-style args only under the flag (the call site just builds a stack `[]any`),
and `profile_mark` records a zero-duration fact. Start the trace before the
thread pool so that, at exit, `parallel_destroy` runs first (LIFO defers) and each
thread releases its own buffer (`profile_thread_destroy`) while the context is
still alive.

## Measured results

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
