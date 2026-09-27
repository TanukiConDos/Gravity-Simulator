// GPU Barnes-Hut stage (M2/M3 of docs/gpu_physics.md).
//
// Builds the deterministic bench bodies with the octree solver, solves them with
// the CPU and the GPU backend, compares the velocity updates and contact sets,
// and reports ms per solve in two scenarios: tree cached (large rebuild
// interval) and rebuilding every tick (which includes the CPU build and the GPU
// structure upload). The CPU solve is parallel over the worker pool, unlike the
// serial brute-force stage.
//
// Usage:
//   odin run bench -o:speed -- gpu-tree [n] [depth] [theta] [ticks] [samples]
package main

import ecs "../Engine/ecs"
import foundation "../foundation"
import graphic "../Engine/Graphic"
import physic "../Engine/physic"
import "core:fmt"
import "core:log"
import "core:math"
import "core:os"
import "core:slice"
import "core:time"

_gpu_tree_world :: proc(
	n, depth: int,
	theta, interval: f32,
	solver: physic.Gravity_Solver,
) -> ^ecs.World {
	w := ecs.world_create()
	ecs.world_reserve(w, n)
	spawn_bodies(w, n)
	physic.physic_init(
		w,
		foundation.Config {
			algorithm = .OCTREE,
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
	return w
}

// One solve the way a tick runs it: begin, gravity, finish. For the tree backend
// the finish is what reads back the velocities and the contacts; the app's
// collision pass triggers it the same way.
_gpu_tree_step :: proc(w: ^ecs.World, dt: f32) {
	physic.physic_system_begin(w, dt)
	physic.physic_system_gravity(w, dt)
	physic.physic_finish_gravity(w)
}


// Median milliseconds of one gravity solve (begin + gravity + finish), matching
// the brute-force stage: begin contains the rebuild when the interval forces
// one.
_gpu_tree_measure :: proc(w: ^ecs.World, ticks: int) -> f64 {
	dt := f32(SIM_DT)
	_gpu_tree_step(w, dt)

	start := time.tick_now()
	for _ in 0 ..< ticks {_gpu_tree_step(w, dt)}
	return time.duration_milliseconds(time.tick_diff(start, time.tick_now())) / f64(ticks)
}

_gpu_tree_contact_less :: proc(x, y: physic.Contact) -> bool {
	if x.a != y.a {return x.a < y.a}
	return x.b < y.b
}

// Median of `samples` independent measurements of one solve. When `solver` is
// set, every sample is preceded by a clock warm-up (GPU samples only; see
// `_gpu_warm_clocks`).
_gpu_tree_measure_median :: proc(
	w: ^ecs.World,
	ticks, samples: int,
	solver: ^graphic.Gpu_Gravity = nil,
	warm_n: int = 0,
) -> f64 {
	times := make([dynamic]f64, 0, samples)
	defer delete(times)
	for _ in 0 ..< samples {
		if solver != nil {_gpu_warm_clocks(solver, .OCTREE, warm_n)}
		append(&times, _gpu_tree_measure(w, ticks))
	}
	slice.sort(times[:])
	return times[len(times) / 2]
}

// Both solve outputs live in Velocity when dt = 1, so the same comparison as the
// brute-force stage applies.
_gpu_tree_compare :: proc(approx_world, exact_world: ^ecs.World) -> CompareResult {
	approx_view := physic.body_view(approx_world)
	exact_view := physic.body_view(exact_world)
	count := min(len(approx_view.bodies), len(exact_view.bodies))
	approx := make([]physic.Vec3, count)
	defer delete(approx)
	exact := make([]physic.Vec3, count)
	defer delete(exact)
	for i in 0 ..< count {
		approx[i] = physic.Vec3(approx_view.velocity[approx_view.bodies[i]])
		exact[i] = physic.Vec3(exact_view.velocity[exact_view.bodies[i]])
	}
	return compare_accel(approx, exact)
}

gpu_tree_run :: proc(args: []string) {
	context.logger = log.create_console_logger(.Info)

	n := 100000
	depth := 16
	theta := f32(0.8)
	ticks := 2
	samples := 2
	if len(args) > 0 {n = _arg_int(args[0], n)}
	if len(args) > 1 {depth = _arg_int(args[1], depth)}
	if len(args) > 2 {theta = _arg_f32(args[2], theta)}
	if len(args) > 3 {ticks = _arg_int(args[3], ticks)}
	if len(args) > 4 {samples = _arg_int(args[4], samples)}
	if n <= 0 || ticks <= 0 || samples <= 0 {
		fmt.eprintfln("gpu-tree: n, ticks and samples must be positive")
		return
	}

	solver, created := graphic.gpu_gravity_init_headless(.OCTREE, n)
	if !created {
		fmt.eprintfln("gpu-tree: cannot create a headless GPU solver")
		os.exit(1)
	}
	defer graphic.gpu_gravity_destroy(solver)
	info := graphic.gpu_gravity_info(solver)

	ensure_workers(REF_WORKERS)
	cpu_world := _gpu_tree_world(n, depth, theta, 1000, {})
	defer ecs.world_destroy(cpu_world)
	gpu_world := _gpu_tree_world(n, depth, theta, 1000, graphic.gpu_gravity_backend(solver))
	defer ecs.world_destroy(gpu_world)

	// Accuracy: one solve with dt = 1 from rest, so the velocity update is the
	// acceleration and the contacts come from the same traversal.
	_gpu_zero_velocities(cpu_world)
	_gpu_zero_velocities(gpu_world)
	_gpu_tree_step(cpu_world, 1.0)
	_gpu_tree_step(gpu_world, 1.0)
	accuracy := _gpu_tree_compare(gpu_world, cpu_world)

	cpu_contacts := physic.physic_state(cpu_world).collision_contacts
	gpu_contacts := physic.physic_state(gpu_world).collision_contacts
	contacts_match := len(cpu_contacts) == len(gpu_contacts)
	if contacts_match {
		slice.sort_by(cpu_contacts[:], _gpu_tree_contact_less)
		slice.sort_by(gpu_contacts[:], _gpu_tree_contact_less)
		for i in 0 ..< len(cpu_contacts) {
			if cpu_contacts[i] != gpu_contacts[i] {
				contacts_match = false
				break
			}
		}
	}

	measure_median :: proc(w: ^ecs.World, ticks, samples: int) -> f64 {
		times := make([dynamic]f64, 0, samples)
		defer delete(times)
		for _ in 0 ..< samples {append(&times, _gpu_tree_measure(w, ticks))}
		slice.sort(times[:])
		return times[len(times) / 2]
	}

	cached_cpu := _gpu_tree_measure_median(cpu_world, ticks, samples)
	cached_gpu := _gpu_tree_measure_median(gpu_world, ticks, samples, solver, n)

	// Worst case: physic rebuilds the tree every tick, so the GPU path also
	// re-uploads the structure before each solve.
	physic.physic_state(cpu_world).rebuild_interval = 0
	physic.physic_state(gpu_world).rebuild_interval = 0
	rebuild_cpu := _gpu_tree_measure_median(cpu_world, ticks, samples)
	rebuild_gpu := _gpu_tree_measure_median(gpu_world, ticks, samples, solver, n)

	cpu_info := physic.physic_state(cpu_world).tree_info
	gpu_info := physic.physic_state(gpu_world).tree_info
	fmt.printfln(
		"=== gpu tree: n=%d depth=%d theta=%.2f ticks=%d samples=%d ===",
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
	fmt.printfln(
		"  tree: cpu nodes=%d max_leaf_depth=%d | gpu nodes=%d max_leaf_depth=%d (CPU-built for the CPU world, GPU-built for the GPU world)",
		cpu_info.node_count,
		cpu_info.max_leaf_depth,
		gpu_info.node_count,
		gpu_info.max_leaf_depth,
	)
	fmt.printfln(
		"  tree cached:       cpu=%8.3f ms/solve  gpu=%8.3f ms/solve  speedup=%.1fx",
		cached_cpu,
		cached_gpu,
		cached_cpu / cached_gpu,
	)
	fmt.printfln(
		"  rebuild per tick:  cpu=%8.3f ms/solve  gpu=%8.3f ms/solve  speedup=%.1fx",
		rebuild_cpu,
		rebuild_gpu,
		rebuild_cpu / rebuild_gpu,
	)
	fmt.printfln(
		"  accuracy vs cpu: mean=%.3e max=%.3e max_abs=%.3e  contacts: cpu=%d gpu=%d match=%v",
		accuracy.mean,
		accuracy.max,
		accuracy.max_abs,
		len(cpu_contacts),
		len(gpu_contacts),
		contacts_match,
	)
	// The mean is the meaningful gate; the max can be dominated by a body whose
	// acceleration nearly cancels or by a tight cluster inside one large node,
	// where the GPU's f32 center of mass (vs the CPU's f64) is the limit.
	if accuracy.mean > 1e-4 || accuracy.max > 5e-2 || !contacts_match {
		fmt.eprintfln("gpu-tree: mismatch against the CPU solver")
		os.exit(1)
	}
}
