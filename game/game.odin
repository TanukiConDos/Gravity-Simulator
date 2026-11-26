package game

import api "engine:game_api"
import ecs "engine:ecs"
import physics "engine:physics"
import "core:log"

// Example hot-reloadable gameplay layer. Save this file while the app runs
// (with `"hot_game": true` in config.json) and the host rebuilds it with
// `odin build -build-mode:shared` and swaps the library at a tick boundary.
//
// The package is compiled only into `build/game_<n>.so`; the host never imports
// it statically. State that must survive a reload goes in `ctx.state` or in ECS
// components that already exist.

@(private)
State :: struct {
	elapsed: f32,
	spawns:  int,
}

@(private)
state_of :: proc(ctx: ^api.Game_Context) -> ^State {
	return cast(^State)rawptr(&ctx.state.bytes[0])
}

@(export)
game_api_version :: proc() -> u32 {
	return api.ABI_VERSION
}

@(export)
game_init :: proc(ctx: ^api.Game_Context) -> bool {
	if ctx == nil || ctx.world == nil || ctx.state == nil {return false}
	log.infof("[GAME] init (bodies=%d)", physics.body_count(ctx.world))
	return true
}

@(export)
game_reload :: proc(ctx: ^api.Game_Context) -> bool {
	if ctx == nil || ctx.world == nil {return false}
	log.infof("[GAME] reloaded (bodies=%d)", physics.body_count(ctx.world))
	return true
}

@(export)
game_tick :: proc(ctx: ^api.Game_Context, dt: f32) {
	if ctx == nil || ctx.world == nil {return}
	state := state_of(ctx)
	state.elapsed += dt

	// Periodically drop a small body into the system. `dt` is simulation seconds,
	// so this is about once per real second at the default 1000x time scale.
	// This is deliberately visible: edit the interval/velocity and save to see
	// the reload take effect.
	if state.elapsed < 1000.0 {return}
	state.elapsed = 0
	if physics.body_count(ctx.world) + 1 >= ctx.world.capacity {
		log.warnf("[GAME] spawn headroom exhausted")
		return
	}
	state.spawns += 1
	_ = physics.body_spawn(
		ctx.world,
		{2.0e9, 0, 0},
		{0, 2.0e4, 0},
		1.0e24,
		1.0e6,
	)
	ctx.reseed_render(ctx.user)
	log.infof("[GAME] spawned body %d", state.spawns)
}

@(export)
game_shutdown :: proc(ctx: ^api.Game_Context) {
	log.infof("[GAME] shutdown")
}
