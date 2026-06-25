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
	g, g_ok := gpu_create(window); if !g_ok {return nil, false}
	r.gpu = g
	cp, cp_ok := command_pool_create(&r.gpu); if !cp_ok {return nil, false}
	r.command_pool = cp
	sc, sc_ok := swapchain_create(&r.gpu, window); if !sc_ok {return nil, false}
	r.swapchain = sc
	pl, pl_ok := pipeline_create(&r.gpu, r.swapchain.render_pass); if !pl_ok {return nil, false}
	r.pipeline = pl
	mdl, mdl_ok := model_create(&r.gpu, &r.command_pool, 30, 30); if !mdl_ok {return nil, false}
	r.model = mdl
	r.camera = camera_create(&r.swapchain)
	if objects != nil && len(objects) > 0 {renderer_update_objects(r)}
	imgr, img_ok := imgui_manager_create(&r.gpu, &r.swapchain, window)
	if !img_ok {log.errorf("[VULKAN] Failed to create ImGui manager"); return nil, false}
	r.im_gui = imgr
	r.initialized = true
	obj_count := 0; if objects != nil {obj_count = len(objects)}
	log.infof("========================================"); log.infof("[VULKAN] RENDERER INITIALIZATION COMPLETE (%d objects)", obj_count); log.infof("========================================")
	return r, true
}

renderer_destroy :: proc(r: ^Renderer) {
	if !r.initialized {return}
	log.infof("[VULKAN] Renderer shutdown...")
	imgui_manager_destroy(r.im_gui); model_destroy(&r.model); descriptor_pool_destroy(&r.descriptor_pool)
	pipeline_destroy(&r.pipeline); swapchain_destroy(&r.swapchain); command_pool_destroy(&r.command_pool); gpu_destroy(&r.gpu)
	delete(r.game_objects); free(r)
	log.infof("[VULKAN] Renderer shutdown complete")
}

renderer_update_objects :: proc(r: ^Renderer) {
	descriptor_pool_destroy(&r.descriptor_pool)
	r.game_objects = make([dynamic]UniformBufferObject, len(r.objects))
	for i in 0 ..< len(r.game_objects) {r.game_objects[i] = UniformBufferObject{}}
	dp, _ := descriptor_pool_create(&r.gpu, &r.pipeline, u32(len(r.objects)))
	r.descriptor_pool = dp
}

renderer_draw_frame :: proc(r: ^Renderer) -> bool {
	r.time += r.frame_time^; if r.time > 1000 {r.time -= 1000}
	result, image_idx := swapchain_acquire_next(&r.swapchain, r.current_frame)
	if result == .ERROR_OUT_OF_DATE_KHR {
		swapchain_recreate(&r.swapchain)
		pipeline_destroy(&r.pipeline); pl, _ := pipeline_create(&r.gpu, r.swapchain.render_pass); r.pipeline = pl
		r.camera = camera_create(&r.swapchain)
		return true
	}
	if result != .SUCCESS && result != .SUBOPTIMAL_KHR {
		log.errorf("[VULKAN] Failed to acquire swapchain image!")
		return false
	}
	swapchain_reset_fences(&r.swapchain, r.current_frame)
	command_pool_reset(&r.command_pool, r.current_frame)
	cmd := command_pool_begin(&r.command_pool, r.current_frame)
	swapchain_begin_render_pass(&r.swapchain, cmd, image_idx)
	pipeline_bind(&r.pipeline, cmd)

	imgui_manager_new_frame()

	if r.draw_ui != nil {
		r.draw_ui(r.draw_ui_data)
	}

	input_process(&r.window.input, r.frame_time^)

	for &ubo, i in r.game_objects {
		obj := &r.objects[i]
		angle := r.time
		ubo.model = la.matrix4_translate_f32(obj.position * 0.00001) * la.matrix4_rotate_f32(math.to_radians_f32(angle), Vec3{0, 1, 0}) * la.matrix4_scale_f32(Vec3{obj.radius, obj.radius, obj.radius} * 0.00001)
		ubo.view = la.matrix4_look_at_f32(r.camera.position, r.camera.target, r.camera.up)
		ubo.proj = la.matrix4_perspective_f32(math.to_radians_f32(r.camera.fov), r.camera.aspect, r.camera.near, r.camera.far)
		ubo.selected = i32(obj.selected)

		descriptor_pool_update_ubo(&r.descriptor_pool, ubo, r.current_frame, u32(i))

		set := descriptor_pool_get_set(&r.descriptor_pool, r.current_frame, u32(i))
		vulkan.CmdBindDescriptorSets(cmd, .GRAPHICS, r.pipeline.layout, 0, 1, &set, 0, nil)
		model_bind(&r.model, cmd)
		vulkan.CmdDrawIndexed(cmd, model_get_index_count(&r.model), 1, 0, 0, 0)
	}

	descriptor_pool_flush_all(&r.descriptor_pool)

	imgui_manager_end_frame()
	imgui_manager_draw(r.im_gui, cmd)

	vulkan.CmdEndRenderPass(cmd)
	command_pool_end(&r.command_pool, cmd)
	present_result := swapchain_queue_submit(&r.swapchain, cmd, r.current_frame, image_idx)
	if present_result == .ERROR_OUT_OF_DATE_KHR || present_result == .SUBOPTIMAL_KHR || r.window.framebuffer_resized {
		r.window.framebuffer_resized = false
		swapchain_recreate(&r.swapchain)
		pipeline_destroy(&r.pipeline)
		pl2, _ := pipeline_create(&r.gpu, r.swapchain.render_pass); r.pipeline = pl2
		r.camera = camera_create(&r.swapchain)
	} else if present_result != .SUCCESS {
		log.errorf("[VULKAN] Failed to present!")
		return false
	}
	r.current_frame = (r.current_frame + 1) % MAX_FRAMES_IN_FLIGHT
	return true
}
