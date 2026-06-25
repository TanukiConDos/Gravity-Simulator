package graphic

import imgui "../../External/odin-imgui"
import imglfw "../../External/odin-imgui/imgui_impl_glfw"
import imgvk "../../External/odin-imgui/imgui_impl_vulkan"
import "core:c"
import "core:log"
import vk "vendor:vulkan"

ImGuiManager :: struct {initialized: bool}

imgui_manager_create :: proc(g: ^GPU, sc: ^SwapChain, w: ^Window) -> (^ImGuiManager, bool) {
	mgr := new(ImGuiManager)
	imgui.CHECKVERSION()
	if imgui.CreateContext(nil) == nil {log.errorf("[IMGUI] Failed to create context"); return nil, false}
	imgui.StyleColorsDark(nil)
	io := imgui.GetIO(); io.IniFilename = nil
	if !imglfw.InitForVulkan(w.handle, true) {log.errorf("[IMGUI] Failed GLFW backend"); return nil, false}
	info := imgvk.InitInfo{Instance=gpu_get_instance(g),PhysicalDevice=gpu_get_physical_device(g),Device=gpu_get_device(g),QueueFamily=gpu_get_queue_family(g),Queue=gpu_get_graphics_queue(g),DescriptorPoolSize=1000,RenderPass=sc.render_pass,MinImageCount=2,ImageCount=u32(len(sc.images)),MSAASamples=vk.SampleCountFlag._1}
	imgvk.LoadFunctions(vk.API_VERSION_1_1,proc"c"(name:cstring,ud:rawptr)->vk.ProcVoidFunction{return vk.GetInstanceProcAddr(cast(vk.Instance)(ud),name)},rawptr(info.Instance))
	if !imgvk.Init(&info) {log.errorf("[IMGUI] Failed Vulkan backend"); return nil, false}
	mgr.initialized = true; log.infof("[IMGUI] ImGui initialized"); return mgr, true
}

imgui_manager_destroy :: proc(mgr: ^ImGuiManager) {if !mgr.initialized {return}; imgvk.Shutdown(); imglfw.Shutdown(); imgui.DestroyContext(nil); free(mgr); log.debugf("[IMGUI] ImGui shutdown")}
imgui_manager_new_frame :: proc() {imgvk.NewFrame(); imglfw.NewFrame(); imgui.NewFrame()}
imgui_manager_end_frame :: proc() {imgui.Render()}
imgui_manager_draw :: proc(mgr: ^ImGuiManager, cmd: vk.CommandBuffer) {if data := imgui.GetDrawData(); data != nil {imgvk.RenderDrawData(data, cmd, {})}}
