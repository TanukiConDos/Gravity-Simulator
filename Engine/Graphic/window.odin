package graphic

import "core:log"
import "base:runtime"
import "vendor:glfw"
import "vendor:vulkan"
import imgui "../../External/odin-imgui"

Window :: struct {handle: glfw.WindowHandle, width: i32, height: i32, framebuffer_resized: bool, surface: vulkan.SurfaceKHR, input: InputEvent}

@(private) _key_callback :: proc"c"(handle: glfw.WindowHandle, key, scancode, action, mods: i32) {
	context = runtime.default_context()
	if action == glfw.RELEASE {return}
	if imgui.GetIO().WantCaptureKeyboard {return}
	w := cast(^Window)glfw.GetWindowUserPointer(handle); if w == nil {return}
	switch key {
	case glfw.KEY_W: input_submit(&w.input,.MOVE_FORWARD)
	case glfw.KEY_A: input_submit(&w.input,.MOVE_LEFT_SIDE)
	case glfw.KEY_S: input_submit(&w.input,.MOVE_BACKWARD)
	case glfw.KEY_D: input_submit(&w.input,.MOVE_RIGHT_SIDE)
	case glfw.KEY_Q: input_submit(&w.input,.MOVE_DOWN)
	case glfw.KEY_E: input_submit(&w.input,.MOVE_UP)
	case glfw.KEY_UP: input_submit(&w.input,.ROTATE_UP)
	case glfw.KEY_DOWN: input_submit(&w.input,.ROTATE_DOWN)
	case glfw.KEY_LEFT: input_submit(&w.input,.ROTATE_LEFT)
	case glfw.KEY_RIGHT: input_submit(&w.input,.ROTATE_RIGHT)
	}
}

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
	glfw.SetKeyCallback(handle, _key_callback)
	return window, true
}

window_destroy :: proc(self: ^Window) {log.debugf("[VULKAN] Destroying window..."); if self.handle!=nil {glfw.DestroyWindow(self.handle)}; glfw.Terminate(); free(self); log.debugf("[VULKAN]   Window destroyed")}
window_should_close :: proc(self: ^Window) -> bool {return bool(glfw.WindowShouldClose(self.handle))}
window_poll_events :: proc() {glfw.PollEvents()}
window_get_framebuffer_size :: proc(self: ^Window) -> (i32,i32) {return glfw.GetFramebufferSize(self.handle)}
window_wait_events :: proc() {glfw.WaitEvents()}
window_check_minimized :: proc(self: ^Window) {self.width,self.height=glfw.GetFramebufferSize(self.handle); for self.width==0||self.height==0 {self.width,self.height=glfw.GetFramebufferSize(self.handle); glfw.WaitEvents()}}
window_create_surface :: proc(self: ^Window, instance: vulkan.Instance) -> bool {log.debugf("[VULKAN] Creating window surface..."); r:=glfw.CreateWindowSurface(instance,self.handle,nil,&self.surface); if r==.SUCCESS{log.debugf("[VULKAN]   Surface created")}else{log.errorf("[VULKAN]   FAILED: CreateWindowSurface")}; return r==.SUCCESS}
