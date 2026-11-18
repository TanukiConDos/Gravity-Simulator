package vk

import gfx "../shared"
import phys "../../physic"
import ecs "../../ecs"
import found "../../../foundation"
import "core:log"
import "core:sync"
import "core:time"
import "vendor:vulkan"

// Backend is the Vulkan side of the renderer: window surface, device, swapchain,
// pipelines, frame graph, compute and the optional GPU gravity solver. The front
// (`graphic`) builds one gfx.Frame_Packet per frame and calls backend_draw; every
// API call, barrier, fence and present stays here.
Backend :: struct {
	window:          ^Window,
	world:           ^ecs.World,
	gpu:             GPU,
	command_pool:    CommandPool,
	swapchain:       SwapChain,
	config:          Pipeline_Config,
	pipelines:       Pipeline_Registry,
	main_pipeline:   Pipeline_ID,
	frame_graph:     Frame_Graph,
	push:            Push_Descriptors,
	model:           Model,
	// Direct rendering (M5): when a GPU gravity backend owns the world, the
	// instance data is packed from its buffers and the frame waits on its
	// timeline. `direct_view` is resolved once per frame.
	gravity_source:  ^Gpu_Gravity,
	direct_pipeline: Pipeline_ID,
	direct_push:     Push_Descriptors,
	direct_valid:    bool,
	direct_view:     Gpu_Render_View,
	// Frame value the currently held set was last read at. When a newer view is
	// claimed, the previous set is released with this value so the solver waits
	// for that frame before reusing it.
	direct_release_value: u64,
	direct_logged:   bool,
	direct_verified: bool,
	direct_count:    int,
	// Signals every submitted frame so the solver can keep its render columns
	// stable while this thread reads them (the reverse of the frame's wait on
	// the solver's timeline).
	frame_timeline:  Timeline,
	instances:       InstanceBuffer,
	// The packet being recorded, so the frame-graph callbacks can reach this
	// frame's camera and instance columns.
	packet:          ^gfx.Frame_Packet,
	// Debug-only reference columns for _backend_verify_direct. The front owns the
	// live columns, so the backend keeps a private copy claimed through the same
	// snapshot handoff.
	verify_positions: [dynamic]Vec3,
	verify_selected:  [dynamic]u8,
	// The pick ID is a transient owned by the frame graph; the backend only owns
	// the readback buffers and the state used to resolve them.
	frame_color:     Render_Target,
	pick_readback:   [MAX_FRAMES_IN_FLIGHT]Buffer,
	pick_pending:    [MAX_FRAMES_IN_FLIGHT]bool,
	current_frame:   u32,
}

// backend_init creates the whole Vulkan side for a window and a world. The world
// is only read (body count for buffers, snapshot for the direct-mode debug
// check); the front keeps ownership of the camera and pick policy.
backend_init :: proc(window: ^Window, world: ^ecs.World) -> (result: ^Backend, ok: bool) {
	self := new(Backend)
	committed := false
	defer if !committed {backend_destroy(self)}

	self.window = window
	self.world = world
	log.infof("========================================")
	log.infof("[VULKAN] BACKEND INITIALIZATION START")
	log.infof("========================================")
	self.gpu = gpu_init(window) or_return
	self.command_pool = command_pool_init(&self.gpu) or_return
	self.swapchain = swapchain_init(&self.gpu, window) or_return
	self.config = renderer_pipeline_config()
	self.pipelines = pipeline_registry_init(&self.gpu)
	color_formats := [2]vulkan.Format{self.swapchain.image_format, PICK_COLOR_FORMAT}
	self.main_pipeline = pipeline_registry_add(&self.pipelines, "main", self.config, color_formats[:], self.swapchain.depth_format) or_return
	_backend_create_pick_resources(self) or_return
	self.model = model_init(&self.gpu, &self.command_pool, 30, 30) or_return
	self.push = push_descriptors_init(&self.gpu, RENDERER_PUSH_BINDINGS[:]) or_return
	if !push_descriptors_validate(&self.push, pipeline_registry_get(&self.pipelines, self.main_pipeline)) {return nil, false}
	self.frame_timeline = timeline_init(&self.gpu) or_return
	_backend_init_direct(self) or_return
	self.instances = instance_buffer_init(&self.gpu)
	obj_count := phys.body_count(world)
	if obj_count > 0 {
		self.verify_positions = make([dynamic]Vec3, obj_count)
		self.verify_selected = make([dynamic]u8, obj_count)
	}
	self.frame_graph = frame_graph_load(&self.gpu, FRAME_GRAPH_PATH, &self.pipelines) or_return
	self.frame_graph.resolve = _backend_resolve_import
	self.frame_graph.resolve_user = self
	self.frame_graph.record = _backend_record_pass
	self.frame_graph.record_user = self
	log.infof("========================================")
	log.infof("[VULKAN] BACKEND INITIALIZATION COMPLETE (%d objects)", obj_count)
	log.infof("========================================")
	committed = true
	return self, true
}

