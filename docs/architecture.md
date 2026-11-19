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
    main["main.odin / parallel.odin"]
    bench["bench/"]
    tests["tests/"]
    front["Engine/Graphic/front<br/>package graphic"]
    backend["Engine/Graphic/backend<br/>package vk"]
    gpu["Engine/Graphic/gpu<br/>package gpu"]
    shared["Engine/Graphic/shared<br/>package gfx"]
    spirv["Engine/Graphic/spirv<br/>SPIR-V reflection (CPU only)"]
    physic["Engine/physic"]
    ecs["Engine/ecs"]
    foundation["foundation"]

    main --> front
    main --> backend
    main --> gpu
    main --> physic
    main --> ecs
    main --> foundation
    bench --> front
    bench --> backend
    bench --> gpu
    bench --> physic
    bench --> ecs
    bench --> foundation
    tests --> front
    tests --> backend
    tests --> gpu
    tests --> physic
    tests --> ecs
    tests --> foundation

    front --> backend
    front --> gpu
    front --> shared
    gpu --> backend
    backend --> shared
    backend --> spirv
    backend --> foundation
    front --> physic
    front --> ecs
    front --> foundation
    gpu --> physic
    gpu --> ecs
    gpu --> foundation
    physic --> ecs
    physic --> foundation
    ecs --> foundation
```

`foundation` has no engine dependencies (config, arena, file I/O, the job pool,
the profiler). `physic` and the front/`gpu` packages sit on `ecs`; the front and
`gpu` additionally depend on `physic` for the body view and snapshot types. The
front never imports `vendor:vulkan`; the backend imports no engine state (no
`ecs`, no `physic`) and never imports the front or `gpu`. `shared` (`gfx`) is
plain data only. The `bench/` and `tests/` packages are separate binaries that
drive the same libraries.

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
    participant F as foundation
    participant W as ecs.World
    participant P as physic
    participant B as vk backend
    participant R as graphic front (Renderer)
    participant T as physics + graphics threads

    M->>F: config_load("config.json")
    M->>F: parallel_init(worker_threads)
    M->>B: vk.window_init(1280, 720)
    M->>W: world_create()
    M->>P: body_spawn(...) — scene / random
    M->>P: physic_init(world, config)
    M->>W: scheduler_create(job_system)
    M->>P: physic_register_systems(scheduler)
    M->>B: vk.backend_init(window)
    M->>R: graphic.renderer_init(backend, window, world)
    M->>R: graphic.graphic_register_systems(scheduler)
    M->>W: scheduler_finalize()
    alt gravity_backend == GPU
        M->>B: gpu.gpu_gravity_init(backend, world, algorithm, capacity)
        M->>R: graphic.renderer_set_gravity_source(renderer, solver)
        M->>P: physic_set_gravity_solver(hook)
    end
    M->>W: world_freeze()
    M->>T: parallel_start()
    loop until the window closes
        M->>M: wait_events + pump
    end
    M->>T: ctx.exit = true, then parallel_stop()
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
        G->>G: front: claim snapshot or solver view<br/>build Frame_Packet / Instance_Stream
        G->>V: backend_draw: resolve picks, fence, acquire
        alt GPU backend owns the world
            G->>G: backend: instance_pack, wait solver timeline
        else CPU instance mode
            G->>G: backend: upload positions / selected columns
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
    backend -->|"GPU"| init{"gpu_gravity_init ok?<br/>backend has a separate compute queue"}
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

    pools -->|"physic.publish"| snap[("RenderSnapshot<br/>3 buffers · atomic state")]
    pools -->|"pack + upload (GPU backend)"| sets[("render view sets ×3<br/>CONCURRENT buffers")]

    subgraph GT["graphics thread"]
        pick["front: claim snapshot or view<br/>build Frame_Packet / Instance_Stream"]
        pack["backend: instance_pack.comp (stream)"]
        draw["backend: CmdDrawIndexed"]
        pick --> pack --> draw
    end

    snap -->|"claim PUBLISHED"| pick
    sets -->|"claim PUBLISHED → READING"| pick
    draw -->|"Frame_Result.picked"| sel[("Selection_State")]
    sel -->|"physic.select (atomic exchange)"| pools
```

The triple buffer is latest-wins and lock-free: the writer never blocks, the
reader always sees a complete version, and intermediate ticks are skipped. The
GPU render view is *vended* rather than shared, because a single set could be
overwritten by solve `T+1` before the frame reading solve `T` completes; see
[`gpu_physics.md`](gpu_physics.md). A pick travels back as `gfx.Frame_Result`
from `backend_draw`; the front stores it into `Selection_State` and the physics
thread consumes it.

## Where to go next

| Topic | Document |
|---|---|
| Entities, pools, scheduler graph, deferred changes | [`ecs.md`](ecs.md) |
| Solver, octree, collision fold, adaptive tuning | [`physics.md`](physics.md) |
| Graphics front/backend split, frame graph, reflection, picking | [`renderer.md`](renderer.md) |
| Compute context, GPU tree build, direct rendering | [`gpu_physics.md`](gpu_physics.md) |
| Sweeps, spall traces, measured results | [`benchmark.md`](benchmark.md) |
| Performance model, measured optimizations, open directions | [`performance.md`](performance.md) |
