package graphic

import phys "../physic"
import ecs "../ecs"
import "core:log"
import "core:sync"
import "vendor:vulkan"

// GPU Barnes-Hut backend: the tree is built on the GPU (`tree_build.comp`, see
// `gpu_tree_build.odin`) and traversed by `physics_tree.comp`. Both stages
// reproduce the CPU builder/traversal's structure, so the physics matches the
// CPU path up to f32 rounding.
//
// The buffers are pool-indexed: entity indices address the body columns, taking
// the same shape the CPU traversal sees. The dispatch walks the tree's own
// permuted body list (`order`), so invocation `k` solves `order[k]`: neighbours
// in a warp sit in nearby leaves and the divergent traversal reuses cache lines.
// Leaf ranges resolve through the same array. Contacts come back in
// entity-index space, exactly like `_calc_force_collect` appends them, so the
// CPU sort and resolve path is unchanged. The kernel applies `vel += acc * dt`
// in place, so the backend owns velocity integration.
//
// The body columns are uploaded every tick; the tree only changes when physic
// rebuilds it. `_gpu_tree_submit` dispatches without waiting; `_gpu_tree_finish`
// waits, scatters the velocities and appends the contacts (collision needs them
// before the narrow phase).

@(private)
GPU_TREE_SHADER :: "Engine/Graphic/shader/physics_tree.spv"

// Must match the tree shader's local_size_x; used only to size the dispatch.
@(private)
GPU_TREE_WORKGROUP :: 128

// Must match the shader's binding order.
@(private)
GPU_TREE_BINDINGS :: []Push_Binding_Spec {
	{set = 0, binding = 0, descriptor = .STORAGE_BUFFER, external = true}, // nodes
	{set = 0, binding = 1, descriptor = .STORAGE_BUFFER, external = true}, // order
	{set = 0, binding = 2, descriptor = .STORAGE_BUFFER, external = true}, // bodies
	{set = 0, binding = 3, descriptor = .STORAGE_BUFFER, external = true}, // radii
	{set = 0, binding = 4, descriptor = .STORAGE_BUFFER, external = true}, // velocities
	{set = 0, binding = 5, descriptor = .STORAGE_BUFFER, external = true}, // contacts
}

// Node layout must match the build and traversal shaders' std430 `Node`: 16-byte
// vectors followed by scalars, 80 bytes per node.
@(private)
Tree_Node :: struct {
	center:      [3]f32,
	half_size:   f32,
	center_mass: [3]f32,
	mass:        f32,
	first_obj:   u32,
	obj_count:   u32,
	child_count: u32,
	depth:       u32,
	children:    [8]u32,
}

@(private)
Gpu_Contact_Pair :: [2]u32

// uint count + three padding u32s, so the pairs start 8-byte aligned.
@(private)
GPU_CONTACT_HEADER_SIZE :: 16

@(private)
Gpu_Tree_Push :: struct {
	live_count:    u32,
	theta:         f32,
	max_radius:    f32,
	pair_capacity: u32,
	dt:            f32,
}

// Tree_Leaf is one leaf of the built tree as `gpu_tree_dump` reads it back.
Tree_Leaf :: struct {
	depth:     int,
	center:    [3]f32,
	half_size: f32,
	first_obj: int,
	obj_count: int,
}

@(private)
Gpu_Tree :: struct {
	order_device:    Buffer,
	contacts_device: Buffer,
	contacts_host:   Buffer,
	node_capacity:   int,
	pair_capacity:   int,
	// Metrics of the last successful build and the live body count it covers.
	info:            phys.Tree_Info,
	live_count:      int,
	valid:           bool,
	build:           Gpu_Tree_Build,
}

