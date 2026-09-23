package graphic

import phys "../physic"
import ecs "../ecs"
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
	pick_pipeline:   Pipeline_ID,
	main_pass:       Frame_Pass,
	pick_pass:       Frame_Pass,
	push:            Push_Descriptors,
	model:           Model,
	camera:          ^Camera,
	world:           ^ecs.World,
	snapshot:        ^phys.RenderSnapshot,
	instances:       InstanceBuffer,
	positions:       [dynamic]Vec3,
	selected:        [dynamic]u8,
	// Offscreen resources for the on-demand pick pass. They are single (not per
	// frame in flight) because the readback serialises on vkQueueWaitIdle.
	pick_color:      Render_Target,
	pick_depth:      Render_Target,
	pick_readback:   Buffer,
	current_frame:   u32,
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
	renderer.main_pipeline = pipeline_registry_add(&renderer.pipelines, "main", renderer.config, renderer.swapchain.image_format, renderer.swapchain.depth_format) or_return
	renderer.pick_pipeline = pipeline_registry_add(&renderer.pipelines, "pick", renderer_pick_pipeline_config(), PICK_COLOR_FORMAT, renderer.swapchain.depth_format) or_return
	renderer.main_pass = frame_pass_create("main", renderer.main_pipeline)
	renderer.pick_pass = frame_pass_create("pick", renderer.pick_pipeline)
	renderer.pick_pass.color_clear = vulkan.ClearValue{color = vulkan.ClearColorValue{uint32 = {0, 0, 0, 0}}}
	_renderer_create_pick_resources(renderer) or_return
	renderer.model = model_init(&renderer.gpu, &renderer.command_pool, 30, 30) or_return
	renderer.camera = ecs.world_resource(world, Camera)
	renderer.camera^ = camera_create(&renderer.swapchain)
	ecs.world_resource(world, Window_Ref).window = window
	_ = ecs.world_resource(world, Pick_Request)
	renderer.push = push_descriptors_init(&renderer.gpu, RENDERER_PUSH_BINDINGS[:]) or_return
	if !push_descriptors_validate(&renderer.push, pipeline_registry_get(&renderer.pipelines, renderer.main_pipeline)) {return nil, false}
	if !push_descriptors_validate(&renderer.push, pipeline_registry_get(&renderer.pipelines, renderer.pick_pipeline)) {return nil, false}
	renderer.instances = instance_buffer_init(&renderer.gpu)
	renderer.snapshot = phys.physic_snapshot(world)
	obj_count := phys.body_count(world)
	if obj_count > 0 {
		renderer.positions = make([dynamic]Vec3, obj_count)
		renderer.selected = make([dynamic]u8, obj_count)
		renderer_update_instances(renderer)
	}
	log.infof("========================================"); log.infof("[VULKAN] RENDERER INITIALIZATION COMPLETE (%d objects)", obj_count); log.infof("========================================")
	committed = true
	result = renderer
	return result, true
}

// Registers the graphics systems. Input mutates the Camera resource, so it runs
// before the renderer reads it for the frame.
graphic_register_systems :: proc(s: ^ecs.Scheduler) {
	ecs.scheduler_add(s, "graphic.input", .RENDER, input_system)
}

renderer_destroy :: proc(self: ^Renderer) {
	if self == nil {return}
	log.infof("[VULKAN] Renderer shutdown...")
	gpu_wait(&self.gpu)
	model_destroy(&self.model); push_descriptors_destroy(&self.push)
	instance_buffer_destroy(&self.instances)
	delete(self.positions); delete(self.selected)
	_renderer_destroy_pick_resources(self)
	pipeline_registry_destroy(&self.pipelines); swapchain_destroy(&self.swapchain); command_pool_destroy(&self.command_pool); gpu_destroy(&self.gpu)
	free(self)
	log.infof("[VULKAN] Renderer shutdown complete")
}

@(private)
renderer_update_instances :: proc(self: ^Renderer) {
	if self.world != nil {
		instance_buffer_write_static(&self.instances, self.world)
	}
}

