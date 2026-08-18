package graphic

import phys "../physic"
import "core:log"
import "core:math"
import la "core:math/linalg"
import "core:sync"
import "vendor:glfw"
import "vendor:vulkan"

Renderer :: struct {
	window:          ^Window,
	gpu:             GPU,
	command_pool:    CommandPool,
	swapchain:       SwapChain,
	pipeline:        Pipeline,
	descriptor_pool: DescriptorPool,
	model:           Model,
	camera:          Camera,
	objects:         ^[dynamic]phys.PhysicObject,
	instances:       InstanceBuffer,
	delta_time:      ^f32,
	current_frame:   u32,
	initialized:     bool,
}

renderer_create :: proc(window: ^Window, objects: ^[dynamic]phys.PhysicObject, delta_time: ^f32) -> (^Renderer, bool) {
	r := new(Renderer); r.window = window; r.objects = objects; r.delta_time = delta_time
	log.infof("========================================"); log.infof("[VULKAN] RENDERER INITIALIZATION START"); log.infof("========================================")
	gpu, gpu_ok := gpu_create(window); if !gpu_ok {return nil, false}
	r.gpu = gpu
	command_pool, command_pool_ok := command_pool_create(&r.gpu); if !command_pool_ok {return nil, false}
	r.command_pool = command_pool
	swapchain, swapchain_ok := swapchain_create(&r.gpu, window); if !swapchain_ok {return nil, false}
	r.swapchain = swapchain
	pipeline, pipeline_ok := pipeline_create(&r.gpu, r.swapchain.render_pass); if !pipeline_ok {return nil, false}
	r.pipeline = pipeline
	model, model_ok := model_create(&r.gpu, &r.command_pool, 30, 30); if !model_ok {return nil, false}
	r.model = model
	r.camera = camera_create(&r.swapchain)
	descriptor_pool, descriptor_pool_ok := descriptor_pool_create(&r.gpu, &r.pipeline); if !descriptor_pool_ok {return nil, false}
	r.descriptor_pool = descriptor_pool
	instances, instances_ok := instance_buffer_create(&r.gpu); if !instances_ok {return nil, false}
	r.instances = instances
	if objects != nil && len(objects) > 0 {renderer_update_instances(r)}
	r.initialized = true
	obj_count := 0; if objects != nil {obj_count = len(objects)}
	log.infof("========================================"); log.infof("[VULKAN] RENDERER INITIALIZATION COMPLETE (%d objects)", obj_count); log.infof("========================================")
	return r, true
}

renderer_destroy :: proc(self: ^Renderer) {
	if !self.initialized {return}
	log.infof("[VULKAN] Renderer shutdown...")
	gpu_wait(&self.gpu)
	model_destroy(&self.model); descriptor_pool_destroy(&self.descriptor_pool)
	instance_buffer_destroy(&self.instances)
	pipeline_destroy(&self.pipeline); swapchain_destroy(&self.swapchain); command_pool_destroy(&self.command_pool); gpu_destroy(&self.gpu)
	free(self)
	log.infof("[VULKAN] Renderer shutdown complete")
}

renderer_update_instances :: proc(self: ^Renderer) {
	if self.objects != nil {
		instance_buffer_update(&self.instances, self.objects[:])
	}
}

renderer_draw_frame :: proc(self: ^Renderer) -> bool {
	result, image_idx := swapchain_acquire_next(&self.swapchain, self.current_frame)
	if result == .ERROR_OUT_OF_DATE_KHR {
		swapchain_recreate(&self.swapchain)
		pipeline_destroy(&self.pipeline); pipeline, pipeline_ok := pipeline_create(&self.gpu, self.swapchain.render_pass)
		if !pipeline_ok {log.errorf("[VULKAN] Failed to recreate pipeline after swapchain!"); return false}
		self.pipeline = pipeline
		self.camera = camera_create(&self.swapchain)
		return true
	}
	if result != .SUCCESS && result != .SUBOPTIMAL_KHR {
		log.errorf("[VULKAN] Failed to acquire swapchain image!")
		return false
	}
	swapchain_reset_fences(&self.swapchain, self.current_frame)
	command_pool_reset(&self.command_pool, self.current_frame)
	command_buffer := command_pool_begin(&self.command_pool, self.current_frame)
	swapchain_begin_render_pass(&self.swapchain, command_buffer, image_idx)
	pipeline_bind(&self.pipeline, command_buffer)

	input_poll(self.window, &self.camera, sync.atomic_load(self.delta_time))

	ubo := UniformBufferObject{
		view = la.matrix4_look_at_f32(self.camera.position, self.camera.target, self.camera.up),
		proj = la.matrix4_perspective_f32(math.to_radians_f32(self.camera.fov), self.camera.aspect, self.camera.near, self.camera.far),
	}
	descriptor_pool_update_ubo(&self.descriptor_pool, ubo, self.current_frame)

	instance_buffer_update(&self.instances, self.objects[:])

	set := descriptor_pool_get_set(&self.descriptor_pool, self.current_frame)
	vulkan.CmdBindDescriptorSets(command_buffer, .GRAPHICS, self.pipeline.layout, 0, 1, &set, 0, nil)
	model_bind(&self.model, command_buffer)
	instance_buffer_bind(&self.instances, command_buffer)
	if len(self.objects) > 0 {
		vulkan.CmdDrawIndexed(command_buffer, model_get_index_count(&self.model), u32(len(self.objects)), 0, 0, 0)
	}

	vulkan.CmdEndRenderPass(command_buffer)
	command_pool_end(&self.command_pool, command_buffer)
	present_result := swapchain_queue_submit(&self.swapchain, command_buffer, self.current_frame, image_idx)
	if present_result == .ERROR_OUT_OF_DATE_KHR || present_result == .SUBOPTIMAL_KHR || sync.atomic_load(&self.window.framebuffer_resized) {
		sync.atomic_store(&self.window.framebuffer_resized, false)
		swapchain_recreate(&self.swapchain)
		pipeline_destroy(&self.pipeline)
		pipeline, pipeline_ok := pipeline_create(&self.gpu, self.swapchain.render_pass)
		if !pipeline_ok {log.errorf("[VULKAN] Failed to recreate pipeline!"); return false}
		self.pipeline = pipeline
		self.camera = camera_create(&self.swapchain)
	} else if present_result != .SUCCESS {
		log.errorf("[VULKAN] Failed to present!")
		return false
	}
	self.current_frame = (self.current_frame + 1) % MAX_FRAMES_IN_FLIGHT
	return true
}
