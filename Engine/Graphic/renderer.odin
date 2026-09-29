package graphic

import phys "../physic"
import ecs "../ecs"
import found "../../foundation"
import "core:log"
import "core:sync"
import "core:time"
import "vendor:vulkan"

Renderer :: struct {
	window:          ^Window,
	gpu:             GPU,
	command_pool:    CommandPool,
	swapchain:       SwapChain,
	config:          Pipeline_Config,
	pipelines:       Pipeline_Registry,
	main_pipeline:   Pipeline_ID,
	frame_graph:     Frame_Graph,
	push:            Push_Descriptors,
	model:           Model,
	camera:          ^Camera,
	world:           ^ecs.World,
	snapshot:        ^phys.RenderSnapshot,
	// Direct rendering (M5): when a GPU gravity backend owns the world, the
	// instance data is packed from its buffers and the frame waits on its
	// timeline. `direct_view` is resolved once per frame.
	gravity_source:  ^Gpu_Gravity,
	direct_pipeline: Pipeline_ID,
	direct_push:     Push_Descriptors,
	direct_valid:    bool,
	direct_view:     Gpu_Render_View,
	direct_logged:   bool,
	direct_verified: bool,
	direct_count:    int,
	// Signals every submitted frame so the solver can keep its render columns
	// stable while this thread reads them (the reverse of the frame's wait on
	// the solver's timeline).
	frame_timeline:  Timeline,
	instances:       InstanceBuffer,
	positions:       [dynamic]Vec3,
	selected:        [dynamic]u8,
	// The pick ID is a transient owned by the frame graph; the renderer only owns
	// the readback buffers and the state used to resolve them.
	frame_color:     Render_Target,
	pick_readback:   [MAX_FRAMES_IN_FLIGHT]Buffer,
	pick_pending:    [MAX_FRAMES_IN_FLIGHT]bool,
	current_frame:   u32,
}

// Stored as a world resource so the RENDER-phase render system can reach the
// renderer without the scheduler carrying a context pointer. The renderer owns
// the underlying handle and clears this on destruction.
@(private)
Renderer_Ref :: struct {
	renderer: ^Renderer,
}

renderer_init :: proc(window: ^Window, world: ^ecs.World) -> (result: ^Renderer, ok: bool) {
	renderer := new(Renderer)
	committed := false
	defer if !committed {renderer_destroy(renderer)}

	renderer.window = window; renderer.world = world
	log.infof("========================================"); log.infof("[VULKAN] RENDERER INITIALIZATION START"); log.infof("========================================")
	renderer.gpu = gpu_init(window) or_return
	renderer.command_pool = command_pool_init(&renderer.gpu) or_return
	renderer.swapchain = swapchain_init(&renderer.gpu, window) or_return
	renderer.config = renderer_pipeline_config()
	renderer.pipelines = pipeline_registry_init(&renderer.gpu)
	color_formats := [2]vulkan.Format{renderer.swapchain.image_format, PICK_COLOR_FORMAT}
	renderer.main_pipeline = pipeline_registry_add(&renderer.pipelines, "main", renderer.config, color_formats[:], renderer.swapchain.depth_format) or_return
	_renderer_create_pick_resources(renderer) or_return
	renderer.model = model_init(&renderer.gpu, &renderer.command_pool, 30, 30) or_return
	renderer.camera = ecs.world_resource(world, Camera)
	renderer.camera^ = camera_create(&renderer.swapchain)
	ecs.world_resource(world, Window_Ref).window = window
	_ = ecs.world_resource(world, Pick_Request)
	renderer.push = push_descriptors_init(&renderer.gpu, RENDERER_PUSH_BINDINGS[:]) or_return
	if !push_descriptors_validate(&renderer.push, pipeline_registry_get(&renderer.pipelines, renderer.main_pipeline)) {return nil, false}
	renderer.frame_timeline = timeline_init(&renderer.gpu) or_return
	_renderer_init_direct(renderer) or_return
	renderer.instances = instance_buffer_init(&renderer.gpu)
	renderer.snapshot = phys.physic_snapshot(world)
	renderer.frame_graph = frame_graph_load(&renderer.gpu, FRAME_GRAPH_PATH, &renderer.pipelines) or_return
	renderer.frame_graph.resolve = _renderer_resolve_import
	renderer.frame_graph.resolve_user = renderer
	renderer.frame_graph.record = _renderer_record_pass
	renderer.frame_graph.record_user = renderer
	obj_count := phys.body_count(world)
	if obj_count > 0 {
		renderer.positions = make([dynamic]Vec3, obj_count)
		renderer.selected = make([dynamic]u8, obj_count)
		renderer_update_instances(renderer)
	}
	log.infof("========================================"); log.infof("[VULKAN] RENDERER INITIALIZATION COMPLETE (%d objects)", obj_count); log.infof("========================================")
	ecs.world_resource(world, Renderer_Ref).renderer = renderer
	committed = true
	result = renderer
	return result, true
}

