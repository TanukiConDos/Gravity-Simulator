package graphic

import imgui "../../External/odin-imgui"
import imglfw "../../External/odin-imgui/imgui_impl_glfw"
import imgvk "../../External/odin-imgui/imgui_impl_vulkan"
import "core:c"
import "core:log"
import vk "vendor:vulkan"

ImGuiManager :: struct {initialized: bool}

imgui_manager_create :: proc(gpu: ^GPU, swapchain: ^SwapChain, window: ^Window) -> (^ImGuiManager, bool) {
	mgr := new(ImGuiManager)
	imgui.CHECKVERSION()
	if imgui.CreateContext(nil) == nil {log.errorf("[IMGUI] Failed to create context"); return nil, false}
	imgui.StyleColorsDark(nil)
	io := imgui.GetIO(); io.IniFilename = nil
	if !imglfw.InitForVulkan(window.handle, true) {log.errorf("[IMGUI] Failed GLFW backend"); return nil, false}
	info := imgvk.InitInfo{Instance=gpu_get_instance(gpu),PhysicalDevice=gpu_get_physical_device(gpu),Device=gpu_get_device(gpu),QueueFamily=gpu_get_queue_family(gpu),Queue=gpu_get_graphics_queue(gpu),DescriptorPoolSize=1000,RenderPass=swapchain.render_pass,MinImageCount=2,ImageCount=u32(len(swapchain.images)),MSAASamples=vk.SampleCountFlag._1}
	imgvk.LoadFunctions(vk.API_VERSION_1_1,proc"c"(name:cstring,user_data:rawptr)->vk.ProcVoidFunction{return vk.GetInstanceProcAddr(cast(vk.Instance)(user_data),name)},rawptr(info.Instance))
	if !imgvk.Init(&info) {log.errorf("[IMGUI] Failed Vulkan backend"); return nil, false}
	mgr.initialized = true; log.infof("[IMGUI] ImGui initialized"); return mgr, true
}

imgui_manager_destroy :: proc(self: ^ImGuiManager) {if !self.initialized {return}; imgvk.Shutdown(); imglfw.Shutdown(); imgui.DestroyContext(nil); free(self); log.debugf("[IMGUI] ImGui shutdown")}
imgui_manager_new_frame :: proc() {imgvk.NewFrame(); imglfw.NewFrame(); imgui.NewFrame()}
imgui_manager_end_frame :: proc() {imgui.Render()}
imgui_manager_draw :: proc(self: ^ImGuiManager, cmd: vk.CommandBuffer) {if data := imgui.GetDrawData(); data != nil {imgvk.RenderDrawData(data, cmd, {})}}