backend_destroy :: proc(self: ^Backend) {
	if self == nil {return}
	log.infof("[VULKAN] Backend shutdown...")
	gpu_wait(&self.gpu)
	timeline_destroy(&self.frame_timeline)
	model_destroy(&self.model); push_descriptors_destroy(&self.push)
	push_descriptors_destroy(&self.direct_push)
	instance_buffer_destroy(&self.instances)
	delete(self.verify_positions); delete(self.verify_selected)
	_backend_destroy_pick_resources(self)
	frame_graph_destroy(&self.frame_graph)
	pipeline_registry_destroy(&self.pipelines); swapchain_destroy(&self.swapchain); command_pool_destroy(&self.command_pool); gpu_destroy(&self.gpu)
	free(self)
	log.infof("[VULKAN] Backend shutdown complete")
}

// backend_set_gravity_source lets the backend draw straight from a GPU solver's
// buffers instead of the front's instance columns. Call it before the
// simulation threads start; without it the backend uploads the CPU columns.
backend_set_gravity_source :: proc(self: ^Backend, solver: ^Gpu_Gravity) {
	self.gravity_source = solver
	if solver != nil {
		// The solver reads this timeline's counter to tell when a vended set's
		// reader has completed.
		gpu_gravity_set_frame_timeline(solver, self.frame_timeline.semaphore)
	}
}

// backend_instances_seed fills the static instance columns (radius, selection)
// once. The front decides which bodies are drawn; the backend owns the packed
// vertex layout and the GPU buffers.
backend_instances_seed :: proc(self: ^Backend, view: phys.Bodies) {
	if self == nil {return}
	instance_buffer_write_static(&self.instances, view)
}

// backend_instance_mode tells the front whether this frame's instance data comes
// from its CPU columns (CPU) or from the GPU solver's buffers (BACKEND). The
// liveness check mirrors backend_draw's, so a solver uninstalled between frames
// drops the front straight back to the snapshot instead of skipping one frame.
// The read is graphics-thread only, like every field of the frame path.
backend_instance_mode :: proc(self: ^Backend) -> gfx.Instance_Mode {
	if self != nil && self.direct_valid && _backend_gravity_backend_active(self) {return .BACKEND}
	return .CPU
}