// Registers the graphics systems. Input mutates the Camera resource, and render
// runs the frame; the dependency makes render read the camera already updated
// for this frame regardless of registration order.
graphic_register_systems :: proc(s: ^ecs.Scheduler) {
	input := ecs.scheduler_add(s, "graphic.input", .RENDER, input_system)
	ecs.scheduler_add(s, "graphic.render", .RENDER, renderer_system, after = {input})
}

// RENDER-phase system: draws one frame through the renderer resource. It returns
// false only on a fatal Vulkan error, which aborts the phase (and the app).
@(private)
renderer_system :: proc(w: ^ecs.World, delta_seconds: f32) -> bool {
	ref := ecs.world_resource(w, Renderer_Ref)
	if ref.renderer == nil {return true}
	return renderer_draw_frame(ref.renderer)
}

renderer_destroy :: proc(self: ^Renderer) {
	if self == nil {return}
	log.infof("[VULKAN] Renderer shutdown...")
	if self.world != nil {
		ref := ecs.world_resource(self.world, Renderer_Ref)
		ref.renderer = nil
	}
	gpu_wait(&self.gpu)
	timeline_destroy(&self.frame_timeline)
	model_destroy(&self.model); push_descriptors_destroy(&self.push)
	push_descriptors_destroy(&self.direct_push)
	instance_buffer_destroy(&self.instances)
	delete(self.positions); delete(self.selected)
	_renderer_destroy_pick_resources(self)
	frame_graph_destroy(&self.frame_graph)
	pipeline_registry_destroy(&self.pipelines); swapchain_destroy(&self.swapchain); command_pool_destroy(&self.command_pool); gpu_destroy(&self.gpu)
	free(self)
	log.infof("[VULKAN] Renderer shutdown complete")
}

// renderer_set_gravity_source gives the renderer the GPU solver whose buffers it
// should draw from. Call it before the simulation threads start; without it the
// renderer reads the CPU snapshot as before.
renderer_set_gravity_source :: proc(self: ^Renderer, solver: ^Gpu_Gravity) {
	self.gravity_source = solver
	if solver != nil {
		gpu_gravity_set_frame_sync(solver, self.frame_timeline.semaphore, 0)
	}
}