// _gpu_tree_reserve sizes the tree buffers from the body capacity. The node
// capacity matches the CPU arena bound (`count * 8 + 1024`), so any tree physic
// can build over that many bodies fits.
@(private)
_gpu_tree_reserve :: proc(self: ^Gpu_Gravity, capacity: int) -> bool {
	node_capacity := capacity * 8 + 1024
	pair_capacity := max(capacity * 16 + 1024, 1024)
	self.tree.node_capacity = node_capacity
	self.tree.pair_capacity = pair_capacity

	order_bytes := vulkan.DeviceSize(capacity * size_of(u32))
	contact_bytes := vulkan.DeviceSize(GPU_CONTACT_HEADER_SIZE + pair_capacity * size_of(Gpu_Contact_Pair))

	gpu := self.compute.gpu
	self.tree.order_device = buffer_init(
		gpu,
		order_bytes,
		{.STORAGE_BUFFER, .TRANSFER_SRC, .TRANSFER_DST},
		.DeviceLocal,
	) or_return
	self.tree.contacts_device = buffer_init(
		gpu,
		contact_bytes,
		{.STORAGE_BUFFER, .TRANSFER_DST, .TRANSFER_SRC},
		.DeviceLocal,
	) or_return
	self.tree.contacts_host = buffer_init(gpu, contact_bytes, {.TRANSFER_DST}, .HostVisible) or_return
	if !_gpu_tree_build_reserve(self, capacity, node_capacity) {return false}
	self.tree.valid = false
	log.debugf(
		"[GPU PHYSICS] Tree buffers for %d bodies (%d nodes, %d contact slots)",
		capacity,
		node_capacity,
		pair_capacity,
	)
	return true
}

@(private)
_gpu_tree_release :: proc(self: ^Gpu_Gravity) {
	buffer_destroy(&self.tree.order_device)
	buffer_destroy(&self.tree.contacts_device)
	buffer_destroy(&self.tree.contacts_host)
	_gpu_tree_build_release(self)
	self.tree.node_capacity = 0
	self.tree.pair_capacity = 0
	self.tree.live_count = 0
	self.tree.valid = false
}

// _gpu_tree_pack_bodies writes the pool-indexed body columns (position, mass,
// velocity, radius, selection) plus the live list that maps the render slots to
// entities. Slot indices are entity indices; the traversal dispatch list is the
// tree's own `order`, built on the GPU.
@(private)
_gpu_tree_pack_bodies :: proc(self: ^Gpu_Gravity, w: ^ecs.World, bodies: []u32) {
	view := phys.body_view(w)
	records := cast([^]Gpu_Body_Record)self.bodies_host.mapped
	velocities := cast([^]Gpu_Velocity_Record)self.velocities_host.mapped
	radii := cast([^]f32)self.radii_host.mapped
	selected := cast([^]u32)self.selected_host.mapped
	live := cast([^]u32)self.live_host.mapped
	for k in 0 ..< len(bodies) {
		entity := bodies[k]
		assert(int(entity) < self.capacity, "tree body exceeds the reserved capacity")
		position := phys.Vec3(view.position[entity])
		velocity := phys.Vec3(view.velocity[entity])
		records[entity] = {position.x, position.y, position.z, f32(view.mass[entity])}
		velocities[entity] = {velocity.x, velocity.y, velocity.z, 0}
		radii[entity] = f32(view.radius[entity])
		selected[entity] = bool(view.selected[entity]) ? 1 : 0
		live[k] = entity
	}
}

