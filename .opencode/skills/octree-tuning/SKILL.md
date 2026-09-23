---
name: Octree Tuning
description: Use when changing or tuning the Barnes-Hut octree solver in Engine/physic (theta, depth, rebuild interval, collision fold).
---

# Octree tuning

`algorithm` in `config.json` selects one solver for both gravity and collision
(`BRUTE_FORCE` or `OCTREE`). The octree is Barnes-Hut with a center-of-mass
approximation and stores entity indices, so it never dangles when pools grow.
Read `docs/physics.md` for the full design.

## Invariants (tests pin these)

- **Collision is folded into the gravity traversal.** A node accepted by the
  opening angle is still descended into when its cell intersects the collision
  sphere (children marked `gravity_done` so the approximation applies exactly
  once). `theta` can never hide a contact, and gravity stays bit-identical.
- **Resolution is order-dependent**, so the serial narrow phase cannot be
  parallelized. Pairs are sorted first so the outcome is deterministic.
- **Fixed timestep**: one `PHYSICS` phase every 1/60 s of real time; the
  accumulator caps at 16 pending steps (the sim slows rather than taking huge,
  unstable steps).
- **Hot-path traversal stacks** (`_calc_force`, `_calc_force_collect`) skip
  zero-initialization: every slot is written before it is read. Keep it that way.
- The tree is read-only during solve; `parallel_for` splits per-body queries.

Relevant tests: `test_octtree_create`, `test_octtree_depth_cap`,
`test_octtree_force`, `test_octree_collision`,
`test_octree_force_collect_equivalence`, `test_adaptive_decide`,
`test_adaptive_tree_stale`.

## Knobs

- `theta` — Barnes-Hut opening angle (default 0.5). Dominates the speed/accuracy
  trade-off; raised = cheaper/less accurate.
- `tree_rebuild_interval` — sim-seconds between rebuilds (0 = every tick).
- `max_depth` / `min_half_size` — subdivision bounds. Natural depth is ≈`log8(N)`.
- `worker_threads` — pool size for the parallel solver.
- `auto_adjust` + `target_tickrate` / `theta_min` / `theta_max` — cost- and
  staleness-driven controller.

Measure any change with the `physics-bench` skill; rationale and measured
numbers are in `docs/benchmark.md`.