// Offscreen pick resources. The color target holds a 1-based instance ID, so
// after clearing to zero a pixel value of zero means "no hit". Both images are
// single, not per frame in flight, because a pick serialises on vkQueueWaitIdle.
@(private)
_renderer_create_pick_resources :: proc(self: ^Renderer) -> bool {
	self.pick_color = render_target_init(&self.gpu, Render_Target_Desc{
		format = PICK_COLOR_FORMAT,
		extent = self.swapchain.extent,
		usage  = {.COLOR_ATTACHMENT, .TRANSFER_SRC},
		aspect = {.COLOR},
	}) or_return
	self.pick_depth = render_target_init(&self.gpu, Render_Target_Desc{
		format = self.swapchain.depth_format,
		extent = self.swapchain.extent,
		usage  = {.DEPTH_STENCIL_ATTACHMENT},
		aspect = {.DEPTH},
	}) or_return
	self.pick_readback = buffer_init(&self.gpu, size_of(u32), {.TRANSFER_DST}, .HostVisible) or_return
	return true
}

@(private)
_renderer_destroy_pick_resources :: proc(self: ^Renderer) {
	render_target_destroy(&self.pick_color)
	render_target_destroy(&self.pick_depth)
	buffer_destroy(&self.pick_readback)
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
		self.main_pipeline = pipeline_registry_add(&self.pipelines, "main", self.config, self.swapchain.image_format, self.swapchain.depth_format) or_return
		self.pick_pipeline = pipeline_registry_add(&self.pipelines, "pick", renderer_pick_pipeline_config(), PICK_COLOR_FORMAT, self.swapchain.depth_format) or_return
	}
	_renderer_destroy_pick_resources(self)
	_renderer_create_pick_resources(self) or_return
	self.camera^ = camera_create(&self.swapchain)
	return true
}

// Rebuilding a 0x0 swapchain is invalid. GLFW only updates the framebuffer size
// while processing events on the main thread, so while minimized this backs off
// and lets the next frame retry. Returns false only on a fatal error.
@(private)
_renderer_recreate_if_possible :: proc(self: ^Renderer) -> bool {
	if !window_update_size(self.window) {
		time.sleep(16 * time.Millisecond)
		return true
	}
	return _renderer_recreate_swapchain(self)
}

// Records the frame's render work into the command buffer. The swapchain
// acquire/present stay in renderer_draw_frame; this proc only knows about
// Render_Targets, pipelines and the render pass list.
@(private)
_renderer_record_frame :: proc(self: ^Renderer, cmd: vulkan.CommandBuffer, frame, image_index: u32) {
	pipeline := pipeline_registry_get(&self.pipelines, self.main_pipeline)
	color := swapchain_color_target(&self.swapchain, image_index)
	depth := swapchain_depth_target(&self.swapchain, frame)

	frame_pass_begin(cmd, &self.main_pass, color, depth, self.swapchain.extent)
	pipeline_bind(pipeline, cmd)

	ubo: UniformBufferObject
	camera_transform(self.camera, &ubo)
	push_descriptors_write(&self.push, CAMERA_SET, CAMERA_BINDING, frame, &ubo, size_of(UniformBufferObject))

	if self.world != nil && len(self.positions) > 0 {
		n := phys.physic_snapshot_read(
			self.snapshot,
			raw_data(self.positions),
			raw_data(self.selected),
			len(self.positions),
		)
		if n > 0 {instance_buffer_update_positions(&self.instances, frame, self.positions[:n], self.selected[:n])}
	}

	push_descriptors_flush(&self.push, cmd, pipeline.layout, frame)
	model_bind(&self.model, cmd, MESH_BINDING)
	instance_buffer_bind(&self.instances, cmd, frame, INSTANCE_BINDING)
	if len(self.positions) > 0 {
		vulkan.CmdDrawIndexed(cmd, self.model.index_count, u32(len(self.positions)), 0, 0, 0)
	}

	frame_pass_end(cmd, &self.main_pass)
	swapchain_prepare_present(&self.swapchain, cmd, image_index)
}

