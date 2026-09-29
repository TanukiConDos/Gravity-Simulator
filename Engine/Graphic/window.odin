package graphic

import "core:log"
import "base:runtime"
import "core:sync"
import "vendor:glfw"
import "vendor:vulkan"

// Bit flags in `Input_State.keys`. `window_pump` fills them from GLFW on the
// main thread; the render phase only ever reads the resulting bitmask.
@(private)
INPUT_KEY_W     :: u32(1 << 0)
@(private)
INPUT_KEY_S     :: u32(1 << 1)
@(private)
INPUT_KEY_A     :: u32(1 << 2)
@(private)
INPUT_KEY_D     :: u32(1 << 3)
@(private)
INPUT_KEY_Q     :: u32(1 << 4)
@(private)
INPUT_KEY_E     :: u32(1 << 5)
@(private)
INPUT_KEY_UP    :: u32(1 << 6)
@(private)
INPUT_KEY_DOWN  :: u32(1 << 7)
@(private)
INPUT_KEY_LEFT  :: u32(1 << 8)
@(private)
INPUT_KEY_RIGHT :: u32(1 << 9)

// A main-thread snapshot of the GLFW state the render phase needs. GLFW is not
// thread-safe, so every query is performed by `window_pump` on the main thread
// and published here; the graphics thread reads the snapshot instead of calling
// GLFW. `cursor_u`/`cursor_v` are normalised window coordinates; the renderer
// maps them to framebuffer pixels, which keeps window scaling out of this code.
@(private)
Input_State :: struct {
	keys:       u32,
	mouse_down: bool,
	cursor_u:   f32,
	cursor_v:   f32,
	fb_width:   i32,
	fb_height:  i32,
	fb_valid:   bool, // false while minimized (0x0 framebuffer)
}

