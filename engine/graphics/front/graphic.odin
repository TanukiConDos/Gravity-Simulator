package graphic

import gfx "engine:graphics/shared"

// Front-end vocabulary. The plain structs that cross into the backend live in
// `shared/gfx.odin`; this file only holds the ECS resources the front owns and
// the aliases that keep its code readable.

Vec3 :: gfx.Vec3

// Stored as a world resource so the input system can reach the window's
// published input snapshot without the scheduler carrying a context pointer.
// `input` points into the backend `Window` (owned by main) and is cleared when
// the renderer is destroyed.
Window_Ref :: struct {
	input: ^gfx.Input_State,
}

// Stored as a world resource so the RENDER-phase render system can reach the
// renderer. The front owns this handle and clears it on destruction.
Renderer_Ref :: struct {
	renderer: ^Renderer,
}

// Set by the input system on a left-button press edge and consumed by
// renderer_draw_frame in the same phase, so it needs no locking. `u`/`v` are
// normalised window coordinates; the backend maps them to framebuffer pixels,
// which keeps window scaling out of this code. `prev_down` is front-only edge
// state; the backend sees only the per-frame `gfx.Pick_Request`.
Pick_Request :: struct {
	requested: bool,
	prev_down: bool,
	u:         f32,
	v:         f32,
}
