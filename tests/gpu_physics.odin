package tests

import ecs "../Engine/ecs"
import graphic "../Engine/Graphic"
import physics "../Engine/physic"
import foundation "../foundation"
import "core:math"
import "core:math/rand"
import "core:slice"
import "core:testing"

// Deterministic world for backend comparisons: every call spawns the same
// bodies in the same order, so entity indices line up between worlds.
@(private)
_gpu_world :: proc(n: int, solver: physics.Gravity_Solver) -> ^ecs.World {
	w := ecs.world_create()
	ecs.world_reserve(w, n)
	rand.reset_u64(7)
	for _ in 0 ..< n {
		physics.body_spawn(
			w,
			{
				rand.float32_range(-1e10, 1e10),
				rand.float32_range(-1e10, 1e10),
				rand.float32_range(-1e10, 1e10),
			},
			{0, 0, 0},
			6e27,
			12371e3,
		)
	}
	physics.physic_init(w, foundation.Config{algorithm = .BRUTE_FORCE})
	if solver.submit != nil {physics.physic_set_gravity_solver(w, solver)}
	return w
}

// The GPU solver needs a compute device, so the test skips (like the SPIR-V
// fixture tests) when the headless context cannot be created.
@(test)
test_gpu_gravity_matches_cpu :: proc(t: ^testing.T) {
	solver, created := graphic.gpu_gravity_init_headless(.BRUTE_FORCE, 64)
	if !created {return}
	defer graphic.gpu_gravity_destroy(solver)

	cpu_world := _gpu_world(64, {})
	defer ecs.world_destroy(cpu_world)
	gpu_world := _gpu_world(64, graphic.gpu_gravity_backend(solver))
	defer ecs.world_destroy(gpu_world)

	// dt = 1 turns the velocity update into the acceleration.
	dt := f32(1.0)
	physics.physic_system_begin(cpu_world, dt)
	physics.physic_system_gravity(cpu_world, dt)
	physics.physic_finish_gravity(cpu_world)
	physics.physic_system_begin(gpu_world, dt)
	physics.physic_system_gravity(gpu_world, dt)
	physics.physic_finish_gravity(gpu_world)

	cpu_view := physics.body_view(cpu_world)
	gpu_view := physics.body_view(gpu_world)
	count := min(len(cpu_view.bodies), len(gpu_view.bodies))
	testing.expect_value(t, count, 64)

	// The GPU evaluates ordered pairs in a different order than the CPU's
	// third-law loop, so the values agree to f32 rounding, not bit-for-bit.
	worst: f64
	for i in 0 ..< count {
		entity := cpu_view.bodies[i]
		cpu := physics.Vec3(cpu_view.velocity[entity])
		gpu := physics.Vec3(gpu_view.velocity[entity])
		dx := f64(cpu.x - gpu.x)
		dy := f64(cpu.y - gpu.y)
		dz := f64(cpu.z - gpu.z)
		error := math.sqrt(dx * dx + dy * dy + dz * dz)
		magnitude := math.sqrt(
			f64(cpu.x) * f64(cpu.x) + f64(cpu.y) * f64(cpu.y) + f64(cpu.z) * f64(cpu.z),
		)
		if magnitude < 1e-30 {magnitude = 1e-30}
		relative := error / magnitude
		if relative > worst {worst = relative}
	}
	testing.expectf(t, worst < 1e-3, "max relative acceleration error %.3e", worst)
}

// Deterministic world for the Barnes-Hut comparison: random bodies plus two
// overlapping clusters whose pairs the fold must find through theta-accepted
// nodes. The tree rebuilds every tick (interval 0), so the structure upload runs
// too.
@(private)
_gpu_tree_world :: proc(solver: physics.Gravity_Solver) -> ^ecs.World {
	w := ecs.world_create()
	ecs.world_reserve(w, 128)
	rand.reset_u64(11)
	for _ in 0 ..< 64 {
		physics.body_spawn(
			w,
			{
				rand.float32_range(-1e10, 1e10),
				rand.float32_range(-1e10, 1e10),
				rand.float32_range(-1e10, 1e10),
			},
			{0, 0, 0},
			6e27,
			12371e3,
		)
	}
	// Radius sum is 2 * 12371e3, so neighbours at 1e7 overlap.
	for i in 0 ..< 8 {
		physics.body_spawn(w, {f32(i) * 1e7, 0, 0}, {0, 0, 0}, 6e27, 12371e3)
	}
	physics.physic_init(
		w,
		foundation.Config {
			algorithm = .OCTREE,
			theta = 0.9,
			tree_rebuild_interval = 0,
			max_depth = 16,
			min_half_size = 1e-4,
		},
	)
	if solver.submit != nil {physics.physic_set_gravity_solver(w, solver)}
	return w
}

