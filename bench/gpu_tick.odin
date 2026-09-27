// Full-tick stage (M3 of docs/gpu_physics.md).
//
// Runs the whole PHYSICS phase (begin, gravity, collision, integrate, select,
// publish, adapt) through the scheduler on two identical worlds — one with the
// CPU solver, one with the GPU backend — and reports ms per tick. The
// solve-level stages price the GPU work in isolation; this one prices the whole
// tick around it, which is what a backend swap actually changes. The brute-force
// mode is where the deferred finish pays off: the serial collision pass runs
// while the GPU solve is still in flight.
//
// The tree rebuilds every tick (interval 0), matching the shipped app config:
// the `time` multiplier makes the rebuild accumulator exceed any interval in a
// single step.
//
// Usage:
//   odin run bench -o:speed -- gpu-tick [n] [depth] [theta] [ticks] [samples] [octree|brute]
package main

import ecs "../Engine/ecs"
import foundation "../foundation"
import graphic "../Engine/Graphic"
import physic "../Engine/physic"
import "core:fmt"
import "core:log"
import "core:os"
import "core:slice"
import "core:strings"
import "core:time"

_gpu_tick_world :: proc(
	n, depth: int,
	theta: f32,
	algorithm: foundation.Algorithm,
	interval: f32,
	solver: physic.Gravity_Solver,
) -> (
	w: ^ecs.World,
	s: ^ecs.Scheduler,
) {
	w = ecs.world_create()
	ecs.world_reserve(w, n)
	spawn_bodies(w, n)
	physic.physic_init(
		w,
		foundation.Config {
			algorithm = algorithm,
			theta = theta,
			tree_rebuild_interval = interval,
			max_depth = depth,
			min_half_size = MIN_HALF_SIZE,
			worker_threads = REF_WORKERS,
			auto_adjust = false,
		},
	)
	if solver.submit != nil {physic.physic_set_gravity_solver(w, solver)}
	ecs.world_freeze(w)
	s = ecs.scheduler_create(foundation.default_job_system())
	physic.physic_register_systems(s)
	_ = ecs.scheduler_finalize(s)
	return
}

// Median milliseconds of one scheduler-run PHYSICS phase.
_gpu_tick_measure :: proc(w: ^ecs.World, s: ^ecs.Scheduler, ticks: int) -> f64 {
	dt := f32(SIM_DT)
	_ = ecs.scheduler_run(s, .PHYSICS, w, dt)
	ecs.world_flush(w)

	start := time.tick_now()
	for _ in 0 ..< ticks {
		_ = ecs.scheduler_run(s, .PHYSICS, w, dt)
		ecs.world_flush(w)
	}
	return time.duration_milliseconds(time.tick_diff(start, time.tick_now())) / f64(ticks)
}

