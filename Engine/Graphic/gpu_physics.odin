package graphic

import phys "../physic"
import ecs "../ecs"
import found "../../foundation"
import "core:log"
import "core:sync"
import "vendor:vulkan"

// GPU gravity backends (M1/M2/M3 of docs/gpu_physics.md).
//
// `Gpu_Gravity` owns a compute context (attached to the renderer's device in the
// app, headless in the bench) plus shared staging for the body list and the
// velocities. Two pipelines implement the `physic.Gravity_Solver` hook:
//
//   - physics_brute.comp: all-pairs O(N^2) gravity (mode .BRUTE_FORCE).
//   - physics_tree.comp: Barnes-Hut traversal of the CPU-built octree with the
//     collision fold (mode .OCTREE, see gpu_tree.odin).
//
// Both apply the velocity update in compute (`vel += acc * dt`); physic keeps
// integration of positions and collision. A solve is split in two so the GPU
// work overlaps the CPU systems that do not consume it: `submit` records and
// dispatches without waiting, and `finish` waits, scatters the velocities and
// appends the contacts. The brute-force solve stays in flight across the
// collision pass (`finish_at_collision = false`); the tree solve feeds
// collision with its contacts and finishes before the narrow phase.

@(private)
GPU_GRAVITY_BRUTE_SHADER :: "Engine/Graphic/shader/physics_brute.spv"

// Must match the brute shader's local_size_x; used only to size the dispatch.
@(private)
GPU_GRAVITY_BRUTE_WORKGROUP :: 256

// The render view is published as one of RENDER_VIEW_SETS device snapshots, so
// a solve can fill one set while the renderer still reads another. S3a routes
// every upload and every read through one set (always index 0); the vending
// protocol that hands sets out is a later change.
RENDER_VIEW_SETS :: 3

// Gpu_Render_Set is one snapshot of the render columns. The host staging is
// shared between sets, so only the device buffers live here.
@(private)
Gpu_Render_Set :: struct {
	bodies_device:   Buffer,
	radii_device:    Buffer,
	selected_device: Buffer,
	live_device:     Buffer,
}

// Both records are vectors so they map to the shader's `vec4` with no padding.
@(private)
Gpu_Body_Record :: [4]f32 // position.xyz, mass
@(private)
Gpu_Velocity_Record :: [4]f32 // velocity.xyz, unused

@(private)
Gpu_Force_Push :: struct {
	body_count: u32,
	dt:         f32,
}

@(private)
GPU_BRUTE_BINDINGS :: []Push_Binding_Spec {
	{set = 0, binding = 0, descriptor = .STORAGE_BUFFER, external = true}, // bodies
	{set = 0, binding = 1, descriptor = .STORAGE_BUFFER, external = true}, // velocities
}

Gpu_Gravity :: struct {
	compute:     Compute,
	mode:        found.Algorithm,
	pipeline_id: Pipeline_ID,
	push:        Push_Descriptors,
	// Shared by both modes and sized for the body capacity. The brute backend
	// packs them densely; the tree backend indexes them by entity index.
	capacity:          int,
	// Host staging shared by both modes and the tree build. `bodies_device` and
	// `radii_device` are the GPU tree build's working copies; the solve and the
	// renderer read the published render set below instead.
	bodies_host:       Buffer,
	bodies_device:     Buffer,
	radii_device:      Buffer,
	velocities_host:   Buffer,
	velocities_device: Buffer,
	// Render columns staged on the host, then uploaded into the active render
	// set below. `bodies` is entity-indexed in tree mode and slot-packed in
	// brute mode; the rest is entity-indexed and `live` maps the draw slot to
	// the entity.
	radii_host:    Buffer,
	selected_host: Buffer,
	live_host:     Buffer,
	// Published render-view snapshots. The renderer reads the buffers of the set
	// named by `render_set` after waiting on `render_value`, so both queues touch
	// them: created CONCURRENT (compute writes, graphics reads).
	render_sets: [RENDER_VIEW_SETS]Gpu_Render_Set,
	render_ready: bool,
	render_mode:  u32,
	render_count: u32, // atomic
	render_set:   u32, // atomic; set index `render_count`/`render_value` describe
	render_value: u64, // atomic
	// Reverse dependency: the submission waits on the renderer's frame timeline
	// so a solve never overwrites columns a frame is still reading. Set by the
	// renderer ("consumer"); zero in headless contexts.
	consumer_semaphore: vulkan.Semaphore,
	consumer_value:     u64, // atomic
	// Submission in flight between `submit` and `finish`.
	pending:       bool,
	pending_value: u64,
	// Barnes-Hut only (mode == .OCTREE).
	tree: Gpu_Tree,
}