// backend_draw runs one frame: resize/acquire, pick resolution, the optional
// direct instance pack, the frame graph, submit and present. A RETRY result
// means no frame slot was consumed; the caller keeps its state and calls again.
backend_draw :: proc(
	self: ^Backend,
	packet: ^gfx.Frame_Packet,
) -> (
	status: gfx.Frame_Status,
	result: gfx.Frame_Result,
) {
	if self == nil || packet == nil {return .FATAL, result}
	self.packet = packet
	defer {self.packet = nil}

	if sync.atomic_load(&self.window.framebuffer_resized) {
		sync.atomic_store(&self.window.framebuffer_resized, false)
		if !_backend_recreate_if_possible(self) {return .FATAL, result}
		return .RETRY, result
	}

	_backend_pick_resolve_ready(self, &result)

	frame := self.current_frame
	{
		found.profile_scope("graphics.wait_frame")
		swapchain_wait_for_frame(&self.swapchain, frame)
	}
	_backend_pick_resolve_slot(self, frame, &result)
	_backend_verify_direct(self, frame)

	recreate := false
	acquire_result: vulkan.Result
	image_idx: u32
	{
		found.profile_scope("graphics.acquire")
		acquire_result, image_idx = swapchain_acquire_next(&self.swapchain, frame)
	}
	if acquire_result == .ERROR_OUT_OF_DATE_KHR {
		if !_backend_recreate_if_possible(self) {return .FATAL, result}
		return .RETRY, result
	} else if acquire_result != .SUCCESS && acquire_result != .SUBOPTIMAL_KHR {
		log.errorf("[VULKAN] Failed to acquire swapchain image!")
		return .FATAL, result
	} else if acquire_result == .SUBOPTIMAL_KHR {
		recreate = true
	}
	found.profile_mark("graphics.acquired", "frame=%d image=%d", {frame, image_idx})

	// Resolve the direct-rendering view once for this frame; the draw and the
	// submit both need it. A view stays READING until a newer one is claimed, so
	// the solver cannot overwrite what this frame reads even across frames.
	//
	// Sample the backend-active signal first. If physic dropped the hook on a
	// mid-run failure, the held set is stale and must be released so the draw
	// returns to the snapshot (physics has re-enabled publishing as part of the
	// same uninstall).
	backend_active := _backend_gravity_backend_active(self)
	if self.direct_valid && !backend_active {
		gpu_gravity_release_render_view(self.gravity_source, self.direct_view, self.direct_release_value)
		self.direct_valid = false
		self.direct_logged = false
		log.warnf("[RENDER] GPU gravity backend uninstalled; falling back to the snapshot path")
	}
	if backend_active {
		if view, ok := gpu_gravity_render_view(self.gravity_source); ok {
			if self.direct_valid {
				// Hand the set we were holding back now that a newer one is claimed.
				// `direct_release_value` is the frame that last read it.
				gpu_gravity_release_render_view(self.gravity_source, self.direct_view, self.direct_release_value)
			}
			self.direct_view = view
			self.direct_valid = true
			if !self.direct_logged {
				self.direct_logged = true
				log.infof(
					"[RENDER] Direct instances enabled: %d bodies (mode %d, set %d) from the GPU solver",
					view.count,
					view.mode,
					view.set,
				)
			}
		}
	}

	swapchain_prepare_frame(&self.swapchain, frame, image_idx)
	command_pool_reset(&self.command_pool, frame)
	command_buffer := command_pool_begin(&self.command_pool, frame)
	self.frame_color = swapchain_color_target(&self.swapchain, image_idx)
	fg_set_pass_enabled(&self.frame_graph, "pick_copy", packet.pick.requested)
	// The instance pack is compute, so it must be recorded before the render
	// pass begins; the main pass then binds the buffer it wrote.
	if self.direct_valid {
		found.profile_scope_args("graphics.instance_pack", "n=%d", {self.direct_view.count})
		self.direct_count = _backend_pack_instances(self, command_buffer, frame)
	}
	{
		found.profile_scope_args("graphics.framegraph", "frame=%d", {frame})
		if !frame_graph_execute(&self.frame_graph, command_buffer, frame, self.swapchain.extent) {
			log.errorf("[FG] Frame graph execution failed")
			return .FATAL, result
		}
	}
	command_pool_end(&self.command_pool, command_buffer)

	submit_result: vulkan.Result
	frame_value := timeline_next(&self.frame_timeline)
	{
		found.profile_scope("graphics.submit")
		wait_semaphore: vulkan.Semaphore
		wait_value: u64
		if self.direct_valid {
			wait_semaphore = self.direct_view.semaphore
			wait_value = self.direct_view.value
		}
		submit_result = swapchain_submit(
			&self.swapchain,
			command_buffer,
			frame,
			image_idx,
			wait_semaphore,
			wait_value,
			self.frame_timeline.semaphore,
			frame_value,
		)
	}
	if submit_result != .SUCCESS {
		log.errorf("[VULKAN] Failed to submit frame!")
		return .FATAL, result
	}
	// The frame that just read the held set keeps it busy until it completes; on
	// the next claim the set is released with this value so the solver waits.
	if self.direct_valid && self.gravity_source != nil {
		self.direct_release_value = frame_value
	}

	present_result: vulkan.Result
	{
		found.profile_scope("graphics.present")
		present_result = swapchain_present(&self.swapchain, frame, image_idx)
	}
	if present_result == .ERROR_OUT_OF_DATE_KHR || present_result == .SUBOPTIMAL_KHR {
		recreate = true
	} else if present_result != .SUCCESS {
		log.errorf("[VULKAN] Failed to present!")
		return .FATAL, result
	}
	if sync.atomic_load(&self.window.framebuffer_resized) {recreate = true}

	if recreate {
		found.profile_mark("graphics.recreate", "frame=%d", {frame})
		sync.atomic_store(&self.window.framebuffer_resized, false)
		if !_backend_recreate_if_possible(self) {return .FATAL, result}
	}

	self.current_frame = (self.current_frame + 1) % MAX_FRAMES_IN_FLIGHT
	return .OK, result
}