// The GPU Barnes-Hut port has to reproduce the CPU traversal's acceleration
// (to f32 rounding) and its exact contact set: the fold, the opening angle and
// the overlap test all run on the same tree.
@(test)
test_gpu_tree_matches_cpu :: proc(t: ^testing.T) {
	solver, created := graphic.gpu_gravity_init_headless(.OCTREE, 128)
	if !created {return}
	defer graphic.gpu_gravity_destroy(solver)

	cpu_world := _gpu_tree_world({})
	defer ecs.world_destroy(cpu_world)
	gpu_world := _gpu_tree_world(graphic.gpu_gravity_backend(solver))
	defer ecs.world_destroy(gpu_world)

	// dt = 1 turns the velocity update into the acceleration.
	dt := f32(1.0)
	physics.physic_system_begin(cpu_world, dt)
	physics.physic_system_gravity(cpu_world, dt)
	physics.physic_finish_gravity(cpu_world)
	physics.physic_system_begin(gpu_world, dt)
	physics.physic_system_gravity(gpu_world, dt)
	physics.physic_finish_gravity(gpu_world)

	cpu_view := physics.body_view(cpu_world)
	gpu_view := physics.body_view(gpu_world)
	worst: f64
	for entity in cpu_view.bodies {
		cpu := physics.Vec3(cpu_view.velocity[entity])
		gpu := physics.Vec3(gpu_view.velocity[entity])
		dx := f64(cpu.x - gpu.x)
		dy := f64(cpu.y - gpu.y)
		dz := f64(cpu.z - gpu.z)
		error := math.sqrt(dx * dx + dy * dy + dz * dz)
		magnitude := math.sqrt(
			f64(cpu.x) * f64(cpu.x) + f64(cpu.y) * f64(cpu.y) + f64(cpu.z) * f64(cpu.z),
		)
		if magnitude < 1e-30 {magnitude = 1e-30}
		relative := error / magnitude
		if relative > worst {worst = relative}
	}
	testing.expectf(t, worst < 1e-3, "max relative acceleration error %.3e", worst)

	cpu_contacts := physics.physic_state(cpu_world).collision_contacts
	gpu_contacts := physics.physic_state(gpu_world).collision_contacts
	testing.expectf(t, len(cpu_contacts) >= 4, "expected folded contacts, got %d", len(cpu_contacts))
	testing.expect_value(t, len(gpu_contacts), len(cpu_contacts))
	if len(gpu_contacts) == len(cpu_contacts) {
		slice.sort_by(cpu_contacts[:], _contact_less)
		slice.sort_by(gpu_contacts[:], _contact_less)
		for i in 0 ..< len(cpu_contacts) {
			testing.expect_value(t, gpu_contacts[i], cpu_contacts[i])
		}
	}
}

// One leaf of a built tree, canonicalized for comparison: the body set is
// sorted, so the GPU's atomic scatter order does not matter.
@(private)
_Leaf_Record :: struct {
	depth:     int,
	center:    [3]f32,
	half_size: f32,
	bodies:    []u32,
}

@(private)
_leaf_record_less :: proc(a, b: _Leaf_Record) -> bool {
	if a.depth != b.depth {return a.depth < b.depth}
	if a.center[0] != b.center[0] {return a.center[0] < b.center[0]}
	if a.center[1] != b.center[1] {return a.center[1] < b.center[1]}
	if a.center[2] != b.center[2] {return a.center[2] < b.center[2]}
	return a.half_size < b.half_size
}

// The GPU build must reproduce the CPU tree cell for cell: same leaf cells
// (center, half, depth), same body sets and the same metrics. Only node ids and
// the order inside a leaf may differ.

