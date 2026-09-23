// Octree parameter sweep.
//
// Times the PHYSICS phase across a grid of (max_depth, theta,
// tree_rebuild_interval, worker_threads) and, for each depth/theta pair,
// reports the gravity accuracy against an exact O(N) reference.
//
// Usage:
//   odin run bench -o:speed -disable-assert -microarch:native -- [1k|10k|100k|all]
//   odin run bench -define:PROFILE=true ... -- profile [n] [depth] [theta] [interval] [workers]
//   odin run bench -o:speed ... -- contacts [n] [depth] [theta] [warmup] [scale]
//   odin run bench -o:speed ... -- interactions [n] [depth] [theta] [warmup] [workers]
//
// Results are written to bench/results/sweep_<stage>.csv; `profile` writes a
// spall trace to bench/results/trace_*.spall (open it in the spall viewer).
package main

import ecs "../Engine/ecs"
import physic "../Engine/physic"
import foundation "../foundation"
import "core:fmt"
import "core:math"
import "core:math/rand"
import "core:os"
import "core:slice"
import "core:strconv"
import "core:time"

RESULTS_DIR :: "bench/results"

// Mirrors config.json: sim_dt = FIXED_STEP_SEC * time_multiplier.
SIM_TIME_MULT :: 1000.0
SIM_DT :: (1.0 / 60.0) * SIM_TIME_MULT
MIN_HALF_SIZE :: 1e-4
REF_WORKERS :: 16

Params :: struct {
	n:         int,
	max_depth: int,
	theta:     f32,
	interval:  f32,
	workers:   int,
}

RunStats :: struct {
	median_ms:         f64,
	min_ms:            f64,
	max_ms:            f64,
	rebuilds:          int,
	nodes:             int,
	median_leaf_depth: int,
	max_leaf_depth:    int,
	typical_half:      f32,
}

AccuracyKey :: struct {
	max_depth: int,
	theta:     f32,
}

CompareResult :: struct {
	mean: f64,
	max:  f64,
}

AccuracyEntry :: struct {
	key: AccuracyKey,
	res: CompareResult,
}

Stage :: struct {
	name:      string,
	n:         int,
	depths:    []int,
	thetas:    []f32,
	intervals: []f32,
	workers:   []int,
	warmup:    int,
	ticks:     int,
	repeats:   int,
	query:     int,
}

@(private)
_last_workers := -1

ensure_workers :: proc(workers: int) {
	if workers == _last_workers {return}
	foundation.parallel_destroy()
	foundation.parallel_init(workers)
	_last_workers = workers
}