// _renderer_init_direct creates the instance pack pipeline. It runs on the
// graphics queue inside the frame command buffer, so it needs no compute
// context of its own.
@(private)
_renderer_init_direct :: proc(self: ^Renderer) -> bool {
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

@(private)
renderer_update_instances :: proc(self: ^Renderer) {
	if self.world != nil {
		instance_buffer_write_static(&self.instances, self.world)
	}
}

// One readback buffer per frame in flight. The pick ID itself is a transient
// owned by the frame graph; a zero value read back means "no hit".
@(private)
_renderer_create_pick_resources :: proc(self: ^Renderer) -> bool {
	for i in 0 ..< MAX_FRAMES_IN_FLIGHT {
		self.pick_readback[i] = buffer_init(&self.gpu, size_of(u32), {.TRANSFER_DST}, .HostVisible) or_return
	}
	return true
}

@(private)
_renderer_destroy_pick_resources :: proc(self: ^Renderer) {
	for i in 0 ..< MAX_FRAMES_IN_FLIGHT {
		buffer_destroy(&self.pick_readback[i])
		self.pick_pending[i] = false
	}
}

// Recreates the swapchain and, only if the attachment formats actually changed,
// rebuilds the pipeline. The pipeline no longer references the swapchain, so a
// plain resize reuses it as-is.
@(private)
_renderer_recreate_swapchain :: proc(self: ^Renderer) -> bool {
	swapchain_recreate(&self.swapchain) or_return
	main := pipeline_registry_get(&self.pipelines, self.main_pipeline)
	format_changed := main.color_format != self.swapchain.image_format || main.depth_format != self.swapchain.depth_format
	if format_changed {
		pipeline_registry_destroy(&self.pipelines)
		self.pipelines = pipeline_registry_init(&self.gpu)
		color_formats := [2]vulkan.Format{self.swapchain.image_format, PICK_COLOR_FORMAT}
		self.main_pipeline = pipeline_registry_add(&self.pipelines, "main", self.config, color_formats[:], self.swapchain.depth_format) or_return
		push_descriptors_destroy(&self.direct_push)
		_renderer_init_direct(self) or_return
	}
	_renderer_destroy_pick_resources(self)
	_renderer_create_pick_resources(self) or_return
	self.camera^ = camera_create(&self.swapchain)
	return true
}

// Rebuilding a 0x0 swapchain is invalid. GLFW only updates the framebuffer size
// while processing events on the main thread, so this waits for the main-thread
// snapshot to report a valid size (the graphics thread never queries GLFW) and
// lets the next frame retry while minimized. Returns false only on a fatal
// error.
@(private)
_renderer_recreate_if_possible :: proc(self: ^Renderer) -> bool {
	if !window_framebuffer_valid(self.window) {
		time.sleep(16 * time.Millisecond)
		return true
	}
	return _renderer_recreate_swapchain(self)
}

// Import resolver: maps the graph's external resource names to the targets and
// buffers that exist for the current frame.
@(private)
_renderer_resolve_import :: proc(user: rawptr, name: string, frame: u32, out: ^Fg_Resolved) -> bool {
	self := cast(^Renderer)user
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
_renderer_record_pass :: proc(user: rawptr, fg: ^Frame_Graph, pass: ^Fg_Pass, cmd: vulkan.CommandBuffer, frame: u32) {
	self := cast(^Renderer)user
	switch pass.name {
	case "main":
		_renderer_draw_main(self, cmd, frame, pass)
	case "pick_copy":
		_renderer_copy_pick(self, fg, cmd, frame)
	case:
		log.errorf("[FG] No recording proc for pass %q", pass.name)
	}
}

@(private)
_renderer_draw_main :: proc(self: ^Renderer, cmd: vulkan.CommandBuffer, frame: u32, pass: ^Fg_Pass) {
	pipeline := pipeline_registry_get(&self.pipelines, pass.pipeline)

	ubo: UniformBufferObject
	camera_transform(self.camera, &ubo)
	push_descriptors_write(&self.push, CAMERA_SET, CAMERA_BINDING, frame, &ubo, size_of(UniformBufferObject))

	valid := 0
	if self.direct_valid {
		valid = self.direct_count
	} else if self.world != nil && len(self.positions) > 0 {
		n: int
		{
			found.profile_scope_args("graphics.snapshot_read", "max=%d", {len(self.positions)})
			n = phys.physic_snapshot_read(
				self.snapshot,
				raw_data(self.positions),
				raw_data(self.selected),
				len(self.positions),
			)
		}
		if n > 0 {
			found.profile_scope_args("graphics.instances", "n=%d", {n})
			instance_buffer_update_positions(&self.instances, frame, self.positions[:n], self.selected[:n])
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

// _renderer_verify_direct is a one-shot debug check that the pack shader indexed
// the live bodies correctly. The previous frame that used this slot has
// completed (the fence above), so its instance data is readable, and the radius
// and selection flag are static per body.
@(private)
_renderer_verify_direct :: proc(self: ^Renderer, frame: u32) {
	when ODIN_DEBUG {
		if !self.direct_valid || self.direct_verified || self.world == nil {return}
		count := min(self.direct_view.count, self.instances.capacity)
		instances := cast([^]InstanceData)self.instances.buffers[frame].mapped
		if count == 0 || instances == nil {return}
		view := phys.body_view(self.world)
		mismatches := 0
		sampled := min(count, 64)
		for i in 0 ..< sampled {
			entity := view.bodies[i]
			want_radius := f32(view.radius[entity]) * INSTANCE_SCALE
			diff := instances[i].radius - want_radius
			if diff < 0 {diff = -diff}
			if diff > want_radius * 0.001 {mismatches += 1}
			want_selected := bool(view.selected[entity]) ? i32(1) : i32(0)
			if instances[i].selected != want_selected {mismatches += 1}
			// Positions come from the solver's last upload; they must at least
			// be finite and in the scene's scale (instance units).
			p := instances[i].position
			if p.x != p.x || p.y != p.y || p.z != p.z {mismatches += 1}
			if p.x * p.x + p.y * p.y + p.z * p.z > 1e12 {mismatches += 1}
		}
		self.direct_verified = true
		if mismatches == 0 {
			log.infof("[RENDER] Direct instances verified: %d of %d sampled", sampled, count)
		} else {
			log.errorf("[RENDER] Direct instance mismatch: %d of %d sampled", mismatches, sampled)
		}
	}
}

// _renderer_pack_instances builds this frame's instance data on the GPU from the
// solver's published buffers and returns the instance count. The frame
// submission waits on the solver's timeline, so the buffers are complete here.
@(private)
_renderer_pack_instances :: proc(self: ^Renderer, cmd: vulkan.CommandBuffer, frame: u32) -> int {
	view := &self.direct_view
	count := min(view.count, self.instances.capacity)
	if count <= 0 {return 0}

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
@(private)
_renderer_copy_pick :: proc(self: ^Renderer, fg: ^Frame_Graph, cmd: vulkan.CommandBuffer, frame: u32) {
	if self.world == nil || self.pick_pending[frame] {return}
	req := ecs.world_resource(self.world, Pick_Request)
	if !req.requested {return}
	req.requested = false

	target := fg_texture(fg, "pick_id")
	if target == nil || target.image == 0 {return}
	x := u32(clamp(req.u, 0, 1) * f32(target.extent.width - 1) + 0.5)
	y := u32(clamp(req.v, 0, 1) * f32(target.extent.height - 1) + 0.5)

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
// signaled (the copy is part of that frame's submission).
@(private)
_renderer_pick_resolve_slot :: proc(self: ^Renderer, frame: u32) {
	if !self.pick_pending[frame] {return}
	id := (cast(^u32)self.pick_readback[frame].mapped)^
	picked := i32(-1)
	if id != 0 {picked = i32(id - 1)}
	if self.world != nil {
		sel := phys.selection_state(self.world)
		sync.atomic_store(&sel.picked, picked)
	}
	self.pick_pending[frame] = false
	log.debugf("[PICK] slot %d instance %d", frame, picked)
}

// Non-blocking: resolves any slot whose frame has already completed, so a click
// is normally applied a frame later without ever stalling.
@(private)
_renderer_pick_resolve_ready :: proc(self: ^Renderer) {
	for frame in 0 ..< MAX_FRAMES_IN_FLIGHT {
		if !self.pick_pending[frame] {continue}
		if vulkan.GetFenceStatus(self.gpu.device, self.swapchain.in_flight_fences[frame]) == .SUCCESS {
			_renderer_pick_resolve_slot(self, u32(frame))
		}
	}
}

renderer_draw_frame :: proc(self: ^Renderer) -> bool {
	if sync.atomic_load(&self.window.framebuffer_resized) {
		sync.atomic_store(&self.window.framebuffer_resized, false)
		if !_renderer_recreate_if_possible(self) {return false}
		return true
	}

	_renderer_pick_resolve_ready(self)

	frame := self.current_frame
	{
		found.profile_scope("graphics.wait_frame")
		swapchain_wait_for_frame(&self.swapchain, frame)
	}
	_renderer_pick_resolve_slot(self, frame)
	_renderer_verify_direct(self, frame)

	recreate := false
	result: vulkan.Result
	image_idx: u32
	{
		found.profile_scope("graphics.acquire")
		result, image_idx = swapchain_acquire_next(&self.swapchain, frame)
	}
	if result == .ERROR_OUT_OF_DATE_KHR {
		if !_renderer_recreate_if_possible(self) {return false}
		return true
	} else if result != .SUCCESS && result != .SUBOPTIMAL_KHR {
		log.errorf("[VULKAN] Failed to acquire swapchain image!")
		return false
	} else if result == .SUBOPTIMAL_KHR {
		recreate = true
	}
	found.profile_mark("graphics.acquired", "frame=%d image=%d", {frame, image_idx})

	// Resolve the direct-rendering view once for this frame; the draw and the
	// submit both need it.
	self.direct_valid = false
	if view, ok := gpu_gravity_render_view(self.gravity_source); ok {
		self.direct_view = view
		self.direct_valid = true
		if !self.direct_logged {
			self.direct_logged = true
			log.infof(
				"[RENDER] Direct instances enabled: %d bodies (mode %d) from the GPU solver",
				view.count,
				view.mode,
			)
		}
	}

	swapchain_prepare_frame(&self.swapchain, frame, image_idx)
	command_pool_reset(&self.command_pool, frame)
	command_buffer := command_pool_begin(&self.command_pool, frame)
	self.frame_color = swapchain_color_target(&self.swapchain, image_idx)
	if self.world != nil {
		req := ecs.world_resource(self.world, Pick_Request)
		fg_set_pass_enabled(&self.frame_graph, "pick_copy", req.requested)
	}
	// The instance pack is compute, so it must be recorded before the render
	// pass begins; the main pass then binds the buffer it wrote.
	if self.direct_valid {
		found.profile_scope_args("graphics.instance_pack", "n=%d", {self.direct_view.count})
		self.direct_count = _renderer_pack_instances(self, command_buffer, frame)
	}
	{
		found.profile_scope_args("graphics.framegraph", "frame=%d", {frame})
		if !frame_graph_execute(&self.frame_graph, command_buffer, frame, self.swapchain.extent) {
			log.errorf("[FG] Frame graph execution failed")
			return false
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
	if submit_result == .SUCCESS && self.gravity_source != nil {
		gpu_gravity_set_frame_sync(self.gravity_source, self.frame_timeline.semaphore, frame_value)
	}
	if submit_result != .SUCCESS {
		log.errorf("[VULKAN] Failed to submit frame!")
		return false
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
		return false
	}
	if sync.atomic_load(&self.window.framebuffer_resized) {recreate = true}

	if recreate {
		found.profile_mark("graphics.recreate", "frame=%d", {frame})
		sync.atomic_store(&self.window.framebuffer_resized, false)
		if !_renderer_recreate_if_possible(self) {return false}
	}

	self.current_frame = (self.current_frame + 1) % MAX_FRAMES_IN_FLIGHT
	return true
}
