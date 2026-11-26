# Performance

A performance companion to [`architecture.md`](architecture.md),
[`physics.md`](physics.md) and [`benchmark.md`](benchmark.md): the performance
model, the measured optimization results (2026-10), and the open directions.

Unless noted, numbers are from a release build
`odin build . -collection:engine=engine -o:speed -disable-assert -microarch:native` on the dev host
(8 physical / 16 SMT cores, RTX 4070 Ti SUPER, 96 MB L3). Absolute times drift
~10–20% between sessions; **re-measure before acting**.

## Two regimes

- **CPU backend** (`gravity_backend = CPU`, default): the octree solve is
  parallelised with `parallel_for`, collision resolution is serial by design, and
  every tick copies a `RenderSnapshot`. Dominated by the octree traversal (and,
  for `BRUTE_FORCE`, by collision).
- **GPU backend** (`gravity_backend = GPU`): the solve dispatches on a separate
  compute queue and the backend draws straight from the solver stream (no snapshot
  copy, no host instance fill). The floor is the host round-trip and the serial
  CPU collision pass.

The GPU is a backend of the CPU pipeline, never a second engine: shrinking the
CPU side (collision, packing, publishing) helps both regimes, while GPU-kernel
work is already near-zero.

## Where CPU octree time goes

`_calc_force` / `_calc_force_collect` (`engine/physics/octtree.odin`) walks the
tree per body with an explicit stack. On this host the traversal is
**throughput/branch-bound, not memory-latency-bound**: a field-layout change that
cut L1 misses by 27% left cycles and IPC unchanged, because the whole tree fits
in L3. The lever is **instructions executed per node**, not cache layout. The
other real cost is the **tree build** (~9.5 ms at 100k bodies, ~21% of a
rebuild-every-tick solve).

## Measured results

| Change | Effect |
|---|---|
| **Squared opening-angle test** (`4·half² ≤ θ²·dist²` instead of `sqrt`), plus a cancelled far-field form. `engine/physics/octtree.odin` | CPU traversal −7…−19% (`interactions` 100k θ0.5 462→404 ms; `10k` −13…−19%) |
| **Per-chunk contact collection** (each work chunk owns its `[dynamic]Contact`; no per-pair mutex). `octtree.odin`, `physics_system.odin` | 3.5× on a dense 186 814-contact scene (22.7→6.5 ms); neutral when sparse |
| **Build `keys` alongside `order`** so the octree partition scatters without recomputing octants. `octtree.odin` | build −24% (9.5→7.2 ms @100k); rebuild tick −5.9% |
| **Tiled SIMD all-pairs brute force** (`core:simd`, 8×f32 SoA scratch, GPU's cancelled form). `physics_system.odin` | CPU brute solve 3.4× (32.5→9.5 ms @4096); CPU brute tick 2.2× (42.6→19.2 ms) |
| **Parallel brute-collision broad phase** with an exact serial replay in dense-list order. `physics_system.odin` | GPU brute tick 3.9× (9.9→2.55 ms @4096); bit-identical collision result |
| **Skip the snapshot copy on the GPU render path** + a liveness flag that returns the renderer to the snapshot after a mid-run GPU failure. `physics_system.odin`, `renderer.odin` | perf-neutral (~0.05 ms copy), but fixes the "stale GPU buffers forever" gap |

### Investigated, no change

| Change | Why not |
|---|---|
| Octree node hot/cold split | L1 misses −27% but cycles/IPC flat (throughput-bound, tree fits in L3) |
| Smaller traversal stacks (4096→1024) | ±1–3%, within noise |
| Parallel GPU host packing | `gpu-force` pins 1 worker; `gpu-tick brute` was collision-bound (now PF7's scan) |
| Pipelined GPU readback | brute's `finish` wait is already hidden by collision (0.001 ms); octree's wait is a genuine same-tick dependency |
| Job-pool work stealing | <0.4% of cycles in the pool; the w8→w16 plateau is SMT saturation, not the mutex |

## How to measure

```sh
# perf build
odin build . -collection:engine=engine -o:speed -disable-assert -microarch:native

# octree sweeps (per-tick ms + accuracy vs an exact reference)
odin run bench -collection:engine=engine -o:speed -microarch:native -- 1k
odin run bench -collection:engine=engine -o:speed -microarch:native -- 10k

# isolated traversal (serial, single config: n depth theta warmup workers)
odin run bench -collection:engine=engine -o:speed -microarch:native -- interactions 100000 16 0.5 0 16

# GPU CPU-vs-GPU comparison (solve / whole tick / tree)
odin run bench -collection:engine=engine -o:speed -microarch:native -- gpu-force 4096 3 3
odin run bench -collection:engine=engine -o:speed -microarch:native -- gpu-tree 100000 16 0.8 2 2
odin run bench -collection:engine=engine -o:speed -microarch:native -- gpu-tick 100000 16 0.8 3 2 octree

# profiling
odin run bench -collection:engine=engine -o:speed -define:PROFILE=true -- profile   # -> bench/results/trace_*.spall
perf stat -d  odin run bench -collection:engine=engine -o:speed -microarch:native -- 10k
perf record -g odin run bench -collection:engine=engine -o:speed -microarch:native -- 10k
```

Rules of thumb learned here: measure medians of ≥3 samples; pair every speedup
with an accuracy gate; use `perf stat -d` to distinguish memory-bound from
throughput-bound; and treat a bench that pins one worker as unable to show a
parallel win.

## Open directions

- **Traversal instruction count.** The traversal is instruction/throughput-bound;
  the next win is fewer instructions per node (branchless accept/descend, fewer
  per-node loads), not better layout. Consider mirroring the CPU's squared
  opening-angle test in `physics_tree.comp` to keep CPU/GPU classification in
  lock-step.
- **One-tick-ahead GPU pipeline.** The only way to remove the octree `finish`
  dependency: run the solve one tick ahead (move `p += v·dt` into the kernel, or
  reorder `gravity(T+1)` before `integrate(T)`). Needs shader + `physics` changes
  and a double-buffered readback.
- **Occasional allocations.** The SIMD brute solve allocates a per-tick scratch,
  and the octree solve allocates per-chunk contact lists; a reusable buffer pool
  in `Physic_State` would remove them.
- **16-lane SIMD.** The brute solve uses 8×f32 (AVX2); AVX-512 width was not
  tried (downclock risk on mixed loads).
- **Renderer.** The direct-render path is already ~free; the frame graph / barrier
  work is a learning surface rather than a current bottleneck.

## Guardrails

Optimizations must not regress: the octree fold/gravity equivalence
(`test_octree_force_collect_equivalence`), CPU/GPU acceleration and exact-contact
parity, the CPU tree-build parity, deterministic collision order, the fixed
timestep, the world-ownership/freeze rules, and the submit/finish CPU fallback
contract.
