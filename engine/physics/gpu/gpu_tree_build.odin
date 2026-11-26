package physics_gpu

import graphic "engine:graphics/front"
import gfx "engine:graphics/shared"
import physics "engine:physics"
import ecs "engine:ecs"
import "core:log"

// GPU octree build (docs/gpu_physics.md). One build reproduces the CPU
// builder's structure exactly (see `shader/tree_build.comp`), so the traversal
// consumes the same multipole tree the CPU path would have produced.
//
// The kernels live in one GLSL source compiled six times (`tree_build_0..5.spv`)
// and run in one command buffer:
//
//   init  -> setup -> root -> level 0 .. level max_depth -> com max_depth .. com 0
//         -> order finalize -> control readback
//
// The level and COM passes are indirect: the per-level counts live in the
// control block and are written by the previous pass on the device, so a level
// with no cells costs a no-op dispatch instead of a host readback per level.
//
// Only the control block comes back to the host (a few hundred bytes) for the
// tree metrics; the tree itself stays on the GPU.

@(private)
TREE_BUILD_STAGES :: 6

@(private)
// Manifest job names (`engine/graphics/shader/manifest.odin`).
TREE_BUILD_SHADERS: [TREE_BUILD_STAGES]string = {
	"tree_build_0",
	"tree_build_1",
	"tree_build_2",
	"tree_build_3",
	"tree_build_4",
	"tree_build_5",
}

@(private)
TREE_BUILD_NAMES: [TREE_BUILD_STAGES]string = {
	"tree_build_init",
	"tree_build_setup",
	"tree_build_root",
	"tree_build_level",
	"tree_build_com",
	"tree_build_order",
}

// Must match the `#if TREE_BUILD_STAGE` blocks in the shader.
@(private)
TREE_BUILD_INIT :: 0
@(private)
TREE_BUILD_SETUP :: 1
@(private)
TREE_BUILD_ROOT :: 2
@(private)
TREE_BUILD_LEVEL :: 3
@(private)
TREE_BUILD_COM :: 4
@(private)
TREE_BUILD_ORDER :: 5

@(private)
TREE_BUILD_WORKGROUP :: 256

@(private)
TREE_BUILD_MAX_LEVELS :: physics.MAX_DEPTH_CAP + 2

// Mirrors the shader's `Control`. `level_dispatch`/`com_dispatch` double as the
// indirect dispatch commands, so they are tightly packed (three u32 each).
@(private)
Tree_Build_Control :: struct {
	nodes_top:       u32,
	overflow:        u32,
	max_leaf_depth:  u32,
	order_parity:    u32,
	max_radius_bits: u32,
	min_bounds:      [3]u32,
	max_bounds:      [3]u32,
	root_half_bits:  u32,
	leaf_hist:       [TREE_BUILD_MAX_LEVELS]u32,
	level_base:      [TREE_BUILD_MAX_LEVELS]u32,
	level_dispatch:  [TREE_BUILD_MAX_LEVELS][3]u32,
	com_dispatch:    [TREE_BUILD_MAX_LEVELS][3]u32,
	cells_top:       u32,
}

@(private)
Tree_Build_Setup_Push :: struct {
	count: u32,
}

@(private)
Tree_Build_Root_Push :: struct {
	count: u32,
}

@(private)
Tree_Build_Level_Push :: struct {
	level:     u32,
	src:       u32,
	dst:       u32,
	max_depth: u32,
	capacity:  u32,
	min_half:  f32,
}

@(private)
Tree_Build_Com_Push :: struct {
	level: u32,
}

@(private)
Tree_Build_Order_Push :: struct {
	count: u32,
}

@(private)
TREE_BUILD_BINDINGS: [TREE_BUILD_STAGES][]u32 = {
	// init: control
	{0},
	// setup: bodies, radii, live, order_a, control
	{0, 1, 2, 3, 4},
	// root: nodes, cells, control
	{0, 1, 2},
	// level: nodes, bodies, order_a, order_b, cells, control
	{0, 1, 2, 3, 4, 5},
	// com: nodes, bodies, order_a, order_b, cells, control
	{0, 1, 2, 3, 4, 5},
	// order: order_a, order_b, order_out, control
	{0, 1, 2, 3},
}