// Runs one pick pass and reads back the ID under the cursor. Returns the
// instance index (the order bodies are drawn in) or -1 for a miss.
@(private)
_renderer_pick :: proc(self: ^Renderer, x, y: u32) -> i32 {
	if self.pick_color.image == 0 || self.pick_readback.mapped == nil {return -1}

	frame := self.current_frame
	pipeline := pipeline_registry_get(&self.pipelines, self.pick_pipeline)
	cmd := command_pool_begin_one_shot(&self.command_pool)

	frame_pass_begin(cmd, &self.pick_pass, self.pick_color, &self.pick_depth, self.swapchain.extent)
	pipeline_bind(pipeline, cmd)

	ubo: UniformBufferObject
	camera_transform(self.camera, &ubo)
	push_descriptors_write(&self.push, CAMERA_SET, CAMERA_BINDING, frame, &ubo, size_of(UniformBufferObject))
	push_descriptors_flush(&self.push, cmd, pipeline.layout, frame)

	model_bind(&self.model, cmd, MESH_BINDING)
	instance_buffer_bind(&self.instances, cmd, frame, INSTANCE_BINDING)
	if len(self.positions) > 0 {
		vulkan.CmdDrawIndexed(cmd, self.model.index_count, u32(len(self.positions)), 0, 0, 0)
	}
	frame_pass_end(cmd, &self.pick_pass)

	render_target_barrier(
		cmd,
		self.pick_color,
		.ATTACHMENT_OPTIMAL,
		.TRANSFER_SRC_OPTIMAL,
		{.COLOR_ATTACHMENT_OUTPUT},
		{.TRANSFER},
		{.COLOR_ATTACHMENT_WRITE},
		{.TRANSFER_READ},
	)
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
	vulkan.CmdCopyImageToBuffer(cmd, self.pick_color.image, .TRANSFER_SRC_OPTIMAL, self.pick_readback.buffer, 1, &region)

	// Submits and waits for idle; the readback buffer is host-visible and
	// coherent, so it can be read directly afterwards.
	command_pool_end_one_shot(&self.command_pool, cmd)

	id := (cast(^u32)self.pick_readback.mapped)^
	if id == 0 {return -1}
	return i32(id - 1)
}

// Consumes a pending Pick_Request and hands the resulting instance index to the
// physics thread, which owns the Selected pool. The graphic side only writes the
// atomic Selection_State; it never touches the world's pools.
@(private)
_renderer_maybe_pick :: proc(self: ^Renderer) {
	if self.world == nil {return}
	req := ecs.world_resource(self.world, Pick_Request)
	if !req.requested {return}
	req.requested = false

	extent := self.swapchain.extent
	if extent.width == 0 || extent.height == 0 {return}
	x := u32(clamp(req.u, 0, 1) * f32(extent.width - 1) + 0.5)
	y := u32(clamp(req.v, 0, 1) * f32(extent.height - 1) + 0.5)

	picked := _renderer_pick(self, x, y)
	sel := phys.selection_state(self.world)
	sync.atomic_store(&sel.picked, picked)
	log.debugf("[PICK] instance %d at (%d, %d)", picked, x, y)
}

renderer_draw_frame :: proc(self: ^Renderer) -> bool {
	if sync.atomic_load(&self.window.framebuffer_resized) {
		sync.atomic_store(&self.window.framebuffer_resized, false)
		if !_renderer_recreate_if_possible(self) {return false}
		return true
	}

	frame := self.current_frame
	swapchain_wait_for_frame(&self.swapchain, frame)

	recreate := false
	result, image_idx := swapchain_acquire_next(&self.swapchain, frame)
	if result == .ERROR_OUT_OF_DATE_KHR {
		if !_renderer_recreate_if_possible(self) {return false}
		return true
	} else if result != .SUCCESS && result != .SUBOPTIMAL_KHR {
		log.errorf("[VULKAN] Failed to acquire swapchain image!")
		return false
	} else if result == .SUBOPTIMAL_KHR {
		recreate = true
	}

	swapchain_prepare_frame(&self.swapchain, frame, image_idx)
	command_pool_reset(&self.command_pool, frame)
	command_buffer := command_pool_begin(&self.command_pool, frame)
	_renderer_record_frame(self, command_buffer, frame, image_idx)
	command_pool_end(&self.command_pool, command_buffer)

	if res := swapchain_submit(&self.swapchain, command_buffer, frame, image_idx); res != .SUCCESS {
		log.errorf("[VULKAN] Failed to submit frame!")
		return false
	}

	present_result := swapchain_present(&self.swapchain, frame, image_idx)
	if present_result == .ERROR_OUT_OF_DATE_KHR || present_result == .SUBOPTIMAL_KHR {
		recreate = true
	} else if present_result != .SUCCESS {
		log.errorf("[VULKAN] Failed to present!")
		return false
	}
	if sync.atomic_load(&self.window.framebuffer_resized) {recreate = true}

	if recreate {
		sync.atomic_store(&self.window.framebuffer_resized, false)
		if !_renderer_recreate_if_possible(self) {return false}
	}

	self.current_frame = (self.current_frame + 1) % MAX_FRAMES_IN_FLIGHT
	_renderer_maybe_pick(self)
	return true
}