// _gpu_tree_submit uploads the body columns and dispatches the traversal. It
// returns without waiting; the results stay in the device buffers until
// `_gpu_tree_finish`.
@(private)
_gpu_tree_submit :: proc(self: ^Gpu_Gravity, w: ^ecs.World, bodies: []u32, seconds: f64) -> bool {
	tree := &self.tree
	if !tree.valid {return false}
	count := len(bodies)
	if count == 0 {return true}
	if count != tree.live_count {
		log.errorf(
			"[GPU PHYSICS] Tree covers %d bodies but %d are live; physic must rebuild",
			tree.live_count,
			count,
		)
		return false
	}

	// The largest entity index the tree can reference this tick bounds the copy.
	max_entity: u32
	for entity in bodies {
		if entity > max_entity {max_entity = entity}
	}
	copy_entries := int(max_entity) + 1
	if copy_entries > self.capacity {
		log.errorf(
			"[GPU PHYSICS] Entity index %d exceeds the reserved capacity %d",
			max_entity,
			self.capacity,
		)
		return false
	}

	_gpu_tree_pack_bodies(self, w, bodies)

	pipeline := pipeline_registry_get(&self.compute.pipelines, self.pipeline_id)
	cmd, slot := compute_begin(&self.compute)

	// Reset the contact counter for this dispatch.
	vulkan.CmdFillBuffer(cmd, tree.contacts_device.buffer, 0, size_of(u32), 0)
	buffer_barrier(
		cmd,
		tree.contacts_device.buffer,
		0,
		GPU_CONTACT_HEADER_SIZE,
		{.TRANSFER},
		{.COMPUTE_SHADER},
		{.TRANSFER_WRITE},
		{.SHADER_READ, .SHADER_WRITE},
	)

	body_bytes := vulkan.DeviceSize(copy_entries * size_of(Gpu_Body_Record))
	velocity_bytes := vulkan.DeviceSize(copy_entries * size_of(Gpu_Velocity_Record))
	pool_bytes := vulkan.DeviceSize(copy_entries * size_of(u32))
	live_bytes := vulkan.DeviceSize(count * size_of(u32))
	// The traversal and the renderer both read the published set's columns (the
	// tree build keeps its own working copies).
	set_index := _gpu_render_set_index(self)
	render_set := &self.render_sets[set_index]
	_gpu_upload(cmd, self.compute.gpu, &self.bodies_host, &render_set.bodies_device, body_bytes)
	_gpu_upload(
		cmd,
		self.compute.gpu,
		&self.velocities_host,
		&self.velocities_device,
		velocity_bytes,
		{.SHADER_STORAGE_READ, .SHADER_STORAGE_WRITE},
	)
	_gpu_upload(cmd, self.compute.gpu, &self.radii_host, &render_set.radii_device, pool_bytes)
	_gpu_upload(cmd, self.compute.gpu, &self.selected_host, &render_set.selected_device, pool_bytes)
	_gpu_upload(cmd, self.compute.gpu, &self.live_host, &render_set.live_device, live_bytes)

	pipeline_bind_compute(pipeline, cmd)
	push := Gpu_Tree_Push {
		live_count    = u32(count),
		theta         = phys.physic_state(w).theta,
		max_radius    = tree.info.max_radius,
		pair_capacity = u32(tree.pair_capacity),
		dt            = f32(seconds),
	}
	pipeline_push_constants(pipeline, cmd, &push, size_of(Gpu_Tree_Push))
	push_descriptors_bind_buffer(&self.push, 0, 0, u32(slot), tree.build.state_device.buffer, tree.build.nodes_offset, tree.build.nodes_bytes)
	push_descriptors_bind_buffer(&self.push, 0, 1, u32(slot), tree.order_device.buffer, 0, tree.order_device.size)
	push_descriptors_bind_buffer(&self.push, 0, 2, u32(slot), render_set.bodies_device.buffer, 0, render_set.bodies_device.size)
	push_descriptors_bind_buffer(&self.push, 0, 3, u32(slot), render_set.radii_device.buffer, 0, render_set.radii_device.size)
	push_descriptors_bind_buffer(&self.push, 0, 4, u32(slot), self.velocities_device.buffer, 0, self.velocities_device.size)
	push_descriptors_bind_buffer(&self.push, 0, 5, u32(slot), tree.contacts_device.buffer, 0, tree.contacts_device.size)
	push_descriptors_flush(&self.push, cmd, pipeline.layout, u32(slot))

	groups := u32((count + GPU_TREE_WORKGROUP - 1) / GPU_TREE_WORKGROUP)
	vulkan.CmdDispatch(cmd, groups, 1, 1)

	buffer_barrier(
		cmd,
		self.velocities_device.buffer,
		0,
		velocity_bytes,
		{.COMPUTE_SHADER},
		{.TRANSFER},
		{.SHADER_STORAGE_WRITE},
		{.TRANSFER_READ},
	)
	gpu_copy_buffer(self.compute.gpu, self.velocities_device.buffer, self.velocities_host.buffer, velocity_bytes, cmd)
	buffer_barrier(
		cmd,
		self.velocities_host.buffer,
		0,
		velocity_bytes,
		{.TRANSFER},
		{.HOST},
		{.TRANSFER_WRITE},
		{.HOST_READ},
	)
	// Only the contact count; `_gpu_tree_finish` copies the pairs themselves
	// when there are any. Copying the pre-allocated region here would move
	// `pair_capacity * 8` bytes every solve (≈13 MB at 100k bodies) for a list
	// that is usually empty.
	buffer_barrier(
		cmd,
		tree.contacts_device.buffer,
		0,
		GPU_CONTACT_HEADER_SIZE,
		{.COMPUTE_SHADER},
		{.TRANSFER},
		{.SHADER_STORAGE_WRITE},
		{.TRANSFER_READ},
	)
	gpu_copy_buffer(
		self.compute.gpu,
		tree.contacts_device.buffer,
		tree.contacts_host.buffer,
		GPU_CONTACT_HEADER_SIZE,
		cmd,
	)
	buffer_barrier(
		cmd,
		tree.contacts_host.buffer,
		0,
		GPU_CONTACT_HEADER_SIZE,
		{.TRANSFER},
		{.HOST},
		{.TRANSFER_WRITE},
		{.HOST_READ},
	)

	self.pending_value = compute_submit(
		&self.compute,
		slot,
		self.consumer_semaphore,
		sync.atomic_load(&self.consumer_value),
	)
	self.pending = true
	// Publish for the renderer: the count and set first, then the value that
	// makes them (and the set's columns) safe to read.
	sync.atomic_store(&self.render_count, u32(count))
	sync.atomic_store(&self.render_set, u32(set_index))
	sync.atomic_store(&self.render_value, self.pending_value)
	return true
}

