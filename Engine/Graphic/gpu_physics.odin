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

// The render view is vended as one of RENDER_VIEW_SETS device snapshots: a solve
// fills a FREE set while the renderer still reads another. Ownership moves
// through the state machine below; the solver only writes a set it acquired and
// only acquires one whose reader has completed, so no buffer is ever overwritten
// in flight.
RENDER_VIEW_SETS :: 3

// Render_Set_State is the per-set ownership state. Only the owning side performs
// the transition: the solver FREE -> WRITING -> PUBLISHED, the renderer
// PUBLISHED -> READING -> FREE. The solver also frees its previous PUBLISHED set
// back to FREE when the renderer did not claim it.
Render_Set_State :: enum(u32) {
	FREE,
	WRITING,
	PUBLISHED,
	READING,
}

// Gpu_Render_Set is one snapshot of the render columns. The host staging is
// shared between sets, so only the device buffers live here.
@(private)
Gpu_Render_Set :: struct {
	bodies_device:   Buffer,
	radii_device:    Buffer,
	selected_device: Buffer,
	live_device:     Buffer,
	// Ownership state (atomic Render_Set_State).
	state:           u32,
	// Frame timeline value whose completion frees this set: the frame that last
	// read it signals `release_value` on the renderer's frame timeline. The
	// solver reads the counter to avoid writing buffers a frame still reads.
	release_value:   u64,
	// How the set was described when it was published: the solve timeline value
	// that wrote its buffers and the live body count. Both are stored before the
	// state turns PUBLISHED, so a successful claim always reads a complete
	// description.
	published_value: u64,
	published_count: u32,
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
	// Published render-view snapshots. The renderer claims the PUBLISHED set and
	// reads it after waiting on the solve value; the solver only writes a set it
	// owns. Both queues touch the buffers, so they are created CONCURRENT.
	render_sets: [RENDER_VIEW_SETS]Gpu_Render_Set,
	render_ready: bool,
	render_mode:  u32,
	// Index of the last set the solver published; solver-private, -1 when none.
	// Used to free the previous PUBLISHED set unless the renderer claimed it.
	published_set: int,
	// The renderer's frame timeline. The vending protocol reads its counter to
	// tell whether the frame named by a set's `release_value` has completed; zero
	// in headless contexts (benches, tests), where sets are always reusable.
	frame_semaphore: vulkan.Semaphore,
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
// are the concrete handles of the claimed set (`set`), which stays READING until
// the renderer releases it.
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

// gpu_gravity_set_frame_timeline gives the solver the renderer's frame timeline.
// The vending protocol reads its counter to know when the frame that last read a
// set has completed. A headless solver has none.
gpu_gravity_set_frame_timeline :: proc(self: ^Gpu_Gravity, semaphore: vulkan.Semaphore) {
	if self == nil {return}
	self.frame_semaphore = semaphore
}

// gpu_gravity_solve_timeline is the timeline every solve signals (the renderer
// waits on it before reading a view). Exposed so a headless test can stand in a
// frame timeline and exercise the vending protocol.
gpu_gravity_solve_timeline :: proc(self: ^Gpu_Gravity) -> vulkan.Semaphore {
	if self == nil {return 0}
	return self.compute.timeline.semaphore
}

// gpu_gravity_render_view claims the PUBLISHED set for the renderer: CAS
// PUBLISHED -> READING and return a view naming that set's buffers and the solve
// value that wrote them. `ok` is false while no complete view is published (or
// another thread won the claim); the caller keeps whatever it already holds.
//
// Every set carries its own solve value and count, written before the state
// turns PUBLISHED, so a successful claim always describes one complete
// submission.
gpu_gravity_render_view :: proc(self: ^Gpu_Gravity) -> (view: Gpu_Render_View, ok: bool) {
	if self == nil || !self.render_ready {return {}, false}
	for i in 0 ..< RENDER_VIEW_SETS {
		set := &self.render_sets[i]
		expected := u32(Render_Set_State.PUBLISHED)
		_, claimed := sync.atomic_compare_exchange_strong(
			&set.state,
			expected,
			u32(Render_Set_State.READING),
		)
		if !claimed {continue}
		return Gpu_Render_View {
			bodies = set.bodies_device.buffer,
			radii = set.radii_device.buffer,
			selected = set.selected_device.buffer,
			live = set.live_device.buffer,
			mode = self.render_mode,
			count = int(sync.atomic_load(&set.published_count)),
			capacity = self.capacity,
			set = u32(i),
			value = sync.atomic_load(&set.published_value),
			semaphore = self.compute.timeline.semaphore,
		}, true
	}
	return {}, false
}

// gpu_gravity_release_render_view hands a claimed set back once the frame that
// read it has been submitted. `frame_value` is the value that frame signals on
// the frame timeline; the solver will not acquire the set until that frame
// completes. The release value is stored before the state turns FREE (release
// ordering) so a solver that observes FREE also observes the value.
gpu_gravity_release_render_view :: proc(self: ^Gpu_Gravity, view: Gpu_Render_View, frame_value: u64) {
	if self == nil {return}
	if int(view.set) < 0 || int(view.set) >= RENDER_VIEW_SETS {return}
	set := &self.render_sets[view.set]
	when ODIN_DEBUG {
		assert(
			sync.atomic_load(&set.state) == u32(Render_Set_State.READING),
			"released a render set the caller does not hold",
		)
	}
	sync.atomic_store(&set.release_value, frame_value)
	sync.atomic_store(&set.state, u32(Render_Set_State.FREE))
}

// gpu_gravity_render_set_state is a diagnostic: the vending state of one set.
gpu_gravity_render_set_state :: proc(self: ^Gpu_Gravity, index: int) -> Render_Set_State {
	assert(index >= 0 && index < RENDER_VIEW_SETS, "render set index out of range")
	return Render_Set_State(sync.atomic_load(&self.render_sets[index].state))
}

// _render_set_released reports whether the frame that last read a set has
// completed, so the solver may write it. A set that was never handed to a
// renderer (release_value == 0), or a headless solver with no frame timeline, is
// always reusable.
@(private)
_render_set_released :: proc(self: ^Gpu_Gravity, set: ^Gpu_Render_Set) -> bool {
	release := sync.atomic_load(&set.release_value)
	if release == 0 || self.frame_semaphore == 0 {return true}
	return semaphore_counter(self.compute.gpu.device, self.frame_semaphore) >= release
}

// _render_set_acquire claims a FREE set whose reader has completed. Returns -1
// when every set is held or still being read; the caller then skips publishing
// the render view rather than blocking the physics thread.
@(private)
_render_set_acquire :: proc(self: ^Gpu_Gravity) -> int {
	for i in 0 ..< RENDER_VIEW_SETS {
		set := &self.render_sets[i]
		if !_render_set_released(self, set) {continue}
		expected := u32(Render_Set_State.FREE)
		_, ok := sync.atomic_compare_exchange_strong(
			&set.state,
			expected,
			u32(Render_Set_State.WRITING),
		)
		if !ok {continue}
		// The assertion proves the write guard: a set is only taken once the
		// frame named by its release value has completed. The value cannot change
		// while the set is FREE, so the pre-check and this check agree.
		when ODIN_DEBUG {
			assert(
				_render_set_released(self, set),
				"acquired a render set whose release value is unsignalled",
			)
		}
		return i
	}
	return -1
}

// _render_set_publish makes a written set visible to the renderer and frees the
// set the solver published before it, unless the renderer claimed that one
// (READING sets are left alone; the renderer releases them itself).
@(private)
_render_set_publish :: proc(self: ^Gpu_Gravity, set_index: int, count: int, value: u64) {
	set := &self.render_sets[set_index]
	sync.atomic_store(&set.published_count, u32(count))
	sync.atomic_store(&set.published_value, value)
	sync.atomic_store(&set.state, u32(Render_Set_State.PUBLISHED))

	old := self.published_set
	self.published_set = set_index
	if old >= 0 && old != set_index {
		expected := u32(Render_Set_State.PUBLISHED)
		sync.atomic_compare_exchange_strong(
			&self.render_sets[old].state,
			expected,
			u32(Render_Set_State.FREE),
		)
	}
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
	self.published_set = -1

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
		sync.atomic_store(&set.state, u32(Render_Set_State.FREE))
		sync.atomic_store(&set.release_value, u64(0))
		sync.atomic_store(&set.published_value, u64(0))
		sync.atomic_store(&set.published_count, u32(0))
	}
	_gpu_tree_release(self)
	self.capacity = 0
	self.render_ready = false
	self.published_set = -1
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
	// Acquire a set for the render view; when none is free, still run the solve
	// (velocities/contacts) against the backend's working copy and skip the
	// render view this tick rather than block.
	set_index := _render_set_acquire(self)
	solve_bodies := set_index >= 0 ? &self.render_sets[set_index].bodies_device : &self.bodies_device
	body_bytes := vulkan.DeviceSize(count * size_of(Gpu_Body_Record))
	velocity_bytes := vulkan.DeviceSize(count * size_of(Gpu_Velocity_Record))
	pool_bytes := vulkan.DeviceSize((int(max_entity) + 1) * size_of(u32))
	live_bytes := vulkan.DeviceSize(count * size_of(u32))

	// The solve reads the set the renderer will read (or the working copy when the
	// view is skipped).
	_gpu_upload(cmd, self.compute.gpu, &self.bodies_host, solve_bodies, body_bytes)
	_gpu_upload(
		cmd,
		self.compute.gpu,
		&self.velocities_host,
		&self.velocities_device,
		velocity_bytes,
		{.SHADER_STORAGE_READ, .SHADER_STORAGE_WRITE},
	)
	if set_index >= 0 {
		set := &self.render_sets[set_index]
		_gpu_upload(cmd, self.compute.gpu, &self.radii_host, &set.radii_device, pool_bytes)
		_gpu_upload(cmd, self.compute.gpu, &self.selected_host, &set.selected_device, pool_bytes)
		_gpu_upload(cmd, self.compute.gpu, &self.live_host, &set.live_device, live_bytes)
	}

	pipeline_bind_compute(pipeline, cmd)
	push := Gpu_Force_Push{body_count = u32(count), dt = f32(seconds)}
	pipeline_push_constants(pipeline, cmd, &push, size_of(Gpu_Force_Push))
	push_descriptors_bind_buffer(&self.push, 0, 0, u32(slot), solve_bodies.buffer, 0, body_bytes)
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
	if set_index >= 0 {
		_render_set_publish(self, set_index, count, self.pending_value)
	}
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
