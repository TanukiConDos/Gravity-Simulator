package physics_gpu

import graphic "engine:graphics/front"
import gfx "engine:graphics/shared"
import physics "engine:physics"
import ecs "engine:ecs"
import "core:log"

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
// The body columns are uploaded every tick; the tree only changes when physics
// rebuilds it. `_gpu_tree_submit` dispatches without waiting; `_gpu_tree_finish`
// waits, scatters the velocities and appends the contacts (collision needs them
// before the narrow phase).

// Manifest job name (`engine/graphics/shader/manifest.odin`).
@(private)
GPU_TREE_SHADER :: "physics_tree"

// Must match the tree shader's local_size_x; used only to size the dispatch.
@(private)
GPU_TREE_WORKGROUP :: 128

// Must match the shader's binding order: nodes, order, bodies, radii, velocities,
// contacts.
@(private)
GPU_TREE_BINDINGS :: []u32 {0, 1, 2, 3, 4, 5}

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
	order_device:    gfx.Buffer,
	contacts_device: gfx.Buffer,
	contacts_host:   gfx.Buffer,
	node_capacity:   int,
	pair_capacity:   int,
	// Highest pair count already warned about this reserve. The list is bounded
	// by `pair_capacity`; warning on each new high-water in the upper half makes
	// the cliff visible without spamming the log every tick.
	pair_warn_level: int,
	// Metrics of the last successful build and the live body count it covers.
	info:            physics.Tree_Info,
	live_count:      int,
	valid:           bool,
	build:           Gpu_Tree_Build,
}

// _gpu_tree_reserve sizes the tree buffers from the body capacity. The node
// capacity matches the CPU arena bound (`count * 8 + 1024`), so any tree physics
// can build over that many bodies fits. The contact list is a fixed
// `max(count * 16 + 1024, 1024)` pairs; a dense cluster can outgrow it, which
// `_gpu_tree_finish` turns into a CPU fallback rather than a partial resolve.
@(private)
_gpu_tree_reserve :: proc(self: ^Gpu_Gravity, capacity: int) -> bool {
	node_capacity := capacity * 8 + 1024
	pair_capacity := max(capacity * 16 + 1024, 1024)
	self.tree.node_capacity = node_capacity
	self.tree.pair_capacity = pair_capacity
	self.tree.pair_warn_level = 0

	order_bytes := u64(capacity * size_of(u32))
	contact_bytes := u64(GPU_CONTACT_HEADER_SIZE + pair_capacity * size_of(Gpu_Contact_Pair))

	self.tree.order_device = graphic.compute_buffer_create(
		self.compute,
		order_bytes,
		{.STORAGE, .TRANSFER_SRC, .TRANSFER_DST},
		.DEVICE,
		.EXCLUSIVE,
	) or_return
	self.tree.contacts_device = graphic.compute_buffer_create(
		self.compute,
		contact_bytes,
		{.STORAGE, .TRANSFER_DST, .TRANSFER_SRC},
		.DEVICE,
		.EXCLUSIVE,
	) or_return
	self.tree.contacts_host = graphic.compute_buffer_create(self.compute, contact_bytes, {.TRANSFER_DST}, .HOST, .EXCLUSIVE) or_return
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
	graphic.compute_buffer_destroy(self.compute, &self.tree.order_device)
	graphic.compute_buffer_destroy(self.compute, &self.tree.contacts_device)
	graphic.compute_buffer_destroy(self.compute, &self.tree.contacts_host)
	_gpu_tree_build_release(self)
	self.tree.node_capacity = 0
	self.tree.pair_capacity = 0
	self.tree.pair_warn_level = 0
	self.tree.live_count = 0
	self.tree.valid = false
}