// _backend_gravity_backend_active mirrors physic's liveness signal. A backend
// that fails mid-run is uninstalled on the physics thread, so the backend must
// stop drawing its (now stale) buffers and return to the snapshot path. The
// lookup is one atomic load.
@(private)
_backend_gravity_backend_active :: proc(self: ^Backend) -> bool {
	if self.world == nil {return false}
	return phys.physic_gravity_backend_active(self.world)
}

// _backend_init_direct creates the instance pack pipeline. It runs on the
// graphics queue inside the frame command buffer, so it needs no compute
// context of its own.
@(private)
_backend_init_direct :: proc(self: ^Backend) -> bool {
	pipeline, built := pipeline_registry_add_compute(
		&self.pipelines,
		"instance_pack",
		Compute_Config{shaders = []Shader_Spec{{path = DIRECT_SHADER}}},
	)
	if !built {return false}
	self.direct_pipeline = pipeline
	self.direct_push = push_descriptors_init(&self.gpu, DIRECT_PUSH_BINDINGS[:]) or_return
	if !push_descriptors_validate(
		&self.direct_push,
		pipeline_registry_get(&self.pipelines, self.direct_pipeline),
	) {
		return false
	}
	return true
}

// One readback buffer per frame in flight. The pick ID itself is a transient
// owned by the frame graph; a zero value read back means "no hit".
@(private)
_backend_create_pick_resources :: proc(self: ^Backend) -> bool {
	for i in 0 ..< MAX_FRAMES_IN_FLIGHT {
		self.pick_readback[i] = buffer_init(&self.gpu, size_of(u32), {.TRANSFER_DST}, .HostVisible) or_return
	}
	return true
}

@(private)
_backend_destroy_pick_resources :: proc(self: ^Backend) {
	for i in 0 ..< MAX_FRAMES_IN_FLIGHT {
		buffer_destroy(&self.pick_readback[i])
		self.pick_pending[i] = false
	}
}

// Recreates the swapchain and, only if the attachment formats actually changed,
// rebuilds the pipeline. The pipeline no longer references the swapchain, so a
// plain resize reuses it as-is. The camera aspect is not touched here: the front
// keeps it in sync from the framebuffer snapshot.
@(private)
_backend_recreate_swapchain :: proc(self: ^Backend) -> bool {
	swapchain_recreate(&self.swapchain) or_return
	main := pipeline_registry_get(&self.pipelines, self.main_pipeline)
	format_changed := main.color_format != self.swapchain.image_format || main.depth_format != self.swapchain.depth_format
	if format_changed {
		pipeline_registry_destroy(&self.pipelines)
		self.pipelines = pipeline_registry_init(&self.gpu)
		color_formats := [2]vulkan.Format{self.swapchain.image_format, PICK_COLOR_FORMAT}
		self.main_pipeline = pipeline_registry_add(&self.pipelines, "main", self.config, color_formats[:], self.swapchain.depth_format) or_return
		push_descriptors_destroy(&self.direct_push)
		_backend_init_direct(self) or_return
	}
	_backend_destroy_pick_resources(self)
	_backend_create_pick_resources(self) or_return
	return true
}