// gpu_gravity_init attaches the solver to the renderer's device so the two share
// one device (and later one set of body buffers). It refuses when compute
// aliases the graphics queue handle: the physics and render threads would share
// one queue and need host-side locking, which the CPU fallback handles better.
//
// `capacity` is the body/entity budget (world capacity or body count) the
// buffers are sized for. It must cover the run: growing later touches the device
// allocator, which is not thread-safe and belongs to the main thread before the
// simulation threads start.
gpu_gravity_init :: proc(
	renderer: ^Renderer,
	mode: found.Algorithm,
	capacity: int,
) -> (
	result: ^Gpu_Gravity,
	ok: bool,
) {
	if !renderer.gpu.has_compute || renderer.gpu.compute_queue_is_shared {
		log.warnf("[GPU PHYSICS] Renderer device has no separately usable compute queue")
		return nil, false
	}

	self := new(Gpu_Gravity)
	committed := false
	defer if !committed {gpu_gravity_destroy(self)}

	self.mode = mode
	self.compute.gpu = &renderer.gpu
	_compute_open(&self.compute) or_return
	_gpu_gravity_open(self) or_return
	if capacity > 0 {_gpu_gravity_reserve(self, capacity) or_return}

	log.infof("[GPU PHYSICS] %v solver ready on %s", mode, gpu_gravity_info(self).device_name)
	committed = true
	return self, true
}

// gpu_gravity_init_headless creates its own windowless device. Used by the bench
// and the tests; the app attaches to the renderer instead.
gpu_gravity_init_headless :: proc(mode: found.Algorithm, capacity: int) -> (result: ^Gpu_Gravity, ok: bool) {
	self := new(Gpu_Gravity)
	committed := false
	defer if !committed {gpu_gravity_destroy(self)}

	self.mode = mode
	self.compute.device = gpu_init_headless() or_return
	self.compute.gpu = &self.compute.device
	self.compute.owns_device = true
	_compute_open(&self.compute) or_return
	_gpu_gravity_open(self) or_return
	if capacity > 0 {_gpu_gravity_reserve(self, capacity) or_return}

	log.infof("[GPU PHYSICS] Headless %v solver ready on %s", mode, gpu_gravity_info(self).device_name)
	committed = true
	return self, true
}

gpu_gravity_destroy :: proc(self: ^Gpu_Gravity) {
	if self == nil {return}
	_gpu_gravity_close(self)
	_compute_close(&self.compute)
	if self.compute.owns_device {gpu_destroy(&self.compute.device)}
	free(self)
}

gpu_gravity_info :: proc(self: ^Gpu_Gravity) -> Compute_Info {
	return compute_info(&self.compute)
}

// Gpu_Render_View is the renderer's read-only view of the solver state. `value`
// is the timeline value (on `semaphore`) whose completion makes the buffers
// safe to read; nothing may read them before it has been waited on. The buffers
// are the concrete handles of the published set (`set`).
Gpu_Render_View :: struct {
	bodies:    vulkan.Buffer,
	radii:     vulkan.Buffer,
	selected:  vulkan.Buffer,
	live:      vulkan.Buffer,
	mode:      u32, // 0 = octree (`bodies` indexed by entity), 1 = brute (packed by slot)
	count:     int,
	// Entity/slot budget the buffers were sized for; descriptor ranges use it.
	capacity:  int,
	set:       u32, // render-view set the buffers belong to
	value:     u64,
	semaphore: vulkan.Semaphore,
}

