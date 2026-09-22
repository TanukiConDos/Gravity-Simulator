package graphic

import phys "../physic"
import "core:log"
import "core:sync"
import "core:time"
import "vendor:vulkan"

Renderer :: struct {
	window:          ^Window,
	gpu:             GPU,
	command_pool:    CommandPool,
	swapchain:       SwapChain,
	pipeline:        Pipeline,
	uniforms:        Uniforms,
	model:           Model,
	camera:          Camera,
	objects:         ^[dynamic]phys.PhysicObject,
	physic_system:   ^phys.PhysicSystem,
	instances:       InstanceBuffer,
	positions:       [dynamic]Vec3,
	delta_time:      ^f32,
	current_frame:   u32,
}

renderer_init :: proc(window: ^Window, objects: ^[dynamic]phys.PhysicObject, physic_system: ^phys.PhysicSystem, delta_time: ^f32) -> (result: ^Renderer, ok: bool) {
	renderer := new(Renderer)
	committed := false
	defer if !committed {renderer_destroy(renderer)}

	renderer.window = window; renderer.objects = objects; renderer.physic_system = physic_system; renderer.delta_time = delta_time
	log.infof("========================================"); log.infof("[VULKAN] RENDERER INITIALIZATION START"); log.infof("========================================")
	renderer.gpu = gpu_init(window) or_return
	renderer.command_pool = command_pool_init(&renderer.gpu) or_return
	renderer.swapchain = swapchain_init(&renderer.gpu, window) or_return
	renderer.pipeline = pipeline_init(&renderer.gpu, renderer.swapchain.image_format, renderer.swapchain.depth_format) or_return
	renderer.model = model_init(&renderer.gpu, &renderer.command_pool, 30, 30) or_return
	renderer.camera = camera_create(&renderer.swapchain)
	renderer.uniforms = uniforms_init(&renderer.gpu) or_return
	renderer.instances = instance_buffer_init(&renderer.gpu)
	if objects != nil && len(objects) > 0 {
		renderer.positions = make([dynamic]Vec3, len(objects))
		renderer_update_instances(renderer)
	}
	obj_count := 0; if objects != nil {obj_count = len(objects)}
	log.infof("========================================"); log.infof("[VULKAN] RENDERER INITIALIZATION COMPLETE (%d objects)", obj_count); log.infof("========================================")
	committed = true
	result = renderer
	return result, true
}

renderer_destroy :: proc(self: ^Renderer) {
	if self == nil {return}
	log.infof("[VULKAN] Renderer shutdown...")
	gpu_wait(&self.gpu)
	model_destroy(&self.model); uniforms_destroy(&self.uniforms)
	instance_buffer_destroy(&self.instances)
	delete(self.positions)
	pipeline_destroy(&self.pipeline); swapchain_destroy(&self.swapchain); command_pool_destroy(&self.command_pool); gpu_destroy(&self.gpu)
	free(self)
	log.infof("[VULKAN] Renderer shutdown complete")
}

@(private)
renderer_update_instances :: proc(self: ^Renderer) {
	if self.objects != nil {
		instance_buffer_write_static(&self.instances, self.objects[:])
	}
}

// Recreates the swapchain and, only if the attachment formats actually changed,
// rebuilds the pipeline. The pipeline no longer references the swapchain, so a
// plain resize reuses it as-is.
@(private)
_renderer_recreate_swapchain :: proc(self: ^Renderer) -> bool {
	swapchain_recreate(&self.swapchain) or_return
	format_changed := self.pipeline.color_format != self.swapchain.image_format || self.pipeline.depth_format != self.swapchain.depth_format
	if format_changed {
		pipeline_destroy(&self.pipeline)
		self.pipeline = pipeline_init(&self.gpu, self.swapchain.image_format, self.swapchain.depth_format) or_return
	}
	self.camera = camera_create(&self.swapchain)
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
	swapchain_begin_rendering(&self.swapchain, command_buffer, image_idx)
	pipeline_bind(&self.pipeline, command_buffer)

	input_poll(self.window, &self.camera, sync.atomic_load(self.delta_time))

	ubo: UniformBufferObject
	camera_transform(&self.camera, &ubo)
	uniforms_write(&self.uniforms, ubo, frame)

	if self.physic_system != nil && self.objects != nil && len(self.positions) >= len(self.objects) {
		phys.physic_snapshot_read(self.physic_system, raw_data(self.positions), len(self.positions))
		instance_buffer_update_positions(&self.instances, frame, self.positions[:])
	}

	uniforms_push(&self.uniforms, command_buffer, self.pipeline.layout, frame)
	model_bind(&self.model, command_buffer)
	instance_buffer_bind(&self.instances, command_buffer, frame)
	if len(self.objects) > 0 {
		vulkan.CmdDrawIndexed(command_buffer, self.model.index_count, u32(len(self.objects)), 0, 0, 0)
	}

	swapchain_end_rendering(&self.swapchain, command_buffer, image_idx)
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
	return true
}
