---
name: Verify Engine
description: Use before committing or finishing a change in Gravity-Simulator to run tests and check engine-specific invariants.
---

# Verify the engine

## Always

```
odin test tests -debug                     # ECS, physics and SPIR-V reflection
odin build . -o:speed -disable-assert      # catches issues only hidden by debug asserts
scripts/check_layering.sh                  # front/backend/shared dependency rules
```

If you edited anything under `Engine/Graphic/shader/`, recompile the shaders
first — see the `shader-pipeline` skill.

`scripts/check_layering.sh` runs the package boundary checks:

```
rg -n "vendor:vulkan" Engine/Graphic/front Engine/Graphic/shared   # must be empty
rg -n '^import (ecs|physic|phys) ' Engine/Graphic/backend           # must be empty
rg -n "Graphic/(front|gpu)" Engine/Graphic/backend                 # must be empty
rg -n "package graphic" Engine/Graphic/backend                     # must be empty
rg -n "Graphic/front" Engine/Graphic/gpu                           # must be empty
```

The front (`graphic`) never imports `vendor:vulkan`; the backend (`vk`) imports
no `ecs`/`physic` state and never imports the front or `gpu`; `gpu` owns the
engine-side compute consumer (solver + render stream). `shared` (`gfx`) is plain
data and imports neither Vulkan nor ECS.

## Engine invariants to respect

- **Never put a side-effecting call inside `assert(...)`.** With
  `-disable-assert` the whole expression is removed. Assign first:
  `created := f(); assert(created, "...")`.
- **Error helpers**: `vk_check` for creation the caller can abort on (propagates
  `(T, bool)` with `or_return`); `vk_assert` for internal/secondary creation and
  API-misuse-only calls; `assert` for pure CPU invariants.
- **Ownership**: `*_init(args) -> (T, bool)` returns a complete value or nothing,
  releasing partial state on failure. `*_destroy` is idempotent and tolerates a
  partially initialized value.
- **Determinism**: collision pairs are sorted before the serial narrow phase;
  octree gravity is bit-identical with collision folded in. Keep it that way.
- **Config**: `config.json` fields fall back to defaults when missing or invalid;
  don't make a field mandatory by accident.
- **Visibility**: the engine packages expose only handles and their
  lifecycle/draw procedures; everything else is `@(private)`.
- **Layering**: `front -> {backend, gpu} -> shared`. The front never imports
  `vendor:vulkan`; the backend imports no `ecs`/`physic` and never imports the
  front or `gpu`.

## Don't commit

`bench/results/`, `perf.data*`, `*.spall` and the built `Gravity-Simulator`
binary are gitignored. Don't force-add them.
