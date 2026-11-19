# Renderer (`Engine/Graphic`)

`Engine/Graphic` is split into four packages: `front` (package `graphic`) owns
camera, input, instancing and the ECS integration; `backend` (package `vk`) owns
everything that talks to Vulkan and imports no engine state; `gpu` (package `gpu`)
owns the GPU gravity solver and the direct-render stream it feeds the backend;
`shared` (package `gfx`) is the plain-data seam. `spirv/` stays a separate
CPU-only reflection package.

```
Engine/Graphic/
├── shared/    package gfx       # plain data only: no Vulkan, no ECS, no GLFW
├── front/     package graphic   # camera, input, instancing, Renderer, ECS systems
├── backend/   package vk        # window, GPU, swapchain, pipeline, frame graph, compute,
│                                # descriptors, sync, render targets, pick, present
├── gpu/       package gpu       # GPU gravity solver, GPU tree build, render stream
├── spirv/                       # unchanged (CPU-only SPIR-V reflection, used by backend)
├── shader/                      # unchanged paths (Vulkan assets)
└── frame_graph.json             # unchanged path
```

```mermaid
flowchart LR
    main["main"] --> front["Engine/Graphic/front<br/>package graphic"]
    main --> backend["Engine/Graphic/backend<br/>package vk"]
    main --> gpu["Engine/Graphic/gpu<br/>package gpu"]
    front -->|"backend_draw / stream"| backend
    front -->|"claim views"| gpu
    front --> shared["Engine/Graphic/shared<br/>package gfx"]
    gpu --> backend
    gpu --> eng["physic · ecs · foundation"]
    backend --> shared
    backend --> spirv["spirv<br/>(reflection)"]
    backend --> foundation["foundation (profiling)"]
    front --> eng
```

Dependency rules, enforced by `scripts/check_layering.sh`:

- `front -> {backend, gpu, shared}`, `gpu -> backend`, `backend -> shared`.
- The front never imports `vendor:vulkan`.
- The backend imports no engine state: no `ecs`, no `physic`, and never the
  front or `gpu` package.
- `gpu` may import the backend plus `physic`/`ecs`/`foundation`: it *is* the
  engine-side compute consumer.