// _gpu_render_set_index is the set a solve uploads into and the renderer reads.
// S3a always uses set 0; the vending protocol that hands out a free set replaces
// this.
@(private)
_gpu_render_set_index :: proc(self: ^Gpu_Gravity) -> int {
	return 0
}

// gpu_gravity_set_frame_sync tells the solver which frame value its next
// submission must wait for. The renderer calls it after submitting each frame;
// the semantics are "frames up to this value have finished reading the render
// view".
gpu_gravity_set_frame_sync :: proc(self: ^Gpu_Gravity, semaphore: vulkan.Semaphore, value: u64) {
	if self == nil {return}
	self.consumer_semaphore = semaphore
	sync.atomic_store(&self.consumer_value, value)
}

// gpu_gravity_render_view publishes the solver's buffers to the renderer thread.
// `ok` is false until a solve completed, and the (count, value) pair is read
// with a seqlock retry so it always describes a single submission.
gpu_gravity_render_view :: proc(self: ^Gpu_Gravity) -> (view: Gpu_Render_View, ok: bool) {
	if self == nil || !self.render_ready {return {}, false}
	for _ in 0 ..< 4 {
		value := sync.atomic_load(&self.render_value)
		count := int(sync.atomic_load(&self.render_count))
		set := int(sync.atomic_load(&self.render_set))
		if value != sync.atomic_load(&self.render_value) {continue}
		if value == 0 || count <= 0 {return {}, false}
		if set < 0 || set >= RENDER_VIEW_SETS {continue}
		buffers := &self.render_sets[set]
		return Gpu_Render_View {
			bodies = buffers.bodies_device.buffer,
			radii = buffers.radii_device.buffer,
			selected = buffers.selected_device.buffer,
			live = buffers.live_device.buffer,
			mode = self.render_mode,
			count = count,
			capacity = self.capacity,
			set = u32(set),
			value = value,
			semaphore = self.compute.timeline.semaphore,
		}, true
	}
	return {}, false
}

// gpu_gravity_backend wraps the solver for `physic.physic_set_gravity_solver`.
// The octree backend also builds its tree on the GPU, so physic never runs the
// CPU builder while it is installed.
gpu_gravity_backend :: proc(self: ^Gpu_Gravity) -> phys.Gravity_Solver {
	solver := phys.Gravity_Solver {
		user                = self,
		submit              = _gpu_gravity_submit,
		finish              = _gpu_gravity_finish,
		finish_at_collision = self.mode == .OCTREE,
	}
	if self.mode == .OCTREE {solver.build_tree = _gpu_gravity_build_tree}
	return solver
}

@(private)
_gpu_gravity_open :: proc(self: ^Gpu_Gravity) -> bool {
	committed := false
	defer if !committed {_gpu_gravity_close(self)}

	name: string
	shader: string
	bindings: []Push_Binding_Spec
	switch self.mode {
	case .BRUTE_FORCE:
		name = "physics_brute"
		shader = GPU_GRAVITY_BRUTE_SHADER
		bindings = GPU_BRUTE_BINDINGS
	case .OCTREE:
		name = "physics_tree"
		shader = GPU_TREE_SHADER
		bindings = GPU_TREE_BINDINGS
	}

	pipeline_id, built := pipeline_registry_add_compute(
		&self.compute.pipelines,
		name,
		Compute_Config{shaders = []Shader_Spec{{path = shader}}},
	)
	if !built {return false}
	self.pipeline_id = pipeline_id

	self.push = push_descriptors_init(self.compute.gpu, bindings) or_return
	pipeline := pipeline_registry_get(&self.compute.pipelines, self.pipeline_id)
	if !push_descriptors_validate(&self.push, pipeline) {return false}
	if self.mode == .OCTREE && !_gpu_tree_build_open(self) {return false}

	committed = true
	return true
}

