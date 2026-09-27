package graphic

import phys "../physic"
import ecs "../ecs"
import "core:log"
import "vendor:vulkan"

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
TREE_BUILD_SHADERS: [TREE_BUILD_STAGES]string = {
	"Engine/Graphic/shader/tree_build_0.spv",
	"Engine/Graphic/shader/tree_build_1.spv",
	"Engine/Graphic/shader/tree_build_2.spv",
	"Engine/Graphic/shader/tree_build_3.spv",
	"Engine/Graphic/shader/tree_build_4.spv",
	"Engine/Graphic/shader/tree_build_5.spv",
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
TREE_BUILD_MAX_LEVELS :: phys.MAX_DEPTH_CAP + 2

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
TREE_BUILD_BINDINGS: [TREE_BUILD_STAGES][]Push_Binding_Spec = {
	// init: control
	{
		{set = 0, binding = 0, descriptor = .STORAGE_BUFFER, external = true},
	},
	// setup: bodies, radii, live, order_a, control
	{
		{set = 0, binding = 0, descriptor = .STORAGE_BUFFER, external = true},
		{set = 0, binding = 1, descriptor = .STORAGE_BUFFER, external = true},
		{set = 0, binding = 2, descriptor = .STORAGE_BUFFER, external = true},
		{set = 0, binding = 3, descriptor = .STORAGE_BUFFER, external = true},
		{set = 0, binding = 4, descriptor = .STORAGE_BUFFER, external = true},
	},
	// root: nodes, cells, control
	{
		{set = 0, binding = 0, descriptor = .STORAGE_BUFFER, external = true},
		{set = 0, binding = 1, descriptor = .STORAGE_BUFFER, external = true},
		{set = 0, binding = 2, descriptor = .STORAGE_BUFFER, external = true},
	},
	// level: nodes, bodies, order_a, order_b, cells, control
	{
		{set = 0, binding = 0, descriptor = .STORAGE_BUFFER, external = true},
		{set = 0, binding = 1, descriptor = .STORAGE_BUFFER, external = true},
		{set = 0, binding = 2, descriptor = .STORAGE_BUFFER, external = true},
		{set = 0, binding = 3, descriptor = .STORAGE_BUFFER, external = true},
		{set = 0, binding = 4, descriptor = .STORAGE_BUFFER, external = true},
		{set = 0, binding = 5, descriptor = .STORAGE_BUFFER, external = true},
	},
	// com: nodes, bodies, order_a, order_b, cells, control
	{
		{set = 0, binding = 0, descriptor = .STORAGE_BUFFER, external = true},
		{set = 0, binding = 1, descriptor = .STORAGE_BUFFER, external = true},
		{set = 0, binding = 2, descriptor = .STORAGE_BUFFER, external = true},
		{set = 0, binding = 3, descriptor = .STORAGE_BUFFER, external = true},
		{set = 0, binding = 4, descriptor = .STORAGE_BUFFER, external = true},
		{set = 0, binding = 5, descriptor = .STORAGE_BUFFER, external = true},
	},
	// order: order_a, order_b, order_out, control
	{
		{set = 0, binding = 0, descriptor = .STORAGE_BUFFER, external = true},
		{set = 0, binding = 1, descriptor = .STORAGE_BUFFER, external = true},
		{set = 0, binding = 2, descriptor = .STORAGE_BUFFER, external = true},
		{set = 0, binding = 3, descriptor = .STORAGE_BUFFER, external = true},
	},
}

@(private)
Gpu_Tree_Build :: struct {
	pipelines:      [TREE_BUILD_STAGES]Pipeline_ID,
	push:           [TREE_BUILD_STAGES]Push_Descriptors,
	state_device:   Buffer, // nodes | cells | control
	state_host:     Buffer, // control readback
	orders_device:  Buffer, // order_a | order_b
	live_host:      Buffer,
	live_device:    Buffer,
	nodes_offset:   vulkan.DeviceSize,
	cells_offset:   vulkan.DeviceSize,
	control_offset: vulkan.DeviceSize,
	nodes_bytes:    vulkan.DeviceSize,
	cells_bytes:    vulkan.DeviceSize,
	control_bytes:  vulkan.DeviceSize,
	order_a_offset: vulkan.DeviceSize,
	order_b_offset: vulkan.DeviceSize,
	order_bytes:    vulkan.DeviceSize,
}

// _gpu_tree_build_open registers the six build pipelines. `_gpu_tree_reserve`
// must have run first: the descriptor bindings reference the reserved buffers.
@(private)
_gpu_tree_build_open :: proc(self: ^Gpu_Gravity) -> bool {
	build := &self.tree.build
	for i in 0 ..< TREE_BUILD_STAGES {
		pipeline_id, built := pipeline_registry_add_compute(
			&self.compute.pipelines,
			TREE_BUILD_NAMES[i],
			Compute_Config{shaders = []Shader_Spec{{path = TREE_BUILD_SHADERS[i]}}},
		)
		if !built {return false}
		build.pipelines[i] = pipeline_id
		build.push[i] = push_descriptors_init(self.compute.gpu, TREE_BUILD_BINDINGS[i]) or_return
		pipeline := pipeline_registry_get(&self.compute.pipelines, pipeline_id)
		if !push_descriptors_validate(&build.push[i], pipeline) {return false}
	}
	return true
}

// _gpu_tree_build_close destroys the build descriptors. The pipelines belong to
// the compute context; buffer release and descriptor close are separate because
// `_gpu_gravity_reserve` may release the buffers again (world growth) without
// touching the descriptors.
@(private)
_gpu_tree_build_close :: proc(self: ^Gpu_Gravity) {
	build := &self.tree.build
	for i in 0 ..< TREE_BUILD_STAGES {
		push_descriptors_destroy(&build.push[i])
	}
}

@(private)
_gpu_tree_build_release :: proc(self: ^Gpu_Gravity) {
	build := &self.tree.build
	buffer_destroy(&build.state_device)
	buffer_destroy(&build.state_host)
	buffer_destroy(&build.orders_device)
	buffer_destroy(&build.live_host)
	buffer_destroy(&build.live_device)
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
	gpu := self.compute.gpu

	build.nodes_bytes = vulkan.DeviceSize(node_capacity * size_of(Tree_Node))
	build.cells_bytes = vulkan.DeviceSize(node_capacity * size_of(u32))
	build.control_bytes = vulkan.DeviceSize(size_of(Tree_Build_Control))
	build.order_bytes = vulkan.DeviceSize(capacity * size_of(u32))

	build.nodes_offset = 0
	build.cells_offset = build.nodes_bytes
	build.control_offset = build.cells_offset + build.cells_bytes
	build.order_a_offset = 0
	build.order_b_offset = build.order_bytes

	state_bytes := build.control_offset + build.control_bytes
	build.state_device = buffer_init(
		gpu,
		state_bytes,
		{.STORAGE_BUFFER, .TRANSFER_SRC, .INDIRECT_BUFFER},
		.DeviceLocal,
	) or_return
	build.state_host = buffer_init(gpu, build.control_bytes, {.TRANSFER_DST}, .HostVisible) or_return
	build.orders_device = buffer_init(
		gpu,
		build.order_bytes * 2,
		{.STORAGE_BUFFER},
		.DeviceLocal,
	) or_return
	build.live_host = buffer_init(
		gpu,
		vulkan.DeviceSize(capacity * size_of(u32)),
		{.TRANSFER_SRC},
		.HostVisible,
	) or_return
	build.live_device = buffer_init(
		gpu,
		vulkan.DeviceSize(capacity * size_of(u32)),
		{.STORAGE_BUFFER, .TRANSFER_DST},
		.DeviceLocal,
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
_tree_build_barrier :: proc(cmd: vulkan.CommandBuffer, buffer: vulkan.Buffer, size: vulkan.DeviceSize) {
	buffer_barrier(
		cmd,
		buffer,
		0,
		size,
		{.COMPUTE_SHADER},
		{.COMPUTE_SHADER, .DRAW_INDIRECT},
		{.SHADER_STORAGE_WRITE},
		{.SHADER_STORAGE_READ, .SHADER_STORAGE_WRITE, .INDIRECT_COMMAND_READ},
	)
}

@(private)
_tree_build_dispatch_indirect :: proc(
	cmd: vulkan.CommandBuffer,
	buffer: vulkan.Buffer,
	base_offset: vulkan.DeviceSize,
	index: int,
) {
	vulkan.CmdDispatchIndirect(cmd, buffer, base_offset + vulkan.DeviceSize(index * size_of([3]u32)))
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
	info: phys.Tree_Info,
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
	level_cap := clamp(max_depth, 0, phys.MAX_DEPTH_CAP)
	levels := level_cap + 1

	// Pool-indexed body columns plus the live list; both are also what the
	// traversal uploads, so a rebuild followed by a solve re-uploads the same
	// data (cheap next to the build).
	view := phys.body_view(w)
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

	entity_bytes := vulkan.DeviceSize(copy_entries * size_of(Gpu_Body_Record))
	velocity_bytes := vulkan.DeviceSize(copy_entries * size_of(Gpu_Velocity_Record))
	radii_bytes := vulkan.DeviceSize(copy_entries * size_of(f32))
	live_bytes := vulkan.DeviceSize(count * size_of(u32))

	init_pipeline := pipeline_registry_get(&self.compute.pipelines, build.pipelines[TREE_BUILD_INIT])
	setup_pipeline := pipeline_registry_get(&self.compute.pipelines, build.pipelines[TREE_BUILD_SETUP])
	root_pipeline := pipeline_registry_get(&self.compute.pipelines, build.pipelines[TREE_BUILD_ROOT])
	level_pipeline := pipeline_registry_get(&self.compute.pipelines, build.pipelines[TREE_BUILD_LEVEL])
	com_pipeline := pipeline_registry_get(&self.compute.pipelines, build.pipelines[TREE_BUILD_COM])
	order_pipeline := pipeline_registry_get(&self.compute.pipelines, build.pipelines[TREE_BUILD_ORDER])

	cmd, slot := compute_begin(&self.compute)
	frame := u32(slot)
	control_size := build.control_bytes

	_gpu_upload(cmd, self.compute.gpu, &self.bodies_host, &self.bodies_device, entity_bytes)
	_gpu_upload(cmd, self.compute.gpu, &self.tree.radii_host, &self.tree.radii_device, radii_bytes)
	_gpu_upload(cmd, self.compute.gpu, &build.live_host, &build.live_device, live_bytes)

	groups := u32((count + TREE_BUILD_WORKGROUP - 1) / TREE_BUILD_WORKGROUP)

	// init
	pipeline_bind_compute(init_pipeline, cmd)
	push_descriptors_bind_buffer(&build.push[TREE_BUILD_INIT], 0, 0, frame, build.state_device.buffer, build.control_offset, control_size)
	push_descriptors_flush(&build.push[TREE_BUILD_INIT], cmd, init_pipeline.layout, frame)
	vulkan.CmdDispatch(cmd, 1, 1, 1)
	_tree_build_barrier(cmd, build.state_device.buffer, build.control_offset + control_size)

	// setup
	pipeline_bind_compute(setup_pipeline, cmd)
	setup_push := Tree_Build_Setup_Push{count = u32(count)}
	pipeline_push_constants(setup_pipeline, cmd, &setup_push, size_of(Tree_Build_Setup_Push))
	push_descriptors_bind_buffer(&build.push[TREE_BUILD_SETUP], 0, 0, frame, self.bodies_device.buffer, 0, self.bodies_device.size)
	push_descriptors_bind_buffer(&build.push[TREE_BUILD_SETUP], 0, 1, frame, self.tree.radii_device.buffer, 0, self.tree.radii_device.size)
	push_descriptors_bind_buffer(&build.push[TREE_BUILD_SETUP], 0, 2, frame, build.live_device.buffer, 0, live_bytes)
	push_descriptors_bind_buffer(&build.push[TREE_BUILD_SETUP], 0, 3, frame, build.orders_device.buffer, build.order_a_offset, build.order_bytes)
	push_descriptors_bind_buffer(&build.push[TREE_BUILD_SETUP], 0, 4, frame, build.state_device.buffer, build.control_offset, control_size)
	push_descriptors_flush(&build.push[TREE_BUILD_SETUP], cmd, setup_pipeline.layout, frame)
	vulkan.CmdDispatch(cmd, groups, 1, 1)
	_tree_build_barrier(cmd, build.state_device.buffer, build.control_offset + control_size)
	_tree_build_barrier(cmd, build.orders_device.buffer, build.order_bytes * 2)

	// root
	pipeline_bind_compute(root_pipeline, cmd)
	root_push := Tree_Build_Root_Push{count = u32(count)}
	pipeline_push_constants(root_pipeline, cmd, &root_push, size_of(Tree_Build_Root_Push))
	push_descriptors_bind_buffer(&build.push[TREE_BUILD_ROOT], 0, 0, frame, build.state_device.buffer, build.nodes_offset, build.nodes_bytes)
	push_descriptors_bind_buffer(&build.push[TREE_BUILD_ROOT], 0, 1, frame, build.state_device.buffer, build.cells_offset, build.cells_bytes)
	push_descriptors_bind_buffer(&build.push[TREE_BUILD_ROOT], 0, 2, frame, build.state_device.buffer, build.control_offset, control_size)
	push_descriptors_flush(&build.push[TREE_BUILD_ROOT], cmd, root_pipeline.layout, frame)
	vulkan.CmdDispatch(cmd, 1, 1, 1)
	_tree_build_barrier(cmd, build.state_device.buffer, build.state_device.size)
	_tree_build_barrier(cmd, build.orders_device.buffer, build.order_bytes * 2)


	// level pass: one workgroup per cell per level, dispatched indirectly from
	// the counts the previous level wrote.
	pipeline_bind_compute(level_pipeline, cmd)
	push_descriptors_bind_buffer(&build.push[TREE_BUILD_LEVEL], 0, 0, frame, build.state_device.buffer, build.nodes_offset, build.nodes_bytes)
	push_descriptors_bind_buffer(&build.push[TREE_BUILD_LEVEL], 0, 1, frame, self.bodies_device.buffer, 0, self.bodies_device.size)
	push_descriptors_bind_buffer(&build.push[TREE_BUILD_LEVEL], 0, 2, frame, build.orders_device.buffer, build.order_a_offset, build.order_bytes)
	push_descriptors_bind_buffer(&build.push[TREE_BUILD_LEVEL], 0, 3, frame, build.orders_device.buffer, build.order_b_offset, build.order_bytes)
	push_descriptors_bind_buffer(&build.push[TREE_BUILD_LEVEL], 0, 4, frame, build.state_device.buffer, build.cells_offset, build.cells_bytes)
	push_descriptors_bind_buffer(&build.push[TREE_BUILD_LEVEL], 0, 5, frame, build.state_device.buffer, build.control_offset, control_size)
	push_descriptors_flush(&build.push[TREE_BUILD_LEVEL], cmd, level_pipeline.layout, frame)
	for d in 0 ..< levels {
		_tree_build_barrier(cmd, build.state_device.buffer, build.state_device.size)
		_tree_build_barrier(cmd, build.orders_device.buffer, build.order_bytes * 2)
		push := Tree_Build_Level_Push {
			level     = u32(d),
			src       = u32(d % 2),
			dst       = u32((d + 1) % 2),
			max_depth = u32(level_cap),
			capacity  = u32(tree.node_capacity),
			min_half  = min_half,
		}
		pipeline_push_constants(level_pipeline, cmd, &push, size_of(Tree_Build_Level_Push))
		_tree_build_dispatch_indirect(
					cmd,
					build.state_device.buffer,
					build.control_offset + vulkan.DeviceSize(offset_of(Tree_Build_Control, level_dispatch)),
					d,
				)
	}


	// COM pass, deepest level first: children are always one level below their
	// parent, so bottom-up order is descending level order.
	if levels > 0 {
		pipeline_bind_compute(com_pipeline, cmd)
		push_descriptors_bind_buffer(&build.push[TREE_BUILD_COM], 0, 0, frame, build.state_device.buffer, build.nodes_offset, build.nodes_bytes)
		push_descriptors_bind_buffer(&build.push[TREE_BUILD_COM], 0, 1, frame, self.bodies_device.buffer, 0, self.bodies_device.size)
		push_descriptors_bind_buffer(&build.push[TREE_BUILD_COM], 0, 2, frame, build.orders_device.buffer, build.order_a_offset, build.order_bytes)
		push_descriptors_bind_buffer(&build.push[TREE_BUILD_COM], 0, 3, frame, build.orders_device.buffer, build.order_b_offset, build.order_bytes)
		push_descriptors_bind_buffer(&build.push[TREE_BUILD_COM], 0, 4, frame, build.state_device.buffer, build.cells_offset, build.cells_bytes)
		push_descriptors_bind_buffer(&build.push[TREE_BUILD_COM], 0, 5, frame, build.state_device.buffer, build.control_offset, control_size)
		push_descriptors_flush(&build.push[TREE_BUILD_COM], cmd, com_pipeline.layout, frame)
		for i in 0 ..< levels {
			d := levels - 1 - i
			_tree_build_barrier(cmd, build.state_device.buffer, build.state_device.size)
			push := Tree_Build_Com_Push{level = u32(d)}
			pipeline_push_constants(com_pipeline, cmd, &push, size_of(Tree_Build_Com_Push))
			_tree_build_dispatch_indirect(
				cmd,
				build.state_device.buffer,
				build.control_offset + vulkan.DeviceSize(offset_of(Tree_Build_Control, com_dispatch)),
				d,
			)
		}
	}

	// Publish the order the traversal binds, whatever parity the last level wrote.
	pipeline_bind_compute(order_pipeline, cmd)
	order_push := Tree_Build_Order_Push{count = u32(count)}
	pipeline_push_constants(order_pipeline, cmd, &order_push, size_of(Tree_Build_Order_Push))
	push_descriptors_bind_buffer(&build.push[TREE_BUILD_ORDER], 0, 0, frame, build.orders_device.buffer, build.order_a_offset, build.order_bytes)
	push_descriptors_bind_buffer(&build.push[TREE_BUILD_ORDER], 0, 1, frame, build.orders_device.buffer, build.order_b_offset, build.order_bytes)
	push_descriptors_bind_buffer(&build.push[TREE_BUILD_ORDER], 0, 2, frame, self.tree.order_device.buffer, 0, self.tree.order_device.size)
	push_descriptors_bind_buffer(&build.push[TREE_BUILD_ORDER], 0, 3, frame, build.state_device.buffer, build.control_offset, control_size)
	push_descriptors_flush(&build.push[TREE_BUILD_ORDER], cmd, order_pipeline.layout, frame)
	vulkan.CmdDispatch(cmd, groups, 1, 1)

	// Control readback (metrics + overflow flag).
	buffer_barrier(
		cmd,
		build.state_device.buffer,
		build.control_offset,
		control_size,
		{.COMPUTE_SHADER},
		{.TRANSFER},
		{.SHADER_STORAGE_WRITE},
		{.TRANSFER_READ},
	)
	copy_region := vulkan.BufferCopy {
		srcOffset = build.control_offset,
		dstOffset = 0,
		size      = control_size,
	}
	vulkan.CmdCopyBuffer(cmd, build.state_device.buffer, build.state_host.buffer, 1, &copy_region)
	buffer_barrier(
		cmd,
		build.state_host.buffer,
		0,
		control_size,
		{.TRANSFER},
		{.HOST},
		{.TRANSFER_WRITE},
		{.HOST_READ},
	)

	value := compute_submit(&self.compute, slot)
	compute_wait(&self.compute, value)

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