// _gpu_tree_pack_bodies writes the pool-indexed body columns (position, mass,
// velocity, radius, selection) plus the live list that maps the render slots to
// entities. Slot indices are entity indices; the traversal dispatch list is the
// tree's own `order`, built on the GPU.
@(private)
_gpu_tree_pack_bodies :: proc(self: ^Gpu_Gravity, w: ^ecs.World, bodies: []u32) {
	view := physics.body_view(w)
	records := cast([^]Gpu_Body_Record)self.bodies_host.mapped
	velocities := cast([^]Gpu_Velocity_Record)self.velocities_host.mapped
	radii := cast([^]f32)self.radii_host.mapped
	selected := cast([^]u32)self.selected_host.mapped
	live := cast([^]u32)self.live_host.mapped
	for k in 0 ..< len(bodies) {
		entity := bodies[k]
		assert(int(entity) < self.capacity, "tree body exceeds the reserved capacity")
		position := physics.Vec3(view.position[entity])
		velocity := physics.Vec3(view.velocity[entity])
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
			"[GPU PHYSICS] Tree covers %d bodies but %d are live; physics must rebuild",
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

	cmd := graphic.compute_begin(self.compute)

	// Reset the contact counter for this dispatch.
	graphic.compute_zero(self.compute, cmd, tree.contacts_device, 0, GPU_CONTACT_HEADER_SIZE)

	body_bytes := u64(copy_entries * size_of(Gpu_Body_Record))
	velocity_bytes := u64(copy_entries * size_of(Gpu_Velocity_Record))
	pool_bytes := u64(copy_entries * size_of(u32))
	live_bytes := u64(count * size_of(u32))
	// Acquire a set for the render view; when none is free, still run the solve
	// against the backend's working copy (the tree build's) and skip the render
	// view this tick rather than block. The traversal reads the set the renderer
	// will read, so its upload lives in the same submission.
	set_index := _render_set_acquire(self)
	solve_bodies: gfx.Buffer
	solve_radii: gfx.Buffer
	if set_index >= 0 {
		set := &self.render_sets[set_index]
		solve_bodies = set.bodies_device
		solve_radii = set.radii_device
	} else {
		solve_bodies = self.bodies_device
		solve_radii = self.radii_device
	}
	_gpu_upload(self, cmd, self.bodies_host, solve_bodies, body_bytes)
	_gpu_upload(self, cmd, self.velocities_host, self.velocities_device, velocity_bytes, write = true)
	_gpu_upload(self, cmd, self.radii_host, solve_radii, pool_bytes)
	if set_index >= 0 {
		set := &self.render_sets[set_index]
		_gpu_upload(self, cmd, self.selected_host, set.selected_device, pool_bytes)
		_gpu_upload(self, cmd, self.live_host, set.live_device, live_bytes)
	}

	push := Gpu_Tree_Push {
		live_count    = u32(count),
		theta         = physics.physics_state(w).theta,
		max_radius    = tree.info.max_radius,
		pair_capacity = u32(tree.pair_capacity),
		dt            = f32(seconds),
	}
	binds := [6]gfx.Bind {
		{binding = 0, buffer = tree.build.state_device, offset = tree.build.nodes_offset, size = tree.build.nodes_bytes},
		{binding = 1, buffer = tree.order_device, size = tree.order_device.size},
		{binding = 2, buffer = solve_bodies, size = solve_bodies.size},
		{binding = 3, buffer = solve_radii, size = solve_radii.size},
		{binding = 4, buffer = self.velocities_device, size = self.velocities_device.size},
		{binding = 5, buffer = tree.contacts_device, size = tree.contacts_device.size},
	}
	groups := u32((count + GPU_TREE_WORKGROUP - 1) / GPU_TREE_WORKGROUP)
	graphic.compute_pass(
		self.compute,
		cmd,
		self.pipeline,
		binds[:],
		{groups = {groups, 1, 1}},
		&push,
		size_of(Gpu_Tree_Push),
	)
	graphic.compute_readback(self.compute, cmd, self.velocities_device, 0, self.velocities_host, 0, velocity_bytes)
	// Only the contact count; `_gpu_tree_finish` copies the pairs themselves
	// when there are any. Copying the pre-allocated region here would move
	// `pair_capacity * 8` bytes every solve (≈13 MB at 100k bodies) for a list
	// that is usually empty.
	graphic.compute_readback(self.compute, cmd, tree.contacts_device, 0, tree.contacts_host, 0, GPU_CONTACT_HEADER_SIZE)

	self.pending_value = graphic.compute_submit(self.compute, cmd)
	self.pending = true
	if set_index >= 0 {
		_render_set_publish(self, set_index, count, self.pending_value)
	}
	return true
}

// _gpu_tree_read_pairs copies `count` contact pairs out of the device buffer.
// Runs as a second, tiny submission only when the solve produced contacts; the
// first submission copied the count. The device buffer still holds the pairs
// (its submission completed before this one was recorded), so the copy is
// fresh data.
@(private)
_gpu_tree_read_pairs :: proc(self: ^Gpu_Gravity, count: int) -> bool {
	bytes := u64(GPU_CONTACT_HEADER_SIZE + count * size_of(Gpu_Contact_Pair))
	cmd := graphic.compute_begin(self.compute)
	graphic.compute_readback(self.compute, cmd, self.tree.contacts_device, 0, self.tree.contacts_host, 0, bytes)
	value := graphic.compute_submit(self.compute, cmd)
	graphic.compute_wait(self.compute, value)
	return true
}

// _gpu_tree_finish waits for the dispatch and applies its results. The contact
// list is a fixed capacity: above half of it a warning names the count and the
// slot budget, and past it the solve fails before the pools are touched, so the
// caller can re-run the CPU tree. Scattering the GPU velocities first would
// double-apply the gravity update when the CPU solve writes them again.
@(private)
_gpu_tree_finish :: proc(
	self: ^Gpu_Gravity,
	w: ^ecs.World,
	bodies: []u32,
	contacts: ^[dynamic]physics.Contact,
) -> bool {
	captured := int((cast(^u32)self.tree.contacts_host.mapped)^)
	capacity := self.tree.pair_capacity
	if captured > capacity {
		log.errorf(
			"[GPU PHYSICS] Contact list overflow: %d pairs for %d bodies exceed the %d-slot capacity; falling back to the CPU octree",
			captured,
			len(bodies),
			capacity,
		)
		return false
	}
	// Warn as the list climbs into the upper half, once per new high-water, so a
	// dense cluster shows the cliff before it is hit without logging every tick.
	if captured * 2 > capacity && captured > self.tree.pair_warn_level {
		self.tree.pair_warn_level = captured
		log.warnf(
			"[GPU PHYSICS] Contact list at %d/%d slots (%d%%) for %d bodies; the fixed capacity falls back to the CPU octree when exceeded",
			captured,
			capacity,
			captured * 100 / capacity,
			len(bodies),
		)
	}
	if captured > 0 && !_gpu_tree_read_pairs(self, captured) {return false}

	vel := ecs.world_pool(w, physics.Velocity).data
	results := cast([^]Gpu_Velocity_Record)self.velocities_host.mapped
	for entity in bodies {
		record := results[entity]
		vel[entity] = physics.Velocity(physics.Vec3{record[0], record[1], record[2]})
	}

	pairs := cast([^]Gpu_Contact_Pair)(uintptr(self.tree.contacts_host.mapped) + GPU_CONTACT_HEADER_SIZE)
	for i in 0 ..< captured {
		pair := pairs[i]
		append(contacts, physics.Contact{a = pair[0], b = pair[1]})
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

	node_bytes := u64(node_count * size_of(Tree_Node))
	node_host, node_ok := graphic.compute_buffer_create(
		self.compute,
		node_bytes,
		{.TRANSFER_DST},
		.HOST,
		.EXCLUSIVE,
	)
	if !node_ok {return 0, 0, false}
	defer graphic.compute_buffer_destroy(self.compute, &node_host)

	order_bytes := u64(tree.live_count * size_of(u32))
	order_host, order_ok := graphic.compute_buffer_create(
		self.compute,
		order_bytes,
		{.TRANSFER_DST},
		.HOST,
		.EXCLUSIVE,
	)
	if !order_ok {return 0, 0, false}
	defer graphic.compute_buffer_destroy(self.compute, &order_host)

	cmd := graphic.compute_begin(self.compute)
	graphic.compute_readback(self.compute, cmd, tree.build.state_device, tree.build.nodes_offset, node_host, 0, node_bytes)
	graphic.compute_readback(self.compute, cmd, tree.order_device, 0, order_host, 0, order_bytes)
	value := graphic.compute_submit(self.compute, cmd)
	graphic.compute_wait(self.compute, value)

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