// _gpu_tree_read_pairs copies `count` contact pairs out of the device buffer.
// Runs as a second, tiny submission only when the solve produced contacts; the
// first submission copied the count. The device buffer still holds the pairs
// (its submission completed before this one was recorded), so the copy is
// fresh data.
@(private)
_gpu_tree_read_pairs :: proc(self: ^Gpu_Gravity, count: int) -> bool {
	bytes := vulkan.DeviceSize(GPU_CONTACT_HEADER_SIZE + count * size_of(Gpu_Contact_Pair))
	cmd, slot := compute_begin(&self.compute)
	buffer_barrier(
		cmd,
		self.tree.contacts_device.buffer,
		0,
		bytes,
		{.COMPUTE_SHADER},
		{.TRANSFER},
		{.SHADER_STORAGE_WRITE},
		{.TRANSFER_READ},
	)
	gpu_copy_buffer(
		self.compute.gpu,
		self.tree.contacts_device.buffer,
		self.tree.contacts_host.buffer,
		bytes,
		cmd,
	)
	buffer_barrier(
		cmd,
		self.tree.contacts_host.buffer,
		0,
		bytes,
		{.TRANSFER},
		{.HOST},
		{.TRANSFER_WRITE},
		{.HOST_READ},
	)
	value := compute_submit(&self.compute, slot)
	compute_wait(&self.compute, value)
	return true
}

// _gpu_tree_finish waits for the dispatch and applies its results. A contact
// list overflow fails before the pools are touched, so the caller can re-run
// the CPU tree: scattering the GPU velocities first would double-apply the
// gravity update when the CPU solve writes them again.
@(private)
_gpu_tree_finish :: proc(
	self: ^Gpu_Gravity,
	w: ^ecs.World,
	bodies: []u32,
	contacts: ^[dynamic]phys.Contact,
) -> bool {
	captured := int((cast(^u32)self.tree.contacts_host.mapped)^)
	if captured > self.tree.pair_capacity {
		log.errorf(
			"[GPU PHYSICS] Contact list overflow (%d > %d); falling back to the CPU octree",
			captured,
			self.tree.pair_capacity,
		)
		return false
	}
	if captured > 0 && !_gpu_tree_read_pairs(self, captured) {return false}

	vel := ecs.world_pool(w, phys.Velocity).data
	results := cast([^]Gpu_Velocity_Record)self.velocities_host.mapped
	for entity in bodies {
		record := results[entity]
		vel[entity] = phys.Velocity(phys.Vec3{record[0], record[1], record[2]})
	}

	pairs := cast([^]Gpu_Contact_Pair)(uintptr(self.tree.contacts_host.mapped) + GPU_CONTACT_HEADER_SIZE)
	for i in 0 ..< captured {
		pair := pairs[i]
		append(contacts, phys.Contact{a = pair[0], b = pair[1]})
	}
	return true
}

