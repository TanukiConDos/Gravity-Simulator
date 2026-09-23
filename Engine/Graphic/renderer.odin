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
	// Pick pass: one query in flight, coalesced, at swapchain/PICK_SCALE. The
	// timeline semaphore signals completion so the readback never stalls the
	// frame loop.
	pick_color:      Render_Target,
	pick_depth:      Render_Target,
	pick_readback:   Buffer,
	pick_cmd:        vulkan.CommandBuffer,
	pick_timeline:   vulkan.Semaphore,
	pick_extent:     vulkan.Extent2D,
	pick_value:      u64,
	pick_pending:    bool,
	pick_slot:       u32,
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
// after clearing to zero a pixel value of zero means "no hit".
@(private)
_renderer_create_pick_resources :: proc(self: ^Renderer) -> bool {
	scale := max(found.config_get().pick_scale, 1)
	self.pick_extent = vulkan.Extent2D{
		width  = max(self.swapchain.extent.width / u32(scale), 1),
		height = max(self.swapchain.extent.height / u32(scale), 1),
	}
	log.debugf("[VULKAN]   Pick target %d x %d (pick_scale=%d)", self.pick_extent.width, self.pick_extent.height, scale)
	self.pick_color = render_target_init(&self.gpu, Render_Target_Desc{
		format = PICK_COLOR_FORMAT,
		extent = self.pick_extent,
		usage  = {.COLOR_ATTACHMENT, .TRANSFER_SRC},
		aspect = {.COLOR},
	}) or_return
	self.pick_depth = render_target_init(&self.gpu, Render_Target_Desc{
		format = self.swapchain.depth_format,
		extent = self.pick_extent,
		usage  = {.DEPTH_STENCIL_ATTACHMENT},
		aspect = {.DEPTH},
	}) or_return
	self.pick_readback = buffer_init(&self.gpu, size_of(u32), {.TRANSFER_DST}, .HostVisible) or_return
	self.pick_timeline = _timeline_semaphore_init(&self.gpu, 0)
	self.pick_cmd = command_pool_allocate(&self.command_pool)
	self.pick_value = 0
	self.pick_pending = false
	return true
}

@(private)
_renderer_destroy_pick_resources :: proc(self: ^Renderer) {
	render_target_destroy(&self.pick_color)
	render_target_destroy(&self.pick_depth)
	buffer_destroy(&self.pick_readback)
	if self.pick_timeline != 0 {vulkan.DestroySemaphore(self.gpu.device, self.pick_timeline, nil); self.pick_timeline = 0}
	if self.pick_cmd != nil {vulkan.FreeCommandBuffers(self.gpu.device, self.command_pool.pool, 1, &self.pick_cmd); self.pick_cmd = nil}
	self.pick_pending = false
}