// The GPU build must reproduce the CPU tree cell for cell: same leaf cells
// (center, half, depth), same body sets and the same metrics. Only node ids and
// the order inside a leaf may differ.
@(test)
test_gpu_tree_build_matches_cpu :: proc(t: ^testing.T) {
	solver, created := graphic.gpu_gravity_init_headless(.OCTREE, 128)
	if !created {return}
	defer graphic.gpu_gravity_destroy(solver)

	cpu_world := _gpu_tree_world({})
	defer ecs.world_destroy(cpu_world)
	gpu_world := _gpu_tree_world(graphic.gpu_gravity_backend(solver))
	defer ecs.world_destroy(gpu_world)

	// begin builds the tree: CPU builder for the first world, GPU build for the
	// second.
	physics.physic_system_begin(cpu_world, 1.0)
	physics.physic_system_begin(gpu_world, 1.0)

	cpu_tree := physics.physic_state(cpu_world).tree
	testing.expect(t, cpu_tree != nil, "CPU world must own a tree")
	if cpu_tree == nil {return}

	gpu_dump_leaves := make([]graphic.Tree_Leaf, 4096)
	defer delete(gpu_dump_leaves)
	gpu_order := make([]u32, 4096)
	defer delete(gpu_order)
	leaf_count, order_count, dumped := graphic.gpu_tree_dump(solver, gpu_dump_leaves, gpu_order)
	testing.expect(t, dumped, "gpu_tree_dump failed")
	if !dumped {return}

	gpu_records := make([dynamic]_Leaf_Record, 0, leaf_count)
	defer {
		for r in gpu_records {delete(r.bodies)}
		delete(gpu_records)
	}
	for i in 0 ..< leaf_count {
		leaf := gpu_dump_leaves[i]
		bodies := make([]u32, leaf.obj_count)
		copy(bodies, gpu_order[leaf.first_obj:leaf.first_obj + leaf.obj_count])
		slice.sort(bodies)
		append(
			&gpu_records,
			_Leaf_Record {
				depth = leaf.depth,
				center = leaf.center,
				half_size = leaf.half_size,
				bodies = bodies,
			},
		)
	}
	slice.sort_by(gpu_records[:], _leaf_record_less)

	cpu_records := make([dynamic]_Leaf_Record, 0, leaf_count)
	defer {
		for r in cpu_records {delete(r.bodies)}
		delete(cpu_records)
	}
	for i in 0 ..< cpu_tree.node_count {
		node := &cpu_tree.nodes[i]
		if node.child_count != 0 {continue}
		bodies := make([]u32, node.obj_count)
		copy(bodies, cpu_tree.order[node.first_obj:node.first_obj + node.obj_count])
		slice.sort(bodies)
		append(
			&cpu_records,
			_Leaf_Record {
				center = node.center,
				half_size = node.half_size,
				bodies = bodies,
			},
		)
	}
	// CPU leaves do not carry their depth; recompute it from the half size
	// relative to the root (each level halves the cell size exactly).
	root_half := cpu_tree.nodes[0].half_size
	for &r in cpu_records {
		depth := 0
		h := root_half
		for h > r.half_size && depth < physics.MAX_DEPTH_CAP {
			h *= 0.5
			depth += 1
		}
		r.depth = depth
	}
	slice.sort_by(cpu_records[:], _leaf_record_less)

	info := physics.physic_state(gpu_world).tree_info
	testing.expect_value(t, info.node_count, cpu_tree.node_count)
	testing.expect_value(t, info.max_leaf_depth, cpu_tree.max_leaf_depth)
	testing.expect_value(t, info.median_leaf_depth, cpu_tree.median_leaf_depth)
	testing.expect_value(t, info.max_radius, cpu_tree.max_radius)
	testing.expect_value(t, order_count, len(cpu_tree.order))
	testing.expectf(
		t,
		len(gpu_records) == len(cpu_records),
		"leaf count %d != %d",
		len(gpu_records),
		len(cpu_records),
	)
	for i in 0 ..< min(len(gpu_records), len(cpu_records)) {
		g := gpu_records[i]
		c := cpu_records[i]
		if !testing.expectf(
			t,
			g.depth == c.depth &&
			g.center == c.center &&
			g.half_size == c.half_size &&
			len(g.bodies) == len(c.bodies),
			"leaf %d differs: depth %d/%d center %v/%v half %v/%v count %d/%d",
			i,
			g.depth,
			c.depth,
			g.center,
			c.center,
			g.half_size,
			c.half_size,
			len(g.bodies),
			len(c.bodies),
		) {
			break
		}
		for j in 0 ..< len(g.bodies) {
			if g.bodies[j] != c.bodies[j] {
				testing.expectf(
					t,
					false,
					"leaf %d body %d differs: %d != %d",
					i,
					j,
					g.bodies[j],
					c.bodies[j],
				)
				break
			}
		}
	}
}