@(private)
_gpu_gravity_close :: proc(self: ^Gpu_Gravity) {
	_gpu_gravity_release_buffers(self)
	_gpu_tree_build_close(self)
	push_descriptors_destroy(&self.push)
}

@(private)
_gpu_gravity_release_buffers :: proc(self: ^Gpu_Gravity) {
	buffer_destroy(&self.bodies_host)
	buffer_destroy(&self.bodies_device)
	buffer_destroy(&self.radii_device)
	buffer_destroy(&self.velocities_host)
	buffer_destroy(&self.velocities_device)
	buffer_destroy(&self.radii_host)
	buffer_destroy(&self.selected_host)
	buffer_destroy(&self.live_host)
	for &set in self.render_sets {
		buffer_destroy(&set.bodies_device)
		buffer_destroy(&set.radii_device)
		buffer_destroy(&set.selected_device)
		buffer_destroy(&set.live_device)
	}
	_gpu_tree_release(self)
	self.capacity = 0
	self.render_ready = false
	sync.atomic_store(&self.render_count, u32(0))
	sync.atomic_store(&self.render_set, u32(0))
	sync.atomic_store(&self.render_value, u64(0))
}

// _gpu_gravity_reserve grows the buffers to a power-of-two body count. The init
// path pre-reserves the world's capacity on the main thread; this runs again
// only if bodies are spawned at runtime, and it touches the device allocator,
// which must not race with renderer allocations.
@(private)
_gpu_gravity_reserve :: proc(self: ^Gpu_Gravity, count: int) -> bool {
	if count <= self.capacity {return true}

	capacity := max(count, 1024)
	power := 1
	for power < capacity {power <<= 1}
	capacity = power
	_gpu_gravity_release_buffers(self)

	// The render sets are written by compute and read by the graphics queue, so
	// they are shared across the two families (CONCURRENT). Everything else
	// stays EXCLUSIVE.
	families: [2]u32
	sharing: []u32
	if !self.compute.owns_device {
		graphics := self.compute.gpu.graphics_queue_family_index
		compute := self.compute.gpu.compute_queue_family_index
		if graphics != compute {
			families = {graphics, compute}
			sharing = families[:]
		}
	}

	body_bytes := vulkan.DeviceSize(capacity * size_of(Gpu_Body_Record))
	velocity_bytes := vulkan.DeviceSize(capacity * size_of(Gpu_Velocity_Record))
	scalar_bytes := vulkan.DeviceSize(capacity * size_of(u32))
	self.bodies_host = buffer_init(self.compute.gpu, body_bytes, {.TRANSFER_SRC}, .HostVisible) or_return
	self.bodies_device = buffer_init_shared(
		self.compute.gpu,
		body_bytes,
		{.STORAGE_BUFFER, .TRANSFER_DST},
		.DeviceLocal,
		sharing,
	) or_return
	self.radii_device = buffer_init_shared(
		self.compute.gpu,
		scalar_bytes,
		{.STORAGE_BUFFER, .TRANSFER_DST},
		.DeviceLocal,
		sharing,
	) or_return
	// The host velocity buffer is both the upload source and the readback
	// destination, so it needs both transfer usages.
	self.velocities_host = buffer_init(
		self.compute.gpu,
		velocity_bytes,
		{.TRANSFER_SRC, .TRANSFER_DST},
		.HostVisible,
	) or_return
	self.velocities_device = buffer_init(
		self.compute.gpu,
		velocity_bytes,
		{.STORAGE_BUFFER, .TRANSFER_DST, .TRANSFER_SRC},
		.DeviceLocal,
	) or_return
	self.radii_host = buffer_init(self.compute.gpu, scalar_bytes, {.TRANSFER_SRC}, .HostVisible) or_return
	self.selected_host = buffer_init(self.compute.gpu, scalar_bytes, {.TRANSFER_SRC}, .HostVisible) or_return
	self.live_host = buffer_init(self.compute.gpu, scalar_bytes, {.TRANSFER_SRC}, .HostVisible) or_return
	// One snapshot of the render columns per set, all shared across the two
	// queue families. Every set must be destroyed on release.
	for &set in self.render_sets {
		set.bodies_device = buffer_init_shared(
			self.compute.gpu,
			body_bytes,
			{.STORAGE_BUFFER, .TRANSFER_DST},
			.DeviceLocal,
			sharing,
		) or_return
		set.radii_device = buffer_init_shared(
			self.compute.gpu,
			scalar_bytes,
			{.STORAGE_BUFFER, .TRANSFER_DST},
			.DeviceLocal,
			sharing,
		) or_return
		set.selected_device = buffer_init_shared(
			self.compute.gpu,
			scalar_bytes,
			{.STORAGE_BUFFER, .TRANSFER_DST},
			.DeviceLocal,
			sharing,
		) or_return
		set.live_device = buffer_init_shared(
			self.compute.gpu,
			scalar_bytes,
			{.STORAGE_BUFFER, .TRANSFER_DST},
			.DeviceLocal,
			sharing,
		) or_return
	}
	if self.mode == .OCTREE && !_gpu_tree_reserve(self, capacity) {return false}
	self.capacity = capacity
	self.render_mode = self.mode == .OCTREE ? 0 : 1
	self.render_ready = true
	log.debugf(
		"[GPU PHYSICS] Buffers grown to %d bodies (%d KiB bodies, %d KiB velocities)",
		capacity,
		body_bytes / 1024,
		velocity_bytes / 1024,
	)
	return true
}

