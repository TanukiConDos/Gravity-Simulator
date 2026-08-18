package graphic

import "core:log"
import "base:runtime"
import "vendor:glfw"
import "vendor:vulkan"

Window :: struct {handle: glfw.WindowHandle, width: i32, height: i32, framebuffer_resized: bool, surface: vulkan.SurfaceKHR}

@(private) _framebuffer_resize_callback :: proc"c"(handle: glfw.WindowHandle, w, height: i32) {context=runtime.default_context(); p:=cast(^Window)glfw.GetWindowUserPointer(handle); if p!=nil {p.framebuffer_resized=true}}

window_create :: proc(w, h: i32) -> (^Window, bool) {
	log.debugf("[VULKAN] Creating window...")
	if !glfw.Init() {log.errorf("[VULKAN]   FAILED: glfw.Init()"); return nil, false}
	log.debugf("[VULKAN]   GLFW initialized")
	glfw.WindowHint(glfw.CLIENT_API, glfw.NO_API); glfw.WindowHint(glfw.RESIZABLE, glfw.FALSE)
	handle := glfw.CreateWindow(w, h, "Gravity Simulation", nil, nil)
	if handle == nil {log.errorf("[VULKAN]   FAILED: glfw.CreateWindow()"); glfw.Terminate(); return nil, false}
	log.debugf("[VULKAN]   Window created: %d x %d", w, h)
	window := new(Window); window.handle=handle; window.width=w; window.height=h
	glfw.SetWindowUserPointer(handle, window)
	glfw.SetFramebufferSizeCallback(handle, _framebuffer_resize_callback)
	return window, true
}

window_destroy :: proc(self: ^Window) {log.debugf("[VULKAN] Destroying window..."); if self.handle!=nil {glfw.DestroyWindow(self.handle)}; glfw.Terminate(); free(self); log.debugf("[VULKAN]   Window destroyed")}
window_should_close :: proc(self: ^Window) -> bool {return bool(glfw.WindowShouldClose(self.handle))}
window_poll_events :: proc() {glfw.PollEvents()}
window_get_framebuffer_size :: proc(self: ^Window) -> (i32,i32) {return glfw.GetFramebufferSize(self.handle)}
window_wait_events :: proc() {glfw.WaitEvents()}
window_check_minimized :: proc(self: ^Window) {self.width,self.height=glfw.GetFramebufferSize(self.handle); for self.width==0||self.height==0 {self.width,self.height=glfw.GetFramebufferSize(self.handle); glfw.WaitEvents()}}
window_create_surface :: proc(self: ^Window, instance: vulkan.Instance) -> bool {log.debugf("[VULKAN] Creating window surface..."); r:=glfw.CreateWindowSurface(instance,self.handle,nil,&self.surface); if r==.SUCCESS{log.debugf("[VULKAN]   Surface created")}else{log.errorf("[VULKAN]   FAILED: CreateWindowSurface")}; return r==.SUCCESS}