// Rebuilding a 0x0 swapchain is invalid. GLFW only updates the framebuffer size
// while processing events on the main thread, so this waits for the main-thread
// snapshot to report a valid size (the graphics thread never queries GLFW) and
// lets the next frame retry while minimized. Returns false only on a fatal
// error.
@(private)
_backend_recreate_if_possible :: proc(self: ^Backend) -> bool {
	if !window_framebuffer_valid(self.window) {
		time.sleep(16 * time.Millisecond)
		return true
	}
	return _backend_recreate_swapchain(self)
}

// Import resolver: maps the graph's external resource names to the targets and
// buffers that exist for the current frame.
@(private)
_backend_resolve_import :: proc(user: rawptr, name: string, frame: u32, out: ^Fg_Resolved) -> bool {
	self := cast(^Backend)user
	switch name {
	case "swapchain":
		out.target = self.frame_color
	case "depth":
		out.target = swapchain_depth_target(&self.swapchain, frame)^
	case "pick_readback":
		out.is_buffer = true
		out.buffer = self.pick_readback[frame].buffer
	case "camera":
		out.is_buffer = true
		out.buffer = push_descriptors_buffer(&self.push, CAMERA_SET, CAMERA_BINDING, frame)
	case:
		log.errorf("[FG] Unknown import %q", name)
		return false
	}
	return true
}

// Dispatch by pass name: the JSON owns the structure, this owns the draw calls.
@(private)
_backend_record_pass :: proc(user: rawptr, fg: ^Frame_Graph, pass: ^Fg_Pass, cmd: vulkan.CommandBuffer, frame: u32) {
	self := cast(^Backend)user
	switch pass.name {
	case "main":
		_backend_draw_main(self, cmd, frame, pass)
	case "pick_copy":
		_backend_copy_pick(self, fg, cmd, frame)
	case:
		log.errorf("[FG] No recording proc for pass %q", pass.name)
	}
}

@(private)
_backend_current_draw :: proc(self: ^Backend) -> ^gfx.Draw {
	if self.packet == nil || len(self.packet.draws) == 0 {return nil}
	return &self.packet.draws[0]
}

@(private)
_backend_draw_main :: proc(self: ^Backend, cmd: vulkan.CommandBuffer, frame: u32, pass: ^Fg_Pass) {
	pipeline := pipeline_registry_get(&self.pipelines, pass.pipeline)

	ubo := self.packet.camera
	push_descriptors_write(&self.push, CAMERA_SET, CAMERA_BINDING, frame, &ubo, size_of(gfx.Camera_Uniforms))

	valid := 0
	if self.direct_valid {
		valid = self.direct_count
	} else if draw := _backend_current_draw(self); draw != nil {
		if draw.material != pass.pipeline_name {
			log.errorf("[FG] Draw material %q does not match pass pipeline %q", draw.material, pass.pipeline_name)
		}
		n := len(draw.positions)
		if n > 0 {
			found.profile_scope_args("graphics.instances", "n=%d", {n})
			instance_buffer_update_positions(&self.instances, frame, draw.positions, draw.selected)
			valid = n
		}
	}
	found.profile_scope("graphics.push_descriptors")
	push_descriptors_flush(&self.push, cmd, pipeline.layout, frame)
	model_bind(&self.model, cmd, MESH_BINDING)
	instance_buffer_bind(&self.instances, cmd, frame, INSTANCE_BINDING)
	// Draw exactly the instances updated this frame; drawing more would reuse
	// stale data in this frame's instance buffer.
	if valid > 0 {
		found.profile_scope_args("graphics.draw_indexed", "instances=%d", {valid})
		vulkan.CmdDrawIndexed(cmd, self.model.index_count, u32(valid), 0, 0, 0)
	}
}

