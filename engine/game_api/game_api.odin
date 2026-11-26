package game_api

import ecs "engine:ecs"
import found "engine:foundation"
import gfx "engine:graphics/shared"

// ABI between the host (`main`) and a hot-swappable gameplay library. Both
// sides import this package, so the types and type IDs are identical even
// though the library owns its own copy of the code. Keep this file free of
// engine implementation packages: the gameplay library must not pull the
// renderer or Vulkan into its .so.
//
// Rules for gameplay code:
//   - It runs on the physics thread, before the physics systems, and may spawn/
//     despawn bodies (structural changes are owner-thread-only).
//   - It must not create ECS pools or resources after `world_freeze` (the host
//     registers `Game_State` before freezing). Keep long-lived state in the
//     blob or in existing components.
//   - Library globals reset on every reload; ECS state does not.
//   - Re-fetch `physics.body_view` each tick: pools can relocate on spawn.

ABI_VERSION :: 1

// Host-owned scratch memory that survives a library reload. 64 KiB is plenty
// for gameplay timers/counters; use ECS components for per-body data.
GAME_STATE_BYTES :: 64 * 1024

Game_State :: struct #align(16) {
	bytes: [GAME_STATE_BYTES]u8,
}

Game_Context :: struct {
	abi_version: u32,
	// Reserved for future fields without moving the existing offsets.
	_pad:        u32,
	world:       ^ecs.World,
	config:      ^found.Config,
	state:       ^Game_State,
	input:       ^gfx.Input_State,
	// Fixed-step counter since process start.
	tick:        u64,
	// Asks the host to rebuild the renderer's static instance columns (radius
	// and selection) after a spawn/despawn. Safe to call from the physics thread.
	reseed_render: proc(user: rawptr),
	user:          rawptr,
}

// Entry points the host resolves from the library. `init` runs on the first
// successful load, `reload` on every subsequent swap (fall back to `init` when
// absent), `tick` once per fixed physics step, and `shutdown` before unload.
Game_Api :: struct {
	api_version: proc() -> u32,
	init:        proc(ctx: ^Game_Context) -> bool,
	reload:      proc(ctx: ^Game_Context) -> bool,
	tick:        proc(ctx: ^Game_Context, dt: f32),
	shutdown:    proc(ctx: ^Game_Context),
}
