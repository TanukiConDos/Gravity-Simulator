// GPU brute-force gravity stage (M1/M3 of docs/gpu_physics.md).
//
// Solves the same deterministic bodies with the serial CPU brute-force loop and
// the GPU backend, compares the velocity updates and reports ms per solve. The
// GPU number includes everything a backend swap costs per tick: packing, upload,
// dispatch, readback and the scatter into the Velocity pool; the CPU number
// includes its inline `vel += acc * dt`.
//
// Usage:
//   odin run bench -o:speed -- gpu-force [n] [ticks] [samples]
package main

import ecs "../Engine/ecs"
import foundation "../foundation"
import graphic "../Engine/Graphic"
import physic "../Engine/physic"
import "core:fmt"
import "core:log"
import "core:os"
import "core:slice"
import "core:time"

// A world with the bench's deterministic bodies and the requested gravity
// backend. `physic_init` needs any config; the brute-force path ignores the
// octree knobs.
_gpu_force_world :: proc(n: int, solver: physic.Gravity_Solver) -> ^ecs.World {
	w := ecs.world_create()
	ecs.world_reserve(w, n)
	spawn_bodies(w, n)
	physic.physic_init(w, foundation.Config{algorithm = .BRUTE_FORCE, worker_threads = 1})
	if solver.submit != nil {physic.physic_set_gravity_solver(w, solver)}
	ecs.world_freeze(w)
	return w
}

// One solve the way a tick runs it: begin, gravity, finish. `finish` is a no-op
// for the CPU solver (it integrates velocities inline) and the wait/readback for
// a hooked backend.
_gpu_force_step :: proc(w: ^ecs.World, dt: f32) {
	physic.physic_system_begin(w, dt)
	physic.physic_system_gravity(w, dt)
	physic.physic_finish_gravity(w)
}

// Median milliseconds of one solve. begin is included because the app pays it
// every tick; it is O(N) next to the O(N^2) solve.
_gpu_force_measure :: proc(w: ^ecs.World, ticks: int) -> f64 {
	dt := f32(SIM_DT)
	// One discarded solve lets buffers and caches settle.
	_gpu_force_step(w, dt)

	start := time.tick_now()
	for _ in 0 ..< ticks {_gpu_force_step(w, dt)}
	return time.duration_milliseconds(time.tick_diff(start, time.tick_now())) / f64(ticks)
}

// Both worlds are spawned from seed 42, so body i is the same body in each and
// the solves leave their result (the gravity update) in `Velocity`, index by
// index.
_gpu_force_compare :: proc(approx_world, exact_world: ^ecs.World) -> CompareResult {
	approx_view := physic.body_view(approx_world)
	exact_view := physic.body_view(exact_world)
	count := min(len(approx_view.bodies), len(exact_view.bodies))

	approx := make([]physic.Vec3, count)
	defer delete(approx)
	exact := make([]physic.Vec3, count)
	defer delete(exact)
	for i in 0 ..< count {
		entity := approx_view.bodies[i]
		approx[i] = physic.Vec3(approx_view.velocity[entity])
		exact[i] = physic.Vec3(exact_view.velocity[entity])
	}
	return compare_accel(approx, exact)
}

// Zeroes the velocities so the next solve's output is exactly `acc * dt` and the
// accuracy metric is not diluted by the spawn velocities.
_gpu_zero_velocities :: proc(w: ^ecs.World) {
	view := physic.body_view(w)
	for entity in view.bodies {view.velocity[entity] = 0}
}