// gpu_tree_dump reads the built tree back for the bench and the parity tests:
// one `Tree_Leaf` per leaf (up to len(leaves)) and the permuted body list (up to
// len(order)). It allocates temporary readback buffers and submits its own work,
// so it is a diagnostic path: call it from the thread that owns the solver, not
// per tick.
gpu_tree_dump :: proc(
	self: ^Gpu_Gravity,
	leaves: []Tree_Leaf,
	order: []u32,
) -> (
	leaf_count: int,
	order_count: int,
	ok: bool,
) {
	tree := &self.tree
	if !tree.valid {return 0, 0, false}
	node_count := tree.info.node_count
	if node_count <= 0 {return 0, 0, false}

	node_bytes := vulkan.DeviceSize(node_count * size_of(Tree_Node))
	node_host, node_ok := buffer_init(self.compute.gpu, node_bytes, {.TRANSFER_DST}, .HostVisible)
	if !node_ok {return 0, 0, false}
	defer buffer_destroy(&node_host)

	order_bytes := vulkan.DeviceSize(tree.live_count * size_of(u32))
	order_host, order_ok := buffer_init(self.compute.gpu, order_bytes, {.TRANSFER_DST}, .HostVisible)
	if !order_ok {return 0, 0, false}
	defer buffer_destroy(&order_host)

	cmd, slot := compute_begin(&self.compute)
	buffer_barrier(
		cmd,
		tree.build.state_device.buffer,
		tree.build.nodes_offset,
		node_bytes,
		{.COMPUTE_SHADER},
		{.TRANSFER},
		{.SHADER_STORAGE_WRITE},
		{.TRANSFER_READ},
	)
	node_region := vulkan.BufferCopy {
		srcOffset = tree.build.nodes_offset,
		dstOffset = 0,
		size      = node_bytes,
	}
	vulkan.CmdCopyBuffer(cmd, tree.build.state_device.buffer, node_host.buffer, 1, &node_region)
	buffer_barrier(
		cmd,
		node_host.buffer,
		0,
		node_bytes,
		{.TRANSFER},
		{.HOST},
		{.TRANSFER_WRITE},
		{.HOST_READ},
	)
	buffer_barrier(
		cmd,
		tree.order_device.buffer,
		0,
		order_bytes,
		{.COMPUTE_SHADER},
		{.TRANSFER},
		{.SHADER_STORAGE_WRITE},
		{.TRANSFER_READ},
	)
	gpu_copy_buffer(self.compute.gpu, tree.order_device.buffer, order_host.buffer, order_bytes, cmd)
	buffer_barrier(
		cmd,
		order_host.buffer,
		0,
		order_bytes,
		{.TRANSFER},
		{.HOST},
		{.TRANSFER_WRITE},
		{.HOST_READ},
	)
	value := compute_submit(&self.compute, slot)
	compute_wait(&self.compute, value)

	nodes := cast([^]Tree_Node)node_host.mapped
	for i in 0 ..< node_count {
		if nodes[i].child_count != 0 {continue}
		if leaf_count >= len(leaves) {break}
		leaves[leaf_count] = Tree_Leaf {
			depth     = int(nodes[i].depth),
			center    = nodes[i].center,
			half_size = nodes[i].half_size,
			first_obj = int(nodes[i].first_obj),
			obj_count = int(nodes[i].obj_count),
		}
		leaf_count += 1
	}
	order_count = min(len(order), tree.live_count)
	source := cast([^]u32)order_host.mapped
	for i in 0 ..< order_count {order[i] = source[i]}
	return leaf_count, order_count, true
}
