# Renderer (`Engine/Graphic`)

## Configuration and reflection

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

## Comments

Code should be self-explanatory. Comments are reserved for non-obvious Vulkan
behaviour, invariants and ordering constraints. Ownership and error handling are
covered by this document, not repeated per function.

## Ownership and lifecycle

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

## Error handling

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

## Visibility

The package exposes only handles and their lifecycle/draw procedures:

- Public: `Window` + `window_init/destroy/should_close/poll_events` /
  `wait_events_timeout`; `Renderer` + `renderer_init/destroy/draw_frame`.
- Everything else is marked `@(private)`. Odin's `@(private)` is package-scoped:
  visible across the package's files, hidden from importers.

## Vulkan usage

- API 1.4 core, no extension fallbacks: dynamic rendering, synchronization2,
  push descriptors (`vkCmdPushDescriptorSet2`), `vkCmdBindIndexBuffer2`,
  negative viewport height, one semaphore per image, one fence per frame in
  flight, FIFO present mode (vsync).
- The engine never enables validation layers itself (see Validation in
  `AGENTS.md`).
