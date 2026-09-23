package graphic

import ecs "../ecs"
import "vendor:glfw"

@(private)
MOVE_SPEED   :: 500.0
@(private)
ROTATE_SPEED :: 1.0

// Set on the graphics thread by the input system on a left-button press and
// consumed by renderer_draw_frame in the same thread, so it needs no locking.
// `u`/`v` are normalised window coordinates; the renderer maps them to
// framebuffer pixels, which keeps window scaling out of this code.
@(private)
Pick_Request :: struct {
	requested: bool,
	prev_down: bool,
	u:         f32,
	v:         f32,
}

// RENDER-phase system: updates the Camera resource from the keyboard. It runs on
// the graphics thread, which is also where the window events are polled.
@(private)
input_system :: proc(w: ^ecs.World, delta_seconds: f32) {
	ref := ecs.world_resource(w, Window_Ref)
	if ref.window == nil {return}
	cam := ecs.world_resource(w, Camera)
	input_poll(ref.window, cam, delta_seconds)
	_input_pick(w, ref.window)
}

// Edge-triggered: a pick is requested only on the press, so the readback never
// stalls the graphics thread for every frame the button is held.
@(private)
_input_pick :: proc(w: ^ecs.World, window: ^Window) {
	req := ecs.world_resource(w, Pick_Request)
	down := glfw.GetMouseButton(window.handle, glfw.MOUSE_BUTTON_LEFT) == glfw.PRESS
	if down && !req.prev_down {
		xpos, ypos := glfw.GetCursorPos(window.handle)
		width, height := glfw.GetWindowSize(window.handle)
		if width > 0 && height > 0 {
			req.u = clamp(f32(xpos) / f32(width), 0, 1)
			req.v = clamp(f32(ypos) / f32(height), 0, 1)
			req.requested = true
		}
	}
	req.prev_down = down
}

@(private)
input_poll :: proc(w: ^Window, cam: ^Camera, delta_seconds: f32) {
	move := delta_seconds * MOVE_SPEED
	rotate := delta_seconds * ROTATE_SPEED

	if glfw.GetKey(w.handle, glfw.KEY_W) == glfw.PRESS {camera_move_forward(cam, move)}
	if glfw.GetKey(w.handle, glfw.KEY_S) == glfw.PRESS {camera_move_backward(cam, move)}
	if glfw.GetKey(w.handle, glfw.KEY_A) == glfw.PRESS {camera_move_left(cam, move)}
	if glfw.GetKey(w.handle, glfw.KEY_D) == glfw.PRESS {camera_move_right(cam, move)}
	if glfw.GetKey(w.handle, glfw.KEY_Q) == glfw.PRESS {camera_move_down(cam, move)}
	if glfw.GetKey(w.handle, glfw.KEY_E) == glfw.PRESS {camera_move_up(cam, move)}

	if glfw.GetKey(w.handle, glfw.KEY_UP) == glfw.PRESS {camera_rotate_pitch(cam, rotate)}
	if glfw.GetKey(w.handle, glfw.KEY_DOWN) == glfw.PRESS {camera_rotate_pitch(cam, -rotate)}
	if glfw.GetKey(w.handle, glfw.KEY_LEFT) == glfw.PRESS {camera_rotate_yaw(cam, -rotate)}
	if glfw.GetKey(w.handle, glfw.KEY_RIGHT) == glfw.PRESS {camera_rotate_yaw(cam, rotate)}
}
