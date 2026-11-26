package foundation

import "core:log"
import "core:sync"
import "core:thread"
import "core:time"

// The application's two runtime loops: a fixed-step physics thread and a
// free-running graphics thread. The application supplies the per-step and
// per-frame work; this package owns pacing, hot-config application, profiling
// and the thread lifecycle, so no engine module below the app has to know about
// the simulation's concrete types.
//
// `physics_step` and `graphics_frame` return false to stop both loops. They run
// on their own threads with the logger copied from the descriptor.

// Must match config.target_tickrate: the accumulator paces one step per
// FIXED_STEP_SEC, so the adaptive controller's cost budget (1000/tickrate)
// only lines up with the real loop rate when both agree.
FIXED_STEP_SEC :: 1.0 / 60.0
MAX_FRAME_SEC :: 0.25
MAX_ACCUMULATED_STEPS :: 16

Loop_Step_Proc :: proc(user: rawptr, dt: f32) -> bool

// Called on the physics thread after a hot-reloaded config has been installed,
// before the next step, so the app can re-apply it to its solver state.
Loop_Config_Proc :: proc(user: rawptr)

Loop_Desc :: struct {
	user:           rawptr,
	physics_step:   Loop_Step_Proc,
	graphics_frame: Loop_Step_Proc,
	config_applied: Loop_Config_Proc,
	logger:         log.Logger,
}

Loop :: struct {
	desc:            Loop_Desc,
	physics_thread:  ^thread.Thread,
	graphics_thread: ^thread.Thread,
	exit:            bool,
	frame_time:      f32,
	tick_time:       f32,
}

loop_start :: proc(desc: Loop_Desc) -> ^Loop {
	l := new(Loop)
	l.desc = desc
	l.physics_thread = thread.create(_loop_physics_thread, .Normal, "physics")
	l.physics_thread.data = l
	l.graphics_thread = thread.create(_loop_graphics_thread, .Normal, "graphics")
	l.graphics_thread.data = l
	thread.start(l.physics_thread)
	thread.start(l.graphics_thread)
	return l
}

// loop_request_exit asks both threads to finish their current iteration.
loop_request_exit :: proc(l: ^Loop) {
	if l == nil {return}
	sync.atomic_store(&l.exit, true)
}

loop_should_exit :: proc(l: ^Loop) -> bool {
	return l != nil && sync.atomic_load(&l.exit)
}

// Last measured frame duration in milliseconds.
loop_frame_time :: proc(l: ^Loop) -> f32 {
	if l == nil {return 0}
	return sync.atomic_load(&l.frame_time)
}

// Mean physics step duration in microseconds over the last batch of updates.
loop_tick_time :: proc(l: ^Loop) -> f32 {
	if l == nil {return 0}
	return sync.atomic_load(&l.tick_time)
}

// loop_stop requests exit, joins both threads and releases the loop.
loop_stop :: proc(l: ^Loop) {
	if l == nil {return}
	loop_request_exit(l)
	if l.physics_thread != nil {
		thread.join(l.physics_thread)
		thread.destroy(l.physics_thread)
	}
	if l.graphics_thread != nil {
		thread.join(l.graphics_thread)
		thread.destroy(l.graphics_thread)
	}
	free(l)
}

@(private)
_loop_physics_thread :: proc(th: ^thread.Thread) {
	l := cast(^Loop)th.data
	if l == nil {return}
	context.logger = l.desc.logger

	profile_thread_ensure()
	profile_thread_name("physics")
	defer profile_thread_destroy()

	accumulator: f32 = 0
	last_tick := time.tick_now()
	for !sync.atomic_load(&l.exit) {
		now := time.tick_now()
		elapsed := f32(time.duration_seconds(time.tick_diff(last_tick, now)))
		last_tick = now
		if elapsed > MAX_FRAME_SEC {elapsed = MAX_FRAME_SEC}

		// A hot-reloaded config is applied on the only thread that writes the
		// tuning state, then the app gets a chance to re-read it.
		if config_apply_pending() && l.desc.config_applied != nil {
			l.desc.config_applied(l.desc.user)
		}

		config := config_get()
		sim_dt := FIXED_STEP_SEC * config.time
		accumulator += elapsed
		if accumulator > FIXED_STEP_SEC * MAX_ACCUMULATED_STEPS {
			accumulator = FIXED_STEP_SEC * MAX_ACCUMULATED_STEPS
		}

		tick_start := time.tick_now()
		updates := 0
		if accumulator >= FIXED_STEP_SEC {
			profile_scope("physics.step")
			for accumulator >= FIXED_STEP_SEC {
				if l.desc.physics_step != nil && !l.desc.physics_step(l.desc.user, sim_dt) {
					sync.atomic_store(&l.exit, true)
					break
				}
				accumulator -= FIXED_STEP_SEC
				updates += 1
			}
		}
		if updates > 0 {
			total_us := time.duration_microseconds(time.tick_diff(tick_start, time.tick_now()))
			sync.atomic_store(&l.tick_time, f32(total_us) / f32(updates))
			profile_mark("physics.updates", "updates=%d", {updates})
		}

		remaining := FIXED_STEP_SEC - accumulator
		if remaining > 0.0001 {
			time.sleep(time.Duration(remaining * 1e6) * time.Microsecond)
		}
	}
}

@(private)
_loop_graphics_thread :: proc(th: ^thread.Thread) {
	l := cast(^Loop)th.data
	if l == nil {return}
	context.logger = l.desc.logger

	profile_thread_ensure()
	profile_thread_name("graphics")
	defer profile_thread_destroy()

	last_frame := time.tick_now()
	for !sync.atomic_load(&l.exit) {
		now := time.tick_now()
		delta := f32(time.duration_seconds(time.tick_diff(last_frame, now)))
		last_frame = now

		frame_start := time.tick_now()
		{
			profile_scope_args("graphics.frame", "dt=%.4f", {delta})
			if l.desc.graphics_frame != nil && !l.desc.graphics_frame(l.desc.user, delta) {
				sync.atomic_store(&l.exit, true)
				break
			}
		}
		sync.atomic_store(
			&l.frame_time,
			f32(time.duration_milliseconds(time.tick_diff(frame_start, time.tick_now()))),
		)
	}
}