Window :: struct {
	handle:              glfw.WindowHandle,
	framebuffer_resized: bool,
	surface:             vulkan.SurfaceKHR,
	glfw_initialized:    bool,
	// Published by `window_pump` on the main thread and read by the graphics
	// thread. Each field is atomic: the writer owns all of them, the reader has
	// no ordering requirement between the cursor and the size beyond what a
	// single frame needs. `input_fb_valid` is stored last so a reader that sees
	// `true` also sees a complete framebuffer size.
	input_keys:          u32,
	input_mouse_down:    bool,
	input_cursor_u:      f32,
	input_cursor_v:      f32,
	input_fb_width:      i32,
	input_fb_height:     i32,
	input_fb_valid:      bool,
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
	// The window must stay resizable: on Wayland GLFW advertises min == max size
	// for a non-resizable one, and tiling compositors (Hyprland) float and refuse
	// to resize any window with a fixed size.
	glfw.WindowHint(glfw.CLIENT_API, glfw.NO_API); glfw.WindowHint(glfw.RESIZABLE, glfw.TRUE)
	window.handle = glfw.CreateWindow(w, h, "Gravity Simulation", nil, nil)
	if window.handle == nil {log.errorf("[VULKAN]   FAILED: glfw.CreateWindow()"); return}
	log.debugf("[VULKAN]   Window created: %d x %d", w, h)
	glfw.SetWindowUserPointer(window.handle, window)
	glfw.SetFramebufferSizeCallback(window.handle, _framebuffer_resize_callback)
	// Seed the snapshot so the swapchain can size itself without a later GLFW
	// query; the callback has not run yet, so discard any resize signal.
	window_pump(window)
	sync.atomic_store(&window.framebuffer_resized, false)
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

// Blocks until an event arrives or `seconds` elapse. Preferred over
// window_poll_events in a loop: polling spins the compositor/decoration event
// machinery at full speed.
window_wait_events_timeout :: proc(seconds: f64) {glfw.WaitEventsTimeout(seconds)}

// window_pump queries GLFW and publishes the input/window snapshot. It must run
// on the main thread, right after event processing, so GLFW is only ever touched
// where it is legal. The graphics thread reads the snapshot through
// `window_input_snapshot`/`window_framebuffer_valid`.
window_pump :: proc(self: ^Window) {
	if self == nil || self.handle == nil {return}

	keys: u32
	if glfw.GetKey(self.handle, glfw.KEY_W) == glfw.PRESS {keys |= INPUT_KEY_W}
	if glfw.GetKey(self.handle, glfw.KEY_S) == glfw.PRESS {keys |= INPUT_KEY_S}
	if glfw.GetKey(self.handle, glfw.KEY_A) == glfw.PRESS {keys |= INPUT_KEY_A}
	if glfw.GetKey(self.handle, glfw.KEY_D) == glfw.PRESS {keys |= INPUT_KEY_D}
	if glfw.GetKey(self.handle, glfw.KEY_Q) == glfw.PRESS {keys |= INPUT_KEY_Q}
	if glfw.GetKey(self.handle, glfw.KEY_E) == glfw.PRESS {keys |= INPUT_KEY_E}
	if glfw.GetKey(self.handle, glfw.KEY_UP) == glfw.PRESS {keys |= INPUT_KEY_UP}
	if glfw.GetKey(self.handle, glfw.KEY_DOWN) == glfw.PRESS {keys |= INPUT_KEY_DOWN}
	if glfw.GetKey(self.handle, glfw.KEY_LEFT) == glfw.PRESS {keys |= INPUT_KEY_LEFT}
	if glfw.GetKey(self.handle, glfw.KEY_RIGHT) == glfw.PRESS {keys |= INPUT_KEY_RIGHT}

	mouse_down := glfw.GetMouseButton(self.handle, glfw.MOUSE_BUTTON_LEFT) == glfw.PRESS
	cursor_u, cursor_v: f32
	win_w, win_h := glfw.GetWindowSize(self.handle)
	if win_w > 0 && win_h > 0 {
		xpos, ypos := glfw.GetCursorPos(self.handle)
		cursor_u = clamp(f32(xpos) / f32(win_w), 0, 1)
		cursor_v = clamp(f32(ypos) / f32(win_h), 0, 1)
	}

	fb_w, fb_h := glfw.GetFramebufferSize(self.handle)
	fb_valid := fb_w > 0 && fb_h > 0
	changed := sync.atomic_load(&self.input_fb_valid) &&
		(fb_w != sync.atomic_load(&self.input_fb_width) || fb_h != sync.atomic_load(&self.input_fb_height))

	sync.atomic_store(&self.input_keys, keys)
	sync.atomic_store(&self.input_mouse_down, mouse_down)
	sync.atomic_store(&self.input_cursor_u, cursor_u)
	sync.atomic_store(&self.input_cursor_v, cursor_v)
	sync.atomic_store(&self.input_fb_width, fb_w)
	sync.atomic_store(&self.input_fb_height, fb_h)
	// Publish validity last so the payload is visible before it.
	sync.atomic_store(&self.input_fb_valid, fb_valid)
	// Signal the swapchain after the new size is visible; the GLFW callback may
	// have set this before the snapshot was refreshed, in which case the flag is
	// set again here so the recreate never reads a stale size.
	if changed {sync.atomic_store(&self.framebuffer_resized, true)}
}

// window_input_snapshot returns a consistent-enough copy for one frame. Each
// field is atomic, so a tear across fields only ever mixes two adjacent pumps.
@(private)
window_input_snapshot :: proc(self: ^Window) -> Input_State {
	return Input_State{
		keys = sync.atomic_load(&self.input_keys),
		mouse_down = sync.atomic_load(&self.input_mouse_down),
		cursor_u = sync.atomic_load(&self.input_cursor_u),
		cursor_v = sync.atomic_load(&self.input_cursor_v),
		fb_width = sync.atomic_load(&self.input_fb_width),
		fb_height = sync.atomic_load(&self.input_fb_height),
		fb_valid = sync.atomic_load(&self.input_fb_valid),
	}
}

// Cached framebuffer size and validity, as last published by `window_pump`. The
// graphics thread uses these instead of querying GLFW.
@(private)
window_framebuffer_size :: proc(self: ^Window) -> (i32, i32) {
	return sync.atomic_load(&self.input_fb_width), sync.atomic_load(&self.input_fb_height)
}

@(private)
window_framebuffer_valid :: proc(self: ^Window) -> bool {
	return sync.atomic_load(&self.input_fb_valid)
}

@(private) window_create_surface :: proc(self: ^Window, instance: vulkan.Instance) -> bool {
	log.debugf("[VULKAN] Creating window surface...")
	if !vk_check(glfw.CreateWindowSurface(instance, self.handle, nil, &self.surface), "glfwCreateWindowSurface") {return false}
	log.debugf("[VULKAN]   Surface created")
	return true
}
