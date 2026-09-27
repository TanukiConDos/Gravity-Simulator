package graphic

import phys "../physic"
import ecs "../ecs"
import found "../../foundation"
import "core:log"
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
	bodies_host:       Buffer,
	bodies_device:     Buffer,
	velocities_host:   Buffer,
	velocities_device: Buffer,
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
	buffer_destroy(&self.velocities_host)
	buffer_destroy(&self.velocities_device)
	_gpu_tree_release(self)
	self.capacity = 0
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

	body_bytes := vulkan.DeviceSize(capacity * size_of(Gpu_Body_Record))
	velocity_bytes := vulkan.DeviceSize(capacity * size_of(Gpu_Velocity_Record))
	self.bodies_host = buffer_init(self.compute.gpu, body_bytes, {.TRANSFER_SRC}, .HostVisible) or_return
	self.bodies_device = buffer_init(
		self.compute.gpu,
		body_bytes,
		{.STORAGE_BUFFER, .TRANSFER_DST},
		.DeviceLocal,
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
	if self.mode == .OCTREE && !_gpu_tree_reserve(self, capacity) {return false}
	self.capacity = capacity
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

	// Pack: vec4(position, mass) and vec4(velocity). Mass is converted here so
	// the shader works with exactly the f32 value the CPU solver uses.
	view := phys.body_view(w)
	records := cast([^]Gpu_Body_Record)self.bodies_host.mapped
	velocities := cast([^]Gpu_Velocity_Record)self.velocities_host.mapped
	for k in 0 ..< count {
		entity := bodies[k]
		position := phys.Vec3(view.position[entity])
		velocity := phys.Vec3(view.velocity[entity])
		records[k] = {position.x, position.y, position.z, f32(view.mass[entity])}
		velocities[k] = {velocity.x, velocity.y, velocity.z, 0}
	}

	pipeline := pipeline_registry_get(&self.compute.pipelines, self.pipeline_id)
	cmd, slot := compute_begin(&self.compute)
	body_bytes := vulkan.DeviceSize(count * size_of(Gpu_Body_Record))
	velocity_bytes := vulkan.DeviceSize(count * size_of(Gpu_Velocity_Record))

	_gpu_upload(cmd, self.compute.gpu, &self.bodies_host, &self.bodies_device, body_bytes)
	_gpu_upload(
		cmd,
		self.compute.gpu,
		&self.velocities_host,
		&self.velocities_device,
		velocity_bytes,
		{.SHADER_STORAGE_READ, .SHADER_STORAGE_WRITE},
	)

	pipeline_bind_compute(pipeline, cmd)
	push := Gpu_Force_Push{body_count = u32(count), dt = f32(seconds)}
	pipeline_push_constants(pipeline, cmd, &push, size_of(Gpu_Force_Push))
	push_descriptors_bind_buffer(&self.push, 0, 0, u32(slot), self.bodies_device.buffer, 0, body_bytes)
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

	self.pending_value = compute_submit(&self.compute, slot)
	self.pending = true
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
