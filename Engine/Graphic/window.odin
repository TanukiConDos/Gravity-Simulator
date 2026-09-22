package graphic

import "core:log"
import "base:runtime"
import "core:sync"
import "vendor:glfw"
import "vendor:vulkan"

Window :: struct {
	handle:              glfw.WindowHandle,
	width:               i32,
	height:              i32,
	framebuffer_resized: bool,
	surface:             vulkan.SurfaceKHR,
	glfw_initialized:    bool,
}

@(private) _framebuffer_resize_callback :: proc"c"(handle: glfw.WindowHandle, w, height: i32) {context=runtime.default_context(); p:=cast(^Window)glfw.GetWindowUserPointer(handle); if p!=nil {sync.atomic_store(&p.framebuffer_resized, true)}}

window_init :: proc(w, h: i32) -> (result: ^Window, ok: bool) {
	log.debugf("[VULKAN] Creating window...")
	window := new(Window)
	committed := false
	defer if !committed {window_destroy(window)}

	if !glfw.Init() {log.errorf("[VULKAN]   FAILED: glfw.Init()"); return}
	window.glfw_initialized = true
	log.debugf("[VULKAN]   GLFW initialized")
	glfw.WindowHint(glfw.CLIENT_API, glfw.NO_API); glfw.WindowHint(glfw.RESIZABLE, glfw.FALSE)
	window.handle = glfw.CreateWindow(w, h, "Gravity Simulation", nil, nil)
	if window.handle == nil {log.errorf("[VULKAN]   FAILED: glfw.CreateWindow()"); return}
	window.width = w; window.height = h
	log.debugf("[VULKAN]   Window created: %d x %d", w, h)
	glfw.SetWindowUserPointer(window.handle, window)
	glfw.SetFramebufferSizeCallback(window.handle, _framebuffer_resize_callback)
	committed = true
	result = window
	return result, true
}

window_destroy :: proc(self: ^Window) {
	if self == nil {return}
	log.debugf("[VULKAN] Destroying window...")
	if self.handle != nil {glfw.DestroyWindow(self.handle); self.handle = nil}
	if self.glfw_initialized {glfw.Terminate(); self.glfw_initialized = false}
	free(self)
	log.debugf("[VULKAN]   Window destroyed")
}

window_should_close :: proc(self: ^Window) -> bool {return bool(glfw.WindowShouldClose(self.handle))}
window_poll_events :: proc() {glfw.PollEvents()}

@(private) window_get_framebuffer_size :: proc(self: ^Window) -> (i32,i32) {return glfw.GetFramebufferSize(self.handle)}
// Refreshes the cached framebuffer size. Returns false while the window is
// minimized (0x0 framebuffer), in which case the swapchain must not be rebuilt.
// Event processing stays on the main thread, so this never blocks.
@(private) window_update_size :: proc(self: ^Window) -> bool {self.width,self.height=glfw.GetFramebufferSize(self.handle); return self.width>0 && self.height>0}
@(private) window_create_surface :: proc(self: ^Window, instance: vulkan.Instance) -> bool {
	log.debugf("[VULKAN] Creating window surface...")
	if !vk_check(glfw.CreateWindowSurface(instance, self.handle, nil, &self.surface), "glfwCreateWindowSurface") {return false}
	log.debugf("[VULKAN]   Surface created")
	return true
}