@(private)
Gpu_Tree_Build :: struct {
	pipelines:      [TREE_BUILD_STAGES]gfx.Pipeline,
	state_device:   gfx.Buffer, // nodes | cells | control
	state_host:     gfx.Buffer, // control readback
	orders_device:  gfx.Buffer, // order_a | order_b
	live_host:      gfx.Buffer,
	live_device:    gfx.Buffer,
	nodes_offset:   u64,
	cells_offset:   u64,
	control_offset: u64,
	nodes_bytes:    u64,
	cells_bytes:    u64,
	control_bytes:  u64,
	order_a_offset: u64,
	order_b_offset: u64,
	order_bytes:    u64,
}

// _gpu_tree_build_open registers the six build pipelines. `_gpu_tree_reserve`
// must have run first: the descriptor bindings reference the reserved buffers.
@(private)
_gpu_tree_build_open :: proc(self: ^Gpu_Gravity) -> bool {
	build := &self.tree.build
	for i in 0 ..< TREE_BUILD_STAGES {
		pipeline, built := graphic.compute_pipeline_create(
			self.compute,
			TREE_BUILD_NAMES[i],
			TREE_BUILD_SHADERS[i],
			TREE_BUILD_BINDINGS[i],
		)
		if !built {return false}
		build.pipelines[i] = pipeline
	}
	return true
}

@(private)
_gpu_tree_build_release :: proc(self: ^Gpu_Gravity) {
	build := &self.tree.build
	graphic.compute_buffer_destroy(self.compute, &build.state_device)
	graphic.compute_buffer_destroy(self.compute, &build.state_host)
	graphic.compute_buffer_destroy(self.compute, &build.orders_device)
	graphic.compute_buffer_destroy(self.compute, &build.live_host)
	graphic.compute_buffer_destroy(self.compute, &build.live_device)
	build.nodes_offset = 0
	build.cells_offset = 0
	build.control_offset = 0
	build.nodes_bytes = 0
	build.cells_bytes = 0
	build.control_bytes = 0
	build.order_a_offset = 0
	build.order_b_offset = 0
	build.order_bytes = 0
}

// _gpu_tree_build_reserve sizes the build buffers from the body capacity. The
// node arena matches the CPU tree's bound (`count * 8 + 1024` nodes).
@(private)
_gpu_tree_build_reserve :: proc(self: ^Gpu_Gravity, capacity, node_capacity: int) -> bool {
	build := &self.tree.build

	build.nodes_bytes = u64(node_capacity * size_of(Tree_Node))
	build.cells_bytes = u64(node_capacity * size_of(u32))
	build.control_bytes = u64(size_of(Tree_Build_Control))
	build.order_bytes = u64(capacity * size_of(u32))

	build.nodes_offset = 0
	build.cells_offset = build.nodes_bytes
	build.control_offset = build.cells_offset + build.cells_bytes
	build.order_a_offset = 0
	build.order_b_offset = build.order_bytes

	state_bytes := build.control_offset + build.control_bytes
	build.state_device = graphic.compute_buffer_create(
		self.compute,
		state_bytes,
		{.STORAGE, .TRANSFER_SRC, .INDIRECT},
		.DEVICE,
		.EXCLUSIVE,
	) or_return
	build.state_host = graphic.compute_buffer_create(self.compute, build.control_bytes, {.TRANSFER_DST}, .HOST, .EXCLUSIVE) or_return
	build.orders_device = graphic.compute_buffer_create(
		self.compute,
		build.order_bytes * 2,
		{.STORAGE},
		.DEVICE,
		.EXCLUSIVE,
	) or_return
	build.live_host = graphic.compute_buffer_create(
		self.compute,
		u64(capacity * size_of(u32)),
		{.TRANSFER_SRC},
		.HOST,
		.EXCLUSIVE,
	) or_return
	build.live_device = graphic.compute_buffer_create(
		self.compute,
		u64(capacity * size_of(u32)),
		{.STORAGE, .TRANSFER_DST},
		.DEVICE,
		.EXCLUSIVE,
	) or_return

	log.debugf(
		"[GPU PHYSICS] Tree build buffers for %d bodies (%d nodes, %d KiB state)",
		capacity,
		node_capacity,
		state_bytes / 1024,
	)
	return true
}

@(private)
_tree_build_barrier :: proc(self: ^Gpu_Gravity, cmd: gfx.Command, buffer: gfx.Buffer, size: u64) {
	graphic.compute_advance(self.compute, cmd, buffer, 0, size, indirect = true)
}

@(private)
_tree_build_float_unkey :: proc(key: u32) -> f32 {
	u := (key & 0x80000000) != 0 ? (key ~ 0x80000000) : (key ~ 0xffffffff)
	return transmute(f32)u
}


