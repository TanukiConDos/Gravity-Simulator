---
name: Physics Bench
description: Use when benchmarking, profiling, or interpreting physics performance and accuracy in bench/.
---

# Physics bench

Sweeps the octree knobs and reports median ms/tick. Full rationale and measured
numbers live in `docs/benchmark.md`.

## Run

```
odin run bench -o:speed -disable-assert -microarch:native            # all stages
odin run bench -o:speed -disable-assert -microarch:native -- 100k    # one stage: all | 1k | 10k | 100k
```

Per config it times the `PHYSICS` phase over `repeats` independent worlds
(discarded warmup), reports median ms/tick, and measures mean/max relative
acceleration error against an exact O(N) sum on a deterministic (seed 42) query
subset. Output is one CSV per stage in `bench/results/` (gitignored, rewritten
per run).

## Profiling (spall)

The profiler is compiled out without `-define:PROFILE=true`.

```
odin run bench -o:speed -disable-assert -microarch:native -define:PROFILE=true -- profile [n] [depth] [theta] [interval] [workers]

odin build . -o:speed -disable-assert -microarch:native -define:PROFILE=true
./Gravity-Simulator          # app traces to trace_app.spall; close the window to flush
```

**Never** combine `-define:PROFILE=true` with timing runs: it leaves the
instrumentation calls in the binary and skews the numbers. Open traces at
https://gravitymoth.com/spall/ or Perfetto.

## Diagnostics

- `odin run bench -- contacts [n] [depth] [theta] [warmup] [scale]` — collision
  candidate quality.
- `odin run bench -- interactions [n] [depth] [theta] [warmup] [workers]` —
  force-application tally (near/far field).

## Interpreting

- Absolute numbers drift up to ~20% between sessions (boost/thermal/load):
  compare configs **within one run**, never across sessions.
- Reuse the established findings rather than re-deriving them: `theta` dominates
  the speed/accuracy trade-off; `tree_rebuild_interval` matters most at high
  `theta`; depth caps above `log8(N)` are insensitive; collision is folded into
  the gravity traversal; third-law sharing is a dead end at the app's settings.
