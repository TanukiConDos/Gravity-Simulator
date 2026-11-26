# Architecture

This is the map of the project: how the packages fit together, which threads
exist at runtime, and how a tick and a frame flow through the engine. It links
to the focused documents, which carry the subsystem diagrams:

- [`ecs.md`](ecs.md) — entity/component storage, the system scheduler, threading.
- [`physics.md`](physics.md) — the tick pipeline, Barnes-Hut octree, collision fold,
  adaptive tuning.
- [`renderer.md`](renderer.md) — the graphics front/backend split and the frame graph.
- [`gpu_physics.md`](gpu_physics.md) — compute backends, GPU tree build, direct
  rendering.
- [`benchmark.md`](benchmark.md) — the bench harness and profiler.

## System context

```mermaid
flowchart LR
    user(["User"]) -->|"edits"| config["config.json"]
    user -->|"edits"| scenes["scenes/*.json"]
    config --> app["Gravity-Simulator<br/>(Odin)"]
    scenes --> app
    win["GLFW window"] -->|"keys / mouse / resize"| app
    app -->|"input snapshot"| win
    app -->|"Vulkan 1.4<br/>graphics + compute queue"| vulkan["Vulkan driver"]
    vulkan --> gpu["GPU"]
    app -->|"1 Hz logs"| console["console (frame/tick time)"]
    app -.->|"-define:PROFILE=true"| spall["trace_app.spall / bench traces"]
```

The simulation is configured entirely from `config.json` and, in `FILE` mode,
one scene JSON in `scenes/`. The app opens one GLFW window, brings up one Vulkan
device (owned by the backend, shared with the optional GPU physics backend), and
runs until the window closes.

## Module dependencies

```mermaid
flowchart TD
    main["main.odin<br/>planet scene + entry point"]
    app["engine/app<br/>runtime assembly"]
    bench["bench/"]
    tests["tests/"]
    game["game/ (shared library)"]
    front["engine/graphics/front<br/>package graphic"]
    backend["engine/graphics/backend<br/>package vk"]
    shared["engine/graphics/shared<br/>package gfx"]
    pgpu["engine/physics/gpu<br/>package physics_gpu"]
    spirv["engine/graphics/spirv<br/>SPIR-V reflection (CPU only)"]
    shader["engine/graphics/shader<br/>manifest"]
    physics["engine/physics"]
    ecs["engine/ecs"]
    hot["engine/hot"]
    gapi["engine/game_api"]
    foundation["engine/foundation"]

    main --> app
    main --> physics
    main --> ecs
    main --> foundation
    app --> physics
    app --> front
    app --> backend
    app --> ecs
    app --> hot
    app --> pgpu
    app --> foundation
    hot --> front
    hot --> pgpu
    hot --> ecs
    hot --> gapi
    hot --> shader
    hot --> foundation
    game --> gapi
    game --> physics
    game --> ecs
    bench --> physics
    bench --> pgpu
    bench --> front
    bench --> backend
    bench --> ecs
    bench --> foundation
    tests --> physics
    tests --> pgpu
    tests --> front
    tests --> backend
    tests --> ecs
    tests --> foundation

    physics --> pgpu
    pgpu --> front
    pgpu --> shared
    front --> backend
    front --> shared
    backend --> shared
    backend --> spirv
    backend --> shader
    backend --> foundation
    pgpu --> ecs
    pgpu --> foundation
    physics --> ecs
    physics --> foundation
    ecs --> foundation
```

`engine/foundation` has no engine dependencies (config, arena, file I/O, the job
pool, the profiler and the fixed-step/free-running loop). `engine/app` is the
runtime orchestrator: it owns the frame source (`engine/app/frame_source.odin`:
CPU columns, snapshot claim, pick handoff), the step/frame callbacks
(`engine/app/loop.odin`), and the window/backend/front bootstrap. `main` supplies
only the planet scene/setup and the entry point, and calls `app.run`. The front
never imports a physics package (or `vendor:vulkan`); physics depends on the front,
which owns the compute context and proxies GPU work to the backend, and on `gfx`
for the plain handles. No physics package imports the backend or `vendor:vulkan`.
The backend imports no engine state and never imports the front. `shared` (`gfx`)
is plain data only. The `bench/` and `tests/` packages are separate binaries that
drive the same libraries; they open a headless compute context from the backend
directly.