- Only the front wires the engine components into the frame: it claims the CPU
  snapshot (or the solver's render view) and applies pick results.

## Configuration and reflection

The pipeline is built from data, not from hand-written Vulkan structs, all of it
in the backend package:

- `Engine/Graphic/spirv/` parses the compiled SPIR-V to expose entry points, stage
  inputs/outputs, descriptor bindings and push constants. It makes no Vulkan
  calls and has unit tests (`tests/shader_reflection.odin`).
- `backend/renderer_config.odin` is the single source of truth for shaders, vertex
  streams and push descriptors. `backend/pipeline_config.odin` defines those types.
- `backend/pipeline.odin` derives shader modules, descriptor set layouts and the
  vertex input from the reflection.
- Vertex attributes are paired by declarative order: each `Vertex_Buffer_Spec`
  names a packed CPU struct whose non-`_` fields, in declaration order, consume
  the shader's input locations in ascending order. Formats are taken from
  SPIR-V; offsets and strides from the struct. A mismatch (wrong type, reordered
  field, missing input) fails at pipeline build time with a log error.
- `backend/descriptors.odin` owns the per-binding buffers and pushes them with
  `vkCmdPushDescriptorSet2`; `push_descriptors_validate` checks each configured
  binding against the shader interface.

Adding an attribute therefore means editing the GLSL interface and the CPU
struct; adding a resource means editing the GLSL interface and
`renderer_config.odin`.

Type layout follows the same split: `InstanceData`, `Vertex`,
`MAX_FRAMES_IN_FLIGHT`, the push-descriptor slots and all vertex formats live in
the backend. `UniformBufferObject` is gone; the camera arrives as
`gfx.Camera_Uniforms`. The sphere mesh is generated and uploaded by the backend
and addressed as `gfx.MESH_PRIMARY`.

## The seam (`shared/gfx`)

The shared package holds plain data only — no Vulkan types, no ECS handles, no
GLFW. Both sides may import it.

```odin
Vec3            :: [3]f32
Camera_Uniforms :: struct #align(16) { view, proj: matrix[4,4]f32 }   // 128 bytes
Mesh_Handle     :: distinct u32
MESH_PRIMARY    :: Mesh_Handle(1)
Input_State     :: struct { keys: u32, mouse_down: bool, cursor_u, cursor_v: f32,
                            fb_width, fb_height: i32, fb_valid: bool }
Pick_Request    :: struct { requested: bool, u, v: f32 }
Frame_Status    :: enum { OK, RETRY, FATAL }
Instance_Mode   :: enum { CPU, BACKEND }
Frame_Result    :: struct { picked: i32, has_pick: bool }
Draw            :: struct { mesh: Mesh_Handle, material: string,
                           positions: []Vec3, selected: []u8 }
Frame_Packet    :: struct { camera: Camera_Uniforms, draws: []Draw, pick: Pick_Request }
```

The backend's public surface (everything else in `vk` is package-private):

```odin
window_init / window_destroy / window_should_close / window_wait_events_timeout / window_pump
backend_init(window: ^Window) -> (^Backend, bool)
backend_instances_seed(b: ^Backend, bodies: []u32, radii: []f32, selected: []u8)
backend_instance_mode(b: ^Backend) -> gfx.Instance_Mode
backend_draw(b: ^Backend, packet: ^gfx.Frame_Packet) -> (gfx.Frame_Status, gfx.Frame_Result)
backend_frame_timeline(b: ^Backend) -> vulkan.Semaphore
backend_set_instance_stream(b: ^Backend, stream: ^Instance_Stream)
backend_clear_instance_stream(b: ^Backend)
backend_stream_release_value(b: ^Backend) -> u64
backend_destroy(b: ^Backend)
compute_* / gpu_init_headless / the pipeline, descriptor, buffer and sync primitives
```

`Instance_Stream` is the backend's neutral view of GPU-produced instance data:
buffer handles, mode/count/capacity, the producer's timeline and value, an opaque
owner token, and an optional `verify` callback. The backend never learns who
produced it or what the token means.

The `gpu` package exposes the solver and the stream conversion:

```odin
Gpu_Gravity + gpu_gravity_init(backend, world, mode, capacity) / _init_headless
gpu_gravity_destroy / gpu_gravity_info / gpu_gravity_backend
gpu_gravity_render_view / gpu_gravity_release_render_view
gpu_gravity_instance_stream(solver, view) -> vk.Instance_Stream
gpu_gravity_set_frame_timeline / gpu_tree_dump / Tree_Leaf / RENDER_VIEW_SETS
```

The front's public surface: `Renderer`, `renderer_init(backend: ^vk.Backend,
window: ^vk.Window, world: ^ecs.World)`, `renderer_destroy`,
`renderer_draw_frame`, `renderer_set_gravity_source(renderer, ^gpu.Gpu_Gravity)`,
`graphic_register_systems`; the `Camera`, `Pick_Request` (a *front* world resource
with `requested`, `prev_down`, `u`, `v`), `Window_Ref{input: ^gfx.Input_State}`
and `Renderer_Ref` resources.

`main` wires the packages in this order:

```odin
window, ok := vk.window_init(1280, 720)
backend, ok := vk.backend_init(window)
renderer, ok := graphic.renderer_init(backend, window, g_world)
graphic.graphic_register_systems(g_scheduler)
// GPU gravity (optional):
solver, ok := gpu.gpu_gravity_init(backend, g_world, config.algorithm, capacity)
graphic.renderer_set_gravity_source(renderer, solver)
physic.physic_set_gravity_solver(g_world, gpu.gpu_gravity_backend(solver))
// shutdown: clear the source, then destroy the solver, the renderer, the backend
// and the window in that order.
```

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
  `window_init(w, h) -> (^Window, bool)`, `backend_init(...) -> (^Backend, bool)`
  and `renderer_init(...) -> (^Renderer, bool)`. On failure they free it and
  return `nil`.
- `*_destroy(handle)` is idempotent and tolerates a partially initialized value;
  the owner registers `defer x_destroy(x)` after a successful init.
- `self` only appears where the resource already exists: destructors, in-place
  recreation (`swapchain_recreate`) and per-frame use (`model_bind`,
  `push_descriptors_write`, ...).

There are three handles: `vk.Backend`, `graphic.Renderer` and (optionally)
`gpu.Gpu_Gravity`. `main` owns all of them, creates the window and backend first,
then the front renderer, then the solver, and destroys them in reverse: clear the
gravity source (which releases the backend's stream), destroy the solver, the
front `Renderer`, the backend, and finally the window. The renderer holds a
backend pointer and a solver pointer; it never holds a device, swapchain or fence,
and the backend holds no world, pool or snapshot.

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
- Across the seam, failure is a `gfx.Frame_Status`: `FATAL` aborts the render
  phase, `RETRY` asks for another attempt without consuming state.

## Visibility

Each package exposes only its handles and their lifecycle/draw procedures:

- Backend: `Window` + `window_init/destroy/should_close` /
  `wait_events_timeout/pump`; `Backend` + `backend_init/destroy/draw`,
  `backend_instances_seed`, `backend_instance_mode`, the instance-stream API
  (`backend_frame_timeline`, `backend_set_instance_stream`,
  `backend_clear_instance_stream`, `backend_stream_release_value`); the compute
  primitives listed above.
- Front: `Renderer` + `renderer_init/destroy/draw_frame`,
  `renderer_set_gravity_source` and `graphic_register_systems`.
- GPU: the `Gpu_Gravity` handle and the solver/stream functions listed above.
- Everything else is marked `@(private)`. Odin's `@(private)` is package-scoped:
  visible across the package's files, hidden from importers.

## As an ECS system

`graphic_register_systems` adds the `RENDER`-phase systems `graphic.input` (which
mutates the `Camera` resource) and `graphic.render`. The latter looks the
renderer up through a `Renderer_Ref` world resource and calls
`renderer_draw_frame`; the system returns its result, so a fatal Vulkan error
aborts the phase and the graphics thread shuts down. `main` owns the renderer and
calls `renderer_destroy`, which clears the ref. The front still keeps a world
back-reference, now only to claim the snapshot and to store a resolved pick.

## Front frame flow

The front does no Vulkan work and keeps no frame state: one backend handle, the
world, the camera resource, the snapshot, its two column slices and the pick
resource.

```mermaid
flowchart TD
    input(["graphic.input"]) --> snap["read Input_State snapshot"]
    snap --> cam["update Camera + aspect<br/>from fb_width / fb_height"]
    cam --> edge["left-click edge → Pick_Request"]
    edge --> draw(["graphic.render → renderer_draw_frame()"])
    draw --> solver{"solver installed<br/>and backend active?"}
    solver -->|"yes"| claim["claim render view<br/>release the previous one<br/>backend_set_instance_stream"]
    solver -->|"no, was holding"| clear["release + clear the stream"]
    claim --> mode{"backend_instance_mode?"}
    clear --> mode
    mode -->|".CPU"| columns["claim RenderSnapshot<br/>fill positions[] / selected[]"]
    mode -->|".BACKEND"| skip["skip CPU snapshot"]
    columns --> packet
    skip --> packet["build Frame_Packet<br/>one draw: MESH_PRIMARY, \"main\""]
    packet --> call["backend_draw(packet)"]
    call --> status{"Frame_Status"}
    status -->|"OK"| apply["apply Frame_Result.picked<br/>to Selection_State (one atomic store)"]
    status -->|"RETRY"| keep["keep pick request"]
    status -->|"FATAL"| fail(["return false"])
    apply --> clear_pick["clear pick request"] --> done(["return"])
    keep --> done