gpu_tick_run :: proc(args: []string) {
	context.logger = log.create_console_logger(.Info)

	n := 100000
	depth := 16
	theta := f32(0.8)
	ticks := 3
	samples := 2
	algorithm := foundation.Algorithm.OCTREE
	if len(args) > 0 {n = _arg_int(args[0], n)}
	if len(args) > 1 {depth = _arg_int(args[1], depth)}
	if len(args) > 2 {theta = _arg_f32(args[2], theta)}
	if len(args) > 3 {ticks = _arg_int(args[3], ticks)}
	if len(args) > 4 {samples = _arg_int(args[4], samples)}
	if len(args) > 5 {
		if strings.equal_fold(args[5], "brute") {
			algorithm = .BRUTE_FORCE
		} else if !strings.equal_fold(args[5], "octree") {
			fmt.eprintfln("gpu-tick: mode must be octree or brute")
			return
		}
	}
	if n <= 0 || ticks <= 0 || samples <= 0 {
		fmt.eprintfln("gpu-tick: n, ticks and samples must be positive")
		return
	}

	solver, created := graphic.gpu_gravity_init_headless(algorithm, n)
	if !created {
		fmt.eprintfln("gpu-tick: cannot create a headless GPU solver")
		os.exit(1)
	}
	defer graphic.gpu_gravity_destroy(solver)
	info := graphic.gpu_gravity_info(solver)

	ensure_workers(REF_WORKERS)
	// The tree rebuilds every tick for the octree sweep; the brute-force path
	// ignores the interval.
	interval := f32(0)
	if algorithm == .OCTREE {interval = 0}
	cpu_world, cpu_scheduler := _gpu_tick_world(n, depth, theta, algorithm, interval, {})
	defer ecs.world_destroy(cpu_world)
	defer ecs.scheduler_destroy(cpu_scheduler)
	gpu_world, gpu_scheduler := _gpu_tick_world(
		n,
		depth,
		theta,
		algorithm,
		interval,
		graphic.gpu_gravity_backend(solver),
	)
	defer ecs.world_destroy(gpu_world)
	defer ecs.scheduler_destroy(gpu_scheduler)

	// Accuracy: one tick from identical initial conditions. The metric is
	// relative to each body's position, so it stays meaningful for a scene this
	// spread out.
	dt := f32(SIM_DT)
	_ = ecs.scheduler_run(cpu_scheduler, .PHYSICS, cpu_world, dt)
	ecs.world_flush(cpu_world)
	_ = ecs.scheduler_run(gpu_scheduler, .PHYSICS, gpu_world, dt)
	ecs.world_flush(gpu_world)
	accuracy := compare_positions(cpu_world, gpu_world)

	cpu_ms := _gpu_tick_measure_median(cpu_world, cpu_scheduler, ticks, samples)
	gpu_ms := _gpu_tick_measure_median(
		gpu_world,
		gpu_scheduler,
		ticks,
		samples,
		solver,
		algorithm,
		n,
	)

	fmt.printfln(
		"=== gpu tick: mode=%v n=%d depth=%d theta=%.2f ticks=%d samples=%d ===",
		algorithm,
		n,
		depth,
		theta,
		ticks,
		samples,
	)
	fmt.printfln(
		"  device=%s compute_queue=%s",
		info.device_name,
		info.dedicated_queue ? "dedicated" : "shared family",
	)
	fmt.printfln("  cpu: %8.3f ms/tick", cpu_ms)
	fmt.printfln("  gpu: %8.3f ms/tick  speedup=%.2fx", gpu_ms, cpu_ms / gpu_ms)
	fmt.printfln("  positions vs cpu after one tick: mean=%.3e max=%.3e", accuracy.mean, accuracy.max)
	if accuracy.max > 1e-4 {
		fmt.eprintfln("gpu-tick: position mismatch too large")
		os.exit(1)
	}
}

@(private)
_gpu_tick_measure_median :: proc(
	w: ^ecs.World,
	s: ^ecs.Scheduler,
	ticks, samples: int,
	solver: ^graphic.Gpu_Gravity = nil,
	mode: foundation.Algorithm = .OCTREE,
	warm_n: int = 0,
) -> f64 {
	times := make([dynamic]f64, 0, samples)
	defer delete(times)
	for _ in 0 ..< samples {
		if solver != nil {_gpu_warm_clocks(solver, mode, warm_n)}
		append(&times, _gpu_tick_measure(w, s, ticks))
	}
	slice.sort(times[:])
	return times[len(times) / 2]
}

@(private)
compare_positions :: proc(a, b: ^ecs.World) -> CompareResult {
	view_a := physic.body_view(a)
	view_b := physic.body_view(b)
	count := min(len(view_a.bodies), len(view_b.bodies))
	pa := make([]physic.Vec3, count)
	defer delete(pa)
	pb := make([]physic.Vec3, count)
	defer delete(pb)
	for i in 0 ..< count {
		pa[i] = physic.Vec3(view_a.position[view_a.bodies[i]])
		pb[i] = physic.Vec3(view_b.position[view_b.bodies[i]])
	}
	return compare_accel(pa, pb)
}
