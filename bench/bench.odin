package main

import physic "../Engine/physic"
import foundation "../foundation"
import "core:fmt"
import "core:math/rand"
import "core:time"

run :: proc(n, ticks: int, interval, theta: f32, workers: int) {
	objects := make([dynamic]physic.PhysicObject, 0, n)
	rand.reset_u64(42)
	for i in 0 ..< n {
		append(&objects, physic.physic_object_make(
			{rand.float32_range(-1e10, 1e10), rand.float32_range(-1e10, 1e10), rand.float32_range(-1e10, 1e10)},
			{rand.float32_range(-1e4, 1e4), rand.float32_range(-1e4, 1e4), rand.float32_range(-1e4, 1e4)},
			6e27,
			12371e3,
		))
	}
	config := foundation.Config{
		solver_algorithm      = .OCTREE,
		collision_algorithm   = .OCTREE,
		theta                 = theta,
		tree_rebuild_interval = interval,
	}
	system := physic.physic_system_create(&objects, &config)
	defer physic.physic_system_destroy(&system)
	defer delete(objects)

	foundation.parallel_destroy()
	foundation.parallel_init(workers)
	defer foundation.parallel_destroy()

	t0 := time.tick_now()
	for t in 0 ..< ticks {
		physic.physic_system_update(&system, 450.0, &objects)
	}
	t1 := time.tick_now()
	dt := time.duration_milliseconds(time.tick_diff(t0, t1))
	fmt.printf("n=%d ticks=%d interval=%8.0f theta=%.1f workers=%2d: total=%8.2f ms  avg=%6.2f ms/tick\n", n, ticks, interval, theta, workers, dt, dt / f64(ticks))
}

main :: proc() {
	run(100000, 10, 100000.0, 0.5, 1)
	run(100000, 10, 100000.0, 0.5, 8)
	run(100000, 10, 100000.0, 0.8, 1)
	run(100000, 10, 100000.0, 0.8, 8)
	run(100000, 10, 1.0, 0.5, 8)
}