```

## Backend frame flow

`backend_draw` is the old `renderer_draw_frame`, minus the front's bookkeeping.

```mermaid
flowchart TD
    draw(["backend_draw(packet)"]) --> resize{"framebuffer_resized?"}
    resize -->|"yes"| recreate["recreate swapchain<br/>(+ pipelines only if formats changed)"]
    recreate --> retry(["return RETRY<br/>(no frame slot consumed)"])
    resize -->|"no"| ready["resolve completed pick slots"]
    ready --> wait["wait frame fence"] --> acquire["acquire next image"]
    acquire --> outofdate{"OUT_OF_DATE?"}
    outofdate -->|"yes"| recreate
    outofdate -->|"no"| direct{"stream set by the caller?"}

    direct -->|"yes"| pack["instance_pack compute dispatch<br/>from the stream's buffers"]
    direct -->|"no"| upload["upload instance columns<br/>positions / selected, 16 B per instance"]
    pack --> fg
    upload --> fg["frame_graph_execute<br/>main, + pick_copy when requested"]
    fg --> submit["submit: wait stream timeline value,<br/>signal frame timeline"]
    submit --> present["present"]
    present --> next["current_frame++"]
    next --> result(["return OK, Frame_Result"])
```

- The backend only knows the neutral `Instance_Stream`; the front/gpu package
  claims, releases and replaces it. A `.RETRY` frame (resize, out-of-date) does
  not consume the pick request; only the front clears it, and only after `.OK`.
- Pick resolution returns `Frame_Result` instead of writing physics.
- Camera aspect is no longer recomputed on swapchain recreation; the input system
  keeps it in sync from the framebuffer snapshot.

## Frame graph

`Engine/Graphic/frame_graph.json` (path unchanged) owns the frame's structure; the
backend binds each pass name to a recording proc (`_backend_record_pass`).
`backend/frame_graph.odin` culls disabled/unused passes, topologically sorts the
rest and emits the layout barriers from each resource's usage.

```mermaid
flowchart LR
    camera["camera<br/>(uniform buffer)"] -->|"set 0"| main
    main["pass: main<br/>pipeline main"] -->|"color"| swapchain["swapchain<br/>final: present_src"]
    main -->|"MRT R32_UINT"| pick_id["pick_id<br/>(transient)"]
    main -->|"depth"| depth["depth<br/>(external)"]
    pick_id -->|"transfer_read"| pick_copy["pass: pick_copy<br/>optional, enabled on click"]
    pick_copy -->|"transfer_write"| pick_readback["pick_readback<br/>(buffer)"]