spawn_bodies :: proc(w: ^ecs.World, n: int) {
	rand.reset_u64(42)
	for _ in 0 ..< n {
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
}

make_world :: proc(p: Params) -> (^ecs.World, ^ecs.Scheduler) {
	w := ecs.world_create()
	spawn_bodies(w, p.n)
	config := foundation.Config {
		algorithm             = .OCTREE,
		theta                 = p.theta,
		tree_rebuild_interval = p.interval,
		max_depth             = p.max_depth,
		min_half_size         = MIN_HALF_SIZE,
		worker_threads        = p.workers,
		auto_adjust           = false,
	}
	physic.physic_init(w, config)
	s := ecs.scheduler_create()
	physic.physic_register_systems(s)
	return w, s
}

// Runs `repeats` independent worlds, each with `warmup` discarded ticks
// followed by `ticks` timed ticks, and reports the median per-tick time.
measure :: proc(p: Params, warmup, ticks, repeats: int) -> RunStats {
	times := make([dynamic]f64, 0, repeats)
	defer delete(times)

	stats := RunStats{}
	for _ in 0 ..< repeats {
		w, s := make_world(p)
		for _ in 0 ..< warmup {
			ecs.scheduler_run(s, .PHYSICS, w, SIM_DT)
		}
		t0 := time.tick_now()
		for _ in 0 ..< ticks {
			ecs.scheduler_run(s, .PHYSICS, w, SIM_DT)
		}
		t1 := time.tick_now()
		append(&times, time.duration_milliseconds(time.tick_diff(t0, t1)) / f64(ticks))

		state := physic.physic_state(w)
		if state.tree != nil {
			stats.rebuilds = state.rebuild_count
			stats.nodes = state.tree.node_count
			stats.median_leaf_depth = state.tree.median_leaf_depth
			stats.max_leaf_depth = state.tree.max_leaf_depth
			stats.typical_half = state.tree.typical_half
		}
		ecs.scheduler_destroy(s)
		ecs.world_destroy(w)
	}

	slice.sort(times[:])
	stats.min_ms = times[0]
	stats.max_ms = times[len(times) - 1]
	stats.median_ms = times[len(times) / 2]
	return stats
}

// A fixed random subset of entity indices used for the accuracy comparison.
make_query :: proc(bodies: []u32, k: int) -> []u32 {
	count := min(k, len(bodies))
	query := make([]u32, count)
	copy(query, bodies[:count])
	rand.reset_u64(20240922)
	for i := count - 1; i > 0; i -= 1 {
		j := int(rand.float32() * f32(i + 1))
		if j > i {j = i}
		if j < 0 {j = 0}
		query[i], query[j] = query[j], query[i]
	}
	return query
}

_ExactData :: struct {
	view:  physic.Bodies,
	query: []u32,
	out:   []physic.Vec3,
}

@(private)
_exact_worker :: proc(i: int, data: rawptr) {
	d := cast(^_ExactData)data
	qi := d.query[i]
	px := physic.Vec3(d.view.position[qi])
	ax, ay, az: f64
	for jj in 0 ..< len(d.view.bodies) {
		j := d.view.bodies[jj]
		if j == qi {continue}
		pj := physic.Vec3(d.view.position[j])
		dx := f64(pj.x) - f64(px.x)
		dy := f64(pj.y) - f64(px.y)
		dz := f64(pj.z) - f64(px.z)
		dist_sq := dx * dx + dy * dy + dz * dz
		if dist_sq < 1e-6 {dist_sq = 1e-6}
		inv := f64(physic.GRAVITY_CONSTANT) * f64(d.view.mass[j]) / (dist_sq * math.sqrt(dist_sq))
		ax += dx * inv
		ay += dy * inv
		az += dz * inv
	}
	d.out[i] = {f32(ax), f32(ay), f32(az)}
}

exact_accel :: proc(view: physic.Bodies, query: []u32, out: []physic.Vec3) {
	data := _ExactData {
		view  = view,
		query = query,
		out   = out,
	}
	foundation.parallel_for(_exact_worker, &data, len(query))
}

_OctreeQueryData :: struct {
	tree:  ^physic.OctTree,
	query: []u32,
}

@(private)
_octree_query_worker :: proc(i: int, data: rawptr) {
	d := cast(^_OctreeQueryData)data
	physic.octtree_calc_force(d.tree, d.query[i], 1.0)
}

// Per-body acceleration from one octree solve, measured as the velocity delta
// with dt = 1. The query bodies' velocities are zeroed first.
octree_accel :: proc(
	view: physic.Bodies,
	query: []u32,
	theta: f32,
	max_depth: int,
	out: []physic.Vec3,
) {
	tree := physic.octtree_create_ex(view, theta, max_depth, MIN_HALF_SIZE)
	defer physic.octtree_destroy(tree)
	for q in query {
		view.velocity[q] = physic.Velocity{0, 0, 0}
	}
	data := _OctreeQueryData {
		tree  = tree,
		query = query,
	}
	foundation.parallel_for(_octree_query_worker, &data, len(query))
	for q, i in query {
		out[i] = physic.Vec3(view.velocity[q])
	}
}

compare_accel :: proc(approx, exact: []physic.Vec3) -> CompareResult {
	sum: f64
	worst: f64
	for i in 0 ..< len(approx) {
		dx := f64(approx[i].x) - f64(exact[i].x)
		dy := f64(approx[i].y) - f64(exact[i].y)
		dz := f64(approx[i].z) - f64(exact[i].z)
		num := math.sqrt(dx * dx + dy * dy + dz * dz)
		den :=
			math.sqrt(
				f64(exact[i].x) * f64(exact[i].x) +
				f64(exact[i].y) * f64(exact[i].y) +
				f64(exact[i].z) * f64(exact[i].z),
			)
		if den < 1e-30 {den = 1e-30}
		err := num / den
		sum += err
		if err > worst {worst = err}
	}
	if len(approx) == 0 {return {}}
	return {mean = sum / f64(len(approx)), max = worst}
}

accuracy_for :: proc(
	cache: ^[dynamic]AccuracyEntry,
	view: physic.Bodies,
	query: []u32,
	exact, acc: []physic.Vec3,
	depth: int,
	theta: f32,
) -> CompareResult {
	for e in cache {
		if e.key.max_depth == depth && e.key.theta == theta {return e.res}
	}
	octree_accel(view, query, theta, depth, acc)
	res := compare_accel(acc, exact)
	append(cache, AccuracyEntry{key = {max_depth = depth, theta = theta}, res = res})
	return res
}

run_stage :: proc(st: Stage) {
	fmt.printfln(
		"=== stage %s: n=%d warmup=%d ticks=%d repeats=%d query=%d ===",
		st.name,
		st.n,
		st.warmup,
		st.ticks,
		st.repeats,
		st.query,
	)

	// Exact reference on the deterministic initial conditions.
	ensure_workers(REF_WORKERS)
	ref_w, ref_s := make_world(
		{ n = st.n, max_depth = 48, theta = 0.5, interval = 0, workers = REF_WORKERS },
	)
	view := physic.body_view(ref_w)
	query := make_query(view.bodies, st.query)
	defer delete(query)
	exact := make([]physic.Vec3, len(query))
	defer delete(exact)
	acc := make([]physic.Vec3, len(query))
	defer delete(acc)
	exact_accel(view, query, exact)

	_ = os.make_directory_all(RESULTS_DIR)
	path := fmt.aprintf("%s/sweep_%s.csv", RESULTS_DIR, st.name)
	defer delete(path)
	f, ferr := os.create(path)
	if ferr != nil {
		fmt.eprintfln("cannot create %s: %v", path, ferr)
		return
	}
	defer os.close(f)
	fmt.fprintf(
		f,
		"n,max_depth,theta,interval,workers,ms_per_tick,ms_min,ms_max,rebuilds,node_count,median_leaf_depth,max_leaf_depth,typical_half,mean_err,max_err\n",
	)

	cache := make([dynamic]AccuracyEntry, 0, 64)
	defer delete(cache)

	total := len(st.workers) * len(st.intervals) * len(st.depths) * len(st.thetas)
	done := 0
	for workers in st.workers {
		for interval in st.intervals {
			ensure_workers(workers)
			for depth in st.depths {
				for theta in st.thetas {
					stats := measure(
						{ n = st.n, max_depth = depth, theta = theta, interval = interval, workers = workers },
						st.warmup,
						st.ticks,
						st.repeats,
					)
					acc_res := accuracy_for(&cache, view, query, exact, acc, depth, theta)
					fmt.fprintf(
						f,
						"%d,%d,%.4f,%.1f,%d,%.4f,%.4f,%.4f,%d,%d,%d,%d,%g,%.6g,%.6g\n",
						st.n,
						depth,
						theta,
						interval,
						workers,
						stats.median_ms,
						stats.min_ms,
						stats.max_ms,
						stats.rebuilds,
						stats.nodes,
						stats.median_leaf_depth,
						stats.max_leaf_depth,
						stats.typical_half,
						acc_res.mean,
						acc_res.max,
					)
					done += 1
					fmt.printfln(
						"  [%3d/%3d] w=%2d int=%6.0f depth=%2d theta=%.2f -> %7.3f ms/tick  err=%.4f",
						done,
						total,
						workers,
						interval,
						depth,
						theta,
						stats.median_ms,
						acc_res.mean,
					)
				}
			}
		}
	}

	ecs.scheduler_destroy(ref_s)
	ecs.world_destroy(ref_w)
	fmt.printfln("wrote %s", path)
}

_arg_int :: proc(s: string, fallback: int) -> int {
	v, ok := strconv.parse_int(s, 10)
	if !ok {return fallback}
	return int(v)
}

_arg_f32 :: proc(s: string, fallback: f32) -> f32 {
	v, ok := strconv.parse_f32(s)
	if !ok {return fallback}
	return v
}

// Traces one config: warm up untraced, then record a handful of ticks. Build
// with `-define:PROFILE=true`; otherwise the trace is a no-op.
profile_run :: proc(args: []string) {
	when !foundation.PROFILE_ENABLED {
		fmt.eprintln("the profile stage requires building with -define:PROFILE=true")
		return
	}

	n := 100000
	depth := 16
	theta := f32(0.5)
	interval := f32(50)
	workers := 16
	if len(args) > 0 {n = _arg_int(args[0], n)}
	if len(args) > 1 {depth = _arg_int(args[1], depth)}
	if len(args) > 2 {theta = _arg_f32(args[2], theta)}
	if len(args) > 3 {interval = _arg_f32(args[3], interval)}
	if len(args) > 4 {workers = _arg_int(args[4], workers)}

	path := fmt.aprintf(
		"%s/trace_n%d_d%d_t%.2f_i%.0f_w%d.spall",
		RESULTS_DIR,
		n,
		depth,
		theta,
		interval,
		workers,
	)
	defer delete(path)

	_ = os.make_directory_all(RESULTS_DIR)

	ensure_workers(workers)
	w, s := make_world(
		{n = n, max_depth = depth, theta = theta, interval = interval, workers = workers},
	)
	for _ in 0 ..< 3 {ecs.scheduler_run(s, .PHYSICS, w, SIM_DT)}

	foundation.profile_start(path)
	foundation.profile_thread_name("main")
	for _ in 0 ..< 5 {ecs.scheduler_run(s, .PHYSICS, w, SIM_DT)}
	foundation.profile_stop()

	ecs.scheduler_destroy(s)
	ecs.world_destroy(w)
	fmt.printfln("wrote %s", path)
}

// Measures the collision broad phase in isolation: how many candidate bodies
// the per-body tree query returns versus how many actually overlap, and how
// long the queries take. Useful to judge whether the broad phase is worth it.
// `warmup` physics ticks are run first so the bodies can evolve (gravity
// clusters them), which is what the app actually sees over time. `scale`
// multiplies the per-body query radius, to probe how cost grows with the
// number of tree cells the sphere touches (1 = the real collision radius).
contacts_run :: proc(args: []string) {
	n := 100000
	depth := 16
	theta := f32(0.8)
	warmup := 0
	scale := f32(1)
	if len(args) > 0 {n = _arg_int(args[0], n)}
	if len(args) > 1 {depth = _arg_int(args[1], depth)}
	if len(args) > 2 {theta = _arg_f32(args[2], theta)}
	if len(args) > 3 {warmup = _arg_int(args[3], warmup)}
	if len(args) > 4 {scale = _arg_f32(args[4], scale)}

	w, s := make_world({n = n, max_depth = depth, theta = theta, interval = 0, workers = 1})
	defer ecs.scheduler_destroy(s)
	defer ecs.world_destroy(w)

	for _ in 0 ..< warmup {ecs.scheduler_run(s, .PHYSICS, w, SIM_DT)}

	view := physic.body_view(w)
	tree := physic.physic_state(w).tree
	owned := false
	if tree == nil {
		tree = physic.octtree_create_ex(view, theta, depth, MIN_HALF_SIZE)
		owned = true
	}
	defer if owned {physic.octtree_destroy(tree)}

	max_radius: f32
	for idx in view.bodies {
		r := f32(view.radius[idx])
		if r > max_radius {max_radius = r}
	}

	scratch := make([]u32, n)
	defer delete(scratch)

	candidates := 0
	contacts := 0
	start := time.tick_now()
	for a in view.bodies {
		count := 0
		physic.octtree_collect_nearby(
			tree,
			physic.Vec3(view.position[a]),
			(f32(view.radius[a]) + max_radius) * scale,
			scratch,
			&count,
		)
		candidates += count
		for j in 0 ..< count {
			b := scratch[j]
			if b <= a {continue}
			dir := physic.Vec3(view.position[b]) - physic.Vec3(view.position[a])
			dist_sq := dir.x * dir.x + dir.y * dir.y + dir.z * dir.z
			radius_sum := f32(view.radius[a]) + f32(view.radius[b])
			if dist_sq < radius_sum * radius_sum && dist_sq > 0.000001 {contacts += 1}
		}
	}
	elapsed := time.duration_milliseconds(time.tick_diff(start, time.tick_now()))
	fmt.printfln(
		"contacts n=%d warmup=%d depth=%d theta=%.2f scale=%g radius=%.3g: candidates=%d overlapping_pairs=%d in %.1f ms (%.3f us/body)",
		n,
		warmup,
		depth,
		theta,
		scale,
		max_radius,
		candidates,
		contacts,
		elapsed,
		elapsed / f64(n) * 1000.0,
	)
}

// Sizes the gravity traversal's interaction mix: how many force applications
// land on accepted far-field nodes versus near-field leaf bodies. The
// near-field share is the hard upper bound on what Newton's third law can
// share symmetrically (each close pair is currently evaluated from both
// sides). Serial and deterministic; warmup ticks let gravity cluster the
// bodies first, as the app actually sees them.
interactions_run :: proc(args: []string) {
	n := 100000
	depth := 16
	theta := f32(1.2)
	warmup := 0
	workers := 16
	if len(args) > 0 {n = _arg_int(args[0], n)}
	if len(args) > 1 {depth = _arg_int(args[1], depth)}
	if len(args) > 2 {theta = _arg_f32(args[2], theta)}
	if len(args) > 3 {warmup = _arg_int(args[3], warmup)}
	if len(args) > 4 {workers = _arg_int(args[4], workers)}

	ensure_workers(workers)
	w, s := make_world(
		{n = n, max_depth = depth, theta = theta, interval = 0, workers = workers},
	)
	defer ecs.scheduler_destroy(s)
	defer ecs.world_destroy(w)

	for _ in 0 ..< warmup {ecs.scheduler_run(s, .PHYSICS, w, SIM_DT)}

	view := physic.body_view(w)
	tree := physic.physic_state(w).tree
	owned := false
	if tree == nil {
		tree = physic.octtree_create_ex(view, theta, depth, MIN_HALF_SIZE)
		owned = true
	}
	defer if owned {physic.octtree_destroy(tree)}

	stats := physic.SolveStats{}
	start := time.tick_now()
	for idx in view.bodies {physic.octtree_stats(tree, idx, &stats)}
	elapsed := time.duration_milliseconds(time.tick_diff(start, time.tick_now()))

	apps := f64(stats.node_accept + stats.body_accept)
	per_body := apps / f64(n)
	near := f64(stats.body_accept) / apps
	asym :=
		stats.body_accept_fwd > 0 \
		? f64(stats.body_accept) / (2.0 * f64(stats.body_accept_fwd)) \
		: 0.0
	leaf_size :=
		stats.leaf_visits > 0 ? f64(stats.leaf_objects) / f64(stats.leaf_visits) : 0.0

	fmt.printfln(
		"interactions n=%d warmup=%d depth=%d theta=%.2f interval=0 workers=%d nodes=%d",
		n,
		warmup,
		depth,
		theta,
		workers,
		tree.node_count,
	)
	fmt.printfln(
		"  applications/body = %.1f  (node %.1f + leaf %.1f)",
		per_body,
		f64(stats.node_accept) / f64(n),
		f64(stats.body_accept) / f64(n),
	)
	fmt.printfln(
		"  near-field share   = %.1f%%  -> third-law ceiling = %.1f%% of applications",
		near * 100.0,
		near * 50.0,
	)
	fmt.printfln(
		"  asymmetry          = %.2f  (1.00 = every close pair reached from both sides)",
		asym,
	)
	fmt.printfln(
		"  nodes/body         = %.1f  (descended %.1f, culled %.1f)",
		f64(stats.nodes_popped) / f64(n),
		f64(stats.nodes_descended) / f64(n),
		f64(stats.nodes_culled) / f64(n),
	)
	fmt.printfln(
		"  leaf occupancy     = %.2f mean, %d max  (%d objects in %d leaves)",
		leaf_size,
		stats.max_leaf_objects,
		stats.leaf_objects,
		stats.leaf_visits,
	)
	fmt.printfln(
		"  serial single-thread solve: %.1f ms (%.3f us/body)",
		elapsed,
		elapsed / f64(n) * 1000.0,
	)
}

main :: proc() {
	stages := []Stage {
		{
			name = "1k",
			n = 1000,
			depths = []int{4, 6, 8, 10, 12, 16, 24, 48},
			thetas = []f32{0.2, 0.35, 0.5, 0.75, 1.0},
			intervals = []f32{0, 5, 50, 1000},
			workers = []int{1, 2, 4, 8, 16},
			warmup = 15,
			ticks = 40,
			repeats = 3,
			query = 1000,
		},
		{
			name = "10k",
			n = 10000,
			depths = []int{6, 8, 12, 24, 48},
			thetas = []f32{0.35, 0.5, 0.75, 1.0},
			intervals = []f32{0, 50},
			workers = []int{8, 16},
			warmup = 10,
			ticks = 25,
			repeats = 3,
			query = 2000,
		},
		{
			name = "100k",
			n = 100000,
			depths = []int{8, 12, 16, 24, 48},
			thetas = []f32{0.5, 0.75, 1.0},
			intervals = []f32{0, 50},
			workers = []int{8, 16},
			warmup = 3,
			ticks = 8,
			repeats = 2,
			query = 2000,
		},
	}

	filter := "all"
	if len(os.args) > 1 {filter = os.args[1]}

	if filter == "profile" {
		profile_run(os.args[2:])
	} else if filter == "contacts" {
		contacts_run(os.args[2:])
	} else if filter == "interactions" {
		interactions_run(os.args[2:])
	} else {
		found_any := false
		for st in stages {
			if filter != "all" && filter != st.name {continue}
			run_stage(st)
			found_any = true
		}
		if !found_any {
			fmt.eprintfln("unknown stage %q (expected: all, 1k, 10k, 100k, profile, contacts, interactions)", filter)
		}
	}

	foundation.parallel_destroy()
}
