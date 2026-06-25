package graphic

import "core:log"
import "base:runtime"
import "vendor:glfw"
import "vendor:vulkan"
import imgui "../../External/odin-imgui"

Window :: struct {handle: glfw.WindowHandle, width: i32, height: i32, framebuffer_resized: bool, surface: vulkan.SurfaceKHR, input: InputEvent}

@(private) _key_callback :: proc"c"(h: glfw.WindowHandle, key, scancode, action, mods: i32) {
	context = runtime.default_context()
	if action == glfw.RELEASE {return}
	if imgui.GetIO().WantCaptureKeyboard {return}
	w := cast(^Window)glfw.GetWindowUserPointer(h); if w == nil {return}
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

@(private) _framebuffer_resize_callback :: proc"c"(h: glfw.WindowHandle, w, ht: i32) {context=runtime.default_context(); p:=cast(^Window)glfw.GetWindowUserPointer(h); if p!=nil {p.framebuffer_resized=true}}

window_create :: proc(w, h: i32) -> (^Window, bool) {
	log.debugf("[VULKAN] Creating window...")
	if !glfw.Init() {log.errorf("[VULKAN]   FAILED: glfw.Init()"); return nil, false}
	log.debugf("[VULKAN]   GLFW initialized")
	glfw.WindowHint(glfw.CLIENT_API, glfw.NO_API); glfw.WindowHint(glfw.RESIZABLE, glfw.FALSE)
	handle := glfw.CreateWindow(w, h, "Gravity Simulation", nil, nil)
	if handle == nil {log.errorf("[VULKAN]   FAILED: glfw.CreateWindow()"); glfw.Terminate(); return nil, false}
	log.debugf("[VULKAN]   Window created: %d x %d", w, h)
	win := new(Window); win.handle=handle; win.width=w; win.height=h
	glfw.SetWindowUserPointer(handle, win)
	glfw.SetFramebufferSizeCallback(handle, _framebuffer_resize_callback)
	glfw.SetKeyCallback(handle, _key_callback)
	return win, true
}

window_destroy :: proc(w: ^Window) {log.debugf("[VULKAN] Destroying window..."); if w.handle!=nil {glfw.DestroyWindow(w.handle)}; glfw.Terminate(); free(w); log.debugf("[VULKAN]   Window destroyed")}
window_should_close :: proc(w: ^Window) -> bool {return bool(glfw.WindowShouldClose(w.handle))}
window_poll_events :: proc() {glfw.PollEvents()}
window_get_framebuffer_size :: proc(w: ^Window) -> (i32,i32) {return glfw.GetFramebufferSize(w.handle)}
window_wait_events :: proc() {glfw.WaitEvents()}
window_check_minimized :: proc(w: ^Window) {w.width,w.height=glfw.GetFramebufferSize(w.handle); for w.width==0||w.height==0 {w.width,w.height=glfw.GetFramebufferSize(w.handle); glfw.WaitEvents()}}
window_create_surface :: proc(w: ^Window, instance: vulkan.Instance) -> bool {log.debugf("[VULKAN] Creating window surface..."); r:=glfw.CreateWindowSurface(instance,w.handle,nil,&w.surface); if r==.SUCCESS{log.debugf("[VULKAN]   Surface created")}else{log.errorf("[VULKAN]   FAILED: CreateWindowSurface")}; return r==.SUCCESS}
