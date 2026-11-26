# Hot reload

Development builds can reload four independent things without restarting the
app:

| Layer | Watches | Applied by |
| --- | --- | --- |
| GLSL shaders | `engine/graphics/shader/*.vert/.frag/.comp` | graphics thread (graphics pipelines) and physics thread (GPU-physics compute pipelines) |
| Frame graph | `engine/graphics/frame_graph.json` | graphics thread, after the frame timeline drains |
| Tuning config | `config.json` | physics thread at a fixed-step boundary |
| Gameplay library | `game/*.odin`, `engine/game_api/*.odin` | rebuild thread, swapped on the physics thread |

It is enabled by `hot_reload` in `config.json`; the default is on in `-debug`
builds and off in optimized builds. Gameplay reloading is a separate opt-in,
`hot_game` (also off by default).

## Shaders

Save a GLSL source and the app runs `glslc` through the job table in
`engine/graphics/shader/manifest.odin`. A multi-output source (`tree_build.comp`)
is compiled to staging files and published only when every stage succeeds. A
compile error is logged with the compiler output and the live pipeline keeps
drawing.

If `glslc` is not in `PATH`, the watcher falls back to the compiled `.spv`
files; run `engine/graphics/shader/build.sh` (or `compilar.bat`) from another
terminal to trigger a reload.

Graphics pipelines are rebuilt in place on the graphics thread after waiting on
the frame timeline, so the `Pipeline_ID`s the frame graph holds stay valid. GPU
physics compute pipelines are rebuilt on the physics thread before its next
dispatch, after waiting on the compute timeline. A shader that changes the
push-descriptor interface is rejected: the old pipeline is kept and an error is
logged.

Every registered pipeline is rebuilt when any watched source changes; adding a
shader still means registering a job in the manifest and naming it from a
pipeline config.

## Frame graph

`frame_graph.json` is re-parsed on the graphics thread. The graph is validated
against the imports and pass recorders the backend implements (`swapchain`,
`depth`, `pick_readback`, `camera`; `main`, `pick_copy`), then swapped in after
the frame timeline completes. A malformed or unsupported graph is rejected and
the live graph stays.

## Config

`config.json` is parsed into a temporary, then installed on the physics thread
before the next fixed step. Live fields:

- `time`
- `theta`, `theta_min`, `theta_max`
- `tree_rebuild_interval`
- `max_depth`, `min_half_size`
- `auto_adjust`, `target_tickrate`

The octree is invalidated so the new values apply on the next gravity tick.
Restart-only fields (`system_creation_mode`, `num_objects`, `filename`,
`algorithm`, `gravity_backend`, `worker_threads`) are logged when they change
but do not take effect until relaunch.

A malformed file (missing number, unterminated object) keeps the live config.
Reloads start from the built-in defaults, so keep every field you care about in
the file.

## Gameplay library

Set `"hot_game": true` and save a file in `game/`. The app builds
`game/game.odin` with

```
odin build game -collection:engine=engine -build-mode:shared -debug -out:build/game_<n>.so
```

on a background thread, then the physics thread loads the new library, calls
`game_reload`, shuts down and unloads the previous one, and continues ticking.
The world and the host-owned `Game_State` blob survive; library globals reset.
The watcher/loader lives in `engine/hot`; `engine/app` supplies the world, input
snapshot, logger and a reseed callback.

The ABI lives in `engine/game_api/game_api.odin`. Gameplay code runs on the
physics thread before the physics systems, so it may spawn/despawn bodies. Its
contract:

- Do not create ECS pools or resources: the world is frozen and the destroy
  callbacks would point into the unloaded library. Put persistent state in
  `ctx.state` (64 KiB) or in existing components.
- Re-fetch `physics.body_view` every tick; spawning can relocate pool columns.
- Call `ctx.reseed_render(ctx.user)` after spawning/despawning so the renderer
  rebuilds the static instance columns. It only sets a flag; the graphics thread
  performs the upload after the frame timeline drains.
- The host reserves `hot.GAME_SPAWN_HEADROOM` entities beyond the initial world
  capacity. Spawns past that budget are refused.

The example `game/game.odin` spawns a small body about once per real second and
is a good place to experiment. Edit its interval or log message and save while
the app runs.

## Limitations

- Windows `.dll`/macOS `.dylib` gameplay reload uses the same `core:dynlib`
  path but has not been exercised here.
- Pipelines and frame-graph resources are not regenerated from scratch on every
  save; the reload rebuilds the existing registered set.
- The config reload parses from defaults, not from the current live values.
- `hot_reload` and `hot_game` are read at startup; changing them in a reloaded
  config does not start or stop the watchers.
- A library that crashes or corrupts the world cannot be recovered; restart.