```

## Picking

The pick ID is the main pass's second color output (MRT, 1-based; zero means
"nothing hit"). On a left-click edge the `pick_copy` transfer pass copies one
pixel into a per-frame readback buffer; the backend resolves it into
`Frame_Result`, and the front hands the index to the physics thread through the
atomic `Selection_State`.

```mermaid
sequenceDiagram
    autonumber
    participant M as main thread
    participant I as graphic.input + front
    participant B as backend (graphics thread)
    participant FG as frame graph
    participant P as physic.select (physics thread)

    M->>I: Input_State snapshot (cursor u,v, mouse edge)
    I->>I: left-click edge → Pick_Request{requested, u, v}
    I->>B: Frame_Packet.pick
    B->>FG: enable pick_copy, map (u,v) → pixel
    FG->>FG: main writes 1-based instance id to pick_id
    FG->>FG: pick_copy: image → pick_readback
    Note over B: the copy rides the frame, resolved once its fence signals
    B->>I: Frame_Result{picked, has_pick}
    I->>P: Selection_State.picked = id − 1 (one atomic store)
    P->>P: atomic_exchange, apply to Selected
```

## Input and the main thread

GLFW is not thread-safe, and its input/framebuffer queries must run on the thread
that processes events. The **main** thread owns the window through the backend:
it blocks in `window_wait_events_timeout`, then calls `window_pump`, which queries
GLFW for the key bitmask, the left-button state, the normalised cursor position
and the framebuffer size, and publishes them as an atomic `gfx.Input_State`
snapshot on the backend's `Window`. The `RENDER` phase never calls GLFW:
`graphic.input` reads the snapshot to move and rotate the camera and to turn a
left-click edge into its `Pick_Request` resource, and the backend's
`_backend_recreate_if_possible`/`_choose_swap_extent` take the cached
framebuffer size from the snapshot instead of asking GLFW. Input latency is
bounded by the event-wait timeout, the same effective polling rate as a direct
query.

## Vulkan usage

- API 1.4 core, no extension fallbacks: dynamic rendering, synchronization2,
  push descriptors (`vkCmdPushDescriptorSet2`), `vkCmdBindIndexBuffer2`,
  negative viewport height, one semaphore per image, one fence per frame in
  flight, FIFO present mode (vsync).
- The engine never enables validation layers itself (see Validation in
  `AGENTS.md`).

## Compute

`backend/compute.odin` exposes the `Compute` handle: a device (headless, or the
backend's, which `gpu/gpu_physics.odin` attaches to), a command pool for the compute
queue, a timeline semaphore and a ring of submission slots.
`compute_begin`/`compute_submit`/`compute_wait` drive one slot at a time; a slot
is safe to record again once its previous timeline value completed.
`docs/gpu_physics.md` covers how the physics solver uses this.

- `backend/sync.odin` holds the primitives: the timeline semaphore (host wait with
  `vkWaitSemaphores`, device wait/signal through `SemaphoreSubmitInfo`), buffer
  memory barriers and timestamp query pools.
- Compute pipelines are built like graphics ones: `Compute_Config` names one
  compute shader and reflection supplies descriptor set layouts, the workgroup
  size (`LocalSize`/`LocalSizeId`) and push constant ranges.
  `pipeline_registry_add_compute` registers it; buffers move between passes
  through buffer barriers, not image barriers.
- Storage buffers are pushed with `vkCmdPushDescriptorSet2` like everything
  else. `Push_Binding_Spec.external` bindings own no buffer; the caller supplies
  one per submission with `push_descriptors_bind_buffer`.
- Compute work is not part of `frame_graph.json`: it is submitted by the compute
  side and ordered with the timeline semaphore. When a render pass consumes
  GPU-produced buffers (M5's instance pack, recorded before the graph's passes),
  the wait lives in the frame submission, not inside the graph: the graph stays a
  render-pass scheduler.
- `gpu/gpu_physics.odin` is the first consumer: the `Gpu_Gravity` backend
  packs body SSBOs, dispatches `physics_brute.comp` (all-pairs) or
  `physics_tree.comp` (Barnes-Hut over the tree `tree_build.comp` builds on the
  GPU, `gpu/gpu_tree.odin` and `gpu/gpu_tree_build.odin`), reads velocities and
  contacts back and installs itself as `physic`'s gravity solver. The hook is
  split into a non-blocking `submit` and an idempotent `finish`, so the solve
  stays in flight until a consumer needs it. `gpu_gravity_init` attaches it to
  the backend's device; `gpu_gravity_init_headless` is the bench/test variant.
  The package imports `physic`/`ecs`; the backend does not. `main` installs it
  with `graphic.renderer_set_gravity_source(renderer, solver)`; the front then
  claims published views and hands the backend an `Instance_Stream`, and the
  backend's one-shot debug hook asks the solver to verify the packed instances
  against its snapshot.
- `gpu_init_headless` takes `vkGetInstanceProcAddr` from the loader loaded at
  runtime (`vulkan_loader.odin`); the windowed path keeps GLFW's wrapper.

## Validation and layering

The engine never enables layers itself. Validation is enabled externally with
Vulkan Configurator (`vkconfig`) or `VK_INSTANCE_LAYERS` plus
`VK_LAYER_SETTINGS_PATH` for headless runs; see Validation in `AGENTS.md`.

Layering is checked by `scripts/check_layering.sh`, which fails if the front or
shared package mentions `vendor:vulkan`, if the backend imports `ecs`/`physic`
or mentions `Graphic/front`/`Graphic/gpu`, or if `gpu` mentions `Graphic/front`:

```
rg -n "vendor:vulkan" Engine/Graphic/front Engine/Graphic/shared
rg -n '^import (ecs|physic|phys) ' Engine/Graphic/backend
rg -n "Graphic/(front|gpu)" Engine/Graphic/backend
rg -n "package graphic" Engine/Graphic/backend
rg -n "Graphic/front" Engine/Graphic/gpu
```

Bench and tests import `Engine/Graphic/backend` as `vk` for `compute_*` and
`Engine/Graphic/gpu` for the solver (`gpu_gravity_*`, `Tree_Leaf`,
`RENDER_VIEW_SETS`); the front is `graphic`.
