package main

import physic "../Engine/physic"
import ecs "../Engine/ecs"
import foundation "../foundation"
import "core:fmt"
import "core:math/rand"
import "core:time"

make_world :: proc(n: int, config: foundation.Config) -> (^ecs.World, ^ecs.Scheduler) {
	w := ecs.world_create()
	rand.reset_u64(42)
	for i in 0 ..< n {
		physic.body_spawn(
			w,
			{
				rand.float32_range(-1e10, 1e10),
				rand.float32_range(-1e10, 1e10),
				rand.float32_range(-1e10, 1e10),
			},
			{
				rand.float32_range(-1e4, 1e4),
				rand.float32_range(-1e4, 1e4),
				rand.float32_range(-1e4, 1e4),
			},
			6e27,
			12371e3,
		)
	}
	physic.physic_init(w, config)
	s := ecs.scheduler_create()
	physic.physic_register_systems(s)
	return w, s
}

run :: proc(n, ticks: int, interval, theta: f32, workers: int, solver: foundation.Algorithm) {
	config := foundation.Config {
		solver_algorithm      = solver,
		collision_algorithm   = .OCTREE,
		theta                 = theta,
		tree_rebuild_interval = interval,
	}
	w, s := make_world(n, config)
	defer ecs.scheduler_destroy(s)
	defer ecs.world_destroy(w)

	foundation.parallel_destroy()
	foundation.parallel_init(workers)
	defer foundation.parallel_destroy()

	t0 := time.tick_now()
	for t in 0 ..< ticks {
		ecs.scheduler_run(s, .PHYSICS, w, 450.0)
	}
	t1 := time.tick_now()
	dt := time.duration_milliseconds(time.tick_diff(t0, t1))
	fmt.printf(
		"n=%6d ticks=%d solver=%-11s interval=%8.0f theta=%.1f workers=%2d: total=%8.2f ms  avg=%6.2f ms/tick\n",
		n,
		ticks,
		solver,
		interval,
		theta,
		workers,
		dt,
		dt / f64(ticks),
	)
}

run_auto :: proc(n, ticks: int, target_tickrate: f32, start_theta, start_interval: f32) {
	w := ecs.world_create()
	defer ecs.world_destroy(w)
	rand.reset_u64(42)
	for i in 0 ..< n {
		physic.body_spawn(
			w,
			{
				rand.float32_range(-1e10, 1e10),
				rand.float32_range(-1e10, 1e10),
				rand.float32_range(-1e10, 1e10),
			},
			{
				rand.float32_range(-1e2, 1e2),
				rand.float32_range(-1e2, 1e2),
				rand.float32_range(-1e2, 1e2),
			},
			1e3,
			1e3,
		)
	}
	config := foundation.Config {
		solver_algorithm      = .OCTREE,
		collision_algorithm   = .OCTREE,
		theta                 = start_theta,
		tree_rebuild_interval = start_interval,
		auto_adjust           = true,
		target_tickrate       = target_tickrate,
		theta_min             = 0.2,
		theta_max             = 1.2,
	}
	physic.physic_init(w, config)
	s := ecs.scheduler_create()
	defer ecs.scheduler_destroy(s)
	physic.physic_register_systems(s)

	foundation.parallel_destroy()
	foundation.parallel_init(8)
	defer foundation.parallel_destroy()

	measure_start := max(ticks - 20, 0)
	t0 := time.tick_now()
	for t in 0 ..< ticks {
		if t == measure_start {
			t0 = time.tick_now()
		}
		ecs.scheduler_run(s, .PHYSICS, w, 450.0)
	}
	t1 := time.tick_now()
	state := physic.physic_state(w)
	dt := time.duration_milliseconds(time.tick_diff(t0, t1))
	measured := f64(max(ticks - measure_start, 1))
	fmt.printf(
		"AUTO n=%6d target=%4.0fHz start(theta=%.2f,int=%.0f): converged theta=%.2f rebuilds=%3d | achieved avg=%6.2f ms/tick (%4.1f Hz)\n",
		n,
		target_tickrate,
		start_theta,
		start_interval,
		state.theta,
		state.rebuild_count,
		dt / measured,
		f64(1000.0) / (dt / measured),
	)
}

main :: proc() {
	run(100000, 10, 100000.0, 0.5, 8, .OCTREE)
	run(100000, 10, 100000.0, 0.8, 8, .OCTREE)
	run(100000, 10, 1.0, 0.5, 8, .OCTREE)
	run(10000, 10, 100000.0, 0.5, 8, .OCTREE)
	run(10000, 5, 100000.0, 0.0, 1, .BRUTE_FORCE)

	run_auto(100000, 160, 60.0, 0.5, 100000.0)
	run_auto(10000, 200, 60.0, 0.5, 100000.0)
	run_auto(100000, 160, 16.0, 0.5, 100000.0)
}