@(private)
_timeline_semaphore_init :: proc(gpu: ^GPU, initial_value: u64) -> vulkan.Semaphore {
	type_info := vulkan.SemaphoreTypeCreateInfo{sType = .SEMAPHORE_TYPE_CREATE_INFO, semaphoreType = .TIMELINE, initialValue = initial_value}
	create_info := vulkan.SemaphoreCreateInfo{sType = .SEMAPHORE_CREATE_INFO, pNext = &type_info}
	semaphore: vulkan.Semaphore
	vk_assert(vulkan.CreateSemaphore(gpu.device, &create_info, nil, &semaphore), "vkCreateSemaphore")
	return semaphore
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

// Records the pick pass and the one-pixel copy into the pick command buffer.
@(private)
_renderer_pick_record :: proc(self: ^Renderer, cmd: vulkan.CommandBuffer, frame, x, y: u32) {
	pipeline := pipeline_registry_get(&self.pipelines, self.pick_pipeline)

	frame_pass_begin(cmd, &self.pick_pass, self.pick_color, &self.pick_depth, self.pick_extent)
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
}

// Submits the pick query on its own submission, signalled through the timeline
// semaphore so it never delays any frame or present. While a query is in flight
// the request is left pending, so only the latest click is served.
@(private)
_renderer_pick_enqueue :: proc(self: ^Renderer, frame: u32) {
	if self.world == nil || self.pick_pending {return}
	req := ecs.world_resource(self.world, Pick_Request)
	if !req.requested {return}
	req.requested = false

	x := u32(clamp(req.u, 0, 1) * f32(self.pick_extent.width - 1) + 0.5)
	y := u32(clamp(req.v, 0, 1) * f32(self.pick_extent.height - 1) + 0.5)

	command_buffer_reset(self.pick_cmd)
	_ = command_buffer_begin(self.pick_cmd)
	_renderer_pick_record(self, self.pick_cmd, frame, x, y)
	command_buffer_end(self.pick_cmd)

	self.pick_value += 1
	signal := vulkan.SemaphoreSubmitInfo{sType = .SEMAPHORE_SUBMIT_INFO, semaphore = self.pick_timeline, value = self.pick_value, stageMask = {.ALL_COMMANDS}}
	cmd_info := vulkan.CommandBufferSubmitInfo{sType = .COMMAND_BUFFER_SUBMIT_INFO, commandBuffer = self.pick_cmd}
	submit := vulkan.SubmitInfo2 {
		sType                    = .SUBMIT_INFO_2,
		commandBufferInfoCount   = 1,
		pCommandBufferInfos      = &cmd_info,
		signalSemaphoreInfoCount = 1,
		pSignalSemaphoreInfos    = &signal,
	}
	if !vk_check(vulkan.QueueSubmit2(self.gpu.graphics_queue, 1, &submit, 0), "vkQueueSubmit2 (pick)") {return}
	self.pick_pending = true
	self.pick_slot = frame
	log.debugf("[PICK] query (%d, %d) value=%d", x, y, self.pick_value)
}

// Non-blocking: publishes the readback once the timeline reaches the submitted
// value. It never stalls the frame loop.
@(private)
_renderer_pick_resolve :: proc(self: ^Renderer) {
	if !self.pick_pending {return}
	value: u64
	vk_assert(vulkan.GetSemaphoreCounterValue(self.gpu.device, self.pick_timeline, &value), "vkGetSemaphoreCounterValue")
	if value < self.pick_value {return}

	id := (cast(^u32)self.pick_readback.mapped)^
	picked := i32(-1)
	if id != 0 {picked = i32(id - 1)}
	if self.world != nil {
		sel := phys.selection_state(self.world)
		sync.atomic_store(&sel.picked, picked)
	}
	self.pick_pending = false
	log.debugf("[PICK] instance %d (value=%d)", picked, value)
}

// Blocks only if the slot about to be rewritten still has a pick reading its
// buffers. In practice the pick from two frames ago is already resolved.
@(private)
_renderer_pick_wait_slot :: proc(self: ^Renderer, frame: u32) {
	if !self.pick_pending || self.pick_slot != frame {return}
	info := vulkan.SemaphoreWaitInfo {
		sType          = .SEMAPHORE_WAIT_INFO,
		semaphoreCount = 1,
		pSemaphores    = &self.pick_timeline,
		pValues        = &self.pick_value,
	}
	vk_assert(vulkan.WaitSemaphores(self.gpu.device, &info, max(u64)), "vkWaitSemaphores")
	_renderer_pick_resolve(self)
}

renderer_draw_frame :: proc(self: ^Renderer) -> bool {
	if sync.atomic_load(&self.window.framebuffer_resized) {
		sync.atomic_store(&self.window.framebuffer_resized, false)
		if !_renderer_recreate_if_possible(self) {return false}
		return true
	}

	_renderer_pick_resolve(self)

	frame := self.current_frame
	swapchain_wait_for_frame(&self.swapchain, frame)
	_renderer_pick_wait_slot(self, frame)

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

	_renderer_pick_enqueue(self, frame)

	self.current_frame = (self.current_frame + 1) % MAX_FRAMES_IN_FLIGHT
	return true
}