// _gpu_gravity_submit and _gpu_gravity_finish are the `physic.Gravity_Solver`
// hook: they dispatch to the backend selected by `mode`. The pools are only
// touched in `finish`, so a failed submission leaves the tick untouched.
@(private)
_gpu_gravity_submit :: proc(user: rawptr, w: ^ecs.World, bodies: []u32, seconds: f64) -> bool {
	self := cast(^Gpu_Gravity)user
	switch self.mode {
	case .BRUTE_FORCE:
		return _gpu_brute_submit(self, w, bodies, seconds)
	case .OCTREE:
		return _gpu_tree_submit(self, w, bodies, seconds)
	}
	return false
}

// _gpu_gravity_build_tree is the `physic` tree build hook: the tree the
// traversal consumes is built on the GPU (see gpu_tree_build.odin).
@(private)
_gpu_gravity_build_tree :: proc(
	user: rawptr,
	w: ^ecs.World,
	bodies: []u32,
	max_depth: int,
	min_half: f32,
) -> (
	info: phys.Tree_Info,
	ok: bool,
) {
	self := cast(^Gpu_Gravity)user
	return _gpu_tree_build(self, w, bodies, max_depth, min_half)
}

@(private)
_gpu_gravity_finish :: proc(
	user: rawptr,
	w: ^ecs.World,
	bodies: []u32,
	contacts: ^[dynamic]phys.Contact,
) -> bool {
	self := cast(^Gpu_Gravity)user
	if !self.pending {return true}
	self.pending = false
	compute_wait(&self.compute, self.pending_value)
	switch self.mode {
	case .BRUTE_FORCE:
		return _gpu_brute_finish(self, w, bodies)
	case .OCTREE:
		return _gpu_tree_finish(self, w, bodies, contacts)
	}
	return false
}

// Records a staging -> device copy with the barriers around it: the host write
// is made available to the transfer, and the transfer write to the compute
// stage. `dst_access` covers both reads and writes when the shader updates the
// buffer in place.
@(private)
_gpu_upload :: proc(
	cmd: vulkan.CommandBuffer,
	gpu: ^GPU,
	host: ^Buffer,
	device: ^Buffer,
	size: vulkan.DeviceSize,
	dst_access: vulkan.AccessFlags2 = {.SHADER_STORAGE_READ},
) {
	buffer_barrier(cmd, host.buffer, 0, size, {.HOST}, {.TRANSFER}, {.HOST_WRITE}, {.TRANSFER_READ})
	gpu_copy_buffer(gpu, host.buffer, device.buffer, size, cmd)
	buffer_barrier(cmd, device.buffer, 0, size, {.TRANSFER}, {.COMPUTE_SHADER}, {.TRANSFER_WRITE}, dst_access)
}