// _backend_verify_direct is a one-shot debug check that the pack shader indexed
// the live bodies correctly. The previous frame that used this slot has
// completed (the fence above), so its instance data is readable.
//
// It runs on the graphics thread, which must not read the simulation pools: the
// physics thread writes `Selected` (and `Position`) concurrently. The reference
// is therefore the published `RenderSnapshot` — claimed through the same triple
// buffer the CPU path uses into the backend's private columns. The solver's
// render view and the snapshot are published at different points in the tick
// (the view is uploaded before `physic.integrate`, the snapshot after), so
// positions are only checked for finite, in-scale values; selection flags are
// static between picks, so they are compared when both name the same body
// count. The radius column is not part of the snapshot, so it is only checked
// for a sane value.
@(private)
_backend_verify_direct :: proc(self: ^Backend, frame: u32) {
	when ODIN_DEBUG {
		if !self.direct_valid || self.direct_verified || self.world == nil {return}
		count := min(self.direct_view.count, self.instances.capacity)
		instances := cast([^]InstanceData)self.instances.buffers[frame].mapped
		if count == 0 || instances == nil {return}
		self.direct_verified = true

		snapshot := phys.physic_snapshot(self.world)
		max_count := min(len(self.verify_positions), count)
		ref_count := phys.physic_snapshot_read(
			snapshot,
			raw_data(self.verify_positions),
			raw_data(self.verify_selected),
			max_count,
		)

		mismatches := 0
		sampled := min(count, 64)
		for i in 0 ..< sampled {
			// Positions come from the solver's last upload; they must at least
			// be finite and in the scene's scale (instance units).
			p := instances[i].position
			if p.x != p.x || p.y != p.y || p.z != p.z {mismatches += 1}
			if p.x * p.x + p.y * p.y + p.z * p.z > 1e12 {mismatches += 1}
			r := instances[i].radius
			if r != r || r <= 0 || r > 1e12 {mismatches += 1}
			// Selection is static between picks, so the snapshot is a valid
			// reference whenever it describes the same body count (the view may
			// otherwise lag the snapshot by a tick).
			if ref_count == count && i < ref_count {
				want_selected := self.verify_selected[i] > 0 ? i32(1) : i32(0)
				if instances[i].selected != want_selected {mismatches += 1}
			}
		}
		if mismatches == 0 {
			log.infof(
				"[RENDER] Direct instances verified against the snapshot: %d of %d sampled (%d bodies)",
				sampled,
				count,
				ref_count,
			)
		} else {
			log.errorf("[RENDER] Direct instance mismatch: %d of %d sampled", mismatches, sampled)
		}
	}
}

// _backend_pack_instances builds this frame's instance data on the GPU from the
// solver's published render set and returns the instance count. The frame
// submission waits on the solver's timeline, so the buffers are complete here.
@(private)
_backend_pack_instances :: proc(self: ^Backend, cmd: vulkan.CommandBuffer, frame: u32) -> int {
	view := &self.direct_view
	count := min(view.count, self.instances.capacity)
	if count <= 0 {return 0}
	assert(view.set < RENDER_VIEW_SETS, "direct view names an invalid render set")

	pipeline := pipeline_registry_get(&self.pipelines, self.direct_pipeline)
	pipeline_bind_compute(pipeline, cmd)
	push := Instance_Pack_Push{count = u32(count), mode = view.mode}
	pipeline_push_constants(pipeline, cmd, &push, size_of(Instance_Pack_Push))

	// Bodies are pool-indexed in octree mode, so their range must cover every
	// entity the live list can name: use the whole capacity for the pool-indexed
	// columns (bodies/radii/selected) and the live count for the slot-indexed
	// list.
	pool_range := vulkan.DeviceSize(view.capacity * size_of(u32))
	bodies_range := vulkan.DeviceSize(view.capacity * size_of(Gpu_Body_Record))
	live_range := vulkan.DeviceSize(count * size_of(u32))
	push_descriptors_bind_buffer(&self.direct_push, DIRECT_SET, DIRECT_BODIES_BINDING, frame, view.bodies, 0, bodies_range)
	push_descriptors_bind_buffer(&self.direct_push, DIRECT_SET, DIRECT_RADII_BINDING, frame, view.radii, 0, pool_range)
	push_descriptors_bind_buffer(&self.direct_push, DIRECT_SET, DIRECT_SELECTED_BINDING, frame, view.selected, 0, pool_range)
	push_descriptors_bind_buffer(&self.direct_push, DIRECT_SET, DIRECT_LIVE_BINDING, frame, view.live, 0, live_range)
	instances := &self.instances.buffers[frame]
	push_descriptors_bind_buffer(&self.direct_push, DIRECT_SET, DIRECT_INSTANCES_BINDING, frame, instances.buffer, 0, instances.size)
	push_descriptors_flush(&self.direct_push, cmd, pipeline.layout, frame)

	groups := u32((count + DIRECT_WORKGROUP - 1) / DIRECT_WORKGROUP)
	vulkan.CmdDispatch(cmd, groups, 1, 1)

	buffer_barrier(
		cmd,
		instances.buffer,
		0,
		instances.size,
		{.COMPUTE_SHADER},
		{.VERTEX_INPUT},
		{.SHADER_STORAGE_WRITE},
		{.VERTEX_ATTRIBUTE_READ},
	)
	return count
}

