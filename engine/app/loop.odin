package app

import ecs "engine:ecs"
import foundation "engine:foundation"
import hot "engine:hot"
import physics "engine:physics"

// Context is the state the foundation loop hands back to the step/frame
// callbacks. Pacing, timings and the exit flag live in `foundation.Loop`.
@(private)
Context :: struct {
	world:     ^ecs.World,
	scheduler: ^ecs.Scheduler,
	game:      ^hot.Game,
}

// Runtime ordering: gameplay runs on the world's owner thread before the
// physics systems, then deferred structural changes are applied, then the
// renderer's static columns are refreshed after a spawn/despawn.
@(private)
physics_step :: proc(user: rawptr, dt: f32) -> bool {
	ctx := cast(^Context)user
	hot.game_physics_tick(ctx.game, dt)
	if !ecs.scheduler_run(ctx.scheduler, .PHYSICS, ctx.world, dt) {return false}
	ecs.world_flush(ctx.world)
	hot.game_after_flush(ctx.game)
	return true
}

@(private)
graphics_frame :: proc(user: rawptr, dt: f32) -> bool {
	ctx := cast(^Context)user
	return ecs.scheduler_run(ctx.scheduler, .RENDER, ctx.world, dt)
}

// A hot-reloaded config has just been installed on the physics thread; push the
// live-tunable fields into the solver state.
@(private)
config_applied :: proc(user: rawptr) {
	ctx := cast(^Context)user
	physics.physics_reload_config(ctx.world, foundation.config_get()^)
}