## Runtime topology

Three long-lived threads plus a worker pool. The `World` has a single owner at a
time: the physics thread writes it, the graphics thread only reads frozen
registries.

```mermaid
flowchart TB
    subgraph Main["main thread"]
        ev["window_wait_events_timeout(1/60 s)"]
        pump["window_pump() → Input_State"]
        log["1 Hz frame/tick log"]
    end

    subgraph Phys["physics thread — fixed 1/60 s step"]
        psched["scheduler_run(PHYSICS, dt)"]
        flush["world_flush()"]
    end

    subgraph Gfx["graphics thread"]
        rsched["scheduler_run(RENDER, dt)"]
    end

    subgraph Pool["job pool — worker_threads (default 8)"]
        workers["help-first workers"]
    end

    world[("World<br/>pools + resources<br/>frozen before threads start")]
    win[("Backend Window<br/>atomic Input_State")]
    snap[("RenderSnapshot<br/>triple buffer")]
    render_view[("Gpu render view<br/>3 vended sets")]
    pick[("Selection_State<br/>atomic pick")]

    pump -->|"atomic Input_State"| win
    win -->|"snapshot"| rsched
    psched -->|"sole writer"| world
    psched -->|"publish"| snap
    rsched -->|"concurrent reads"| world
    snap -->|"claim latest"| rsched
    rsched -->|"store pick id"| pick
    psched -->|"consume pick"| pick
    psched <-->|"parallel_for"| workers
    rsched -.->|"ready .ANY systems"| workers
    psched -->|"publish"| render_view
    render_view -->|"claim"| rsched
```

- **GLFW belongs to the main thread.** The render phase never calls it; it reads
  the atomic snapshot `window_pump` publishes.
- **The physics thread owns every mutation**, including `world_flush`, which
  applies deferred structural changes.
- **The job pool is shared.** `parallel_for` (solver) and ready `.ANY` systems
  (scheduler) both submit to it, and a blocked thread helps run queued work.

## Startup sequence

```mermaid
sequenceDiagram
    autonumber
    participant M as main()
    participant A as engine/app
    participant F as foundation
    participant W as ecs.World
    participant P as physics
    participant B as vk backend
    participant R as graphic front (Renderer)
    participant PG as physics_gpu
    participant T as physics + graphics threads

    M->>A: app.run(Desc{title, config_path, setup})
    A->>F: config_load(config_path)
    A->>F: parallel_init(worker_threads)
    A->>W: world_create()
    A->>M: setup(world, config)
    M->>P: world_reserve + body_spawn(...) — scene / random
    A->>W: world_reserve(... + game headroom)
    A->>P: physics_init(world, config)
    A->>W: scheduler_create(job_system)
    A->>P: physics_register_systems(scheduler)
    A->>B: vk.window_init(1280, 720)
    A->>B: vk.backend_init(window)
    A->>R: graphic.renderer_init(backend, window, world)
    A->>A: frame_source_init(renderer, world)
    A->>R: graphic.graphic_register_systems(scheduler)
    A->>W: scheduler_finalize()
    alt gravity_backend == GPU
        A->>R: renderer_compute() (attaches on first use) -> gfx.Compute
        A->>PG: gpu_gravity_init(compute, world, algorithm, capacity)
        A->>R: renderer_set_stream_producer(handle, ops)
        A->>P: physics_set_gravity_solver(hook)
    end
    A->>A: hot.reload_init + hot.game_init
    A->>W: world_freeze()
    A->>T: foundation.loop_start(callbacks)
    loop until the window closes
        A->>A: wait_events + pump
    end
    A->>T: loop_request_exit(), then loop_stop()
```

All pools and resources must exist before `world_freeze`; after it the registries
are read-only so the two side threads can look values up concurrently (creating a
pool/resource after freeze is an error).

## Tick and frame lifecycle

The physics thread paces itself with an accumulator and runs zero or more fixed
steps per wake-up (`MAX_ACCUMULATED_STEPS` caps a slow solver rather than taking
an unstable step). The graphics thread renders as fast as the swapchain allows.