// Copies the one ID pixel under the cursor. The frame graph has already put the
// pick_id target in TRANSFER_SRC; the copy rides in the frame command buffer.
// The request itself is cleared by the front once this frame returns OK.
@(private)
_backend_copy_pick :: proc(self: ^Backend, fg: ^Frame_Graph, cmd: vulkan.CommandBuffer, frame: u32) {
	if self.packet == nil || self.world == nil || self.pick_pending[frame] {return}
	pick := self.packet.pick
	if !pick.requested {return}

	target := fg_texture(fg, "pick_id")
	if target == nil || target.image == 0 {return}
	x := u32(clamp(pick.u, 0, 1) * f32(target.extent.width - 1) + 0.5)
	y := u32(clamp(pick.v, 0, 1) * f32(target.extent.height - 1) + 0.5)

	region := vulkan.BufferImageCopy{
		bufferOffset     = 0,
		bufferRowLength   = 0,
		bufferImageHeight = 0,
		imageSubresource = vulkan.ImageSubresourceLayers {
			aspectMask = {.COLOR},
			mipLevel = 0,
			baseArrayLayer = 0,
			layerCount = 1,
		},
		imageOffset = vulkan.Offset3D{x = i32(x), y = i32(y), z = 0},
		imageExtent = vulkan.Extent3D{width = 1, height = 1, depth = 1},
	}
	vulkan.CmdCopyImageToBuffer(cmd, target.image, .TRANSFER_SRC_OPTIMAL, fg_buffer(fg, "pick_readback"), 1, &region)
	self.pick_pending[frame] = true
	log.debugf("[PICK] copy (%d, %d) slot=%d", x, y, frame)
}

// Reads a pending result. The caller must have ensured the slot's frame fence is
// signaled (the copy is part of that frame's submission). The result is returned
// to the front, which applies it to the simulation.
@(private)
_backend_pick_resolve_slot :: proc(self: ^Backend, frame: u32, result: ^gfx.Frame_Result) {
	if !self.pick_pending[frame] {return}
	id := (cast(^u32)self.pick_readback[frame].mapped)^
	result.picked = i32(-1)
	if id != 0 {result.picked = i32(id - 1)}
	result.has_pick = true
	self.pick_pending[frame] = false
	log.debugf("[PICK] slot %d instance %d", frame, result.picked)
}

// Non-blocking: resolves any slot whose frame has already completed, so a click
// is normally applied a frame later without ever stalling.
@(private)
_backend_pick_resolve_ready :: proc(self: ^Backend, result: ^gfx.Frame_Result) {
	for frame in 0 ..< MAX_FRAMES_IN_FLIGHT {
		if !self.pick_pending[frame] {continue}
		if vulkan.GetFenceStatus(self.gpu.device, self.swapchain.in_flight_fences[frame]) == .SUCCESS {
			_backend_pick_resolve_slot(self, u32(frame), result)
		}
	}
}
