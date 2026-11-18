// Package gfx holds the plain data that crosses the front/backend seam. It
// imports nothing: no Vulkan, no ECS, no GLFW. The front (`graphic`) builds a
// Frame_Packet from it and the backend (`vk`) consumes it, so neither package
// has to know the other's implementation types.
package gfx

Vec3 :: [3]f32

// Camera_Uniforms is the camera block both sides agree on: the front computes
// it from its Camera, the backend uploads it. 128 bytes, aligned for std140.
Camera_Uniforms :: struct #align(16) {
	view: matrix[4, 4]f32,
	proj: matrix[4, 4]f32,
}

#assert(size_of(Camera_Uniforms) == 128)

// A drawable mesh. Today the backend owns one generated sphere; the handle keeps
// the front's draw list independent of how the mesh is stored.
Mesh_Handle :: distinct u32

MESH_PRIMARY :: Mesh_Handle(1)

// Which side produces this frame's instance data. The backend reports BACKEND
// while a GPU gravity solver owns the world (its compute pass packs the vertex
// buffer); otherwise the front uploads its CPU columns.
Instance_Mode :: enum {
	CPU,
	BACKEND,
}

// A main-thread snapshot of the GLFW state the render phase needs. GLFW is not
// thread-safe, so `vk.window_pump` publishes this and the front only reads it.
// `cursor_u`/`cursor_v` are normalised window coordinates.
Input_State :: struct {
	keys:       u32,
	mouse_down: bool,
	cursor_u:   f32,
	cursor_v:   f32,
	fb_width:   i32,
	fb_height:  i32,
	fb_valid:   bool, // false while minimized (0x0 framebuffer)
}

// Bit flags in `Input_State.keys`.
INPUT_KEY_W     :: u32(1 << 0)
INPUT_KEY_S     :: u32(1 << 1)
INPUT_KEY_A     :: u32(1 << 2)
INPUT_KEY_D     :: u32(1 << 3)
INPUT_KEY_Q     :: u32(1 << 4)
INPUT_KEY_E     :: u32(1 << 5)
INPUT_KEY_UP    :: u32(1 << 6)
INPUT_KEY_DOWN  :: u32(1 << 7)
INPUT_KEY_LEFT  :: u32(1 << 8)
INPUT_KEY_RIGHT :: u32(1 << 9)

// A pick request for one frame. The front maps the click edge into this; the
// backend maps u/v to framebuffer pixels and reads the ID back.
Pick_Request :: struct {
	requested: bool,
	u:         f32,
	v:         f32,
}

// One instanced draw. `positions`/`selected` are the frame's CPU columns in
// draw-slot order (phys.physic_snapshot_read packs them); they are empty when
// the backend draws from its own GPU instance stream.
Draw :: struct {
	mesh:      Mesh_Handle,
	material:  string,
	positions: []Vec3,
	selected:  []u8,
}

Frame_Packet :: struct {
	camera: Camera_Uniforms,
	draws:  []Draw,
	pick:   Pick_Request,
}

// RETRY covers frames that were not submitted (resize, minimized window,
// out-of-date swapchain): the front keeps its state and calls again. A retry
// never consumes a frame slot or the pick request.
Frame_Status :: enum {
	OK,
	RETRY,
	FATAL,
}

// A pick resolved from a readback whose frame has completed. `picked` is -1
// when the copied pixel was empty (nothing hit).
Frame_Result :: struct {
	picked:   i32,
	has_pick: bool,
}