// _gpu_tree_build runs one full build and returns its metrics. On success the
// traversal buffers (`tree.nodes_device`, `tree.order_device`) hold the new
// tree; on failure neither is usable and the caller falls back.
@(private)
_gpu_tree_build :: proc(
	self: ^Gpu_Gravity,
	w: ^ecs.World,
	bodies: []u32,
	max_depth: int,
	min_half: f32,
) -> (
	info: physics.Tree_Info,
	ok: bool,
) {
	tree := &self.tree
	build := &tree.build
	count := len(bodies)
	if count == 0 {return {}, false}
	if count > self.capacity {
		log.errorf("[GPU PHYSICS] %d bodies exceed the reserved capacity %d", count, self.capacity)
		return {}, false
	}
	level_cap := clamp(max_depth, 0, physics.MAX_DEPTH_CAP)
	levels := level_cap + 1

	// Pool-indexed body columns plus the live list; both are also what the
	// traversal uploads, so a rebuild followed by a solve re-uploads the same
	// data (cheap next to the build).
	view := physics.body_view(w)
	max_entity: u32
	for entity in bodies {
		if entity > max_entity {max_entity = entity}
	}
	copy_entries := int(max_entity) + 1
	if copy_entries > self.capacity {
		log.errorf("[GPU PHYSICS] Entity index %d exceeds the reserved capacity %d", max_entity, self.capacity)
		return {}, false
	}
	_gpu_tree_pack_bodies(self, w, bodies)
	live := cast([^]u32)build.live_host.mapped
	for k in 0 ..< count {live[k] = bodies[k]}

	entity_bytes := u64(copy_entries * size_of(Gpu_Body_Record))
	velocity_bytes := u64(copy_entries * size_of(Gpu_Velocity_Record))
	radii_bytes := u64(copy_entries * size_of(f32))
	live_bytes := u64(count * size_of(u32))

	cmd := graphic.compute_begin(self.compute)
	control_size := build.control_bytes

	_gpu_upload(self, cmd, self.bodies_host, self.bodies_device, entity_bytes)
	_gpu_upload(self, cmd, self.radii_host, self.radii_device, radii_bytes)
	_gpu_upload(self, cmd, build.live_host, build.live_device, live_bytes)

	groups := u32((count + TREE_BUILD_WORKGROUP - 1) / TREE_BUILD_WORKGROUP)

	// init: clear the control block.
	graphic.compute_pass(
		self.compute,
		cmd,
		build.pipelines[TREE_BUILD_INIT],
		[]gfx.Bind{{binding = 0, buffer = build.state_device, offset = build.control_offset, size = control_size}},
		{groups = {1, 1, 1}},
	)
	_tree_build_barrier(self, cmd, build.state_device, build.control_offset + control_size)

	// setup: bounds, counts and the initial order.
	setup_binds := [5]gfx.Bind {
		{binding = 0, buffer = self.bodies_device, size = self.bodies_device.size},
		{binding = 1, buffer = self.radii_device, size = self.radii_device.size},
		{binding = 2, buffer = build.live_device, size = live_bytes},
		{binding = 3, buffer = build.orders_device, offset = build.order_a_offset, size = build.order_bytes},
		{binding = 4, buffer = build.state_device, offset = build.control_offset, size = control_size},
	}
	setup_push := Tree_Build_Setup_Push{count = u32(count)}
	graphic.compute_pass(
		self.compute,
		cmd,
		build.pipelines[TREE_BUILD_SETUP],
		setup_binds[:],
		{groups = {groups, 1, 1}},
		&setup_push,
		size_of(Tree_Build_Setup_Push),
	)
	_tree_build_barrier(self, cmd, build.state_device, build.control_offset + control_size)
	_tree_build_barrier(self, cmd, build.orders_device, build.order_bytes * 2)

	// root
	root_binds := [3]gfx.Bind {
		{binding = 0, buffer = build.state_device, offset = build.nodes_offset, size = build.nodes_bytes},
		{binding = 1, buffer = build.state_device, offset = build.cells_offset, size = build.cells_bytes},
		{binding = 2, buffer = build.state_device, offset = build.control_offset, size = control_size},
	}
	root_push := Tree_Build_Root_Push{count = u32(count)}
	graphic.compute_pass(
		self.compute,
		cmd,
		build.pipelines[TREE_BUILD_ROOT],
		root_binds[:],
		{groups = {1, 1, 1}},
		&root_push,
		size_of(Tree_Build_Root_Push),
	)
	_tree_build_barrier(self, cmd, build.state_device, build.state_device.size)
	_tree_build_barrier(self, cmd, build.orders_device, build.order_bytes * 2)

	// level pass: one workgroup per cell per level, dispatched indirectly from
	// the counts the previous level wrote.
	level_binds := [6]gfx.Bind {
		{binding = 0, buffer = build.state_device, offset = build.nodes_offset, size = build.nodes_bytes},
		{binding = 1, buffer = self.bodies_device, size = self.bodies_device.size},
		{binding = 2, buffer = build.orders_device, offset = build.order_a_offset, size = build.order_bytes},
		{binding = 3, buffer = build.orders_device, offset = build.order_b_offset, size = build.order_bytes},
		{binding = 4, buffer = build.state_device, offset = build.cells_offset, size = build.cells_bytes},
		{binding = 5, buffer = build.state_device, offset = build.control_offset, size = control_size},
	}
	for d in 0 ..< levels {
		_tree_build_barrier(self, cmd, build.state_device, build.state_device.size)
		_tree_build_barrier(self, cmd, build.orders_device, build.order_bytes * 2)
		push := Tree_Build_Level_Push {
			level     = u32(d),
			src       = u32(d % 2),
			dst       = u32((d + 1) % 2),
			max_depth = u32(level_cap),
			capacity  = u32(tree.node_capacity),
			min_half  = min_half,
		}
		graphic.compute_pass(
			self.compute,
			cmd,
			build.pipelines[TREE_BUILD_LEVEL],
			level_binds[:],
			{
				indirect = build.state_device,
				offset   = build.control_offset +
					u64(offset_of(Tree_Build_Control, level_dispatch)) +
					u64(d * size_of([3]u32)),
			},
			&push,
			size_of(Tree_Build_Level_Push),
		)
	}

	// COM pass, deepest level first: children are always one level below their
	// parent, so bottom-up order is descending level order.
	if levels > 0 {
		for i in 0 ..< levels {
			d := levels - 1 - i
			_tree_build_barrier(self, cmd, build.state_device, build.state_device.size)
			push := Tree_Build_Com_Push{level = u32(d)}
			graphic.compute_pass(
				self.compute,
				cmd,
				build.pipelines[TREE_BUILD_COM],
				level_binds[:],
				{
					indirect = build.state_device,
					offset   = build.control_offset +
						u64(offset_of(Tree_Build_Control, com_dispatch)) +
						u64(d * size_of([3]u32)),
				},
				&push,
				size_of(Tree_Build_Com_Push),
			)
		}
	}

	// Publish the order the traversal binds, whatever parity the last level wrote.
	order_binds := [4]gfx.Bind {
		{binding = 0, buffer = build.orders_device, offset = build.order_a_offset, size = build.order_bytes},
		{binding = 1, buffer = build.orders_device, offset = build.order_b_offset, size = build.order_bytes},
		{binding = 2, buffer = self.tree.order_device, size = self.tree.order_device.size},
		{binding = 3, buffer = build.state_device, offset = build.control_offset, size = control_size},
	}
	order_push := Tree_Build_Order_Push{count = u32(count)}
	graphic.compute_pass(
		self.compute,
		cmd,
		build.pipelines[TREE_BUILD_ORDER],
		order_binds[:],
		{groups = {groups, 1, 1}},
		&order_push,
		size_of(Tree_Build_Order_Push),
	)

	// Control readback (metrics + overflow flag).
	graphic.compute_readback(self.compute, cmd, build.state_device, build.control_offset, build.state_host, 0, control_size)

	value := graphic.compute_submit(self.compute, cmd)
	graphic.compute_wait(self.compute, value)

	control := cast(^Tree_Build_Control)build.state_host.mapped
	if control.overflow != 0 {
		log.errorf("[GPU PHYSICS] Tree build ran out of node capacity (%d)", tree.node_capacity)
		return {}, false
	}

	info.node_count = int(control.nodes_top)
	info.max_leaf_depth = int(control.max_leaf_depth)
	info.max_radius = _tree_build_float_unkey(control.max_radius_bits)
	root_half := transmute(f32)control.root_half_bits

	total := 0
	for d in 0 ..< TREE_BUILD_MAX_LEVELS {total += int(control.leaf_hist[d])}
	cumulative := 0
	median := 0
	for d in 0 ..< TREE_BUILD_MAX_LEVELS {
		cumulative += int(control.leaf_hist[d])
		if cumulative >= total / 2 {
			median = d
			break
		}
	}
	info.median_leaf_depth = median
	info.typical_half = root_half / f32(u64(1) << uint(median))

	tree.valid = true
	tree.live_count = count
	tree.info = info
	return info, true
}
