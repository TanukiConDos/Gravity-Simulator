package graphic

import phys "../physic"
import "core:log"
import "core:math"
import la "core:math/linalg"
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
	im_gui:          ^ImGuiManager,
	objects:         ^[dynamic]phys.PhysicObject,
	game_objects:    [dynamic]UniformBufferObject,
	frame_time:      ^f32,
	tick_time:       ^f32,
	time:            f32,
	current_frame:   u32,
	initialized:     bool,
	draw_ui:         proc(ud: rawptr),
	draw_ui_data:    rawptr,
}

renderer_create :: proc(window: ^Window, objects: ^[dynamic]phys.PhysicObject, frame_time, tick_time: ^f32) -> (^Renderer, bool) {
	r := new(Renderer); r.window = window; r.objects = objects; r.frame_time = frame_time; r.tick_time = tick_time
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
	if objects != nil && len(objects) > 0 {renderer_update_objects(r)}
	imgui_manager, imgui_ok := imgui_manager_create(&r.gpu, &r.swapchain, window)
	if !imgui_ok {log.errorf("[VULKAN] Failed to create ImGui manager"); return nil, false}
	r.im_gui = imgui_manager
	r.initialized = true
	obj_count := 0; if objects != nil {obj_count = len(objects)}
	log.infof("========================================"); log.infof("[VULKAN] RENDERER INITIALIZATION COMPLETE (%d objects)", obj_count); log.infof("========================================")
	return r, true
}

renderer_destroy :: proc(self: ^Renderer) {
	if !self.initialized {return}
	log.infof("[VULKAN] Renderer shutdown...")
	imgui_manager_destroy(self.im_gui); model_destroy(&self.model); descriptor_pool_destroy(&self.descriptor_pool)
	pipeline_destroy(&self.pipeline); swapchain_destroy(&self.swapchain); command_pool_destroy(&self.command_pool); gpu_destroy(&self.gpu)
	delete(self.game_objects); free(self)
	log.infof("[VULKAN] Renderer shutdown complete")
}

renderer_update_objects :: proc(self: ^Renderer) {
	descriptor_pool_destroy(&self.descriptor_pool)
	self.game_objects = make([dynamic]UniformBufferObject, len(self.objects))
	for i in 0 ..< len(self.game_objects) {self.game_objects[i] = UniformBufferObject{}}
	descriptor_pool, _ := descriptor_pool_create(&self.gpu, &self.pipeline, u32(len(self.objects)))
	self.descriptor_pool = descriptor_pool
}

renderer_draw_frame :: proc(self: ^Renderer) -> bool {
	self.time += self.frame_time^; if self.time > 1000 {self.time -= 1000}
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

	imgui_manager_new_frame()

	if self.draw_ui != nil {
		self.draw_ui(self.draw_ui_data)
	}

	input_process(&self.window.input, self.frame_time^)

	for &ubo, i in self.game_objects {
		obj := &self.objects[i]
		angle := self.time
		ubo.model = la.matrix4_translate_f32(obj.position * 0.00001) * la.matrix4_rotate_f32(math.to_radians_f32(angle), Vec3{0, 1, 0}) * la.matrix4_scale_f32(Vec3{obj.radius, obj.radius, obj.radius} * 0.00001)
		ubo.view = la.matrix4_look_at_f32(self.camera.position, self.camera.target, self.camera.up)
		ubo.proj = la.matrix4_perspective_f32(math.to_radians_f32(self.camera.fov), self.camera.aspect, self.camera.near, self.camera.far)
		ubo.selected = i32(obj.selected)

		descriptor_pool_update_ubo(&self.descriptor_pool, ubo, self.current_frame, u32(i))

		set := descriptor_pool_get_set(&self.descriptor_pool, self.current_frame, u32(i))
		vulkan.CmdBindDescriptorSets(command_buffer, .GRAPHICS, self.pipeline.layout, 0, 1, &set, 0, nil)
		model_bind(&self.model, command_buffer)
		vulkan.CmdDrawIndexed(command_buffer, model_get_index_count(&self.model), 1, 0, 0, 0)
	}

	descriptor_pool_flush_all(&self.descriptor_pool)

	imgui_manager_end_frame()
	imgui_manager_draw(self.im_gui, command_buffer)

	vulkan.CmdEndRenderPass(command_buffer)
	command_pool_end(&self.command_pool, command_buffer)
	present_result := swapchain_queue_submit(&self.swapchain, command_buffer, self.current_frame, image_idx)
	if present_result == .ERROR_OUT_OF_DATE_KHR || present_result == .SUBOPTIMAL_KHR || self.window.framebuffer_resized {
		self.window.framebuffer_resized = false
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
