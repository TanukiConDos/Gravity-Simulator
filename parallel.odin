package main

import graphic "./Engine/Graphic"
import ecs "./Engine/ecs"
import foundation "./foundation"
import "core:log"
import "core:sync"
import "core:thread"
import "core:time"

SimulationContext :: struct {
	world:      ^ecs.World,
	scheduler:  ^ecs.Scheduler,
	renderer:   ^graphic.Renderer,
	window:     ^graphic.Window,
	frame_time: f32,
	tick_time:  f32,
	delta_time: f32,
	exit:       bool,
}

@(private)
g_sim_logger: log.Logger

// Must match config.target_tickrate: the accumulator paces one step per
// FIXED_STEP_SEC, so the adaptive controller's cost budget (1000/tickrate)
// only lines up with the real loop rate when both agree.
FIXED_STEP_SEC :: 1.0 / 60.0
MAX_FRAME_SEC :: 0.25
MAX_ACCUMULATED_STEPS :: 16

@(private)
_physics_thread :: proc(th: ^thread.Thread) {
	context.logger = g_sim_logger
	ctx := cast(^SimulationContext)th.data
	if ctx == nil {log.errorf("[PARALLEL] physics thread: ctx is nil"); return}

	foundation.profile_thread_ensure()
	foundation.profile_thread_name("physics")
	defer foundation.profile_thread_destroy()

	accumulator: f32 = 0
	last_tick := time.tick_now()
	for !sync.atomic_load(&ctx.exit) {
		now := time.tick_now()
		elapsed := f32(time.duration_seconds(time.tick_diff(last_tick, now)))
		last_tick = now
		if elapsed > MAX_FRAME_SEC {elapsed = MAX_FRAME_SEC}

		config := foundation.config_get()
		sim_dt := FIXED_STEP_SEC * config.time
		accumulator += elapsed
		if accumulator > FIXED_STEP_SEC * MAX_ACCUMULATED_STEPS {
			accumulator = FIXED_STEP_SEC * MAX_ACCUMULATED_STEPS
		}

		tick_start := time.tick_now()
		updates := 0
		if accumulator >= FIXED_STEP_SEC {
			foundation.profile_scope("physics.step")
			for accumulator >= FIXED_STEP_SEC {
				ecs.scheduler_run(ctx.scheduler, .PHYSICS, ctx.world, sim_dt)
				accumulator -= FIXED_STEP_SEC
				updates += 1
			}
		}
		if updates > 0 {
			total_us := time.duration_microseconds(time.tick_diff(tick_start, time.tick_now()))
			sync.atomic_store(&ctx.tick_time, f32(total_us) / f32(updates))
			foundation.profile_mark("physics.updates", "updates=%d", {updates})
		}

		remaining := FIXED_STEP_SEC - accumulator
		if remaining > 0.0001 {
			time.sleep(time.Duration(remaining * 1e6) * time.Microsecond)
		}
	}
}

@(private)
_graphics_thread :: proc(th: ^thread.Thread) {
	context.logger = g_sim_logger
	ctx := cast(^SimulationContext)th.data
	if ctx == nil {return}

	foundation.profile_thread_ensure()
	foundation.profile_thread_name("graphics")
	defer foundation.profile_thread_destroy()

	last_frame := time.tick_now()
	for !sync.atomic_load(&ctx.exit) {
		now := time.tick_now()
		delta := f32(time.duration_seconds(time.tick_diff(last_frame, now)))
		sync.atomic_store(&ctx.delta_time, delta)
		last_frame = now

		frame_start := time.tick_now()
		{
			foundation.profile_scope_args("graphics.frame", "dt=%.4f", {delta})
			ecs.scheduler_run(ctx.scheduler, .RENDER, ctx.world, delta)
			{
				foundation.profile_scope("graphics.draw")
				if ok := graphic.renderer_draw_frame(ctx.renderer); !ok {
					sync.atomic_store(&ctx.exit, true)
					break
				}
			}
		}
		sync.atomic_store(
			&ctx.frame_time,
			f32(time.duration_milliseconds(time.tick_diff(frame_start, time.tick_now()))),
		)
	}
}

parallel_start :: proc(
	ctx: ^SimulationContext,
) -> (
	physics: ^thread.Thread,
	graphics: ^thread.Thread,
) {
	physics = thread.create(_physics_thread, .Normal, "physics")
	physics.data = ctx
	graphics = thread.create(_graphics_thread, .Normal, "graphics")
	graphics.data = ctx
	thread.start(physics)
	thread.start(graphics)
	return
}

parallel_stop :: proc(physics, graphics: ^thread.Thread) {
	thread.join(physics)
	thread.join(graphics)
	thread.destroy(physics)
	thread.destroy(graphics)
}