// Spins the solver's own pipeline on a throwaway world for ~0.4 s so the timed
// runs sample boost clocks. Without it a short solve loop catches the idle SM
// clock (≈210 MHz vs ≈2.7 GHz on the dev machine) and reports numbers that are
// several times too slow and far noisier; the app never sees that state because
// the renderer keeps the device busy. The GPU samples in each stage run before
// the (much longer) CPU samples, each preceded by its own warm-up, because the
// CPU measurement is long enough for the device to clock back down.
_gpu_warm_clocks :: proc(solver: ^graphic.Gpu_Gravity, mode: foundation.Algorithm, n: int) {
	w := ecs.world_create()
	defer ecs.world_destroy(w)
	ecs.world_reserve(w, n)
	spawn_bodies(w, n)
	physic.physic_init(
		w,
		foundation.Config {
			algorithm = mode,
			worker_threads = 1,
			tree_rebuild_interval = 1000,
			max_depth = 16,
			min_half_size = MIN_HALF_SIZE,
		},
	)
	physic.physic_set_gravity_solver(w, graphic.gpu_gravity_backend(solver))
	ecs.world_freeze(w)

	dt := f32(SIM_DT)
	start := time.tick_now()
	for time.tick_since(start) < 400 * time.Millisecond {
		physic.physic_system_begin(w, dt)
		physic.physic_system_gravity(w, dt)
		physic.physic_finish_gravity(w)
	}
}

gpu_force_run :: proc(args: []string) {
	// The engine reports Vulkan failures through the logger; the bench itself
	// only prints via fmt.
	context.logger = log.create_console_logger(.Info)

	n := 4096
	ticks := 3
	samples := 3
	if len(args) > 0 {n = _arg_int(args[0], n)}
	if len(args) > 1 {ticks = _arg_int(args[1], ticks)}
	if len(args) > 2 {samples = _arg_int(args[2], samples)}
	if n <= 0 || ticks <= 0 || samples <= 0 {
		fmt.eprintfln("gpu-force: n, ticks and samples must be positive")
		return
	}

	solver, created := graphic.gpu_gravity_init_headless(.BRUTE_FORCE, n)
	if !created {
		fmt.eprintfln("gpu-force: cannot create a headless GPU solver")
		os.exit(1)
	}
	defer graphic.gpu_gravity_destroy(solver)
	info := graphic.gpu_gravity_info(solver)

	ensure_workers(1)
	cpu_world := _gpu_force_world(n, {})
	defer ecs.world_destroy(cpu_world)
	gpu_world := _gpu_force_world(n, graphic.gpu_gravity_backend(solver))
	defer ecs.world_destroy(gpu_world)

	// Accuracy: one solve from rest on each backend, so the compared velocities
	// are exactly the gravity update.
	_gpu_zero_velocities(cpu_world)
	_gpu_zero_velocities(gpu_world)
	_gpu_force_step(cpu_world, f32(SIM_DT))
	_gpu_force_step(gpu_world, f32(SIM_DT))
	accuracy := _gpu_force_compare(gpu_world, cpu_world)

	cpu_times := make([dynamic]f64, 0, samples)
	defer delete(cpu_times)
	gpu_times := make([dynamic]f64, 0, samples)
	defer delete(gpu_times)
	// GPU samples first, each preceded by a clock warm-up; the CPU solve is
	// long enough at these sizes to let the device clock back down.
	for _ in 0 ..< samples {
		_gpu_warm_clocks(solver, .BRUTE_FORCE, n)
		append(&gpu_times, _gpu_force_measure(gpu_world, ticks))
	}
	for _ in 0 ..< samples {append(&cpu_times, _gpu_force_measure(cpu_world, ticks))}
	slice.sort(cpu_times[:])
	slice.sort(gpu_times[:])
	cpu_ms := cpu_times[len(cpu_times) / 2]
	gpu_ms := gpu_times[len(gpu_times) / 2]

	fmt.printfln("=== gpu force: n=%d ticks=%d samples=%d ===", n, ticks, samples)
	fmt.printfln(
		"  device=%s compute_queue=%s",
		info.device_name,
		info.dedicated_queue ? "dedicated" : "shared family",
	)
	fmt.printfln("  cpu: %.3f ms/solve (serial brute force + velocity update)", cpu_ms)
	fmt.printfln("  gpu: %.3f ms/solve (pack, upload, dispatch, readback)", gpu_ms)
	fmt.printfln("  speedup: %.1fx", cpu_ms / gpu_ms)
	fmt.printfln(
		"  accuracy vs cpu: mean=%.3e max=%.3e max_abs=%.3e",
		accuracy.mean,
		accuracy.max,
		accuracy.max_abs,
	)
	if accuracy.max > 1e-2 {
		fmt.eprintfln("gpu-force: velocity mismatch too large")
		os.exit(1)
	}
}