// _gpu_brute_submit packs, uploads, dispatches and submits the all-pairs solve.
// It returns before the GPU is done; `_gpu_brute_finish` waits and applies the
// velocities.
@(private)
_gpu_brute_submit :: proc(self: ^Gpu_Gravity, w: ^ecs.World, bodies: []u32, seconds: f64) -> bool {
	count := len(bodies)
	if count == 0 {return true}
	if count > self.capacity {
		log.errorf("[GPU PHYSICS] %d bodies exceed the reserved capacity %d", count, self.capacity)
		return false
	}

	// Pack: vec4(position, mass) and vec4(velocity), plus the render view
	// columns (radii/selection are entity-indexed, `live` maps slot to entity).
	view := phys.body_view(w)
	records := cast([^]Gpu_Body_Record)self.bodies_host.mapped
	velocities := cast([^]Gpu_Velocity_Record)self.velocities_host.mapped
	radii := cast([^]f32)self.radii_host.mapped
	selected := cast([^]u32)self.selected_host.mapped
	live := cast([^]u32)self.live_host.mapped
	max_entity: u32
	for k in 0 ..< count {
		entity := bodies[k]
		if entity > max_entity {max_entity = entity}
		position := phys.Vec3(view.position[entity])
		velocity := phys.Vec3(view.velocity[entity])
		records[k] = {position.x, position.y, position.z, f32(view.mass[entity])}
		velocities[k] = {velocity.x, velocity.y, velocity.z, 0}
		radii[entity] = f32(view.radius[entity])
		selected[entity] = bool(view.selected[entity]) ? 1 : 0
		live[k] = entity
	}

	pipeline := pipeline_registry_get(&self.compute.pipelines, self.pipeline_id)
	cmd, slot := compute_begin(&self.compute)
	set_index := _gpu_render_set_index(self)
	render_set := &self.render_sets[set_index]
	body_bytes := vulkan.DeviceSize(count * size_of(Gpu_Body_Record))
	velocity_bytes := vulkan.DeviceSize(count * size_of(Gpu_Velocity_Record))
	pool_bytes := vulkan.DeviceSize((int(max_entity) + 1) * size_of(u32))
	live_bytes := vulkan.DeviceSize(count * size_of(u32))

	// The solve and the renderer both read the published set's columns (the
	// tree build keeps its own working copies).
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
	push := Gpu_Force_Push{body_count = u32(count), dt = f32(seconds)}
	pipeline_push_constants(pipeline, cmd, &push, size_of(Gpu_Force_Push))
	push_descriptors_bind_buffer(&self.push, 0, 0, u32(slot), render_set.bodies_device.buffer, 0, body_bytes)
	push_descriptors_bind_buffer(&self.push, 0, 1, u32(slot), self.velocities_device.buffer, 0, velocity_bytes)
	push_descriptors_flush(&self.push, cmd, pipeline.layout, u32(slot))

	groups := u32((count + GPU_GRAVITY_BRUTE_WORKGROUP - 1) / GPU_GRAVITY_BRUTE_WORKGROUP)
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

@(private)
_gpu_brute_finish :: proc(self: ^Gpu_Gravity, w: ^ecs.World, bodies: []u32) -> bool {
	vel := ecs.world_pool(w, phys.Velocity).data
	results := cast([^]Gpu_Velocity_Record)self.velocities_host.mapped
	for k in 0 ..< len(bodies) {
		entity := bodies[k]
		record := results[k]
		vel[entity] = phys.Velocity(phys.Vec3{record[0], record[1], record[2]})
	}
	return true
}
