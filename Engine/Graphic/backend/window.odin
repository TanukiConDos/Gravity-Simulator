package vk

import gfx "../shared"
import "core:log"
import "base:runtime"
import "core:sync"
import "vendor:glfw"
import "vendor:vulkan"

// Window owns the GLFW window and the Vulkan surface created from it. GLFW is
// not thread-safe: `window_pump` runs on the main thread and publishes the
// input snapshot the render phase reads.
Window :: struct {
	handle:              glfw.WindowHandle,
	framebuffer_resized: bool,
	surface:             vulkan.SurfaceKHR,
	glfw_initialized:    bool,
	// Published by `window_pump` on the main thread and read by the graphics
	// thread. Each field is atomic: the writer owns all of them, the reader has
	// no ordering requirement between the cursor and the size beyond what a
	// single frame needs. `fb_valid` is stored last so a reader that sees `true`
	// also sees a complete framebuffer size.
	input:               gfx.Input_State,
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
// where it is legal. The graphics thread reads `Window.input` instead.
window_pump :: proc(self: ^Window) {
	if self == nil || self.handle == nil {return}

	keys: u32
	if glfw.GetKey(self.handle, glfw.KEY_W) == glfw.PRESS {keys |= gfx.INPUT_KEY_W}
	if glfw.GetKey(self.handle, glfw.KEY_S) == glfw.PRESS {keys |= gfx.INPUT_KEY_S}
	if glfw.GetKey(self.handle, glfw.KEY_A) == glfw.PRESS {keys |= gfx.INPUT_KEY_A}
	if glfw.GetKey(self.handle, glfw.KEY_D) == glfw.PRESS {keys |= gfx.INPUT_KEY_D}
	if glfw.GetKey(self.handle, glfw.KEY_Q) == glfw.PRESS {keys |= gfx.INPUT_KEY_Q}
	if glfw.GetKey(self.handle, glfw.KEY_E) == glfw.PRESS {keys |= gfx.INPUT_KEY_E}
	if glfw.GetKey(self.handle, glfw.KEY_UP) == glfw.PRESS {keys |= gfx.INPUT_KEY_UP}
	if glfw.GetKey(self.handle, glfw.KEY_DOWN) == glfw.PRESS {keys |= gfx.INPUT_KEY_DOWN}
	if glfw.GetKey(self.handle, glfw.KEY_LEFT) == glfw.PRESS {keys |= gfx.INPUT_KEY_LEFT}
	if glfw.GetKey(self.handle, glfw.KEY_RIGHT) == glfw.PRESS {keys |= gfx.INPUT_KEY_RIGHT}

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
	changed := sync.atomic_load(&self.input.fb_valid) &&
		(fb_w != sync.atomic_load(&self.input.fb_width) || fb_h != sync.atomic_load(&self.input.fb_height))

	sync.atomic_store(&self.input.keys, keys)
	sync.atomic_store(&self.input.mouse_down, mouse_down)
	sync.atomic_store(&self.input.cursor_u, cursor_u)
	sync.atomic_store(&self.input.cursor_v, cursor_v)
	sync.atomic_store(&self.input.fb_width, fb_w)
	sync.atomic_store(&self.input.fb_height, fb_h)
	// Publish validity last so the payload is visible before it.
	sync.atomic_store(&self.input.fb_valid, fb_valid)
	// Signal the swapchain after the new size is visible; the GLFW callback may
	// have set this before the snapshot was refreshed, in which case the flag is
	// set again here so the recreate never reads a stale size.
	if changed {sync.atomic_store(&self.framebuffer_resized, true)}
}

// Cached framebuffer size and validity, as last published by `window_pump`. The
// graphics thread uses these instead of querying GLFW.
window_framebuffer_size :: proc(self: ^Window) -> (i32, i32) {
	return sync.atomic_load(&self.input.fb_width), sync.atomic_load(&self.input.fb_height)
}

@(private)
window_framebuffer_valid :: proc(self: ^Window) -> bool {
	return sync.atomic_load(&self.input.fb_valid)
}

@(private) window_create_surface :: proc(self: ^Window, instance: vulkan.Instance) -> bool {
	log.debugf("[VULKAN] Creating window surface...")
	if !vk_check(glfw.CreateWindowSurface(instance, self.handle, nil, &self.surface), "glfwCreateWindowSurface") {return false}
	log.debugf("[VULKAN]   Surface created")
	return true
}