```mermaid
sequenceDiagram
    autonumber
    participant M as main
    participant P as physics thread
    participant W as World
    participant S as RenderSnapshot
    participant G as graphics thread
    participant V as vk.Backend

    loop every wake-up
        P->>P: accumulator += elapsed, clamp to 16 steps
        loop while accumulator ≥ 1/60 s
            P->>W: scheduler_run(PHYSICS, dt)
            W->>W: begin → gravity → collision → integrate/select → publish → adapt
            P->>W: world_flush()
            P->>S: publish positions + selection
        end
    end

    loop every frame
        G->>W: scheduler_run(RENDER, dt)
        W->>W: graphic.input → graphic.render
        G->>G: front: runtime frame-source columns, pump the producer handle<br/>build Frame_Packet
        G->>V: backend_draw: resolve picks, fence, acquire
        alt GPU backend owns the world
            G->>G: backend: instance_pack, wait producer timeline
        else CPU instance mode
            G->>G: backend: upload the source columns
        end
        G->>V: frame graph, submit, present
        G->>W: store Frame_Result pick in Selection_State
    end

    loop blocked up to 1/60 s
        M->>V: window_wait_events_timeout + window_pump
    end
```

## Gravity backend selection

One `algorithm` chooses the solver *and* the collision strategy; `gravity_backend`
chooses who runs the solve. The GPU path is a backend of the CPU pipeline, never
a second engine.

```mermaid
flowchart TD
    algo{"config.algorithm"} -->|"BRUTE_FORCE"| bf["all-pairs solve<br/>+ serial O(N²) collision"]
    algo -->|"OCTREE"| ot["Barnes-Hut octree<br/>+ collision folded into traversal"]

    bf --> backend{"config.gravity_backend"}
    ot --> backend
    backend -->|"CPU"| cpu["built-in CPU solver"]
    backend -->|"GPU"| init{"renderer_compute attaches?<br/>device has a separate compute queue"}
    init -->|"yes"| hook["Gpu_Gravity submit/finish hook"]
    init -->|"no"| cpu
    hook -->|"submit or finish fails at runtime"| cpu
```

The octree GPU hook also builds the tree on the GPU (`build_tree`); when any hook
step fails, the hook is uninstalled and the CPU solver runs for the current tick
and the rest of the run.

## Data ownership and handoff

The simulation pools never cross threads directly. Two handoff channels carry
state to the graphics thread: the CPU `RenderSnapshot` triple buffer, and (with a
GPU backend) the vended render-view sets.

```mermaid
flowchart LR
    subgraph PT["physics thread (sole writer)"]
        pools[("component pools<br/>Position · Velocity · Mass · Radius · Selected")]
    end

    pools -->|"physics.publish"| snap[("RenderSnapshot<br/>3 buffers · atomic state")]
    pools -->|"pack + upload (GPU backend)"| sets[("render view sets ×3<br/>CONCURRENT buffers")]

    subgraph GT["graphics thread"]
        pick["main Frame_Source: claim snapshot<br/>(called by the front)"]
        pack["backend: stream claim + instance_pack.comp"]
        draw["backend: CmdDrawIndexed"]
        pick --> pack --> draw
    end

    snap -->|"claim PUBLISHED"| pick
    sets -->|"claim via Stream_Ops"| pack
    draw -->|"Frame_Result.picked"| sel[("Selection_State")]
    sel -->|"physics.select (atomic exchange)"| pools
```

The triple buffer is latest-wins and lock-free: the writer never blocks, the
reader always sees a complete version, and intermediate ticks are skipped. The
GPU render view is *vended* rather than shared, because a single set could be
overwritten by solve `T+1` before the frame reading solve `T` completes; see
[`gpu_physics.md`](gpu_physics.md). A pick travels back as `gfx.Frame_Result`
from `backend_draw`; the front passes it to the frame source's pick callback,
`main` stores it into `Selection_State`, and the physics thread consumes it.

## Where to go next

| Topic | Document |
|---|---|
| Entities, pools, scheduler graph, deferred changes | [`ecs.md`](ecs.md) |
| Solver, octree, collision fold, adaptive tuning | [`physics.md`](physics.md) |
| Graphics front/backend split, frame graph, reflection, picking | [`renderer.md`](renderer.md) |
| Compute context, GPU tree build, direct rendering | [`gpu_physics.md`](gpu_physics.md) |
| Sweeps, spall traces, measured results | [`benchmark.md`](benchmark.md) |
| Performance model, measured optimizations, open directions | [`performance.md`](performance.md) |
